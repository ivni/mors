use mors_domain::{health::*, selection::*, Capability};

const POLICY: HealthPolicy = HealthPolicy {
    freshness_ms: 100,
    failure_window_ms: 500,
};
const ENABLED: Intent = Intent {
    enabled: true,
    in_pool: true,
};

fn observe(
    health: Health,
    seq: u64,
    at: Time,
    endpoint: ProbeEndpoint,
    result: ProbeResult,
) -> Health {
    let (next, reason) = health.observe(
        Observation {
            generation: health.generation(),
            sequence: seq,
            observed_at: at,
            endpoint,
            result,
        },
        ObservationContext {
            now: at,
            policy: POLICY,
            probes_enabled: true,
            capability: Capability::Supported,
        },
    );
    assert_eq!(reason, ObservationReason::Accepted);
    next
}
fn success(h: Health, seq: u64, at: Time, latency_ms: u32) -> Health {
    observe(
        h,
        seq,
        at,
        ProbeEndpoint::Primary,
        ProbeResult::Success { latency_ms },
    )
}
fn failure(h: Health, seq: u64, at: Time, endpoint: ProbeEndpoint) -> Health {
    observe(h, seq, at, endpoint, ProbeResult::Failed(Failure::Timeout))
}
fn failed(h: Health, seq: u64, at: Time) -> Health {
    let h = failure(h, seq, at, ProbeEndpoint::Primary);
    let h = failure(h, seq + 1, at + 1, ProbeEndpoint::Confirmation);
    failure(h, seq + 2, at + 2, ProbeEndpoint::Confirmation)
}
fn candidate(id: u64, latency: u32) -> Candidate {
    Candidate {
        id: ConnectionId(id),
        generation: 1,
        intent: ENABLED,
        admitted: true,
        draining: false,
        tcp_capability: Capability::Supported,
        udp_capability: Capability::Unknown,
        tcp: success(Health::new(1), 1, 10, latency),
        udp: Health::new(1),
    }
}
fn snapshot(candidates: &[Candidate]) -> Snapshot<'_> {
    Snapshot {
        now: 20,
        generation: 7,
        policy: POLICY,
        paused: false,
        active: None,
        direct: DirectPolicy::Forbidden,
        upstream: Some(Upstream {
            generation: 7,
            observed_at: 20,
            state: UpstreamState::Up,
        }),
        candidates,
    }
}
fn select(s: &Snapshot<'_>) -> Decision {
    (&StickyHealth as &dyn SelectionStrategy).select(s)
}

#[test]
fn table_initial_pools_and_deterministic_ties() {
    let cases = [
        (vec![], None, DecisionReason::Unconfigured),
        (
            vec![candidate(4, 90)],
            Some(ConnectionId(4)),
            DecisionReason::InitialSelection,
        ),
        (
            vec![
                candidate(4, 90),
                candidate(3, 80),
                candidate(2, 80),
                candidate(1, 100),
            ],
            Some(ConnectionId(2)),
            DecisionReason::InitialSelection,
        ),
    ];
    for (mut pool, expected, reason) in cases {
        for _ in 0..pool.len().max(1) {
            let decision = select(&snapshot(&pool));
            assert_eq!(decision.active, expected);
            assert_eq!(decision.reason, reason);
            if !pool.is_empty() {
                pool.rotate_left(1);
            }
        }
    }
}

#[test]
fn failure_requires_two_distinct_confirmation_tickets_and_recovers() {
    let mut h = Health::new(1);
    assert_eq!(h.state(0, POLICY), HealthState::Checking);
    h = success(h, 1, 1, 80);
    let cases = [
        (2, ProbeEndpoint::Primary, HealthState::Unstable),
        (3, ProbeEndpoint::Primary, HealthState::Unstable),
        (4, ProbeEndpoint::Confirmation, HealthState::Unstable),
        (5, ProbeEndpoint::Confirmation, HealthState::Unavailable),
    ];
    for (seq, endpoint, expected) in cases {
        h = failure(h, seq, seq, endpoint);
        assert_eq!(h.state(seq, POLICY), expected);
    }
    h = success(h, 6, 6, 40);
    assert_eq!(h.state(6, POLICY), HealthState::Healthy);
    assert_eq!(h.recent_failures(6, POLICY), 4);
    assert_eq!(h.latency_ms(), Some(70));
}

#[test]
fn table_rejects_stale_future_duplicate_old_generation_and_out_of_order_probes() {
    let h = success(Health::new(2), 10, 100, 20);
    let base = Observation {
        generation: 2,
        sequence: 11,
        observed_at: 101,
        endpoint: ProbeEndpoint::Confirmation,
        result: ProbeResult::Failed(Failure::Tls),
    };
    let ctx = ObservationContext {
        now: 120,
        policy: POLICY,
        probes_enabled: true,
        capability: Capability::Supported,
    };
    for (observation, expected) in [
        (
            Observation {
                generation: 1,
                ..base
            },
            ObservationReason::WrongGeneration,
        ),
        (
            Observation {
                observed_at: 121,
                ..base
            },
            ObservationReason::Future,
        ),
        (
            Observation {
                observed_at: 19,
                ..base
            },
            ObservationReason::Stale,
        ),
        (
            Observation {
                sequence: 10,
                ..base
            },
            ObservationReason::OutOfOrder,
        ),
        (
            Observation {
                sequence: 9,
                ..base
            },
            ObservationReason::OutOfOrder,
        ),
        (
            Observation {
                observed_at: 99,
                ..base
            },
            ObservationReason::OutOfOrder,
        ),
        (
            Observation {
                result: ProbeResult::Unsupported,
                ..base
            },
            ObservationReason::Unsupported,
        ),
    ] {
        assert_eq!(h.observe(observation, ctx), (h, expected));
    }
    for (context, expected) in [
        (
            ObservationContext {
                probes_enabled: false,
                ..ctx
            },
            ObservationReason::ProbesStopped,
        ),
        (
            ObservationContext {
                capability: Capability::Unknown,
                ..ctx
            },
            ObservationReason::CapabilityNotSupported,
        ),
        (
            ObservationContext {
                capability: Capability::Unsupported,
                ..ctx
            },
            ObservationReason::CapabilityNotSupported,
        ),
        (
            ObservationContext {
                policy: HealthPolicy {
                    freshness_ms: 0,
                    ..POLICY
                },
                ..ctx
            },
            ObservationReason::InvalidPolicy,
        ),
    ] {
        assert_eq!(h.observe(base, context), (h, expected));
    }
}

#[test]
fn confirmation_cannot_be_replayed_or_carried_across_stale_gap() {
    let first = failure(Health::new(1), 1, 10, ProbeEndpoint::Primary);
    let o = Observation {
        generation: 1,
        sequence: 2,
        observed_at: 11,
        endpoint: ProbeEndpoint::Confirmation,
        result: ProbeResult::Failed(Failure::Timeout),
    };
    let ctx = ObservationContext {
        now: 11,
        policy: POLICY,
        probes_enabled: true,
        capability: Capability::Supported,
    };
    let (second, _) = first.observe(o, ctx);
    assert_eq!(
        second.observe(o, ctx),
        (second, ObservationReason::OutOfOrder)
    );
    let after_gap = failure(second, 3, 112, ProbeEndpoint::Confirmation);
    assert_eq!(after_gap.state(112, POLICY), HealthState::Unstable);
    assert_eq!(
        failure(after_gap, 4, 113, ProbeEndpoint::Confirmation).state(113, POLICY),
        HealthState::Unstable
    );
}

#[test]
fn table_flapping_does_not_confirm_failure_or_erase_recent_errors() {
    let mut pool = [candidate(1, 1), candidate(2, 500)];
    for seq in 2..8 {
        let at = seq + 10;
        pool[0].tcp = if seq % 2 == 0 {
            failure(pool[0].tcp, seq, at, ProbeEndpoint::Primary)
        } else {
            success(pool[0].tcp, seq, at, 1)
        };
        let s = snapshot(&pool);
        assert_ne!(pool[0].tcp.state(s.now, POLICY), HealthState::Unavailable);
        assert_eq!(select(&s).active, Some(ConnectionId(2)));
        assert!(pool[0].tcp.recent_failures(s.now, POLICY) > 0);
    }
    assert_eq!(pool[0].tcp.recent_failures(517, POLICY), 0);
}

#[test]
fn sticky_failover_then_recovery_never_fails_back() {
    let mut pool = [candidate(1, 90), candidate(2, 1)];
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).reason, DecisionReason::StickyActive);
    assert_eq!(select(&s).active, s.active);
    pool[0].tcp = failure(pool[0].tcp, 2, 11, ProbeEndpoint::Primary);
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).reason, DecisionReason::AwaitingConfirmation);
    assert_eq!(select(&s).active, s.active);
    pool[0].tcp = failure(pool[0].tcp, 3, 12, ProbeEndpoint::Confirmation);
    pool[0].tcp = failure(pool[0].tcp, 4, 13, ProbeEndpoint::Confirmation);
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    let next = select(&s);
    assert_eq!(next.reason, DecisionReason::ConfirmedFailure);
    assert_eq!(next.active, Some(ConnectionId(2)));
    pool[0].tcp = success(pool[0].tcp, 5, 14, 0);
    let mut s = snapshot(&pool);
    s.active = next.active;
    assert_eq!(select(&s).active, next.active);
    assert_eq!(
        pool[0].state(s.now, POLICY, next.active),
        ConnectionState::Standby
    );
}

#[test]
fn health_and_fresh_success_precede_latency() {
    let mut pool = [candidate(1, 1), candidate(2, 1000)];
    pool[0].tcp = success(
        failure(pool[0].tcp, 2, 11, ProbeEndpoint::Primary),
        3,
        12,
        1,
    );
    assert_eq!(select(&snapshot(&pool)).active, Some(ConnectionId(2)));
    pool[0] = candidate(1, 1);
    pool[1].tcp = success(pool[1].tcp, 2, 11, 1000);
    assert_eq!(select(&snapshot(&pool)).active, Some(ConnectionId(2)));
}

#[test]
fn table_upstream_outage_unknown_stale_and_recovery() {
    let mut pool = [candidate(1, 10), candidate(2, 20)];
    pool[0].tcp = failed(pool[0].tcp, 2, 11);
    for (upstream, reason) in [
        (
            Some(Upstream {
                generation: 7,
                observed_at: 20,
                state: UpstreamState::Down,
            }),
            DecisionReason::UpstreamUnavailable,
        ),
        (None, DecisionReason::UpstreamUnknown),
        (
            Some(Upstream {
                generation: 7,
                observed_at: 20,
                state: UpstreamState::Unknown,
            }),
            DecisionReason::UpstreamUnknown,
        ),
        (
            Some(Upstream {
                generation: 6,
                observed_at: 20,
                state: UpstreamState::Up,
            }),
            DecisionReason::UpstreamUnknown,
        ),
        (
            Some(Upstream {
                generation: 7,
                observed_at: 21,
                state: UpstreamState::Up,
            }),
            DecisionReason::UpstreamUnknown,
        ),
    ] {
        let mut s = snapshot(&pool);
        s.active = Some(ConnectionId(1));
        s.upstream = upstream;
        let d = select(&s);
        assert_eq!(d.reason, reason);
        assert_eq!((d.tcp, d.udp), (Path::Block, Path::Block));
        assert_eq!(d.preference, s.active);
    }
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).active, Some(ConnectionId(2)));
    s.now = 101;
    s.upstream.as_mut().unwrap().observed_at = 0;
    assert_eq!(select(&s).reason, DecisionReason::UpstreamUnknown);
}

#[test]
fn table_pause_disabled_draining_and_generation_reset() {
    let mut pool = [candidate(1, 10), candidate(2, 20)];
    let mut s = snapshot(&pool);
    s.paused = true;
    s.active = Some(ConnectionId(1));
    let paused = select(&s);
    assert_eq!(paused.reason, DecisionReason::Paused);
    assert!(!paused.probes_enabled);
    assert_eq!(paused.tcp, Path::Block);
    assert_eq!(paused.preference, s.active);
    for c in &mut pool {
        c.generation = 2;
        c.tcp = Health::new(2);
        c.udp = Health::new(2);
    }
    let mut s = snapshot(&pool);
    s.active = paused.preference;
    assert_eq!(select(&s).reason, DecisionReason::AwaitingFreshProbe);
    pool[0].tcp = success(pool[0].tcp, 1, 15, 10);
    let mut s = snapshot(&pool);
    s.active = paused.preference;
    assert_eq!(select(&s).active, paused.preference);
    pool[1] = candidate(2, 20);
    pool[0].draining = true;
    pool[0].intent.enabled = false;
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(
        pool[0].state(20, POLICY, s.active),
        ConnectionState::Draining
    );
    assert_eq!(select(&s).reason, DecisionReason::ActiveWithdrawn);
    assert_eq!(select(&s).active, Some(ConnectionId(2)));
    pool[0].draining = false;
    assert_eq!(pool[0].state(20, POLICY, None), ConnectionState::Disabled);
    pool[1].intent.enabled = false;
    assert_eq!(select(&snapshot(&pool)).reason, DecisionReason::Paused);
}

#[test]
fn table_all_unavailable_direct_requires_explicit_policy_and_fresh_upstream() {
    let mut pool = [candidate(1, 10)];
    pool[0].tcp = failed(pool[0].tcp, 2, 11);
    for (direct, upstream, expected, reason) in [
        (
            DirectPolicy::Forbidden,
            UpstreamState::Up,
            Path::Block,
            DecisionReason::AllUnavailable,
        ),
        (
            DirectPolicy::ExplicitlyConfirmed,
            UpstreamState::Up,
            Path::Direct,
            DecisionReason::DirectFallback,
        ),
        (
            DirectPolicy::ExplicitlyConfirmed,
            UpstreamState::Down,
            Path::Block,
            DecisionReason::UpstreamUnavailable,
        ),
        (
            DirectPolicy::ExplicitlyConfirmed,
            UpstreamState::Unknown,
            Path::Block,
            DecisionReason::AllUnavailable,
        ),
    ] {
        let mut s = snapshot(&pool);
        s.direct = direct;
        s.upstream.as_mut().unwrap().state = upstream;
        let d = select(&s);
        assert_eq!(d.reason, reason);
        assert_eq!(d.tcp, expected);
        assert_eq!(d.udp, expected);
    }
    pool[0].tcp = success(pool[0].tcp, 5, 15, 40);
    assert_eq!(select(&snapshot(&pool)).active, Some(ConnectionId(1)));
}

#[test]
fn table_mixed_protocol_fixtures_have_no_protocol_priority_or_implicit_udp() {
    // Protocol labels are fixture metadata, deliberately absent from the scoring API.
    let fixtures = [
        ("NaiveProxy", Capability::Unsupported),
        ("VLESS", Capability::Supported),
        ("Shadowsocks", Capability::Unknown),
        ("WireGuard", Capability::Supported),
    ];
    for winner in 0..fixtures.len() {
        let pool: Vec<_> = fixtures
            .iter()
            .enumerate()
            .map(|(i, (_, udp))| {
                let mut c = candidate(if i == winner { 1 } else { i as u64 + 2 }, 50);
                c.udp_capability = *udp;
                if *udp == Capability::Supported {
                    c.udp = success(c.udp, 1, 10, 60);
                }
                c
            })
            .collect();
        let d = select(&snapshot(&pool));
        assert_eq!(d.active, Some(ConnectionId(1)), "{}", fixtures[winner].0);
        let expected = if fixtures[winner].1 == Capability::Supported {
            Path::Connection(ConnectionId(1))
        } else {
            Path::Block
        };
        assert_eq!(d.udp, expected);
        assert_eq!(d.tcp, Path::Connection(ConnectionId(1)));
    }
    let mut naive = candidate(1, 1);
    naive.udp_capability = Capability::Unsupported;
    let o = Observation {
        generation: 1,
        sequence: 2,
        observed_at: 11,
        endpoint: ProbeEndpoint::Primary,
        result: ProbeResult::Unsupported,
    };
    let ctx = ObservationContext {
        now: 11,
        policy: POLICY,
        capability: Capability::Unsupported,
        probes_enabled: true,
    };
    assert_eq!(naive.udp.observe(o, ctx).0, naive.udp);
    let pool = [naive];
    let d = select(&snapshot(&pool));
    assert_eq!(d.active, Some(naive.id));
    assert_eq!(d.udp, Path::Block);
    assert_eq!(naive.state(20, POLICY, d.active), ConnectionState::Active);
}

#[test]
fn tcp_success_never_proves_udp_and_udp_failure_never_rotates_tcp() {
    let mut pool = [candidate(1, 50), candidate(2, 1)];
    pool[0].udp_capability = Capability::Supported;
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).udp, Path::Block);
    pool[0].udp = failed(pool[0].udp, 1, 10);
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).active, s.active);
    assert_eq!(select(&s).udp, Path::Block);
    pool[0].udp = success(pool[0].udp, 4, 15, 80);
    let mut s = snapshot(&pool);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).udp, Path::Connection(ConnectionId(1)));
}

#[test]
fn table_admission_staleness_generation_and_duplicate_identity_fail_closed() {
    for variant in 0..6 {
        let mut pool = [candidate(1, 10)];
        match variant {
            0 => pool[0].admitted = false,
            1 => pool[0].tcp_capability = Capability::Unknown,
            2 => pool[0].tcp_capability = Capability::Unsupported,
            3 => pool[0].generation = 2,
            4 => pool[0].intent.in_pool = false,
            _ => pool[0].draining = true,
        }
        let d = select(&snapshot(&pool));
        assert_eq!(d.active, None);
        assert_eq!(d.tcp, Path::Block);
    }
    let pool = [candidate(1, 10)];
    let mut s = snapshot(&pool);
    s.now = 111;
    s.upstream = None;
    assert_eq!(select(&s).tcp, Path::Block);
    s.active = Some(ConnectionId(1));
    assert_eq!(select(&s).reason, DecisionReason::AwaitingFreshProbe);
    assert_eq!(
        pool[0].state(s.now, POLICY, s.active),
        ConnectionState::Checking
    );
    let pool = [candidate(1, 10), candidate(1, 20)];
    assert_eq!(
        select(&snapshot(&pool)).reason,
        DecisionReason::InvalidSnapshot
    );
}

#[test]
fn state_vocabulary_is_derived_separately_from_intent() {
    let mut c = candidate(1, 10);
    assert_eq!(c.state(20, POLICY, Some(c.id)), ConnectionState::Active);
    assert_eq!(c.state(20, POLICY, None), ConnectionState::Standby);
    c.tcp = failure(c.tcp, 2, 11, ProbeEndpoint::Primary);
    assert_eq!(c.state(20, POLICY, Some(c.id)), ConnectionState::Unstable);
    c.tcp = failed(c.tcp, 3, 12);
    assert_eq!(c.state(20, POLICY, None), ConnectionState::Unavailable);
    assert_eq!(c.intent, ENABLED);
    assert_eq!(c.state(113, POLICY, None), ConnectionState::Unavailable);
    assert_eq!(c.state(115, POLICY, None), ConnectionState::Checking);
}

#[test]
fn arithmetic_and_freshness_boundaries_are_deterministic() {
    let h = success(Health::new(1), 1, 0, u32::MAX);
    assert_eq!(h.state(100, POLICY), HealthState::Healthy);
    assert_eq!(h.state(101, POLICY), HealthState::Checking);
    let h = success(h, 2, 1, u32::MAX);
    assert_eq!(h.latency_ms(), Some(u32::MAX));
    let h = success(h, u64::MAX, u64::MAX, 0);
    assert_eq!(h.state(u64::MAX, POLICY), HealthState::Healthy);
    assert_eq!(h.state(0, POLICY), HealthState::Checking);
}

#[test]
fn confirmed_failure_stays_unavailable_until_success_or_expiry() {
    let h = failed(Health::new(1), 1, 10);
    for endpoint in [ProbeEndpoint::Primary, ProbeEndpoint::Confirmation] {
        let next = failure(h, 4, 20, endpoint);
        assert_eq!(next.state(20, POLICY), HealthState::Unavailable);
        let mut c = candidate(1, 10);
        c.tcp = next;
        let pool = [c, candidate(2, 50)];
        let mut s = snapshot(&pool);
        s.active = Some(ConnectionId(1));
        assert_eq!(select(&s).active, Some(ConnectionId(2)));
    }
}

#[test]
fn tie_break_is_stable_under_every_four_candidate_permutation() {
    fn check(pool: &mut [Candidate], start: usize) {
        if start == pool.len() {
            assert_eq!(select(&snapshot(pool)).active, Some(ConnectionId(1)));
            return;
        }
        for i in start..pool.len() {
            pool.swap(start, i);
            check(pool, start + 1);
            pool.swap(start, i);
        }
    }
    check(
        &mut [
            candidate(4, 20),
            candidate(3, 20),
            candidate(2, 20),
            candidate(1, 20),
        ],
        0,
    );
}

#[test]
fn stale_udp_and_reconfigured_tcp_cannot_reuse_previous_evidence() {
    let mut c = candidate(1, 10);
    c.udp_capability = Capability::Supported;
    c.udp = success(c.udp, 1, 0, 10);
    c.tcp = success(c.tcp, 2, 100, 10);
    let pool = [c];
    let mut s = snapshot(&pool);
    s.now = 101;
    assert_eq!(select(&s).tcp, Path::Connection(c.id));
    assert_eq!(select(&s).udp, Path::Block);
    c.generation = 2;
    let pool = [c];
    let mut s = snapshot(&pool);
    s.active = Some(c.id);
    assert_eq!(select(&s).reason, DecisionReason::AwaitingFreshProbe);
    assert_eq!(select(&s).tcp, Path::Block);
}
