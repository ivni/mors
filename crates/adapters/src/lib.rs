//! Typed engine boundary. Config/secret handling and lifecycle effects are deferred.
//! Adapters never select the active connection or write the durable registry.

use mors_domain::{Capability, Operation, Transport, TransportContract};

pub trait Adapter {
    fn transport_contract(&self) -> TransportContract;
    fn transport_capability(&self, transport: Transport) -> Capability;
    fn operation_capability(&self, operation: Operation) -> Capability;
}

/// External Chromium client; no HTTP/2 or TLS implementation in Rust.
/// No process spawning, listener, endpoint, credentials or network access here.
#[derive(Default)]
pub struct NaiveProxy;

impl Adapter for NaiveProxy {
    fn transport_contract(&self) -> TransportContract {
        TransportContract::TcpOnly
    }

    fn transport_capability(&self, transport: Transport) -> Capability {
        match transport {
            Transport::Tcp => Capability::Unknown,
            Transport::Udp => Capability::Unsupported,
        }
    }

    fn operation_capability(&self, _operation: Operation) -> Capability {
        Capability::Unknown
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn naive_contract_does_not_admit_an_unverified_runtime() {
        let adapter: &dyn Adapter = &NaiveProxy;
        assert_eq!(adapter.transport_contract(), TransportContract::TcpOnly);
        assert_eq!(
            adapter.transport_capability(Transport::Tcp),
            Capability::Unknown
        );
        assert_eq!(
            adapter.transport_capability(Transport::Udp),
            Capability::Unsupported
        );
        for operation in [
            Operation::Discover,
            Operation::Read,
            Operation::Create,
            Operation::Update,
            Operation::Delete,
            Operation::Enable,
            Operation::Disable,
            Operation::Probe,
            Operation::Select,
            Operation::Drain,
            Operation::Restore,
        ] {
            assert_eq!(adapter.operation_capability(operation), Capability::Unknown);
        }
    }
}
