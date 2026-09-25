//! Pure contracts for registry, health/selection and adapters.
//! No I/O, persistence, clock, secrets or selection policy in this scaffold.

/// In-process contract version, not a dynamic Rust plugin ABI.
pub const ADAPTER_CONTRACT_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Capability {
    /// Requires scoped evidence and preflight in a future implementation.
    Supported,
    Unsupported,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Operation {
    Discover,
    Read,
    Create,
    Update,
    Delete,
    Enable,
    Disable,
    Probe,
    Select,
    Drain,
    Restore,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Transport {
    Tcp,
    Udp,
}

/// A protocol constraint is not proof of readiness or production admission.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TransportContract {
    TcpOnly,
}
