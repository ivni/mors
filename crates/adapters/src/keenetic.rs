//! Read-only Keenetic inventory. Discovery never grants ownership or routing admission.
use serde_json::{Map, Value};
use std::{collections::BTreeSet, io::Read};

pub const MAX_RESPONSE_BYTES: usize = 1024 * 1024;

/// Closed errors intentionally exclude RCI bodies, XML, endpoints and credentials.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Transport,
    Http(u32),
    Semantic,
    Malformed,
    Limit,
    Unavailable,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum State {
    Up,
    Down,
    Unknown,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Connected {
    Yes,
    No,
    Unknown,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Role {
    Unknown,
    Upstream,
    Server,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Disposition {
    /// Protocol family only: client role, egress and explicit adoption still required.
    VpnNeedsValidation,
    Upstream,
    Server,
    ProxyNeedsOwnership,
    OutsideScope,
    Unknown,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Interface {
    pub id: Option<String>,
    pub system_name: Option<String>,
    pub kind: Option<String>,
    pub administrative: State,
    pub link: State,
    pub connected: Connected,
    pub default_gateway: Option<bool>,
    pub global: Option<bool>,
    pub role: Role,
    pub disposition: Disposition,
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Components {
    pub os_version: Option<String>,
    pub names: BTreeSet<String>,
}
impl Components {
    /// Presence in the local installed manifest, not engine readiness or UDP support.
    pub fn contains(&self, name: &str) -> bool {
        self.names.contains(name)
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Inventory {
    pub interfaces: Vec<Interface>,
    /// A missing/unreadable component manifest is not an empty component inventory.
    pub components: Result<Components, Error>,
}

/// Only the fixed read operations required by discovery are exposed.
/// Implementations must not perform writes or reconnect interfaces.
pub trait ReadOnlySource {
    fn interfaces(&mut self) -> Result<(u32, Vec<u8>), Error>;
    fn components(&mut self) -> Result<Vec<u8>, Error>;
}
pub fn discover(source: &mut impl ReadOnlySource) -> Result<Inventory, Error> {
    let (status, body) = source.interfaces()?;
    let interfaces = parse_interfaces(status, &body)?;
    let components = source.components().and_then(|xml| parse_components(&xml));
    Ok(Inventory {
        interfaces,
        components,
    })
}

fn text(map: &Map<String, Value>, key: &str) -> Result<Option<String>, Error> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) if !s.is_empty() => Ok(Some(s.clone())),
        _ => Err(Error::Malformed),
    }
}
fn boolean(map: &Map<String, Value>, key: &str) -> Result<Option<bool>, Error> {
    match map.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        _ => Err(Error::Malformed),
    }
}
fn state(value: Option<&str>) -> State {
    match value {
        Some("up") => State::Up,
        Some("down") => State::Down,
        _ => State::Unknown,
    }
}
fn semantic_error(value: &Value) -> bool {
    match value {
        Value::Object(m) => {
            m.get("status").and_then(Value::as_str) == Some("error")
                || m.get("error")
                    .is_some_and(|v| !v.is_null() && v != &Value::Bool(false))
                || m.values().any(semantic_error)
        }
        Value::Array(a) => a.iter().any(semantic_error),
        _ => false,
    }
}
pub fn parse_interfaces(status: u32, body: &[u8]) -> Result<Vec<Interface>, Error> {
    if !(200..300).contains(&status) {
        return Err(Error::Http(status));
    }
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(Error::Limit);
    }
    let value: Value = serde_json::from_slice(body).map_err(|_| Error::Malformed)?;
    if semantic_error(&value) {
        return Err(Error::Semantic);
    }
    // Known show/interface forms: array and object keyed by interface ID.
    // Keys are not substituted for missing explicit IDs.
    let entries: Vec<_> = match &value {
        Value::Array(a) => a.iter().collect(),
        Value::Object(m) => m.values().collect(),
        _ => return Err(Error::Malformed),
    };
    let mut ids = BTreeSet::new();
    let mut result = Vec::new();
    for entry in entries {
        let m = entry.as_object().ok_or(Error::Malformed)?;
        if !["id", "type", "interface-name", "state", "link"]
            .iter()
            .any(|k| m.contains_key(*k))
        {
            return Err(Error::Malformed);
        }
        let id = text(m, "id")?;
        if let Some(id) = &id {
            if !ids.insert(id.clone()) {
                return Err(Error::Malformed);
            }
        }
        let kind = text(m, "type")?;
        let default_gateway = boolean(m, "defaultgw")?;
        let global = boolean(m, "global")?;
        let (role, disposition) = match kind.as_deref() {
            Some(
                "PPPOE" | "WifiStation" | "Dsl" | "CdcEthernet" | "UsbLte" | "UsbModem" | "UsbQmi",
            ) => (Role::Upstream, Disposition::Upstream),
            // These explicit server types are rejected; ambiguous shared types stay unknown.
            Some(
                "PPTPServer" | "L2TPServer" | "SSTPServer" | "IKEServer" | "OpenConnectServer",
            ) => (Role::Server, Disposition::Server),
            Some("Proxy") => (Role::Unknown, Disposition::ProxyNeedsOwnership),
            Some("OpenVPN") => (Role::Unknown, Disposition::OutsideScope),
            Some("Wireguard" | "IKE" | "SSTP" | "PPTP" | "L2TP" | "OpenConnect") => {
                (Role::Unknown, Disposition::VpnNeedsValidation)
            }
            Some("GigabitEthernet" | "FastEthernet" | "Ethernet" | "Vlan")
                if default_gateway == Some(true) || global == Some(true) =>
            {
                (Role::Upstream, Disposition::Upstream)
            }
            Some(
                "GigabitEthernet" | "FastEthernet" | "Ethernet" | "Vlan" | "Bridge" | "Port"
                | "AccessPoint" | "WifiMaster" | "ZeroTier" | "IPIP" | "GRE" | "EoIP" | "XFRM",
            ) => (Role::Unknown, Disposition::OutsideScope),
            _ => (Role::Unknown, Disposition::Unknown),
        };
        result.push(Interface {
            id,
            system_name: text(m, "interface-name")?,
            kind,
            administrative: state(text(m, "state")?.as_deref()),
            link: state(text(m, "link")?.as_deref()),
            connected: match text(m, "connected")?.as_deref() {
                Some("yes") => Connected::Yes,
                Some("no") => Connected::No,
                _ => Connected::Unknown,
            },
            default_gateway,
            global,
            role,
            disposition,
        });
    }
    Ok(result)
}

pub fn parse_components(body: &[u8]) -> Result<Components, Error> {
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(Error::Limit);
    }
    let xml = std::str::from_utf8(body).map_err(|_| Error::Malformed)?;
    // roxmltree rejects DTD by default; no external entities or network resolution.
    let doc = roxmltree::Document::parse(xml).map_err(|_| Error::Malformed)?;
    let root = doc.root_element();
    if root.tag_name().name() != "components" {
        return Err(Error::Malformed);
    }
    let mut names = BTreeSet::new();
    for component in root.children().filter(|n| n.has_tag_name("component")) {
        let fields: Vec<_> = component
            .children()
            .filter(|n| n.has_tag_name("name"))
            .collect();
        if fields.len() != 1 {
            return Err(Error::Malformed);
        }
        let name = fields[0].text().ok_or(Error::Malformed)?.trim();
        if name.is_empty() || !names.insert(name.to_owned()) {
            return Err(Error::Malformed);
        }
    }
    Ok(Components {
        os_version: root.attribute("version").map(str::to_owned),
        names,
    })
}

/// Fixed loopback HTTP endpoint and fixed installed component manifest.
/// No general RCI command, URL, process execution or mutation API is exposed.
#[cfg(target_os = "linux")]
pub struct LocalKeenetic;
#[cfg(target_os = "linux")]
impl ReadOnlySource for LocalKeenetic {
    fn interfaces(&mut self) -> Result<(u32, Vec<u8>), Error> {
        read_interfaces_http("http://127.0.0.1:79/rci/show/interface")
    }
    fn components(&mut self) -> Result<Vec<u8>, Error> {
        let file = std::fs::File::open("/etc/components.xml").map_err(|_| Error::Unavailable)?;
        read_bounded(file)
    }
}
/// Shared bounded reader, also usable by fixture sources.
pub fn read_bounded(reader: impl Read) -> Result<Vec<u8>, Error> {
    let mut body = Vec::new();
    reader
        .take(MAX_RESPONSE_BYTES as u64 + 1)
        .read_to_end(&mut body)
        .map_err(|_| Error::Unavailable)?;
    if body.len() > MAX_RESPONSE_BYTES {
        return Err(Error::Limit);
    }
    Ok(body)
}

#[cfg(target_os = "linux")]
fn read_interfaces_http(url: &str) -> Result<(u32, Vec<u8>), Error> {
    use std::time::Duration;
    let mut easy = curl::easy::Easy::new();
    easy.url(url).map_err(|_| Error::Transport)?;
    easy.get(true).map_err(|_| Error::Transport)?;
    easy.proxy("").map_err(|_| Error::Transport)?;
    easy.follow_location(false).map_err(|_| Error::Transport)?;
    easy.connect_timeout(Duration::from_secs(2))
        .map_err(|_| Error::Transport)?;
    easy.timeout(Duration::from_secs(5))
        .map_err(|_| Error::Transport)?;
    let mut body = Vec::new();
    let mut limited = false;
    let performed;
    {
        let mut transfer = easy.transfer();
        transfer
            .write_function(|bytes| {
                if body.len().saturating_add(bytes.len()) > MAX_RESPONSE_BYTES {
                    limited = true;
                    return Ok(0);
                }
                body.extend_from_slice(bytes);
                Ok(bytes.len())
            })
            .map_err(|_| Error::Transport)?;
        performed = transfer.perform();
    }
    if limited {
        return Err(Error::Limit);
    }
    performed.map_err(|_| Error::Transport)?;
    Ok((easy.response_code().map_err(|_| Error::Transport)?, body))
}

#[cfg(all(test, target_os = "linux"))]
mod http_tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    fn request(response: Vec<u8>) -> Result<(u32, Vec<u8>), Error> {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/rci/show/interface",
            listener.local_addr().unwrap()
        );
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(std::time::Duration::from_secs(3)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
                assert!(request.len() < 8192);
            }
            let request = String::from_utf8(request).unwrap();
            assert!(request.starts_with("GET /rci/show/interface HTTP/1.1\r\n"));
            assert!(!request.to_ascii_lowercase().contains("content-length:"));
            let _ = stream.write_all(&response);
        });
        let result = read_interfaces_http(&url);
        server.join().unwrap();
        result
    }
    #[test]
    fn transport_is_get_and_keeps_http_status() {
        let (status, body) = request(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 2\r\nConnection: close\r\n\r\n[]".to_vec(),
        )
        .unwrap();
        assert_eq!(parse_interfaces(status, &body), Err(Error::Http(403)));
    }
    #[test]
    fn redirects_are_not_followed() {
        let (status, _) = request(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec()).unwrap();
        assert_eq!(status, 302);
    }
    #[test]
    fn transport_enforces_response_bound_and_truncation() {
        let mut response = format!(
            "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            MAX_RESPONSE_BYTES + 1
        )
        .into_bytes();
        response.extend(vec![b' '; MAX_RESPONSE_BYTES + 1]);
        assert_eq!(request(response), Err(Error::Limit));
        assert_eq!(
            request(
                b"HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\n[]".to_vec()
            ),
            Err(Error::Transport)
        );
    }
}
