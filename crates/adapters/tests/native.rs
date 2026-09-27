use mors_adapters::{
    keenetic::{parse_interfaces, State},
    native::*,
};
use std::{collections::VecDeque, time::Duration};

fn owned() -> Owned {
    Owned {
        id: "Wireguard7".into(),
        alias: "Mors0123456789abcdef0123456789abcdef".into(),
        system_name: "nwg7".into(),
        kind: "Wireguard".into(),
        owner: 1,
        epoch: 2,
        incarnation: 3,
    }
}
fn observation(state: &str, link: &str, connected: &str) -> Observation {
    let data = serde_json::json!([{ "id": "Wireguard7", "interface-name": "nwg7", "type": "Wireguard", "state": state, "link": link, "connected": connected }]);
    Observation {
        ownership: Some(owned()),
        interface: parse_interfaces(200, &serde_json::to_vec(&data).unwrap())
            .unwrap()
            .remove(0),
        validated_client: true,
    }
}
struct Fixture {
    observations: VecDeque<Result<Observation, Error>>,
    last: Observation,
    writes: Vec<(State, Action)>,
    effect: Option<Observation>,
    failure: Option<Error>,
}
impl Fixture {
    fn new(last: Observation) -> Self {
        Self {
            observations: VecDeque::new(),
            last,
            writes: vec![],
            effect: None,
            failure: None,
        }
    }
}
impl Source for Fixture {
    fn observe(&mut self, _: &Owned, timeout: Duration) -> Result<Observation, Error> {
        assert!(!timeout.is_zero());
        self.observations
            .pop_front()
            .unwrap_or_else(|| Ok(self.last.clone()))
    }
    fn set(
        &mut self,
        expected: &Owned,
        before: State,
        action: Action,
        _: Duration,
    ) -> Result<(), Error> {
        // Fake models the conditional mutation promised by the platform port.
        if self.last.ownership.as_ref() != Some(expected)
            || self.last.interface.administrative != before
        {
            return Err(Error::Ownership);
        }
        self.writes.push((before, action));
        if let Some(effect) = self.effect.take() {
            self.last = effect;
        }
        self.failure.map_or(Ok(()), Err)
    }
}
const TIMEOUT: Duration = Duration::from_millis(100);
#[test]
fn readiness_is_observed_and_unknown_is_preserved() {
    for (state, link, connected, expected) in [
        ("up", "up", "yes", Status::Ready),
        ("down", "up", "yes", Status::Down),
        ("up", "down", "no", Status::Unknown),
        ("up", "up", "missing", Status::Unknown),
        ("missing", "up", "yes", Status::Unknown),
    ] {
        let mut backend =
            Backend::new(Fixture::new(observation(state, link, connected)), owned()).unwrap();
        assert_eq!(backend.observe(TIMEOUT), Ok(expected));
        assert!(backend.into_source().writes.is_empty());
    }
}
#[test]
fn start_stop_and_repeated_operations_use_poststate() {
    let mut source = Fixture::new(observation("down", "down", "no"));
    source.effect = Some(observation("up", "up", "yes"));
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(backend.start(StartIntent::User, TIMEOUT), Ok(Status::Ready));
    assert_eq!(backend.start(StartIntent::User, TIMEOUT), Ok(Status::Ready));
    let mut source = backend.into_source();
    assert_eq!(source.writes, [(State::Down, Action::Up)]);
    source.effect = Some(observation("down", "down", "no"));
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(backend.stop(TIMEOUT), Ok(Status::Down));
    assert_eq!(backend.stop(TIMEOUT), Ok(Status::Down));
    assert_eq!(backend.into_source().writes.len(), 2);
}
#[test]
fn successful_command_without_poststate_times_out_and_is_not_retried() {
    let mut backend =
        Backend::new(Fixture::new(observation("down", "down", "no")), owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::User, TIMEOUT),
        Err(Error::Timeout)
    );
    assert_eq!(backend.into_source().writes.len(), 1);
}
#[test]
fn uncertain_write_is_reported_even_when_effect_applied() {
    for error in [Error::Transport, Error::Timeout, Error::Semantic] {
        let mut source = Fixture::new(observation("down", "down", "no"));
        source.effect = Some(observation("up", "up", "yes"));
        source.failure = Some(error);
        let mut backend = Backend::new(source, owned()).unwrap();
        assert_eq!(backend.start(StartIntent::User, TIMEOUT), Err(error));
        assert_eq!(backend.observe(TIMEOUT), Ok(Status::Ready));
        assert_eq!(backend.into_source().writes.len(), 1);
    }
}
#[test]
fn automatic_start_respects_user_down() {
    let mut backend =
        Backend::new(Fixture::new(observation("down", "down", "no")), owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::Automatic, TIMEOUT),
        Err(Error::UserDown)
    );
    assert!(backend.into_source().writes.is_empty());
}
#[test]
fn unknown_administration_does_not_allow_mutation() {
    let mut backend = Backend::new(Fixture::new(observation("?", "up", "yes")), owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::User, TIMEOUT),
        Err(Error::Unknown)
    );
    assert_eq!(backend.stop(TIMEOUT), Err(Error::Unknown));
    assert!(backend.into_source().writes.is_empty());
}
#[test]
fn foreign_reused_or_ambiguous_interfaces_never_get_written() {
    for mode in 0..8 {
        let mut o = observation("down", "down", "no");
        match mode {
            0 => o.ownership = None,
            1 => o.ownership.as_mut().unwrap().incarnation += 1,
            2 => o.ownership.as_mut().unwrap().epoch += 1,
            3 => o.ownership.as_mut().unwrap().owner += 1,
            4 => o.interface.id = Some("Wireguard8".into()),
            5 => o.interface.system_name = None,
            6 => o.interface.kind = Some("Proxy".into()),
            _ => o.validated_client = false,
        }
        let mut backend = Backend::new(Fixture::new(o), owned()).unwrap();
        assert!(matches!(
            backend.start(StartIntent::User, TIMEOUT),
            Err(Error::Ownership | Error::Unsupported)
        ));
        assert!(backend.into_source().writes.is_empty());
    }
}
#[test]
fn replacement_between_read_and_write_is_fenced() {
    let old = observation("down", "down", "no");
    let mut replacement = old.clone();
    replacement.ownership.as_mut().unwrap().incarnation += 1;
    let mut source = Fixture::new(replacement);
    source.observations.push_back(Ok(old));
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::User, TIMEOUT),
        Err(Error::Ownership)
    );
    assert!(backend.into_source().writes.is_empty());
}
#[test]
fn replacement_after_write_is_not_rolled_back() {
    let mut source = Fixture::new(observation("down", "down", "no"));
    let mut replacement = observation("up", "up", "yes");
    replacement.ownership.as_mut().unwrap().incarnation += 1;
    source.effect = Some(replacement);
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::User, TIMEOUT),
        Err(Error::Ownership)
    );
    assert_eq!(backend.into_source().writes.len(), 1);
}
#[test]
fn link_progress_is_polled_without_resetting_already_up_vpn() {
    let mut source = Fixture::new(observation("up", "up", "yes"));
    source
        .observations
        .push_back(Ok(observation("up", "down", "no")));
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(
        backend.start(StartIntent::Automatic, TIMEOUT),
        Ok(Status::Ready)
    );
    assert!(backend.into_source().writes.is_empty());
}
#[test]
fn read_errors_and_invalid_deadlines_prevent_writes() {
    let mut source = Fixture::new(observation("down", "down", "no"));
    source.observations.push_back(Err(Error::Transport));
    let mut backend = Backend::new(source, owned()).unwrap();
    assert_eq!(backend.stop(TIMEOUT), Err(Error::Transport));
    assert_eq!(backend.stop(Duration::ZERO), Err(Error::Invalid));
    assert_eq!(backend.stop(Duration::from_secs(61)), Err(Error::Invalid));
    assert!(backend.into_source().writes.is_empty());
}

#[cfg(target_os = "linux")]
#[test]
fn unvalidated_client_cannot_construct_rci_writer() {
    assert!(matches!(
        LocalNative::new(owned(), false),
        Err(Error::Unsupported)
    ));
}
