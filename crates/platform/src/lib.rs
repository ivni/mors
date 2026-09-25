//! Boundary for scoped routing apply, observed verification and restore.
//! No platform implementation or router mutation is available in this scaffold.

use mors_domain::Capability;

/// Routing admission is separate from engine readiness.
/// This interface reports admission only; it cannot apply a route.
pub trait RoutingPlatform {
    fn routing_capability(&self) -> Capability;
}
