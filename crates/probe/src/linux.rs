use super::*;
use curl::{
    easy::{Easy2, Handler, IpResolve, List, ProxyType, WriteError},
    multi::Multi,
};
use socket2::{Domain, Protocol, Socket, Type};
use std::{os::fd::IntoRawFd, time::Instant};

const HEADER_LIMIT: usize = 8192;
struct Capture {
    interface: Option<String>,
    body: Vec<u8>,
    limit: usize,
    headers: usize,
    failure: Option<Reason>,
}
impl Handler for Capture {
    fn open_socket(&mut self, family: i32, kind: i32, protocol: i32) -> Option<i32> {
        if Domain::from(family) != Domain::IPV4
            || Type::from(kind) != Type::STREAM
            || Protocol::from(protocol) != Protocol::TCP
        {
            self.failure = Some(Reason::Binding);
            return None;
        }
        let socket = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).ok()?;
        if let Some(interface) = &self.interface {
            if socket.bind_device(Some(interface.as_bytes())).is_err() {
                self.failure = Some(Reason::Binding);
                return None; // Never pass an unbound socket to libcurl.
            }
        }
        Some(socket.into_raw_fd()) // Ownership transfers to libcurl, including errors.
    }
    fn write(&mut self, data: &[u8]) -> Result<usize, WriteError> {
        if data.len() > self.limit.saturating_sub(self.body.len()) {
            self.failure = Some(Reason::ResponseLimit);
            return Ok(0);
        }
        self.body.extend_from_slice(data);
        Ok(data.len())
    }
    fn header(&mut self, data: &[u8]) -> bool {
        if data.len() > HEADER_LIMIT.saturating_sub(self.headers) {
            self.failure = Some(Reason::ResponseLimit);
            return false;
        }
        self.headers += data.len();
        true
    }
}

fn configured(
    path: &CandidatePath,
    control: &Control,
    limits: Limits,
    ca_file: Option<&std::path::Path>,
) -> Result<Easy2<Capture>, curl::Error> {
    let mut easy = Easy2::new(Capture {
        interface: match path {
            CandidatePath::Native(p) => Some(p.0.clone()),
            _ => None,
        },
        body: Vec::with_capacity(limits.response_bytes),
        limit: limits.response_bytes,
        headers: 0,
        failure: None,
    });
    let scheme = match control.scheme {
        Scheme::Http => "http",
        Scheme::Https => "https",
    };
    easy.url(&format!(
        "{scheme}://{}:{}{}",
        control.host, control.port, control.path
    ))?;
    easy.follow_location(false)?;
    easy.max_redirections(0)?;
    easy.ssl_verify_peer(true)?;
    easy.ssl_verify_host(true)?;
    if let Some(path) = ca_file {
        easy.cainfo(path)?;
    }
    easy.ip_resolve(IpResolve::V4)?;
    easy.timeout(limits.timeout)?;
    easy.connect_timeout(limits.timeout)?;
    easy.buffer_size(1024)?;
    easy.fresh_connect(true)?;
    easy.forbid_reuse(true)?;
    // No curlrc, cookie jar, netrc, HSTS file, raw diagnostics, decompression or retries.
    match path {
        CandidatePath::Native(_) => {
            easy.proxy("")?; // Disable all ambient proxy environment variables.
            let mut resolve = List::new();
            resolve.append(&format!(
                "{}:{}:{}",
                control.host, control.port, control.resolved
            ))?;
            easy.resolve(resolve)?; // No unbound host DNS lookup.
        }
        CandidatePath::Socks(endpoint) | CandidatePath::NaiveProxy(endpoint) => {
            easy.proxy(&endpoint.to_string())?;
            easy.proxy_type(ProxyType::Socks5Hostname)?;
            easy.noproxy("")?; // Even NO_PROXY=* cannot bypass the candidate.
        }
    }
    Ok(easy)
}

fn classify(error: &curl::Error) -> Reason {
    match error.code() {
        5 | 6 => Reason::Dns,
        28 => Reason::Timeout,
        60 | 77 | 82 | 83 => Reason::Ca,
        35 | 53 | 54 | 58 | 59 | 64 | 66 | 80 => Reason::Tls,
        67 => Reason::Authentication,
        // SOCKS failures share CURLE_PROXY. Only explicit libcurl auth diagnostics
        // are classified further. The fixed CURL_ERROR_SIZE buffer is never exported.
        97 if error.extra_description().is_some_and(|s| {
            s.contains("User was rejected by the SOCKS5 server")
                || s.contains("No authentication method was acceptable")
        }) =>
        {
            Reason::Authentication
        }
        _ => Reason::Transport,
    }
}

fn response(control: &Control, status: u32, body: &[u8]) -> Result<(), Reason> {
    match control.expected {
        Expected::EmptyStatus(expected) if status == u32::from(expected) && body.is_empty() => {
            Ok(())
        }
        Expected::Address(expected) if status == 200 => {
            let text = std::str::from_utf8(body)
                .map_err(|_| Reason::UnexpectedResponse)?
                .trim();
            let address: Ipv4Addr = text.parse().map_err(|_| Reason::UnexpectedResponse)?;
            if address == expected {
                Ok(())
            } else {
                Err(Reason::AddressMismatch)
            }
        }
        _ => Err(Reason::UnexpectedResponse),
    }
}

pub(super) fn run(
    path: &CandidatePath,
    control: &Control,
    limits: Limits,
    cancel: &Cancellation,
    ca_file: Option<&std::path::Path>,
) -> Outcome {
    let start = Instant::now();
    // libcurl may open this file in its pre-main constructor. Refuse all network
    // I/O here; the daemon launcher must remove the variable before exec.
    if std::env::var_os("SSLKEYLOGFILE").is_some() {
        return Outcome::Skipped(Skipped::PlatformUnavailable);
    }
    // Refuse blocking resolver/TLS-less builds; configuration never silently
    // downgrades HTTPS. No network library version or raw error enters reports.
    let version = curl::Version::get();
    if !version.feature_async_dns()
        || (matches!(control.scheme, Scheme::Https) && !version.feature_ssl())
    {
        return Outcome::Skipped(Skipped::PlatformUnavailable);
    }
    let easy = match configured(path, control, limits, ca_file) {
        Ok(easy) => easy,
        Err(_) => return Outcome::Skipped(Skipped::PlatformUnavailable),
    };
    let multi = Multi::new();
    let handle = match multi.add2(easy) {
        Ok(handle) => handle,
        Err(_) => return Outcome::Skipped(Skipped::PlatformUnavailable),
    };
    loop {
        if cancel.is_cancelled() {
            return Outcome::Skipped(Skipped::Cancelled);
        }
        if start.elapsed() >= limits.timeout {
            return Outcome::Failed(Reason::Timeout);
        }
        if multi.perform().is_err() {
            return Outcome::Failed(Reason::Transport);
        }
        let mut completed = None;
        multi.messages(|message| {
            if let Some(result) = message.result_for2(&handle) {
                completed = Some(result);
            }
        });
        if let Some(result) = completed {
            // Cancellation wins even when the response and cancellation race.
            if cancel.is_cancelled() {
                return Outcome::Skipped(Skipped::Cancelled);
            }
            if start.elapsed() >= limits.timeout {
                return Outcome::Failed(Reason::Timeout);
            }
            let easy = match multi.remove2(handle) {
                Ok(easy) => easy,
                Err(_) => return Outcome::Failed(Reason::Transport),
            };
            if let Some(reason) = easy.get_ref().failure {
                return Outcome::Failed(reason);
            }
            if let Err(error) = result {
                return Outcome::Failed(classify(&error));
            }
            let status = match easy.response_code() {
                Ok(status) => status,
                Err(_) => return Outcome::Failed(Reason::UnexpectedResponse),
            };
            return match response(control, status, &easy.get_ref().body) {
                Ok(()) => Outcome::Success {
                    latency_ms: start.elapsed().as_millis().min(u32::MAX as u128) as u32,
                },
                Err(reason) => Outcome::Failed(reason),
            };
        }
        // Multi uses nonblocking sockets. No worker threads or unbounded queue;
        // dropping the handle on timeout/cancel removes and closes the transfer.
        let wait = Duration::from_millis(10).min(limits.timeout.saturating_sub(start.elapsed()));
        if multi.wait(&mut [], wait).is_err() {
            return Outcome::Failed(Reason::Transport);
        }
        // curl_multi_wait can return immediately when it has no fd (e.g. resolver).
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn closed_error_classification() {
        for (code, reason) in [
            (5, Reason::Dns),
            (6, Reason::Dns),
            (28, Reason::Timeout),
            (35, Reason::Tls),
            (60, Reason::Ca),
            (77, Reason::Ca),
            (67, Reason::Authentication),
            (7, Reason::Transport),
            (97, Reason::Transport),
        ] {
            assert_eq!(classify(&curl::Error::new(code)), reason);
        }
    }
}
