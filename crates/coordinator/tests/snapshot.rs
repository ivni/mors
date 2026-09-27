use mors_coordinator::snapshot::*;
use mors_domain::{
    health::*,
    selection::{Candidate, ConnectionId, Intent},
    Capability,
};
use serde_json::{from_str, Value};

fn frame(revision: u64) -> Frame {
    let policy = HealthPolicy::default();
    let (tcp, _) = Health::new(revision).observe(
        Observation {
            generation: revision,
            sequence: 1,
            observed_at: 0,
            endpoint: ProbeEndpoint::Primary,
            result: ProbeResult::Success { latency_ms: 12 },
        },
        ObservationContext {
            now: 0,
            policy,
            probes_enabled: true,
            capability: Capability::Supported,
        },
    );
    Frame {
        config_revision: revision,
        observed_generation: revision,
        lifecycle: Lifecycle::Ready,
        active_transaction: None,
        current_active: Some(ConnectionId(7)),
        preference: Some(ConnectionId(7)),
        policy,
        connections: vec![Connection {
            backend: Backend::NaiveProxy,
            udp_protection: UdpProtection::Blocked,
            next_probe_at: Some(10_000),
            candidate: Candidate {
                id: ConnectionId(7),
                generation: revision,
                intent: Intent {
                    enabled: true,
                    in_pool: true,
                },
                admitted: true,
                draining: false,
                tcp_capability: Capability::Supported,
                udp_capability: Capability::Unsupported,
                tcp,
                udp: Health::new(revision),
            },
        }],
    }
}
fn read(reader: &Reader, op: ReadOperation) -> Value {
    from_str(&reader.read(op).unwrap()).unwrap()
}

#[test]
fn boot_preference_is_not_health_and_restart_drops_state() {
    let (mut writer, reader) = channel([1; 16], Some(ConnectionId(7)));
    let boot = read(&reader, ReadOperation::Status);
    assert_eq!(boot["preference"], 7);
    assert!(boot["current_active"].is_null());
    assert_eq!(boot["not_ready"], true);
    assert_eq!(boot["connections"], serde_json::json!([]));
    writer
        .publish(frame(1), Some(EventKind::ActiveChanged))
        .unwrap();
    let (_, restarted) = channel([2; 16], Some(ConnectionId(7)));
    let fresh = read(&restarted, ReadOperation::Status);
    assert_ne!(fresh["boot_id"], boot["boot_id"]);
    assert_eq!(fresh["sequence"], 0);
    assert!(fresh["current_active"].is_null());
}

#[test]
fn tcp_udp_and_observed_block_are_independent_and_age_honest() {
    let (mut writer, reader) = channel([0; 16], None);
    let mut f = frame(1);
    f.connections[0].udp_protection = UdpProtection::Unknown;
    writer.publish(f.clone(), None).unwrap();
    let value = read(&reader, ReadOperation::Status);
    assert_eq!(value["connections"][0]["tcp_ready"], true);
    assert_eq!(value["connections"][0]["udp_health"], "unsupported");
    assert_eq!(value["connections"][0]["protected_udp"], "unknown");
    f.connections[0].udp_protection = UdpProtection::Blocked;
    writer.publish(f, None).unwrap();
    assert_eq!(
        read(&reader, ReadOperation::List)["connections"][0]["protected_udp"],
        "blocked"
    );
    let stale: Value = from_str(
        &reader
            .read_at(ReadOperation::Status, writer.now() + SNAPSHOT_TTL_MS + 1)
            .unwrap(),
    )
    .unwrap();
    assert_eq!(stale["stale"], true);
    assert!(stale["current_active"].is_null());
    assert_eq!(stale["connections"][0]["tcp_ready"], false);
    assert_eq!(stale["connections"][0]["protected_udp"], "unknown");
}

#[test]
fn all_not_ready_lifecycle_states_hide_dataplane() {
    for state in [
        Lifecycle::Unconfigured,
        Lifecycle::Starting,
        Lifecycle::Paused,
        Lifecycle::Changing,
        Lifecycle::RecoveryRequired,
    ] {
        let (mut writer, reader) = channel([0; 16], None);
        let mut f = frame(1);
        f.lifecycle = state;
        assert_eq!(writer.publish(f.clone(), None), Err(Error::InvalidFrame));
        f.current_active = None;
        f.active_transaction = Some(9);
        writer.publish(f, None).unwrap();
        let value = read(&reader, ReadOperation::Status);
        assert!(value["current_active"].is_null());
        assert_eq!(value["not_ready"], true);
        assert_eq!(value["connections"][0]["tcp_health"], "unknown");
    }
}

#[test]
fn rejected_publication_is_atomic() {
    let (mut writer, reader) = channel([0; 16], None);
    writer.publish(frame(2), None).unwrap();
    let mut invalid = frame(3);
    invalid.connections.push(invalid.connections[0]);
    assert_eq!(writer.publish(invalid, None), Err(Error::InvalidFrame));
    assert_eq!(writer.publish(frame(1), None), Err(Error::InvalidFrame));
    let mut invalid = frame(3);
    invalid.connections[0].candidate.udp_capability = Capability::Supported;
    assert_eq!(writer.publish(invalid, None), Err(Error::InvalidFrame));
    let mut invalid = frame(3);
    invalid.connections = vec![invalid.connections[0]; MAX_CONNECTIONS + 1];
    assert_eq!(writer.publish(invalid, None), Err(Error::Limit));
    assert_eq!(read(&reader, ReadOperation::Status)["sequence"], 1);
}

#[test]
fn bounded_events_are_nondestructive_and_overflow_is_explicit() {
    let (mut writer, reader) = channel([0; 16], None);
    for revision in 1..=300 {
        writer
            .publish(frame(revision), Some(EventKind::HealthChanged))
            .unwrap();
    }
    let value = read(&reader, ReadOperation::Events);
    assert_eq!(value["events"].as_array().unwrap().len(), MAX_EVENTS);
    assert_eq!(value["dropped_events"], 45);
    for _ in 0..100 {
        assert_eq!(
            read(&reader, ReadOperation::Events)["events"],
            value["events"]
        );
        assert_eq!(read(&reader, ReadOperation::Status)["sequence"], 300);
    }
}

#[test]
fn concurrent_readers_never_mix_cycles_or_mutate_sequence() {
    let (mut writer, reader) = channel([0; 16], None);
    writer
        .publish(frame(1), Some(EventKind::HealthChanged))
        .unwrap();
    std::thread::scope(|scope| {
        for _ in 0..8 {
            let reader = reader.clone();
            scope.spawn(move || {
                for _ in 0..250 {
                    let v = read(&reader, ReadOperation::Status);
                    assert_eq!(v["sequence"], v["config_revision"]);
                    assert_eq!(v["config_revision"], v["observed_generation"]);
                    assert_eq!(v["config_revision"], v["connections"][0]["generation"]);
                    assert!(
                        v["read_at_ms"].as_u64().unwrap() >= v["observed_at_ms"].as_u64().unwrap()
                    );
                }
            });
        }
        scope.spawn(move || {
            for revision in 2..=500 {
                writer
                    .publish(frame(revision), Some(EventKind::HealthChanged))
                    .unwrap();
            }
        });
    });
    assert_eq!(read(&reader, ReadOperation::Status)["sequence"], 500);
}

#[test]
fn maximum_schema_response_is_bounded_and_contains_no_free_text_fields() {
    let (mut writer, reader) = channel([255; 16], None);
    let mut f = frame(1);
    f.current_active = None;
    let row = f.connections[0];
    f.connections = (0..MAX_CONNECTIONS)
        .map(|id| {
            let mut row = row;
            row.candidate.id = ConnectionId(id as u64);
            row
        })
        .collect();
    writer.publish(f, None).unwrap();
    let raw = reader.read(ReadOperation::List).unwrap();
    assert!(raw.len() < MAX_RESPONSE_BYTES);
    let v: Value = from_str(&raw).unwrap();
    let fields = v["connections"][0].as_object().unwrap();
    assert_eq!(fields.len(), 18);
    for forbidden in ["name", "endpoint", "config", "credentials", "stderr"] {
        assert!(!fields.contains_key(forbidden));
    }
}
