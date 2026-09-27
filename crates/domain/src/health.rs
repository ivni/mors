//! Pure, replayable health transitions. Time and probe results are supplied by the caller.
use crate::Capability;

/// Monotonic milliseconds within one coordinator epoch (never wall clock).
pub type Time = u64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct HealthPolicy {
    pub freshness_ms: u64,
    pub failure_window_ms: u64,
}

impl Default for HealthPolicy {
    fn default() -> Self {
        Self {
            freshness_ms: 90_000,
            failure_window_ms: 300_000,
        }
    }
}

impl HealthPolicy {
    pub fn valid(self) -> bool {
        self.freshness_ms > 0 && self.failure_window_ms >= self.freshness_ms
    }
}

pub(crate) fn fresh(at: Time, now: Time, ttl: u64) -> bool {
    now.checked_sub(at).is_some_and(|age| age <= ttl)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum HealthState {
    Checking,
    Healthy,
    Unstable,
    Unavailable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProbeEndpoint {
    Primary,
    Confirmation,
}

/// Closed classifications; no raw backend diagnostics or endpoint data.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Failure {
    Timeout,
    Dns,
    Tls,
    Authentication,
    Transport,
    UnexpectedResponse,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProbeResult {
    Success { latency_ms: u32 },
    Failed(Failure),
    Unsupported,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Observation {
    /// Must change on reconfiguration, pause/resume, disable/enable or restart.
    pub generation: u64,
    /// Coordinator-issued increasing probe ticket, assigned before dispatch.
    pub sequence: u64,
    pub observed_at: Time,
    pub endpoint: ProbeEndpoint,
    pub result: ProbeResult,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ObservationReason {
    Accepted,
    InvalidPolicy,
    ProbesStopped,
    CapabilityNotSupported,
    WrongGeneration,
    Future,
    Stale,
    OutOfOrder,
    Unsupported,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct ObservationContext {
    pub now: Time,
    pub policy: HealthPolicy,
    pub probes_enabled: bool,
    pub capability: Capability,
}

/// One transport of one connection. TCP and UDP never share this snapshot.
/// All fields are private so callers cannot manufacture Healthy/confirmed failure.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Health {
    generation: u64,
    last: Option<Observation>,
    success_at: Option<Time>,
    failure_at: Option<Time>,
    failures: u32,
    confirming: bool,
    confirmations: u8,
    latency_ms: Option<u32>,
}

impl Health {
    pub fn new(generation: u64) -> Self {
        Self {
            generation,
            last: None,
            success_at: None,
            failure_at: None,
            failures: 0,
            confirming: false,
            confirmations: 0,
            latency_ms: None,
        }
    }

    pub fn generation(&self) -> u64 {
        self.generation
    }

    pub fn state(&self, now: Time, policy: HealthPolicy) -> HealthState {
        let Some(last) = self.last else {
            return HealthState::Checking;
        };
        if !policy.valid() || !fresh(last.observed_at, now, policy.freshness_ms) {
            return HealthState::Checking;
        }
        match last.result {
            ProbeResult::Success { .. } => HealthState::Healthy,
            ProbeResult::Failed(_) if self.confirmations >= 2 => HealthState::Unavailable,
            ProbeResult::Failed(_) => HealthState::Unstable,
            ProbeResult::Unsupported => HealthState::Checking,
        }
    }

    pub fn recent_failures(&self, now: Time, policy: HealthPolicy) -> u32 {
        if self
            .failure_at
            .is_some_and(|at| fresh(at, now, policy.failure_window_ms))
        {
            self.failures
        } else {
            0
        }
    }

    pub fn last_success(&self) -> Option<Time> {
        self.success_at
    }
    pub fn latency_ms(&self) -> Option<u32> {
        self.latency_ms
    }

    /// Returns a new volatile snapshot; never reads a clock or performs a probe.
    /// A failure needs two distinct subsequent Confirmation tickets. Repeated primary
    /// failures cannot impersonate the independent endpoint confirmation protocol.
    pub fn observe(
        &self,
        observation: Observation,
        context: ObservationContext,
    ) -> (Self, ObservationReason) {
        let ObservationContext {
            now,
            policy,
            probes_enabled,
            capability,
        } = context;
        let rejected = if !policy.valid() {
            Some(ObservationReason::InvalidPolicy)
        } else if !probes_enabled {
            Some(ObservationReason::ProbesStopped)
        } else if capability != Capability::Supported {
            Some(ObservationReason::CapabilityNotSupported)
        } else if observation.generation != self.generation {
            Some(ObservationReason::WrongGeneration)
        } else if observation.observed_at > now {
            Some(ObservationReason::Future)
        } else if !fresh(observation.observed_at, now, policy.freshness_ms) {
            Some(ObservationReason::Stale)
        } else if self.last.is_some_and(|last| {
            observation.sequence <= last.sequence || observation.observed_at < last.observed_at
        }) {
            Some(ObservationReason::OutOfOrder)
        } else if observation.result == ProbeResult::Unsupported {
            Some(ObservationReason::Unsupported)
        } else {
            None
        };
        if let Some(reason) = rejected {
            return (*self, reason);
        }
        let mut next = *self;
        if !self.last.is_some_and(|last| {
            fresh(
                last.observed_at,
                observation.observed_at,
                policy.freshness_ms,
            )
        }) {
            next.confirming = false;
            next.confirmations = 0;
            next.latency_ms = None;
        }
        match observation.result {
            ProbeResult::Success { latency_ms } => {
                next.success_at = Some(observation.observed_at);
                next.confirming = false;
                next.confirmations = 0;
                next.latency_ms = Some(next.latency_ms.map_or(latency_ms, |old| {
                    ((u64::from(old) * 3 + u64::from(latency_ms)) / 4) as u32
                }));
            }
            ProbeResult::Failed(_) => {
                next.failures = self
                    .recent_failures(observation.observed_at, policy)
                    .saturating_add(1);
                next.failure_at = Some(observation.observed_at);
                if next.confirmations >= 2 {
                    // A confirmed failure is sticky until success or expiry.
                } else if next.confirming && observation.endpoint == ProbeEndpoint::Confirmation {
                    next.confirmations = next.confirmations.saturating_add(1).min(2);
                } else {
                    next.confirming = true;
                    next.confirmations = 0;
                }
            }
            ProbeResult::Unsupported => unreachable!(),
        }
        next.last = Some(observation);
        (next, ObservationReason::Accepted)
    }
}
