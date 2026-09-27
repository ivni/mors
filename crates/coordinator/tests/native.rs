use mors_adapters::keenetic::State;
use mors_adapters::native::{Action, Backend, Error, Observation, Owned, Source};
use mors_coordinator::{
    native::{lifecycle, Request},
    transaction::Reason,
};
use std::time::Duration;
struct Unavailable;
impl Source for Unavailable {
    fn observe(&mut self, _: &Owned, _: Duration) -> Result<Observation, Error> {
        Err(Error::Transport)
    }
    fn set(&mut self, _: &Owned, _: State, _: Action, _: Duration) -> Result<(), Error> {
        panic!("no write authorized")
    }
}
fn backend() -> Backend<Unavailable> {
    Backend::new(
        Unavailable,
        Owned {
            id: "Wireguard7".into(),
            alias: "Mors0123456789abcdef0123456789abcdef".into(),
            system_name: "nwg7".into(),
            kind: "Wireguard".into(),
            owner: 1,
            epoch: 2,
            incarnation: 3,
        },
    )
    .unwrap()
}
#[test]
fn exclusion_never_observes_or_stops_vpn() {
    assert_eq!(
        lifecycle(&mut backend(), Request::ExcludeFromPool, Duration::ZERO),
        Ok(None)
    );
}
#[test]
fn errors_go_to_coordinator_and_mutations_require_reconciliation() {
    for request in [
        Request::Observe,
        Request::UserStart,
        Request::AutomaticStart,
        Request::StopVpn,
    ] {
        let failure = lifecycle(&mut backend(), request, Duration::from_secs(1)).unwrap_err();
        assert_eq!(failure.reason, Reason::Unknown);
        assert_eq!(failure.recovery_required, request != Request::Observe);
    }
}
