//! Alias-addressed RCI writer. No canonical-ID write or automatic alias adoption.
use super::*;
use crate::keenetic::{self, parse_interfaces};
use serde_json::Value;

pub struct LocalNative {
    binding: Owned,
    // Fixed in production. Only unit tests can substitute a loopback fixture.
    base: String,
}
impl LocalNative {
    /// Preparation must have validated the platform alias contract, client
    /// role/egress and installed the alias
    /// with user consent. Discovery/type matching alone must not pass `true`.
    pub fn new(binding: Owned, validated_client: bool) -> Result<Self, Error> {
        if !binding.valid() {
            return Err(Error::Invalid);
        }
        if !validated_client {
            return Err(Error::Unsupported);
        }
        Ok(Self {
            binding,
            base: "http://127.0.0.1:79/rci".into(),
        })
    }
    fn request(&self, path: &str, payload: Option<&[u8]>, until: Instant) -> Result<Value, Error> {
        let reply =
            keenetic::http_request(&format!("{}/{path}", self.base), payload, remaining(until)?);
        remaining_time_check(until)?;
        let (status, bytes) = reply.map_err(|_| Error::Transport)?;
        if !(200..300).contains(&status) {
            return Err(Error::Transport);
        }
        let value: Value = if bytes.is_empty() {
            Value::Null
        } else {
            serde_json::from_slice(&bytes).map_err(|_| Error::Unknown)?
        };
        if keenetic::semantic_error(&value) {
            return Err(Error::Semantic);
        }
        Ok(value)
    }
    fn observed(&mut self, owned: &Owned, until: Instant) -> Result<Observation, Error> {
        if owned != &self.binding {
            return Err(Error::Ownership);
        }
        // Read-only canonical lookup is allowed; never use this path for writes.
        let alias = self
            .request(&format!("interface/{}/rename", owned.id), None, until)
            .map_err(|e| {
                if e == Error::Semantic {
                    Error::Ownership
                } else {
                    e
                }
            })?;
        if alias.as_str() != Some(owned.alias.as_str()) {
            return Err(Error::Ownership);
        }
        let value = self.request("show/interface", None, until)?;
        let bytes = serde_json::to_vec(&value).map_err(|_| Error::Unknown)?;
        let interface = parse_interfaces(200, &bytes)
            .map_err(|_| Error::Unknown)?
            .into_iter()
            .find(|i| i.id.as_deref() == Some(owned.id.as_str()))
            .ok_or(Error::Ownership)?;
        let observed = Observation {
            ownership: Some(owned.clone()),
            interface,
            validated_client: true,
        };
        validate(owned, &observed)?;
        Ok(observed)
    }
}
impl Source for LocalNative {
    fn observe(&mut self, owned: &Owned, timeout: Duration) -> Result<Observation, Error> {
        self.observed(owned, deadline(timeout)?)
    }
    fn set(
        &mut self,
        owned: &Owned,
        before: State,
        action: Action,
        timeout: Duration,
    ) -> Result<(), Error> {
        let until = deadline(timeout)?;
        let observed = self.observed(owned, until)?;
        if before == State::Unknown || observed.interface.administrative != before {
            return Err(Error::StateChanged);
        }
        let payload: &[u8] = match action {
            Action::Up => br#"{"up":true}"#,
            Action::Down => br#"{"down":true}"#,
        };
        self.request(&format!("interface/{}", owned.alias), Some(payload), until)?;
        // Source's acknowledgment is not success: Backend always verifies poststate.
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };
    const ALIAS: &str = "Mors0123456789abcdef0123456789abcdef";
    fn owned() -> Owned {
        Owned {
            id: "PPTP7".into(),
            alias: ALIAS.into(),
            system_name: "ppp7".into(),
            kind: "PPTP".into(),
            owner: 1,
            epoch: 1,
            incarnation: 1,
        }
    }
    fn inventory(up: bool) -> String {
        serde_json::json!([{ "id":"PPTP7", "type":"PPTP", "interface-name":"ppp7", "state":if up {"up"}else{"down"}, "link":if up {"up"}else{"down"}, "connected":if up {"yes"}else{"no"} }]).to_string()
    }
    struct Step {
        method: &'static str,
        path: String,
        request: &'static str,
        status: u16,
        response: String,
    }
    fn alias(value: &str) -> Step {
        Step {
            method: "GET",
            path: "/rci/interface/PPTP7/rename".into(),
            request: "",
            status: 200,
            response: serde_json::to_string(value).unwrap(),
        }
    }
    fn state(up: bool) -> Step {
        Step {
            method: "GET",
            path: "/rci/show/interface".into(),
            request: "",
            status: 200,
            response: inventory(up),
        }
    }
    fn write(action: &'static str, response: &str) -> Step {
        Step {
            method: "POST",
            path: format!("/rci/interface/{ALIAS}"),
            request: action,
            status: 200,
            response: response.into(),
        }
    }
    fn fixture(steps: Vec<Step>) -> (Backend<LocalNative>, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let base = format!("http://{}/rci", listener.local_addr().unwrap());
        let server = thread::spawn(move || {
            for step in steps {
                let until = Instant::now() + Duration::from_secs(5);
                let mut stream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(Instant::now() < until, "missing request");
                            thread::sleep(Duration::from_millis(1));
                        }
                        Err(e) => panic!("{e}"),
                    }
                };
                stream
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut headers = Vec::new();
                let mut b = [0];
                while !headers.ends_with(b"\r\n\r\n") {
                    stream.read_exact(&mut b).unwrap();
                    headers.push(b[0]);
                    assert!(headers.len() < 8192);
                }
                let headers = String::from_utf8(headers).unwrap();
                assert!(headers.starts_with(&format!("{} {} HTTP/1.1\r\n", step.method, step.path)));
                let length = headers
                    .lines()
                    .find_map(|line| {
                        line.to_lowercase()
                            .strip_prefix("content-length:")
                            .map(|v| v.trim().parse::<usize>().unwrap())
                    })
                    .unwrap_or(0);
                assert!(length < 1024);
                let mut body = vec![0; length];
                stream.read_exact(&mut body).unwrap();
                assert_eq!(body, step.request.as_bytes());
                write!(
                    stream,
                    "HTTP/1.1 {} Result\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    step.status,
                    step.response.len(),
                    step.response
                )
                .unwrap();
            }
        });
        let mut source = LocalNative::new(owned(), true).unwrap();
        source.base = base;
        (Backend::new(source, owned()).unwrap(), server)
    }
    #[test]
    fn start_uses_alias_only_and_verifies_observed_effect() {
        let (mut backend, server) = fixture(vec![
            alias(ALIAS),
            state(false),
            alias(ALIAS),
            state(false),
            write(r#"{"up":true}"#, "[]"),
            alias(ALIAS),
            state(true),
        ]);
        assert_eq!(
            backend.start(StartIntent::User, Duration::from_secs(2)),
            Ok(Status::Ready)
        );
        server.join().unwrap();
    }
    #[test]
    fn stop_uses_alias_only_and_verifies_observed_effect() {
        let (mut backend, server) = fixture(vec![
            alias(ALIAS),
            state(true),
            alias(ALIAS),
            state(true),
            write(r#"{"down":true}"#, "[]"),
            alias(ALIAS),
            state(false),
        ]);
        assert_eq!(backend.stop(Duration::from_secs(2)), Ok(Status::Down));
        server.join().unwrap();
    }
    #[test]
    fn stale_alias_after_precheck_never_falls_back_to_canonical_id() {
        let (mut backend, server) = fixture(vec![
            alias(ALIAS),
            state(false),
            alias(ALIAS),
            state(false),
            write(r#"{"up":true}"#, r#"[{"status":"error","code":"6553609"}]"#),
            alias(""),
        ]);
        assert_eq!(
            backend.start(StartIntent::User, Duration::from_secs(2)),
            Err(Error::Semantic)
        );
        server.join().unwrap();
    }
    #[test]
    fn lost_alias_before_write_prevents_post() {
        let (mut backend, server) = fixture(vec![alias(ALIAS), state(false), alias(""), alias("")]);
        assert_eq!(
            backend.start(StartIntent::User, Duration::from_secs(2)),
            Err(Error::Ownership)
        );
        server.join().unwrap();
    }
    #[test]
    fn already_down_and_automatic_down_do_not_post() {
        for automatic in [false, true] {
            let (mut backend, server) = fixture(vec![alias(ALIAS), state(false)]);
            let result = if automatic {
                backend.start(StartIntent::Automatic, Duration::from_secs(2))
            } else {
                backend.stop(Duration::from_secs(2))
            };
            assert_eq!(
                result,
                if automatic {
                    Err(Error::UserDown)
                } else {
                    Ok(Status::Down)
                }
            );
            server.join().unwrap();
        }
    }
    #[test]
    fn foreign_alias_malformed_http_and_semantic_responses_fail_closed() {
        for (status, body, error) in [
            (200, r#""Other""#, Error::Ownership),
            (403, "[]", Error::Transport),
            (200, "{", Error::Unknown),
            (200, r#"[{"status":"error"}]"#, Error::Ownership),
        ] {
            let mut step = alias(ALIAS);
            step.status = status;
            step.response = body.into();
            let (mut backend, server) = fixture(vec![step]);
            assert_eq!(backend.stop(Duration::from_secs(2)), Err(error));
            server.join().unwrap();
        }
    }
    #[test]
    fn copied_alias_is_an_explicit_limit_not_an_incarnation_proof() {
        // An externally copied alias plus identical canonical identity is
        // indistinguishable. Do not claim to detect this scenario via an index.
        let (mut backend, server) = fixture(vec![alias(ALIAS), state(true)]);
        assert_eq!(backend.observe(Duration::from_secs(2)), Ok(Status::Ready));
        server.join().unwrap();
    }
    #[test]
    fn unsafe_alias_cannot_construct_a_writer() {
        for value in [
            "PPTP7",
            "Mors/../../interface",
            "Mors0000000000000000000000000000000?",
            "Mors0123456789ABCDEF0123456789ABCDEF",
        ] {
            let mut binding = owned();
            binding.alias = value.into();
            assert!(matches!(
                LocalNative::new(binding, true),
                Err(Error::Invalid)
            ));
        }
    }
    #[test]
    fn concurrent_admin_change_is_not_misclassified_as_lost_ownership() {
        let (mut backend, server) = fixture(vec![
            alias(ALIAS),
            state(false),
            alias(ALIAS),
            state(true),
            alias(ALIAS),
            state(true),
        ]);
        assert_eq!(
            backend.start(StartIntent::User, Duration::from_secs(2)),
            Err(Error::StateChanged)
        );
        server.join().unwrap();
    }

    #[test]
    fn empty_rename_response_is_missing_ownership() {
        let mut step = alias(ALIAS);
        step.response.clear();
        let (mut backend, server) = fixture(vec![step]);
        assert_eq!(backend.stop(Duration::from_secs(2)), Err(Error::Ownership));
        server.join().unwrap();
    }
}
