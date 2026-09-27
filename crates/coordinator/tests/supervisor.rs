use mors_coordinator::{
    snapshot::{self, Backend, Connection, ReadOperation, UdpProtection},
    supervisor::*,
};
use mors_domain::{
    health::{Health, HealthPolicy, ProbeEndpoint, ProbeResult},
    selection::{Candidate, ConnectionId, DirectPolicy, Intent, Path},
    Capability,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct State {
    operations: Vec<Operation>,
    pending: Option<Operation>,
    probes: BTreeMap<u64, Probe>,
    started: Vec<Probe>,
    cancelled: Vec<u64>,
    hold_operations: bool,
    hold_probes: bool,
    fail: bool,
    writes: usize,
    preferences: usize,
    max_probes: usize,
}
#[derive(Clone, Default)]
struct Fake(Arc<Mutex<State>>);
impl Runtime for Fake {
    fn start_operation(&mut self, op: Operation) -> Result<(), Error> {
        let mut s = self.0.lock().unwrap();
        assert!(s.pending.is_none(), "two decision owners");
        s.operations.push(op);
        s.pending = Some(op);
        Ok(())
    }
    fn poll_operation(&mut self, ticket: u64) -> Option<Result<(), Error>> {
        let mut s = self.0.lock().unwrap();
        if s.hold_operations {
            return None;
        }
        let op = s.pending.take().unwrap();
        assert_eq!(ticket, op.ticket);
        if s.fail {
            return Some(Err(Error::Backend));
        }
        if let Work::Apply {
            preference_changed, ..
        } = op.work
        {
            s.writes += 1;
            s.preferences += usize::from(preference_changed);
        }
        Some(Ok(()))
    }
    fn cancel_operation(&mut self, ticket: u64) {
        let mut s = self.0.lock().unwrap();
        s.cancelled.push(ticket);
        s.pending = None;
    }
    fn start_tcp_probe(&mut self, p: Probe) -> Result<(), Error> {
        let mut s = self.0.lock().unwrap();
        s.started.push(p);
        s.probes.insert(p.ticket, p);
        s.max_probes = s.max_probes.max(s.probes.len());
        Ok(())
    }
    fn poll_tcp_probe(&mut self, ticket: u64) -> Option<ProbeResult> {
        let mut s = self.0.lock().unwrap();
        if s.hold_probes {
            return None;
        }
        s.probes.remove(&ticket).unwrap();
        Some(ProbeResult::Success { latency_ms: 10 })
    }
    fn cancel_tcp_probe(&mut self, ticket: u64) {
        let mut s = self.0.lock().unwrap();
        s.probes.remove(&ticket);
        s.cancelled.push(ticket);
    }
}
fn config(count: usize) -> Configuration {
    Configuration {
        revision: 1,
        policy: HealthPolicy::default(),
        paused: false,
        direct: DirectPolicy::Forbidden,
        connections: (1..=count)
            .map(|id| Connection {
                backend: Backend::NaiveProxy,
                udp_protection: UdpProtection::Unknown,
                next_probe_at: None,
                candidate: Candidate {
                    id: ConnectionId(id as u64),
                    generation: 42,
                    intent: Intent {
                        enabled: true,
                        in_pool: true,
                    },
                    admitted: true,
                    draining: false,
                    tcp_capability: Capability::Supported,
                    udp_capability: Capability::Unsupported,
                    tcp: Health::new(42),
                    udp: Health::new(42),
                },
            })
            .collect(),
    }
}
fn setup(count: usize) -> (Supervisor<Fake>, Handle, snapshot::Reader, Fake) {
    let fake = Fake::default();
    let (publisher, reader) = snapshot::channel([1; 16], None);
    let (owner, handle) = Supervisor::new(
        fake.clone(),
        publisher,
        config(count),
        None,
        Timing::default(),
    )
    .unwrap();
    (owner, handle, reader, fake)
}
fn status(reader: &snapshot::Reader, at: u64) -> String {
    reader.read_at(ReadOperation::Status, at).unwrap()
}
#[test]
fn recovery_precedes_selection_and_idle_has_no_persistent_writes() {
    let (mut owner, _, reader, fake) = setup(1);
    for at in 0..5 {
        owner.tick(at).unwrap();
    }
    let s = fake.0.lock().unwrap();
    assert_eq!(s.operations[0].work, Work::Recover);
    assert_eq!(s.preferences, 1);
    let writes = s.writes;
    drop(s);
    for at in 5..100 {
        owner.tick(at).unwrap();
    }
    assert_eq!(fake.0.lock().unwrap().writes, writes);
    assert!(status(&reader, 99).contains("ready"));
    for op in &fake.0.lock().unwrap().operations {
        if let Work::Apply { decision, .. } = op.work {
            assert_eq!(decision.udp, Path::Block);
        }
    }
}
#[test]
fn probes_are_bounded_fair_and_timeout_uses_confirmation_endpoint() {
    let (mut owner, _, _, fake) = setup(10);
    fake.0.lock().unwrap().hold_probes = true;
    for at in [0, 1, 2, 5001, 5002, 10002, 10003, 35002, 35003] {
        owner.tick(at).unwrap();
    }
    let s = fake.0.lock().unwrap();
    assert!(s.max_probes <= PROBE_LIMIT);
    for id in 1..=10 {
        assert!(s.started.iter().any(|p| p.connection == ConnectionId(id)));
    }
    assert!(s
        .started
        .iter()
        .any(|p| p.endpoint == ProbeEndpoint::Confirmation));
    assert!(!s.cancelled.is_empty());
}
#[test]
fn stop_bypasses_full_queue_and_cancels_pending_work() {
    let (mut owner, handle, reader, fake) = setup(1);
    fake.0.lock().unwrap().hold_operations = true;
    owner.tick(0).unwrap();
    for _ in 0..QUEUE_LIMIT {
        handle.send(Event::Wake).unwrap();
    }
    assert_eq!(handle.send(Event::Wake), Err(Error::Full));
    handle.stop();
    owner.tick(1).unwrap();
    assert_eq!(fake.0.lock().unwrap().cancelled.len(), 1);
    assert!(status(&reader, 1).contains("recovery_required"));
    assert_eq!(handle.send(Event::Wake), Err(Error::Stopped));
}
#[test]
fn deadline_wins_over_late_success_and_requires_restart_recovery() {
    let (mut owner, _, reader, fake) = setup(1);
    owner.tick(0).unwrap();
    owner.tick(30_000).unwrap();
    owner.tick(30_001).unwrap();
    assert_eq!(fake.0.lock().unwrap().operations.len(), 1);
    assert!(status(&reader, 30_001).contains("recovery_required"));
    drop(owner);
    let (publisher, _) = snapshot::channel([2; 16], None);
    let (mut restarted, _) =
        Supervisor::new(fake.clone(), publisher, config(1), None, Timing::default()).unwrap();
    restarted.tick(0).unwrap();
    assert_eq!(
        fake.0.lock().unwrap().operations.last().unwrap().work,
        Work::Recover
    );
}
#[test]
fn mutations_are_serialized_and_revision_conflicts_do_not_overwrite_intent() {
    let (mut owner, handle, _, fake) = setup(1);
    for at in 0..5 {
        owner.tick(at).unwrap();
    }
    let mut updated = config(1);
    updated.revision = 2;
    updated.paused = true;
    handle
        .send(Event::Configure {
            expected_revision: 1,
            config: updated.clone(),
        })
        .unwrap();
    handle
        .send(Event::Configure {
            expected_revision: 1,
            config: updated,
        })
        .unwrap();
    owner.tick(5).unwrap();
    owner.tick(6).unwrap();
    assert_eq!(owner.rejected_events(), 1);
    let s = fake.0.lock().unwrap();
    let last = s.operations.last().unwrap();
    assert_eq!(last.revision, 2);
    assert!(matches!(last.work, Work::Apply { decision, .. } if decision.tcp == Path::Block));
    assert!(s.probes.is_empty());
}
#[test]
fn status_remains_readable_during_expensive_backend_work() {
    let (mut owner, _, reader, fake) = setup(1);
    fake.0.lock().unwrap().hold_operations = true;
    owner.tick(0).unwrap();
    let reader_thread = std::thread::spawn(move || {
        for _ in 0..1000 {
            assert!(status(&reader, 1000).contains("starting"));
        }
    });
    for at in 1..1000 {
        owner.tick(at).unwrap();
    }
    reader_thread.join().unwrap();
    assert_eq!(fake.0.lock().unwrap().operations.len(), 1);
}
#[test]
fn backwards_clock_and_backend_failure_never_publish_ready() {
    let (mut owner, _, reader, _) = setup(1);
    owner.tick(10).unwrap();
    assert_eq!(owner.tick(9), Err(Error::Clock));
    assert!(status(&reader, 10).contains("recovery_required"));
    let (mut owner, _, reader, fake) = setup(1);
    fake.0.lock().unwrap().fail = true;
    owner.tick(0).unwrap();
    owner.tick(1).unwrap();
    assert!(status(&reader, 1).contains("recovery_required"));
}
#[test]
fn drop_reaps_workers_and_closed_sender_wakes_run() {
    let (mut owner, handle, _, fake) = setup(1);
    fake.0.lock().unwrap().hold_operations = true;
    owner.tick(0).unwrap();
    drop(owner);
    assert_eq!(fake.0.lock().unwrap().cancelled.len(), 1);
    assert_eq!(handle.send(Event::Wake), Err(Error::Stopped));
    let (owner, handle, _, _) = setup(1);
    drop(handle);
    owner.run().unwrap();
}
#[test]
fn invalid_configuration_is_rejected_before_queueing() {
    let (_owner, handle, _, _) = setup(1);
    let mut c = config(129);
    assert_eq!(
        handle.send(Event::Configure {
            expected_revision: 1,
            config: c.clone()
        }),
        Err(Error::Invalid)
    );
    c = config(1);
    c.connections[0].candidate.udp_capability = Capability::Supported;
    assert_eq!(
        handle.send(Event::Configure {
            expected_revision: 1,
            config: c
        }),
        Err(Error::Invalid)
    );
}

#[test]
fn receipts_distinguish_queued_intent_from_busy_and_revision_conflict() {
    let (mut owner, handle, _, _) = setup(1);
    let mut changed = config(1);
    changed.revision = 2;
    let busy = handle
        .submit(Event::Configure {
            expected_revision: 1,
            config: changed.clone(),
        })
        .unwrap();
    owner.tick(0).unwrap();
    assert_eq!(busy.recv().unwrap(), EventOutcome::Busy);
    for now in 1..5 {
        owner.tick(now).unwrap();
    }
    let accepted = handle
        .submit(Event::Configure {
            expected_revision: 1,
            config: changed.clone(),
        })
        .unwrap();
    let conflict = handle
        .submit(Event::Configure {
            expected_revision: 1,
            config: changed,
        })
        .unwrap();
    owner.tick(5).unwrap();
    assert_eq!(accepted.recv().unwrap(), EventOutcome::Accepted);
    assert_eq!(conflict.recv().unwrap(), EventOutcome::RevisionConflict);
    let stopped = handle.submit(Event::Wake).unwrap();
    handle.stop();
    owner.tick(6).unwrap();
    assert_eq!(stopped.recv().unwrap(), EventOutcome::Stopped);
}
#[test]
fn probe_deadlines_are_enforced_while_an_apply_is_pending() {
    let (mut owner, _, _, fake) = setup(1);
    owner.tick(0).unwrap();
    fake.0.lock().unwrap().hold_probes = true;
    owner.tick(1).unwrap(); // recovered, TCP probe + initial block transaction
    fake.0.lock().unwrap().hold_operations = true;
    owner.tick(5001).unwrap();
    let state = fake.0.lock().unwrap();
    assert!(state.pending.is_some());
    assert!(state.probes.is_empty());
    assert_eq!(state.cancelled.len(), 1);
}

#[test]
fn repeated_successful_probe_cycles_do_not_write_preference_or_reapply() {
    let (mut owner, _handle, _, fake) = setup(1);
    for now in 0..5 {
        owner.tick(now).unwrap();
    }
    let writes = fake.0.lock().unwrap().writes;
    for cycle in 1..20 {
        let now = cycle * 30_002;
        owner.tick(now).unwrap();
        owner.tick(now + 1).unwrap();
    }
    let state = fake.0.lock().unwrap();
    assert_eq!(state.writes, writes);
    assert_eq!(state.preferences, 1);
    assert!(state.started.len() >= 20);
}
#[test]
fn live_event_loop_wakes_for_receipts_and_stops() {
    let (owner, handle, _, _) = setup(1);
    let runner = std::thread::spawn(move || owner.run());
    let receipt = handle.submit(Event::Wake).unwrap();
    assert_eq!(
        receipt
            .recv_timeout(std::time::Duration::from_secs(2))
            .unwrap(),
        EventOutcome::Accepted
    );
    handle.stop();
    runner.join().unwrap().unwrap();
}
