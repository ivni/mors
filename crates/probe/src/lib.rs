//! Bounded volatile probes. No route selection, persistence, or backend lifecycle.
//!
//! Linux uses libcurl with freshly opened sockets and mandatory SO_BINDTODEVICE
//! for native paths. All other platforms fail closed. Callers own candidate-to-
//! listener/interface identity and generation leases for the lifetime of a probe.

use mors_domain::{
    health::{Failure, Observation, ProbeEndpoint, ProbeResult, Time},
    Transport,
};
use std::{
    net::{Ipv4Addr, SocketAddrV4},
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};

#[cfg(target_os = "linux")]
mod linux;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Reason {
    Dns,
    Ca,
    Tls,
    Authentication,
    Timeout,
    Transport,
    Binding,
    UnexpectedResponse,
    AddressMismatch,
    ResponseLimit,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Skipped {
    Cancelled,
    Busy,
    UnsupportedTransport,
    UnimplementedTransport,
    PlatformUnavailable,
    InvalidRequest,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Outcome {
    Success { latency_ms: u32 },
    Failed(Reason),
    Skipped(Skipped),
}

impl Outcome {
    /// Cancellation, backpressure and missing implementation are not outages.
    pub fn health_result(self) -> Option<ProbeResult> {
        Some(match self {
            Self::Success { latency_ms } => ProbeResult::Success { latency_ms },
            Self::Skipped(Skipped::UnsupportedTransport) => ProbeResult::Unsupported,
            Self::Skipped(_) => return None,
            Self::Failed(reason) => ProbeResult::Failed(match reason {
                Reason::Dns => Failure::Dns,
                Reason::Ca | Reason::Tls => Failure::Tls,
                Reason::Authentication => Failure::Authentication,
                Reason::Timeout => Failure::Timeout,
                Reason::Binding | Reason::Transport => Failure::Transport,
                Reason::UnexpectedResponse | Reason::AddressMismatch | Reason::ResponseLimit => {
                    Failure::UnexpectedResponse
                }
            }),
        })
    }
}

/// Never contains a URL, address, interface, credential or raw library error.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Ticket {
    pub generation: u64,
    pub sequence: u64,
    pub endpoint: ProbeEndpoint,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct CandidateReport {
    pub ticket: Ticket,
    pub outcome: Outcome,
}
impl CandidateReport {
    /// Supply completion time from the coordinator's monotonic epoch.
    pub fn observation(self, completed_at: Time) -> Option<Observation> {
        Some(Observation {
            generation: self.ticket.generation,
            sequence: self.ticket.sequence,
            endpoint: self.ticket.endpoint,
            observed_at: completed_at,
            result: self.outcome.health_result()?,
        })
    }
}

/// Deliberately has no conversion into a candidate observation. A single failing
/// control endpoint does not establish common upstream outage; #70 owns policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct UpstreamReport {
    pub outcome: Outcome,
}

#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub parallelism: usize,
    pub timeout: Duration,
    pub response_bytes: usize,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            parallelism: 2,
            timeout: Duration::from_secs(10),
            response_bytes: 1024,
        }
    }
}

#[derive(Clone, Copy)]
pub enum Scheme {
    Http,
    Https,
}
#[derive(Clone, Copy)]
pub enum Expected {
    EmptyStatus(u16),
    Address(Ipv4Addr),
}

/// Validated, bounded configuration. Intentionally neither Debug nor Serialize.
/// Native paths require a pre-resolved target; SOCKS sends the hostname to its
/// resolver. Protected DNS discovery is a separate platform admission contract.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub struct Control {
    scheme: Scheme,
    host: String,
    port: u16,
    path: String,
    resolved: Ipv4Addr,
    expected: Expected,
}
impl Control {
    pub fn new(
        scheme: Scheme,
        host: &str,
        port: u16,
        path: &str,
        resolved: Ipv4Addr,
        expected: Expected,
    ) -> Result<Self, Skipped> {
        if host.is_empty()
            || host.len() > 253
            || !host.split('.').all(|label| {
                !label.is_empty()
                    && label.len() <= 63
                    && !label.starts_with('-')
                    && !label.ends_with('-')
                    && label
                        .bytes()
                        .all(|c| c.is_ascii_alphanumeric() || c == b'-')
            })
            || port == 0
            || path.len() > 512
            || !path.starts_with('/')
            || !path
                .bytes()
                .all(|c| c.is_ascii_graphic() && !matches!(c, b'"' | b'\\' | b'#' | b'?' | b'@'))
            || resolved.is_unspecified()
            || resolved.is_multicast()
            || matches!(expected, Expected::EmptyStatus(code) if !(200..300).contains(&code))
        {
            return Err(Skipped::InvalidRequest);
        }
        Ok(Self {
            scheme,
            host: host.into(),
            port,
            path: path.into(),
            resolved,
            expected,
        })
    }
}

/// Exact kernel interface name, not a source IP or a hostname.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub struct NativePath(String);
impl NativePath {
    pub fn new(interface: &str) -> Result<Self, Skipped> {
        if interface.is_empty()
            || interface.len() > 15
            || !interface
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"_.-".contains(&c))
        {
            return Err(Skipped::InvalidRequest);
        }
        Ok(Self(interface.into()))
    }
}

pub enum CandidatePath {
    Native(NativePath),
    Socks(SocketAddrV4),
    NaiveProxy(SocketAddrV4),
}

/// One runner per coordinator, shared by all workers (including upstream).
/// No queue: overload returns Busy without allocating a connection or a thread.
pub struct Runner {
    limits: Limits,
    active: AtomicUsize,
    ca_file: Option<std::path::PathBuf>,
}
impl Runner {
    pub fn new(limits: Limits) -> Result<Self, Skipped> {
        if !(1..=16).contains(&limits.parallelism)
            || limits.timeout < Duration::from_millis(10)
            || limits.timeout > Duration::from_secs(30)
            || !(16..=16384).contains(&limits.response_bytes)
        {
            return Err(Skipped::InvalidRequest);
        }
        Ok(Self {
            limits,
            active: AtomicUsize::new(0),
            ca_file: None,
        })
    }

    /// Explicit trust store, never taken from a probe response or environment variable.
    pub fn with_ca_file(mut self, path: std::path::PathBuf) -> Result<Self, Skipped> {
        if !path.is_absolute() || path.as_os_str().len() > 512 {
            return Err(Skipped::InvalidRequest);
        }
        self.ca_file = Some(path);
        Ok(self)
    }

    pub fn candidate(
        &self,
        path: &CandidatePath,
        control: &Control,
        transport: Transport,
        ticket: Ticket,
        cancel: &Cancellation,
    ) -> CandidateReport {
        let outcome = if transport == Transport::Udp {
            Outcome::Skipped(if matches!(path, CandidatePath::NaiveProxy(_)) {
                Skipped::UnsupportedTransport
            } else {
                Skipped::UnimplementedTransport
            })
        } else if matches!(path, CandidatePath::NaiveProxy(_))
            && !matches!(control.scheme, Scheme::Https)
        {
            Outcome::Skipped(Skipped::InvalidRequest)
        } else {
            self.run(path, control, cancel)
        };
        CandidateReport { ticket, outcome }
    }

    pub fn upstream(
        &self,
        path: NativePath,
        control: &Control,
        cancel: &Cancellation,
    ) -> UpstreamReport {
        UpstreamReport {
            outcome: self.run(&CandidatePath::Native(path), control, cancel),
        }
    }

    fn run(&self, path: &CandidatePath, control: &Control, cancel: &Cancellation) -> Outcome {
        if cancel.is_cancelled() {
            return Outcome::Skipped(Skipped::Cancelled);
        }
        if let CandidatePath::Socks(endpoint) | CandidatePath::NaiveProxy(endpoint) = path {
            // Only managed local listeners; numeric address prevents proxy DNS on WAN.
            if !endpoint.ip().is_loopback() || endpoint.port() == 0 {
                return Outcome::Skipped(Skipped::InvalidRequest);
            }
        }
        if self
            .active
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < self.limits.parallelism).then_some(n + 1)
            })
            .is_err()
        {
            return Outcome::Skipped(Skipped::Busy);
        }
        struct Permit<'a>(&'a AtomicUsize);
        impl Drop for Permit<'_> {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::Release);
            }
        }
        let _permit = Permit(&self.active);
        #[cfg(target_os = "linux")]
        {
            linux::run(path, control, self.limits, cancel, self.ca_file.as_deref())
        }
        #[cfg(not(target_os = "linux"))]
        {
            let _ = (path, control);
            Outcome::Skipped(Skipped::PlatformUnavailable)
        }
    }
}
