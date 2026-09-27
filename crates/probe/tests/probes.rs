#![cfg(target_os = "linux")]
use mors_domain::{
    health::{ProbeEndpoint, ProbeResult},
    Transport,
};
use mors_probe::*;
use std::{
    io::{BufRead, BufReader, Write},
    net::{Ipv4Addr, SocketAddrV4},
    process::{Child, Command, Stdio},
    sync::Arc,
    time::{Duration, Instant},
};

struct Fixture {
    child: Child,
    output: BufReader<std::process::ChildStdout>,
    data: serde_json::Value,
}
impl Fixture {
    fn new(mode: &str) -> Self {
        let mut child = Command::new("python3")
            .args([
                concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fixture.py"),
                mode,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        let data = serde_json::from_str(&line).expect("fixture startup");
        Self {
            child,
            output,
            data,
        }
    }
    fn port(&self, key: &str) -> u16 {
        self.data[key].as_u64().unwrap() as u16
    }
    fn path(&self, naive: bool) -> CandidatePath {
        let endpoint = SocketAddrV4::new(Ipv4Addr::LOCALHOST, self.port("socks"));
        if naive {
            CandidatePath::NaiveProxy(endpoint)
        } else {
            CandidatePath::Socks(endpoint)
        }
    }
    fn control(&self, scheme: Scheme, path: &str) -> Control {
        Control::new(
            scheme,
            "probe.invalid",
            self.port(if matches!(scheme, Scheme::Http) {
                "http"
            } else {
                "https"
            }),
            path,
            Ipv4Addr::LOCALHOST,
            Expected::Address(Ipv4Addr::new(203, 0, 113, 9)),
        )
        .unwrap()
    }
    fn runner(&self, limits: Limits) -> Runner {
        Runner::new(limits)
            .unwrap()
            .with_ca_file(self.data["ca"].as_str().unwrap().into())
            .unwrap()
    }
    fn stats(&mut self) -> serde_json::Value {
        writeln!(self.child.stdin.as_mut().unwrap(), "stats").unwrap();
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.child.stdin.take();
        self.child.wait().unwrap();
    }
}
fn ticket() -> Ticket {
    Ticket {
        generation: 7,
        sequence: 8,
        endpoint: ProbeEndpoint::Primary,
    }
}
fn probe(runner: &Runner, path: &CandidatePath, control: &Control) -> Outcome {
    runner
        .candidate(
            path,
            control,
            Transport::Tcp,
            ticket(),
            &Cancellation::default(),
        )
        .outcome
}
fn success(outcome: Outcome) {
    assert!(matches!(outcome, Outcome::Success { .. }), "{outcome:?}");
}

#[test]
fn native_binding_cannot_fall_back_to_healthy_default() {
    let mut f = Fixture::new("good");
    let r = f.runner(Limits {
        timeout: Duration::from_millis(250),
        ..Limits::default()
    });
    let control = f.control(Scheme::Http, "/ip");
    success(probe(
        &r,
        &CandidatePath::Native(NativePath::new("lo").unwrap()),
        &control,
    ));
    assert_eq!(
        probe(
            &r,
            &CandidatePath::Native(NativePath::new("mors_missing").unwrap()),
            &control
        ),
        Outcome::Failed(Reason::Binding)
    );
    // Existing non-loopback device must not reach an origin reachable over lo.
    assert!(!matches!(
        probe(
            &r,
            &CandidatePath::Native(NativePath::new("eth0").unwrap()),
            &control
        ),
        Outcome::Success { .. }
    ));
    assert_eq!(f.stats()["requests"], 1);
}

#[test]
fn socks_connect_uses_remote_dns_despite_no_proxy_environment() {
    let mut f = Fixture::new("good");
    let r = f.runner(Limits::default());
    success(probe(&r, &f.path(false), &f.control(Scheme::Http, "/ip")));
    success(probe(&r, &f.path(true), &f.control(Scheme::Https, "/ip")));
    let stats = f.stats();
    assert_eq!(stats["connects"], 2);
    assert_eq!(stats["command"], 1);
    assert_eq!(stats["host"], "probe.invalid");
}

#[test]
fn failed_candidate_cannot_borrow_upstream_success() {
    let mut f = Fixture::new("reject");
    let r = f.runner(Limits::default());
    let control = f.control(Scheme::Https, "/ip");
    assert_eq!(
        probe(&r, &f.path(true), &control),
        Outcome::Failed(Reason::Transport)
    );
    success(
        r.upstream(
            NativePath::new("lo").unwrap(),
            &control,
            &Cancellation::default(),
        )
        .outcome,
    );
    assert_eq!(f.stats()["requests"], 1);
}

#[test]
fn controls_classify_tls_ca_auth_and_validate_address() {
    let f = Fixture::new("good");
    let r = f.runner(Limits::default());
    assert_eq!(
        probe(
            &Runner::new(Limits::default()).unwrap(),
            &f.path(true),
            &f.control(Scheme::Https, "/ip")
        ),
        Outcome::Failed(Reason::Ca)
    );
    let missing_ca = Runner::new(Limits::default())
        .unwrap()
        .with_ca_file("/mors-missing-ca-file.pem".into())
        .unwrap();
    assert_eq!(
        probe(&missing_ca, &f.path(true), &f.control(Scheme::Https, "/ip")),
        Outcome::Failed(Reason::Ca)
    );
    let wrong_host = Control::new(
        Scheme::Https,
        "wrong.invalid",
        f.port("https"),
        "/ip",
        Ipv4Addr::LOCALHOST,
        Expected::Address(Ipv4Addr::new(203, 0, 113, 9)),
    )
    .unwrap();
    assert_eq!(
        probe(&r, &f.path(true), &wrong_host),
        Outcome::Failed(Reason::Ca)
    );
    let wrong_tls = Control::new(
        Scheme::Https,
        "probe.invalid",
        f.port("http"),
        "/ip",
        Ipv4Addr::LOCALHOST,
        Expected::Address(Ipv4Addr::new(203, 0, 113, 9)),
    )
    .unwrap();
    assert_eq!(
        probe(&r, &f.path(true), &wrong_tls),
        Outcome::Failed(Reason::Tls)
    );
    assert_eq!(
        probe(&r, &f.path(true), &f.control(Scheme::Https, "/wrong")),
        Outcome::Failed(Reason::AddressMismatch)
    );
    let auth = Fixture::new("auth");
    assert_eq!(
        probe(
            &auth.runner(Limits::default()),
            &auth.path(true),
            &auth.control(Scheme::Https, "/ip")
        ),
        Outcome::Failed(Reason::Authentication)
    );
}

#[test]
fn endpoint_failure_and_limits_do_not_redirect_or_export_data() {
    let mut f = Fixture::new("good");
    let r = f.runner(Limits::default());
    for (path, reason) in [
        ("/bad", Reason::UnexpectedResponse),
        ("/redirect", Reason::UnexpectedResponse),
        ("/large", Reason::ResponseLimit),
        ("/chunked", Reason::ResponseLimit),
        ("/headers", Reason::ResponseLimit),
    ] {
        let report = r.candidate(
            &f.path(true),
            &f.control(Scheme::Https, path),
            Transport::Tcp,
            Ticket {
                endpoint: ProbeEndpoint::Confirmation,
                ..ticket()
            },
            &Cancellation::default(),
        );
        assert_eq!(report.outcome, Outcome::Failed(reason));
        assert_eq!(
            report.observation(100).unwrap().endpoint,
            ProbeEndpoint::Confirmation
        );
        let exported = format!("{report:?}");
        for sensitive in ["probe.invalid", "203.0.113", "127.0.0.1", path, "BEGIN"] {
            assert!(!exported.contains(sensitive));
        }
    }
    assert_eq!(f.stats()["requests"], 5);
    let status = Control::new(
        Scheme::Http,
        "probe.invalid",
        f.port("http"),
        "/status",
        Ipv4Addr::LOCALHOST,
        Expected::EmptyStatus(204),
    )
    .unwrap();
    success(probe(&r, &f.path(false), &status));
}

#[test]
fn unsupported_udp_and_pre_cancel_do_not_create_connections() {
    let mut f = Fixture::new("good");
    let r = f.runner(Limits::default());
    let control = f.control(Scheme::Https, "/ip");
    let report = r.candidate(
        &f.path(true),
        &control,
        Transport::Udp,
        ticket(),
        &Cancellation::default(),
    );
    assert_eq!(
        report.outcome,
        Outcome::Skipped(Skipped::UnsupportedTransport)
    );
    assert_eq!(
        report.observation(42).unwrap().result,
        ProbeResult::Unsupported
    );
    assert_eq!(
        r.candidate(
            &f.path(false),
            &control,
            Transport::Udp,
            ticket(),
            &Cancellation::default()
        )
        .outcome,
        Outcome::Skipped(Skipped::UnimplementedTransport)
    );
    assert_eq!(
        probe(&r, &f.path(true), &f.control(Scheme::Http, "/ip")),
        Outcome::Skipped(Skipped::InvalidRequest)
    );
    let cancel = Cancellation::default();
    cancel.cancel();
    let report = r.candidate(&f.path(true), &control, Transport::Tcp, ticket(), &cancel);
    assert_eq!(report.outcome, Outcome::Skipped(Skipped::Cancelled));
    assert_eq!(report.observation(42), None);
    assert_eq!(f.stats()["connects"], 0);
}

#[test]
fn cancellation_timeout_and_backpressure_release_slot() {
    let mut f = Fixture::new("good");
    let runner = Arc::new(f.runner(Limits {
        parallelism: 1,
        timeout: Duration::from_secs(2),
        ..Limits::default()
    }));
    let cancel = Cancellation::default();
    let worker_runner = Arc::clone(&runner);
    let worker_cancel = cancel.clone();
    let path = f.path(true);
    let slow = f.control(Scheme::Https, "/slow");
    let worker = std::thread::spawn(move || {
        worker_runner.candidate(&path, &slow, Transport::Tcp, ticket(), &worker_cancel)
    });
    let started = Instant::now();
    while f.stats()["requests"] != 1 {
        assert!(started.elapsed() < Duration::from_secs(2));
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        probe(&runner, &f.path(true), &f.control(Scheme::Https, "/ip")),
        Outcome::Skipped(Skipped::Busy)
    );
    let stopped = Instant::now();
    cancel.cancel();
    assert_eq!(
        worker.join().unwrap().outcome,
        Outcome::Skipped(Skipped::Cancelled)
    );
    assert!(stopped.elapsed() < Duration::from_millis(500));
    while f.stats()["closed"].as_u64().unwrap() < 1 {
        assert!(
            stopped.elapsed() < Duration::from_millis(500),
            "cancel must close the SOCKS connection"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
    success(probe(
        &runner,
        &f.path(true),
        &f.control(Scheme::Https, "/ip"),
    ));
    let short = f.runner(Limits {
        timeout: Duration::from_millis(100),
        ..Limits::default()
    });
    let started = Instant::now();
    assert_eq!(
        probe(&short, &f.path(true), &f.control(Scheme::Https, "/slow")),
        Outcome::Failed(Reason::Timeout)
    );
    assert!(started.elapsed() < Duration::from_millis(500));
}

#[test]
fn invalid_configuration_is_rejected_before_io() {
    for host in ["", "bad@host", "-bad.invalid", "host\ninvalid"] {
        assert!(Control::new(
            Scheme::Https,
            host,
            443,
            "/ip",
            Ipv4Addr::LOCALHOST,
            Expected::EmptyStatus(204)
        )
        .is_err());
    }
    for interface in ["", "if!lo", "127.0.0.1/32", "this_name_is_too_long"] {
        assert!(NativePath::new(interface).is_err());
    }
    assert!(Runner::new(Limits {
        parallelism: 0,
        ..Limits::default()
    })
    .is_err());
    assert!(Runner::new(Limits {
        response_bytes: usize::MAX,
        ..Limits::default()
    })
    .is_err());
}

#[test]
fn ambient_proxy_environment_cannot_override_paths() {
    for test in [
        "socks_connect_uses_remote_dns_despite_no_proxy_environment",
        "native_binding_cannot_fall_back_to_healthy_default",
    ] {
        let output = Command::new(std::env::current_exe().unwrap())
            .args(["--exact", test])
            .env("NO_PROXY", "*")
            .env("no_proxy", "*")
            .env("ALL_PROXY", "http://127.0.0.1:9")
            .env("http_proxy", "http://127.0.0.1:9")
            .env("HTTPS_PROXY", "http://127.0.0.1:9")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stdout)
        );
    }
}

#[test]
fn upstream_endpoint_failure_does_not_replace_candidate_observation() {
    let f = Fixture::new("good");
    let r = f.runner(Limits::default());
    let report = r.candidate(
        &f.path(true),
        &f.control(Scheme::Https, "/ip"),
        Transport::Tcp,
        ticket(),
        &Cancellation::default(),
    );
    success(report.outcome);
    let observation = report.observation(100).unwrap();
    assert_eq!(
        (
            observation.generation,
            observation.sequence,
            observation.observed_at
        ),
        (7, 8, 100)
    );
    assert_eq!(
        r.upstream(
            NativePath::new("lo").unwrap(),
            &f.control(Scheme::Https, "/bad"),
            &Cancellation::default()
        )
        .outcome,
        Outcome::Failed(Reason::UnexpectedResponse)
    );
    // The pure health machine still rejects a result for an earlier generation.
    let health = mors_domain::health::Health::new(9);
    let (next, reason) = health.observe(
        observation,
        mors_domain::health::ObservationContext {
            now: 100,
            policy: Default::default(),
            probes_enabled: true,
            capability: mors_domain::Capability::Supported,
        },
    );
    assert_eq!(next, health);
    assert_eq!(
        reason,
        mors_domain::health::ObservationReason::WrongGeneration
    );
}

#[test]
fn tls_keylog_environment_blocks_network_and_secret_logging() {
    const MARKER: &str = "MORS_PROBE_TEST_KEYLOG_CHILD";
    if std::env::var_os(MARKER).is_some() {
        let control = Control::new(
            Scheme::Https,
            "probe.invalid",
            443,
            "/ip",
            Ipv4Addr::LOCALHOST,
            Expected::EmptyStatus(204),
        )
        .unwrap();
        let result = probe(
            &Runner::new(Limits::default()).unwrap(),
            &CandidatePath::Native(NativePath::new("lo").unwrap()),
            &control,
        );
        assert_eq!(result, Outcome::Skipped(Skipped::PlatformUnavailable));
        return;
    }
    let output_path =
        std::env::temp_dir().join(format!("mors-probe-keylog-{}.log", std::process::id()));
    assert!(!output_path.exists());
    let status = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "tls_keylog_environment_blocks_network_and_secret_logging",
        ])
        .env(MARKER, "1")
        .env("SSLKEYLOGFILE", &output_path)
        .output()
        .unwrap();
    assert!(status.status.success());
    // libcurl constructor runs before main and may open an empty file.
    // Launchers must remove SSLKEYLOGFILE before exec; no TLS secret is emitted.
    if output_path.exists() {
        assert_eq!(std::fs::metadata(&output_path).unwrap().len(), 0);
        std::fs::remove_file(&output_path).unwrap();
    }
}
