//! No filesystem, network, adapter or probe handles enter this module.
use mors_domain::{
    health::{HealthPolicy, HealthState, Time},
    selection::{Candidate, ConnectionId},
    Capability,
};
use std::{
    collections::VecDeque,
    fmt::Write,
    sync::{Arc, RwLock},
    time::{Instant, SystemTime, UNIX_EPOCH},
};

pub const MAX_CONNECTIONS: usize = 128;
pub const MAX_EVENTS: usize = 256;
pub const MAX_RESPONSE_BYTES: usize = 128 * 1024;
pub const SNAPSHOT_TTL_MS: u64 = 90_000;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Lifecycle {
    Unconfigured,
    Starting,
    Ready,
    Paused,
    Changing,
    RecoveryRequired,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Backend {
    NaiveProxy,
    Vless,
    Shadowsocks,
    Native,
}
/// Observed routing result, never inferred from UDP capability or TCP health.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UdpProtection {
    Unknown,
    Blocked,
    Forwarded,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventKind {
    Started,
    LifecycleChanged,
    ActiveChanged,
    HealthChanged,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ReadOperation {
    Handshake,
    Status,
    List,
    Events,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    InvalidFrame,
    Limit,
    Unavailable,
    Clock,
    Overflow,
}

/// Closed fields deliberately exclude names, endpoints, config and raw diagnostics.
#[derive(Clone, Copy, Debug)]
pub struct Connection {
    pub candidate: Candidate,
    pub backend: Backend,
    pub udp_protection: UdpProtection,
    /// Coordinator's monotonic deadline; a reader never schedules this probe.
    pub next_probe_at: Option<Time>,
}

/// One complete coordinator cycle; never publish worker results independently.
#[derive(Clone, Debug)]
pub struct Frame {
    pub config_revision: u64,
    pub observed_generation: u64,
    pub lifecycle: Lifecycle,
    pub active_transaction: Option<u64>,
    pub current_active: Option<ConnectionId>,
    pub preference: Option<ConnectionId>,
    pub policy: HealthPolicy,
    pub connections: Vec<Connection>,
}
impl Frame {
    pub fn starting(preference: Option<ConnectionId>) -> Self {
        Self {
            config_revision: 0,
            observed_generation: 0,
            lifecycle: Lifecycle::Starting,
            active_transaction: None,
            current_active: None,
            preference,
            policy: HealthPolicy::default(),
            connections: Vec::new(),
        }
    }
    fn validate(&self, now: Time) -> Result<(), Error> {
        if self.connections.len() > MAX_CONNECTIONS {
            return Err(Error::Limit);
        }
        if !self.policy.valid() {
            return Err(Error::InvalidFrame);
        }
        for (i, row) in self.connections.iter().enumerate() {
            let c = row.candidate;
            if self.connections[..i].iter().any(|r| r.candidate.id == c.id)
                || c.tcp.generation() != c.generation
                || c.udp.generation() != c.generation
                || [c.tcp.last_observed_at(), c.udp.last_observed_at()]
                    .into_iter()
                    .flatten()
                    .any(|t| t > now)
                || (row.backend == Backend::NaiveProxy
                    && c.udp_capability != Capability::Unsupported)
                || (c.udp_capability == Capability::Unsupported
                    && row.udp_protection == UdpProtection::Forwarded)
            {
                return Err(Error::InvalidFrame);
            }
        }
        if let Some(id) = self.current_active {
            let valid = self.connections.iter().any(|r| {
                let c = r.candidate;
                c.id == id
                    && c.admitted
                    && c.intent.enabled
                    && c.intent.in_pool
                    && !c.draining
                    && c.tcp_capability == Capability::Supported
            });
            if !valid || self.lifecycle != Lifecycle::Ready || self.active_transaction.is_some() {
                return Err(Error::InvalidFrame);
            }
        }
        Ok(())
    }
}

#[derive(Clone, Copy, Debug)]
struct Event {
    sequence: u64,
    at: Time,
    kind: EventKind,
}
#[derive(Clone, Debug)]
struct Snapshot {
    boot_id: [u8; 16],
    sequence: u64,
    observed_at: Time,
    observed_unix_ms: Option<u64>,
    frame: Frame,
    events: VecDeque<Event>,
    dropped_events: u64,
}
struct Shared {
    snapshot: RwLock<Snapshot>,
    origin: Instant,
}
/// Unique, non-cloneable publishing capability. Readers cannot obtain this handle.
pub struct Publisher {
    shared: Arc<Shared>,
}
#[derive(Clone)]
pub struct Reader {
    shared: Arc<Shared>,
}

pub fn channel(boot_id: [u8; 16], preference: Option<ConnectionId>) -> (Publisher, Reader) {
    let shared = Arc::new(Shared {
        origin: Instant::now(),
        snapshot: RwLock::new(Snapshot {
            boot_id,
            sequence: 0,
            observed_at: 0,
            observed_unix_ms: wall_time(),
            frame: Frame::starting(preference),
            events: VecDeque::from([Event {
                sequence: 0,
                at: 0,
                kind: EventKind::Started,
            }]),
            dropped_events: 0,
        }),
    });
    (
        Publisher {
            shared: Arc::clone(&shared),
        },
        Reader { shared },
    )
}
fn wall_time() -> Option<u64> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_millis()
        .try_into()
        .ok()
}
fn now(shared: &Shared) -> Time {
    shared
        .origin
        .elapsed()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}
impl Publisher {
    pub fn now(&self) -> Time {
        now(&self.shared)
    }
    /// Timestamp is captured once per cycle; the whole frame and sequence are
    /// committed under the same publication lock.
    /// The caller has already serialized config/health/routing decisions.
    pub fn publish(&mut self, mut frame: Frame, event: Option<EventKind>) -> Result<u64, Error> {
        let at = self.now();
        frame.validate(at)?;
        // Do not retain arbitrarily oversized caller-owned Vec capacity.
        frame.connections = frame.connections.into_boxed_slice().into_vec();
        let mut s = self
            .shared
            .snapshot
            .write()
            .map_err(|_| Error::Unavailable)?;
        if frame.config_revision < s.frame.config_revision
            || frame.observed_generation < s.frame.observed_generation
        {
            return Err(Error::InvalidFrame);
        }
        let sequence = s.sequence.checked_add(1).ok_or(Error::Overflow)?;
        if let Some(kind) = event {
            if s.events.len() == MAX_EVENTS {
                s.events.pop_front();
                s.dropped_events = s.dropped_events.saturating_add(1);
            }
            s.events.push_back(Event { sequence, at, kind });
        }
        s.frame = frame;
        s.sequence = sequence;
        s.observed_at = at;
        s.observed_unix_ms = wall_time();
        Ok(sequence)
    }
}

fn cap(c: Capability) -> &'static str {
    match c {
        Capability::Supported => "supported",
        Capability::Unsupported => "unsupported",
        Capability::Unknown => "unknown",
    }
}
fn lifecycle(l: Lifecycle) -> &'static str {
    match l {
        Lifecycle::Unconfigured => "unconfigured",
        Lifecycle::Starting => "starting",
        Lifecycle::Ready => "ready",
        Lifecycle::Paused => "paused",
        Lifecycle::Changing => "lifecycle_operation_active",
        Lifecycle::RecoveryRequired => "recovery_required",
    }
}
fn backend(b: Backend) -> &'static str {
    match b {
        Backend::NaiveProxy => "naiveproxy",
        Backend::Vless => "vless",
        Backend::Shadowsocks => "shadowsocks",
        Backend::Native => "native",
    }
}
fn protection(p: UdpProtection) -> &'static str {
    match p {
        UdpProtection::Unknown => "unknown",
        UdpProtection::Blocked => "blocked",
        UdpProtection::Forwarded => "forwarded",
    }
}
fn event_kind(k: EventKind) -> &'static str {
    match k {
        EventKind::Started => "started",
        EventKind::LifecycleChanged => "lifecycle_changed",
        EventKind::ActiveChanged => "active_changed",
        EventKind::HealthChanged => "health_changed",
    }
}
fn number(value: Option<u64>) -> String {
    value.map_or_else(|| "null".into(), |v| v.to_string())
}
fn health(
    h: mors_domain::health::Health,
    capability: Capability,
    at: Time,
    policy: HealthPolicy,
    usable: bool,
) -> &'static str {
    if capability == Capability::Unsupported {
        return "unsupported";
    }
    if capability != Capability::Supported || !usable {
        return "unknown";
    }
    if h.last_observed_at()
        .is_some_and(|t| at.saturating_sub(t) > policy.freshness_ms)
    {
        return "stale";
    }
    match h.state(at, policy) {
        HealthState::Checking => "checking",
        HealthState::Healthy => "healthy",
        HealthState::Unstable => "unstable",
        HealthState::Unavailable => "unavailable",
    }
}

impl Reader {
    pub fn read(&self, op: ReadOperation) -> Result<String, Error> {
        // Capture time after acquiring the lock: a concurrent publisher cannot
        // install a newer timestamp than this response's observation time.
        let s = self
            .shared
            .snapshot
            .read()
            .map_err(|_| Error::Unavailable)?;
        render(&s, op, now(&self.shared))
    }
    /// Deterministic clock input for replay/testing. Never changes shared state.
    pub fn read_at(&self, op: ReadOperation, at: Time) -> Result<String, Error> {
        let s = self
            .shared
            .snapshot
            .read()
            .map_err(|_| Error::Unavailable)?;
        render(&s, op, at)
    }
}

fn render(s: &Snapshot, op: ReadOperation, at: Time) -> Result<String, Error> {
    let age = at.checked_sub(s.observed_at).ok_or(Error::Clock)?;
    if op == ReadOperation::Handshake {
        return Ok("{\"protocol_version\":1,\"operations\":[\"handshake\",\"status\",\"list\",\"events\"]}\n".into());
    }
    let f = &s.frame;
    let usable =
        age <= SNAPSHOT_TTL_MS && f.lifecycle == Lifecycle::Ready && f.active_transaction.is_none();
    let mut out = String::with_capacity(1024);
    let boot = s
        .boot_id
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    // Only bounded numbers and closed string enums are serialized. Never Debug
    // or arbitrary strings; this is an IPC schema, not the eventual CLI schema.
    write!(out, "{{\"protocol_version\":1,\"boot_id\":\"{boot}\",\"sequence\":{},\"config_revision\":{},\"observed_generation\":{},\"observed_at_ms\":{},\"read_at_ms\":{at},\"age_ms\":{age},\"stale\":{},\"lifecycle\":\"{}\",\"not_ready\":{},\"active_transaction\":{},\"current_active\":{},\"preference\":{}",
        s.sequence, f.config_revision, f.observed_generation, s.observed_at, age > SNAPSHOT_TTL_MS, lifecycle(f.lifecycle), !usable,
        number(f.active_transaction), number(f.current_active.filter(|_| usable).map(|v| v.0)), number(f.preference.map(|v| v.0))).unwrap();
    write!(out, ",\"observed_unix_ms\":{}", number(s.observed_unix_ms)).unwrap();
    if matches!(op, ReadOperation::Status | ReadOperation::List) {
        out.push_str(",\"connections\":[");
        for (i, row) in f.connections.iter().enumerate() {
            if i != 0 {
                out.push(',');
            }
            let c = row.candidate;
            let tcp = health(c.tcp, c.tcp_capability, at, f.policy, usable);
            let udp = health(c.udp, c.udp_capability, at, f.policy, usable);
            write!(out, "{{\"next_probe_at_ms\":{},", number(row.next_probe_at)).unwrap();
            write!(out, "\"id\":{},\"generation\":{},\"backend\":\"{}\",\"enabled\":{},\"in_pool\":{},\"admitted\":{},\"draining\":{},\"tcp_capability\":\"{}\",\"udp_capability\":\"{}\",\"tcp_health\":\"{tcp}\",\"udp_health\":\"{udp}\",\"tcp_ready\":{},\"protected_udp\":\"{}\",\"tcp_observed_at_ms\":{},\"udp_observed_at_ms\":{},\"tcp_latency_ms\":{},\"tcp_recent_failures\":{}}}",
                c.id.0, c.generation, backend(row.backend), c.intent.enabled, c.intent.in_pool, c.admitted, c.draining, cap(c.tcp_capability), cap(c.udp_capability),
                tcp == "healthy", protection(if usable { row.udp_protection } else { UdpProtection::Unknown }),
                number(c.tcp.last_observed_at()), number(c.udp.last_observed_at()),
                number(c.tcp.latency_ms().filter(|_| tcp == "healthy" || tcp == "unstable").map(u64::from)),
                c.tcp.recent_failures(at, f.policy)).unwrap();
        }
        out.push(']');
    } else {
        write!(out, ",\"dropped_events\":{},\"events\":[", s.dropped_events).unwrap();
        for (i, event) in s.events.iter().enumerate() {
            if i != 0 {
                out.push(',');
            }
            write!(
                out,
                "{{\"sequence\":{},\"observed_at_ms\":{},\"kind\":\"{}\"}}",
                event.sequence,
                event.at,
                event_kind(event.kind)
            )
            .unwrap();
        }
        out.push(']');
    }
    out.push_str("}\n");
    if out.len() > MAX_RESPONSE_BYTES {
        return Err(Error::Limit);
    }
    Ok(out)
}
