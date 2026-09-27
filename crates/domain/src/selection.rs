//! Side-effect-free selection plans. Applying and committing a plan belongs to the coordinator.
use crate::{
    health::{fresh, Health, HealthPolicy, HealthState, Time},
    Capability,
};
use std::cmp::Reverse;

/// Opaque registry identity; carries neither credentials nor a protocol priority.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct ConnectionId(pub u64);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Intent {
    pub enabled: bool,
    pub in_pool: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Candidate {
    pub id: ConnectionId,
    pub generation: u64,
    pub intent: Intent,
    /// Caller-provided admission proof including platform/DNS/loop and warning gates.
    /// Merely naming a protocol or passing a TCP probe cannot set this gate.
    pub admitted: bool,
    pub draining: bool,
    pub tcp_capability: Capability,
    pub udp_capability: Capability,
    pub tcp: Health,
    pub udp: Health,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ConnectionState {
    Checking,
    Active,
    Standby,
    Unstable,
    Unavailable,
    Draining,
    Disabled,
}

impl Candidate {
    fn eligible(&self) -> bool {
        self.intent.enabled
            && self.intent.in_pool
            && self.admitted
            && !self.draining
            && self.tcp_capability == Capability::Supported
    }

    fn tcp_state(&self, now: Time, policy: HealthPolicy) -> HealthState {
        if self.tcp.generation() != self.generation {
            HealthState::Checking
        } else {
            self.tcp.state(now, policy)
        }
    }

    pub fn state(
        &self,
        now: Time,
        policy: HealthPolicy,
        selected: Option<ConnectionId>,
    ) -> ConnectionState {
        if self.draining {
            return ConnectionState::Draining;
        }
        if !self.intent.enabled || !self.intent.in_pool {
            return ConnectionState::Disabled;
        }
        if !self.eligible() {
            return ConnectionState::Checking;
        }
        match self.tcp_state(now, policy) {
            HealthState::Checking => ConnectionState::Checking,
            HealthState::Healthy if selected == Some(self.id) => ConnectionState::Active,
            HealthState::Healthy => ConnectionState::Standby,
            HealthState::Unstable => ConnectionState::Unstable,
            HealthState::Unavailable => ConnectionState::Unavailable,
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum UpstreamState {
    Up,
    Down,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Upstream {
    pub generation: u64,
    pub observed_at: Time,
    pub state: UpstreamState,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DirectPolicy {
    Forbidden,
    ExplicitlyConfirmed,
}

pub struct Snapshot<'a> {
    pub now: Time,
    pub generation: u64,
    pub policy: HealthPolicy,
    pub paused: bool,
    /// Last committed active/preference, not a claim of current health.
    pub active: Option<ConnectionId>,
    pub direct: DirectPolicy,
    pub upstream: Option<Upstream>,
    pub candidates: &'a [Candidate],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Path {
    Block,
    Connection(ConnectionId),
    Direct,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecisionReason {
    InvalidSnapshot,
    Unconfigured,
    Paused,
    UpstreamUnavailable,
    UpstreamUnknown,
    StickyActive,
    AwaitingConfirmation,
    AwaitingFreshProbe,
    InitialSelection,
    ConfirmedFailure,
    ActiveWithdrawn,
    AllUnavailable,
    DirectFallback,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Decision {
    /// Only one proposed active for all new sessions. None when paths are closed/direct.
    pub active: Option<ConnectionId>,
    /// Kept independently across upstream outages and pause; not committed by this module.
    pub preference: Option<ConnectionId>,
    pub tcp: Path,
    pub udp: Path,
    pub reason: DecisionReason,
    pub probes_enabled: bool,
}

/// Replacements receive exactly the same immutable inputs and contract scenarios.
/// No adapter, filesystem, RCI, executor or clock handles are passed here.
pub trait SelectionStrategy {
    fn select(&self, snapshot: &Snapshot<'_>) -> Decision;
}

#[derive(Default)]
pub struct StickyHealth;

impl StickyHealth {
    fn blocked(snapshot: &Snapshot<'_>, reason: DecisionReason, probes_enabled: bool) -> Decision {
        Decision {
            active: None,
            preference: snapshot.active,
            tcp: Path::Block,
            udp: Path::Block,
            reason,
            probes_enabled,
        }
    }

    fn selected(
        snapshot: &Snapshot<'_>,
        candidate: &Candidate,
        reason: DecisionReason,
    ) -> Decision {
        let udp = if candidate.udp_capability == Capability::Supported
            && candidate.udp.generation() == candidate.generation
            && candidate.udp.state(snapshot.now, snapshot.policy) == HealthState::Healthy
        {
            Path::Connection(candidate.id)
        } else {
            Path::Block
        };
        Decision {
            active: Some(candidate.id),
            preference: Some(candidate.id),
            tcp: Path::Connection(candidate.id),
            udp,
            reason,
            probes_enabled: true,
        }
    }
}

impl SelectionStrategy for StickyHealth {
    fn select(&self, snapshot: &Snapshot<'_>) -> Decision {
        let s = snapshot;
        // Ambiguous identities must never turn input ordering into route ownership.
        if !s.policy.valid()
            || s.candidates
                .iter()
                .enumerate()
                .any(|(i, c)| s.candidates[..i].iter().any(|previous| previous.id == c.id))
        {
            return Self::blocked(s, DecisionReason::InvalidSnapshot, false);
        }
        if s.candidates.is_empty() {
            return Self::blocked(s, DecisionReason::Unconfigured, false);
        }
        if s.paused
            || s.candidates
                .iter()
                .all(|c| !c.intent.enabled || !c.intent.in_pool)
        {
            return Self::blocked(s, DecisionReason::Paused, false);
        }
        let upstream = s
            .upstream
            .filter(|u| {
                u.generation == s.generation && fresh(u.observed_at, s.now, s.policy.freshness_ms)
            })
            .map_or(UpstreamState::Unknown, |u| u.state);
        if upstream == UpstreamState::Down {
            return Self::blocked(s, DecisionReason::UpstreamUnavailable, true);
        }
        let active = s
            .candidates
            .iter()
            .find(|c| Some(c.id) == s.active && c.eligible());
        let reason = if let Some(active) = active {
            match active.tcp_state(s.now, s.policy) {
                HealthState::Healthy => {
                    return Self::selected(s, active, DecisionReason::StickyActive)
                }
                HealthState::Unstable => {
                    return Self::selected(s, active, DecisionReason::AwaitingConfirmation)
                }
                HealthState::Checking => {
                    return Self::blocked(s, DecisionReason::AwaitingFreshProbe, true)
                }
                HealthState::Unavailable if upstream != UpstreamState::Up => {
                    return Self::blocked(s, DecisionReason::UpstreamUnknown, true);
                }
                HealthState::Unavailable => DecisionReason::ConfirmedFailure,
            }
        } else if s.active.is_some() {
            DecisionReason::ActiveWithdrawn
        } else {
            DecisionReason::InitialSelection
        };
        // Fresh success is mandatory; recent failures and freshness precede latency.
        let best = s
            .candidates
            .iter()
            .filter(|c| c.eligible() && c.tcp_state(s.now, s.policy) == HealthState::Healthy)
            .min_by_key(|c| {
                (
                    c.tcp.recent_failures(s.now, s.policy),
                    Reverse(c.tcp.last_success()),
                    c.tcp.latency_ms().unwrap_or(u32::MAX),
                    c.id,
                )
            });
        if let Some(best) = best {
            return Self::selected(s, best, reason);
        }
        if s.direct == DirectPolicy::ExplicitlyConfirmed && upstream == UpstreamState::Up {
            return Decision {
                active: None,
                preference: s.active,
                tcp: Path::Direct,
                udp: Path::Direct,
                reason: DecisionReason::DirectFallback,
                probes_enabled: true,
            };
        }
        Self::blocked(s, DecisionReason::AllUnavailable, true)
    }
}
