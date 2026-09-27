//! Single decision owner. Runtime methods are nonblocking dispatch/poll contracts;
//! no real process, socket, init hook or router mutation is installed by this module.
use crate::snapshot::{
    Backend, Connection, EventKind, Frame, Lifecycle, Publisher, MAX_CONNECTIONS,
};
use mors_domain::{
    health::{
        Failure, Health, HealthPolicy, HealthState, Observation, ObservationContext, ProbeEndpoint,
        ProbeResult, Time,
    },
    selection::{
        ConnectionId, Decision, DirectPolicy, Path, SelectionStrategy, Snapshot, StickyHealth,
        Upstream,
    },
    Capability,
};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc::{self, Receiver, SyncSender, TrySendError},
    Arc,
};
use std::time::Duration;

pub const QUEUE_LIMIT: usize = 64;
pub const PROBE_LIMIT: usize = 4;
const EVENTS_PER_TURN: usize = 16;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Invalid,
    Full,
    Stopped,
    Backend,
    Snapshot,
    Clock,
    Overflow,
}
#[derive(Clone, Copy, Debug)]
pub struct Timing {
    pub interval_ms: u64,
    pub probe_ms: u64,
    pub operation_ms: u64,
    pub poll_ms: u64,
}
impl Default for Timing {
    fn default() -> Self {
        Self {
            interval_ms: 30_000,
            probe_ms: 5_000,
            operation_ms: 30_000,
            poll_ms: 100,
        }
    }
}
#[derive(Clone, Debug)]
pub struct Configuration {
    pub revision: u64,
    pub connections: Vec<Connection>,
    pub policy: HealthPolicy,
    pub paused: bool,
    pub direct: DirectPolicy,
}
impl Configuration {
    fn valid(&self) -> bool {
        self.revision > 0
            && self.connections.len() <= MAX_CONNECTIONS
            && self.policy.valid()
            && self.connections.iter().enumerate().all(|(i, r)| {
                !self.connections[..i]
                    .iter()
                    .any(|p| p.candidate.id == r.candidate.id)
                    && (r.backend != Backend::NaiveProxy
                        || r.candidate.udp_capability == Capability::Unsupported)
            })
    }
}
#[derive(Clone, Debug)]
pub enum Event {
    /// CLI/hook mutations use the same queue and optimistic revision check.
    Configure {
        expected_revision: u64,
        config: Configuration,
    },
    Upstream(Upstream),
    Wake,
}
#[derive(Clone)]
pub struct Handle {
    sender: SyncSender<Envelope>,
    stop: Arc<AtomicBool>,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum EventOutcome {
    Accepted,
    RevisionConflict,
    Busy,
    Ignored,
    Stopped,
}
struct Envelope {
    event: Event,
    receipt: Option<SyncSender<EventOutcome>>,
}
impl Handle {
    fn enqueue(
        &self,
        mut event: Event,
        receipt: Option<SyncSender<EventOutcome>>,
    ) -> Result<(), Error> {
        if self.stop.load(Ordering::Acquire) {
            return Err(Error::Stopped);
        }
        if let Event::Configure { config, .. } = &mut event {
            if !config.valid() {
                return Err(Error::Invalid);
            }
            config.connections = std::mem::take(&mut config.connections)
                .into_boxed_slice()
                .into_vec();
        }
        self.sender
            .try_send(Envelope { event, receipt })
            .map_err(|e| match e {
                TrySendError::Full(_) => Error::Full,
                TrySendError::Disconnected(_) => Error::Stopped,
            })
    }
    /// Queue acceptance only. Mutating clients should use submit for an owner receipt.
    pub fn send(&self, event: Event) -> Result<(), Error> {
        self.enqueue(event, None)
    }
    /// The receipt confirms intent acceptance, not successful dataplane application.
    pub fn submit(&self, event: Event) -> Result<Receiver<EventOutcome>, Error> {
        let (sender, receiver) = mpsc::sync_channel(1);
        self.enqueue(event, Some(sender))?;
        Ok(receiver)
    }
    /// Out-of-band stop cannot be starved by a full mutation queue.
    pub fn stop(&self) {
        self.stop.store(true, Ordering::Release);
        let _ = self.sender.try_send(Envelope {
            event: Event::Wake,
            receipt: None,
        });
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Probe {
    pub ticket: u64,
    pub generation: u64,
    pub connection: ConnectionId,
    pub endpoint: ProbeEndpoint,
    pub deadline: Time,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Work {
    /// Must reconcile the durable #73 journal before reporting success.
    Recover,
    /// Apply TCP/UDP together using #73; persist preference only if changed,
    /// after verified effects. Success means both stages are durable/verified.
    Apply {
        decision: Decision,
        preference_changed: bool,
    },
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Operation {
    pub ticket: u64,
    pub generation: u64,
    pub revision: u64,
    pub deadline: Time,
    pub work: Work,
}
/// Dispatch and poll never wait for I/O. Workers cannot select, publish or change
/// registry intent. Exactly one operation may exist; probe workers are bounded.
/// Cancellation must revoke the ticket and reap/stop its worker before returning.
/// Uncertain operation effects are recovered on restart, never assumed rolled back.
/// A runtime owns the exclusive executor lease for its lifetime. Tickets are
/// volatile and scoped to this owner; the runtime maps them to restart-unique
/// durable operation IDs and the current #73 fence, never reusing an old epoch.
/// Production implementations and ownership handoff remain gated by #95.
pub trait Runtime {
    fn start_operation(&mut self, operation: Operation) -> Result<(), Error>;
    fn poll_operation(&mut self, ticket: u64) -> Option<Result<(), Error>>;
    fn cancel_operation(&mut self, ticket: u64);
    fn start_tcp_probe(&mut self, probe: Probe) -> Result<(), Error>;
    fn poll_tcp_probe(&mut self, ticket: u64) -> Option<ProbeResult>;
    fn cancel_tcp_probe(&mut self, ticket: u64);
}
struct Pending {
    operation: Operation,
}
struct Row {
    connection: Connection,
    next: Time,
    probe: Option<Probe>,
}
pub struct Supervisor<R: Runtime> {
    runtime: R,
    publisher: Publisher,
    receiver: Receiver<Envelope>,
    stop: Arc<AtomicBool>,
    config: Configuration,
    rows: Vec<Row>,
    timing: Timing,
    generation: u64,
    ticket: u64,
    last_time: Time,
    preference: Option<ConnectionId>,
    applied: Option<Decision>,
    upstream: Option<Upstream>,
    pending: Option<Pending>,
    recovered: bool,
    fault: bool,
    stopped: bool,
    cursor: usize,
    rejected_events: u64,
    last_lifecycle: Option<Lifecycle>,
}
impl<R: Runtime> Supervisor<R> {
    pub fn new(
        runtime: R,
        publisher: Publisher,
        config: Configuration,
        preference: Option<ConnectionId>,
        timing: Timing,
    ) -> Result<(Self, Handle), Error> {
        if !config.valid()
            || timing.interval_ms == 0
            || timing.probe_ms == 0
            || timing.operation_ms == 0
            || timing.poll_ms == 0
            || timing.poll_ms > 1000
            || timing.poll_ms > timing.probe_ms
            || timing.poll_ms > timing.operation_ms
        {
            return Err(Error::Invalid);
        }
        let (sender, receiver) = mpsc::sync_channel(QUEUE_LIMIT);
        let stop = Arc::new(AtomicBool::new(false));
        let handle = Handle {
            sender,
            stop: Arc::clone(&stop),
        };
        let mut owner = Self {
            runtime,
            publisher,
            receiver,
            stop,
            config,
            rows: vec![],
            timing,
            generation: 0,
            ticket: 0,
            last_time: 0,
            preference,
            applied: None,
            upstream: None,
            pending: None,
            recovered: false,
            fault: false,
            stopped: false,
            cursor: 0,
            rejected_events: 0,
            last_lifecycle: None,
        };
        owner.reset()?;
        Ok((owner, handle))
    }
    pub fn rejected_events(&self) -> u64 {
        self.rejected_events
    }
    pub fn runtime(&self) -> &R {
        &self.runtime
    }
    fn reset(&mut self) -> Result<(), Error> {
        self.generation = self.generation.checked_add(1).ok_or(Error::Overflow)?;
        self.cancel_probes();
        self.rows = self
            .config
            .connections
            .iter()
            .map(|r| {
                let mut connection = *r;
                connection.candidate.generation = self.generation;
                connection.candidate.tcp = Health::new(self.generation);
                connection.candidate.udp = Health::new(self.generation);
                // Runtime observation is unknown until the common transaction verifies it.
                connection.udp_protection = crate::snapshot::UdpProtection::Unknown;
                Row {
                    connection,
                    next: self.last_time,
                    probe: None,
                }
            })
            .collect();
        self.config.connections = self
            .config
            .connections
            .clone()
            .into_boxed_slice()
            .into_vec();
        self.upstream = None;
        self.applied = None;
        Ok(())
    }
    fn ticket(&mut self) -> Result<u64, Error> {
        self.ticket = self.ticket.checked_add(1).ok_or(Error::Overflow)?;
        Ok(self.ticket)
    }
    fn cancel_probes(&mut self) {
        for r in &mut self.rows {
            if let Some(p) = r.probe.take() {
                self.runtime.cancel_tcp_probe(p.ticket);
            }
        }
    }
    fn fail(&mut self) {
        self.fault = true;
        self.applied = None;
        self.cancel_probes();
        if let Some(p) = self.pending.take() {
            self.runtime.cancel_operation(p.operation.ticket);
        }
    }
    fn event(&mut self, envelope: Envelope) -> Result<(), Error> {
        let outcome = match envelope.event {
            Event::Configure {
                expected_revision,
                config,
            } => {
                if self.pending.is_some() || self.fault || !self.recovered {
                    EventOutcome::Busy
                } else if expected_revision != self.config.revision
                    || config.revision <= expected_revision
                    || !config.valid()
                {
                    EventOutcome::RevisionConflict
                } else {
                    self.config = config;
                    self.reset()?;
                    EventOutcome::Accepted
                }
            }
            Event::Upstream(u) => {
                if u.generation == self.generation
                    && u.observed_at <= self.last_time
                    && self
                        .upstream
                        .is_none_or(|old| u.observed_at >= old.observed_at)
                {
                    self.upstream = Some(u);
                    EventOutcome::Accepted
                } else {
                    EventOutcome::Ignored
                }
            }
            Event::Wake => EventOutcome::Accepted,
        };
        if matches!(outcome, EventOutcome::Busy | EventOutcome::RevisionConflict) {
            self.rejected_events = self.rejected_events.saturating_add(1);
        }
        if let Some(receipt) = envelope.receipt {
            let _ = receipt.try_send(outcome);
        }
        Ok(())
    }
    fn start(&mut self, work: Work, now: Time) -> Result<(), Error> {
        let operation = Operation {
            ticket: self.ticket()?,
            generation: self.generation,
            revision: self.config.revision,
            deadline: now
                .checked_add(self.timing.operation_ms)
                .ok_or(Error::Overflow)?,
            work,
        };
        // Publish changing before dispatch; status readers hold no runtime handles.
        self.pending = Some(Pending { operation });
        self.publish(now)?;
        if self.runtime.start_operation(operation).is_err() {
            self.fail();
        }
        Ok(())
    }
    fn decision(&self, now: Time) -> Decision {
        let candidates: Vec<_> = self.rows.iter().map(|r| r.connection.candidate).collect();
        StickyHealth.select(&Snapshot {
            now,
            generation: self.generation,
            policy: self.config.policy,
            paused: self.config.paused,
            active: self.preference,
            direct: self.config.direct,
            upstream: self.upstream,
            candidates: &candidates,
        })
    }
    fn probes(&mut self, now: Time, enabled: bool, dispatch: bool) -> Result<(), Error> {
        if !enabled {
            self.cancel_probes();
            return Ok(());
        }
        for row in &mut self.rows {
            if let Some(p) = row.probe {
                let result = if now >= p.deadline {
                    self.runtime.cancel_tcp_probe(p.ticket);
                    Some(ProbeResult::Failed(Failure::Timeout))
                } else {
                    self.runtime.poll_tcp_probe(p.ticket)
                };
                if let Some(result) = result {
                    let c = &mut row.connection.candidate;
                    c.tcp = c
                        .tcp
                        .observe(
                            Observation {
                                generation: p.generation,
                                sequence: p.ticket,
                                observed_at: now,
                                endpoint: p.endpoint,
                                result,
                            },
                            ObservationContext {
                                now,
                                policy: self.config.policy,
                                probes_enabled: true,
                                capability: c.tcp_capability,
                            },
                        )
                        .0;
                    row.probe = None;
                    row.next = now
                        .checked_add(self.timing.interval_ms)
                        .ok_or(Error::Overflow)?;
                }
            }
        }
        if !dispatch {
            return Ok(());
        }
        let mut slots =
            PROBE_LIMIT.saturating_sub(self.rows.iter().filter(|r| r.probe.is_some()).count());
        // Rotating cursor prevents a permanently failing first profile starving the tail.
        let len = self.rows.len();
        for offset in 0..len {
            if slots == 0 {
                break;
            }
            let i = (self.cursor + offset) % len;
            let c = self.rows[i].connection.candidate;
            if self.rows[i].probe.is_some()
                || self.rows[i].next > now
                || !c.intent.enabled
                || !c.intent.in_pool
                || c.draining
                || c.tcp_capability != Capability::Supported
            {
                continue;
            }
            let probe = Probe {
                ticket: self.ticket()?,
                generation: self.generation,
                connection: c.id,
                endpoint: if c.tcp.state(now, self.config.policy) == HealthState::Unstable {
                    ProbeEndpoint::Confirmation
                } else {
                    ProbeEndpoint::Primary
                },
                deadline: now
                    .checked_add(self.timing.probe_ms)
                    .ok_or(Error::Overflow)?,
            };
            self.rows[i].next = now
                .checked_add(self.timing.interval_ms)
                .ok_or(Error::Overflow)?;
            if self.runtime.start_tcp_probe(probe).is_ok() {
                self.rows[i].probe = Some(probe);
            }
            slots -= 1;
        }
        if len > 0 {
            self.cursor = (self.cursor + PROBE_LIMIT) % len;
        }
        Ok(())
    }
    fn publish(&mut self, now: Time) -> Result<(), Error> {
        let lifecycle = if self.fault {
            Lifecycle::RecoveryRequired
        } else if !self.recovered {
            Lifecycle::Starting
        } else if self.pending.is_some() {
            Lifecycle::Changing
        } else if self.stopped || self.config.paused {
            Lifecycle::Paused
        } else if self.rows.is_empty() {
            Lifecycle::Unconfigured
        } else {
            Lifecycle::Ready
        };
        self.publisher
            .publish_at(
                Frame {
                    config_revision: self.config.revision,
                    observed_generation: self.generation,
                    lifecycle,
                    active_transaction: self.pending.as_ref().map(|p| p.operation.ticket),
                    current_active: if lifecycle == Lifecycle::Ready {
                        self.applied.and_then(|d| d.active)
                    } else {
                        None
                    },
                    preference: self.preference,
                    policy: self.config.policy,
                    connections: self
                        .rows
                        .iter()
                        .map(|r| {
                            let mut c = r.connection;
                            c.next_probe_at = if self.recovered
                                && !self.fault
                                && !self.stopped
                                && !self.config.paused
                                && c.candidate.intent.enabled
                                && c.candidate.intent.in_pool
                                && !c.candidate.draining
                                && c.candidate.tcp_capability == Capability::Supported
                            {
                                Some(r.probe.map_or(r.next, |p| p.deadline))
                            } else {
                                None
                            };
                            c
                        })
                        .collect(),
                },
                if self.last_lifecycle != Some(lifecycle) {
                    Some(EventKind::LifecycleChanged)
                } else {
                    None
                },
                now,
            )
            .map_err(|_| Error::Snapshot)?;
        self.last_lifecycle = Some(lifecycle);
        Ok(())
    }
    /// One bounded turn with injected monotonic time. No sleeps or persistent idle writes.
    pub fn tick(&mut self, now: Time) -> Result<(), Error> {
        let result = self.turn(now);
        if result.is_err() {
            self.fail();
            let _ = self.publish(self.last_time);
        }
        result
    }
    fn turn(&mut self, now: Time) -> Result<(), Error> {
        if now < self.last_time {
            self.fail();
            self.publish(self.last_time)?;
            return Err(Error::Clock);
        }
        self.last_time = now;
        if self.stop.load(Ordering::Acquire) {
            self.stopped = true;
            while let Ok(envelope) = self.receiver.try_recv() {
                if let Some(receipt) = envelope.receipt {
                    let _ = receipt.try_send(EventOutcome::Stopped);
                }
            }
            self.cancel_probes();
            if self.pending.is_some() {
                self.fail();
            }
            return self.publish(now);
        }
        for _ in 0..EVENTS_PER_TURN {
            match self.receiver.try_recv() {
                Ok(e) => self.event(e)?,
                Err(_) => break,
            }
        }
        if self.fault {
            return self.publish(now);
        }
        if self.recovered {
            self.probes(now, self.decision(now).probes_enabled, false)?;
        }
        if let Some(pending) = &self.pending {
            let operation = pending.operation;
            if now >= operation.deadline {
                self.fail();
            } else if let Some(result) = self.runtime.poll_operation(operation.ticket) {
                self.pending = None;
                if result.is_err() {
                    self.fail();
                } else {
                    match operation.work {
                        Work::Recover => self.recovered = true,
                        Work::Apply { decision, .. } => {
                            self.applied = Some(decision);
                            self.preference = decision.preference;
                            for row in &mut self.rows {
                                row.connection.udp_protection = match decision.udp {
                                    Path::Block => crate::snapshot::UdpProtection::Blocked,
                                    _ => crate::snapshot::UdpProtection::Unknown,
                                };
                            }
                        }
                    }
                }
            }
        }
        if !self.fault && self.pending.is_none() {
            if !self.recovered {
                self.start(Work::Recover, now)?;
            } else {
                self.probes(now, self.decision(now).probes_enabled, true)?;
                let decision = self.decision(now);
                let changed = self.applied.is_none_or(|d| {
                    (d.active, d.tcp, d.udp, d.preference)
                        != (
                            decision.active,
                            decision.tcp,
                            decision.udp,
                            decision.preference,
                        )
                });
                if changed {
                    self.start(
                        Work::Apply {
                            decision,
                            preference_changed: self.preference != decision.preference,
                        },
                        now,
                    )?;
                }
            }
        }
        self.publish(now)
    }
    /// The owning thread waits interruptibly; fake-clock tests drive tick directly.
    pub fn run(mut self) -> Result<(), Error> {
        loop {
            self.tick(self.publisher.now())?;
            if self.stopped {
                return Ok(());
            }
            match self
                .receiver
                .recv_timeout(Duration::from_millis(self.timing.poll_ms))
            {
                Ok(e) => {
                    self.last_time = self.publisher.now();
                    self.event(e)?;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    self.stop.store(true, Ordering::Release);
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
            }
        }
    }
}
impl<R: Runtime> Drop for Supervisor<R> {
    fn drop(&mut self) {
        self.cancel_probes();
        if let Some(p) = self.pending.take() {
            self.runtime.cancel_operation(p.operation.ticket);
        }
        self.stop.store(true, Ordering::Release);
    }
}
