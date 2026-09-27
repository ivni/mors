use mors_adapters::{
    keenetic::{parse_interfaces, State},
    native::{Action, Backend, Error, Observation, Owned, Source},
};
use mors_coordinator::{
    native::Request,
    native_transaction::{Executor, Journal, Phase, Record},
    transaction::Reason,
};
use std::{cell::RefCell, rc::Rc, time::Duration};
const TIMEOUT: Duration = Duration::from_millis(100);
fn owned() -> Owned {
    Owned {
        id: "PPTP7".into(),
        alias: "Mors0123456789abcdef0123456789abcdef".into(),
        system_name: "ppp7".into(),
        kind: "PPTP".into(),
        owner: 1,
        epoch: 1,
        incarnation: 1,
    }
}
struct World {
    identity: Owned,
    up: bool,
    writes: usize,
    error: Option<Error>,
    unknown: bool,
}
#[derive(Clone)]
struct Fake(Rc<RefCell<World>>);
impl Fake {
    fn new() -> Self {
        Self(Rc::new(RefCell::new(World {
            identity: owned(),
            up: true,
            writes: 0,
            error: None,
            unknown: false,
        })))
    }
    fn backend(&self) -> Backend<Self> {
        Backend::new(self.clone(), owned()).unwrap()
    }
}
impl Source for Fake {
    fn observe(&mut self, _: &Owned, _: Duration) -> Result<Observation, Error> {
        let w = self.0.borrow();
        let state = if w.up { "up" } else { "down" };
        let value = serde_json::json!([{ "id": "PPTP7", "interface-name": "ppp7", "type": "PPTP", "state": if w.unknown { "unknown" } else { state }, "link": state, "connected": if w.up { "yes" } else { "no" } }]);
        Ok(Observation {
            ownership: Some(w.identity.clone()),
            interface: parse_interfaces(200, &serde_json::to_vec(&value).unwrap())
                .unwrap()
                .remove(0),
            validated_client: true,
        })
    }
    fn set(
        &mut self,
        expected: &Owned,
        before: State,
        action: Action,
        _: Duration,
    ) -> Result<(), Error> {
        let mut w = self.0.borrow_mut();
        if &w.identity != expected || (before == State::Up) != w.up {
            return Err(Error::Ownership);
        }
        w.writes += 1;
        w.up = action == Action::Up;
        w.error.map_or(Ok(()), Err)
    }
}
#[derive(Clone, Default)]
struct Memory(Rc<RefCell<MemoryState>>);
#[derive(Default)]
struct MemoryState {
    record: Option<Record>,
    saves: usize,
    fail: usize,
    publish_before_failure: bool,
}
impl Journal for Memory {
    fn load(&mut self) -> Result<Option<Record>, Reason> {
        Ok(self.0.borrow().record.clone())
    }
    fn save(&mut self, record: &Record) -> Result<(), Reason> {
        let mut s = self.0.borrow_mut();
        s.saves += 1;
        let fails = s.saves == s.fail;
        if !fails || s.publish_before_failure {
            s.record = Some(record.clone());
        }
        if fails {
            Err(Reason::Journal)
        } else {
            Ok(())
        }
    }
}
fn initialized() -> (Executor<Memory, Fake>, Memory, Fake) {
    let journal = Memory::default();
    let world = Fake::new();
    let mut executor = Executor::new(journal.clone(), world.backend());
    executor.grant(1, TIMEOUT).unwrap();
    (executor, journal, world)
}
#[test]
fn durable_stop_blocks_automatic_start_after_restart() {
    let (mut e, j, world) = initialized();
    e.execute(2, 1, Request::StopVpn, TIMEOUT).unwrap();
    drop(e);
    let mut e = Executor::new(j.clone(), world.backend());
    assert!(e.recover(TIMEOUT).unwrap().user_down);
    assert_eq!(
        e.execute(3, 2, Request::AutomaticStart, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::Policy
    );
    e.execute(3, 2, Request::UserStart, TIMEOUT).unwrap();
    assert!(!j.0.borrow().record.as_ref().unwrap().user_down);
    assert_eq!(world.0.borrow().writes, 2);
}
#[test]
fn durable_exclusion_preserves_running_vpn() {
    let (mut e, j, world) = initialized();
    e.execute(2, 1, Request::ExcludeFromPool, TIMEOUT).unwrap();
    assert!(j.0.borrow().record.as_ref().unwrap().excluded);
    assert!(world.0.borrow().up);
    assert_eq!(world.0.borrow().writes, 0);
    assert_eq!(
        e.execute(3, 2, Request::AutomaticStart, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::Policy
    );
}
#[test]
fn no_grant_stale_revision_or_duplicate_request_can_mutate() {
    let world = Fake::new();
    let mut empty = Executor::new(Memory::default(), world.backend());
    assert_eq!(
        empty
            .execute(1, 1, Request::StopVpn, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::OwnershipConflict
    );
    let (mut e, _, world) = initialized();
    assert_eq!(
        e.execute(2, 9, Request::StopVpn, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::RevisionConflict
    );
    assert_eq!(
        e.execute(1, 1, Request::StopVpn, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::Invalid
    );
    assert_eq!(world.0.borrow().writes, 0);
}
#[test]
fn each_uncertain_journal_save_poison_blocks_effects_and_recovery_never_writes() {
    for point in 1..=3 {
        for published in [false, true] {
            let (mut e, j, world) = initialized();
            {
                let mut state = j.0.borrow_mut();
                state.fail = state.saves + point;
                state.publish_before_failure = published;
            }
            assert_eq!(
                e.execute(2, 1, Request::StopVpn, TIMEOUT)
                    .unwrap_err()
                    .reason,
                Reason::Journal
            );
            assert_eq!(world.0.borrow().writes, usize::from(point == 3));
            assert_eq!(
                e.execute(3, 2, Request::UserStart, TIMEOUT)
                    .unwrap_err()
                    .reason,
                Reason::Journal
            );
            let writes = world.0.borrow().writes;
            drop(e);
            j.0.borrow_mut().fail = 0;
            let mut reopened = Executor::new(j, world.backend());
            let recovered = reopened.recover(TIMEOUT).unwrap();
            assert!(matches!(
                recovered.phase,
                Phase::Committed | Phase::Reconciled
            ));
            assert_eq!(world.0.borrow().writes, writes);
        }
    }
}
#[test]
fn uncertain_applied_stop_is_reconciled_without_inverse_write() {
    let (mut e, j, world) = initialized();
    world.0.borrow_mut().error = Some(Error::Transport);
    assert!(
        e.execute(2, 1, Request::StopVpn, TIMEOUT)
            .unwrap_err()
            .recovery_required
    );
    assert_eq!(
        j.0.borrow().record.as_ref().unwrap().phase,
        Phase::RecoveryRequired
    );
    world.0.borrow_mut().error = None;
    let recovered = e.recover(TIMEOUT).unwrap();
    assert_eq!(recovered.phase, Phase::Reconciled);
    assert!(recovered.user_down);
    assert_eq!(recovered.reason, Some(Reason::Unknown));
    assert_eq!(world.0.borrow().writes, 1);
    e.recover(TIMEOUT).unwrap();
    assert_eq!(world.0.borrow().writes, 1);
}
#[test]
fn recovered_external_down_is_not_undone() {
    let (mut e, j, world) = initialized();
    {
        let mut state = j.0.borrow_mut();
        let r = state.record.as_mut().unwrap();
        r.phase = Phase::Applying;
        r.request = Some(Request::UserStart);
    }
    world.0.borrow_mut().up = false;
    assert!(e.recover(TIMEOUT).unwrap().user_down);
    assert_eq!(
        e.execute(2, 1, Request::AutomaticStart, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::Policy
    );
    assert_eq!(world.0.borrow().writes, 0);
}
#[test]
fn replacement_during_recovery_permanently_revokes_grant() {
    let (mut e, j, world) = initialized();
    {
        let mut state = j.0.borrow_mut();
        let r = state.record.as_mut().unwrap();
        r.phase = Phase::Applying;
        r.request = Some(Request::UserStart);
    }
    world.0.borrow_mut().identity.incarnation += 1;
    assert_eq!(
        e.recover(TIMEOUT).err().unwrap().reason,
        Reason::OwnershipConflict
    );
    assert!(j.0.borrow().record.as_ref().unwrap().revoked);
    world.0.borrow_mut().identity = owned();
    assert_eq!(
        e.recover(TIMEOUT).err().unwrap().reason,
        Reason::OwnershipConflict
    );
    assert_eq!(world.0.borrow().writes, 0);
}
#[test]
fn unknown_poststate_keeps_recovery_pending() {
    let (mut e, j, world) = initialized();
    {
        let mut state = j.0.borrow_mut();
        let r = state.record.as_mut().unwrap();
        r.phase = Phase::Applying;
        r.request = Some(Request::UserStart);
    }
    world.0.borrow_mut().unknown = true;
    assert!(e.recover(TIMEOUT).is_err());
    assert_eq!(
        e.execute(2, 1, Request::UserStart, TIMEOUT)
            .unwrap_err()
            .reason,
        Reason::Busy
    );
    assert_eq!(world.0.borrow().writes, 0);
}
#[cfg(target_os = "linux")]
#[test]
fn durable_native_journal_reopens_and_shares_exclusion_with_proxy_journal() {
    use mors_coordinator::{
        native_transaction::FileJournal, transaction_journal::FileJournal as ProxyJournal,
    };
    use std::{fs, os::unix::fs::PermissionsExt};
    let path = std::env::temp_dir().join(format!(
        "mors-native-{}",
        mors_storage::Store::new_id().unwrap().as_str()
    ));
    fs::create_dir(&path).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    let journal = FileJournal::open(&path).unwrap();
    assert!(matches!(ProxyJournal::open(&path), Err(Reason::Busy)));
    let world = Fake::new();
    let mut e = Executor::new(journal, world.backend());
    e.grant(1, TIMEOUT).unwrap();
    e.execute(2, 1, Request::StopVpn, TIMEOUT).unwrap();
    drop(e);
    let mut e = Executor::new(FileJournal::open(&path).unwrap(), world.backend());
    assert!(e.recover(TIMEOUT).unwrap().user_down);
    drop(e);
    let mut wrong_schema = ProxyJournal::open(&path).unwrap();
    assert!(wrong_schema.load_record().unwrap().is_none());
    drop(wrong_schema);
    fs::write(path.join("native.json"), b"{\"native_schema\":99}").unwrap();
    let mut broken = FileJournal::open(&path).unwrap();
    assert!(broken.load().is_err());
    drop(broken);
    fs::remove_dir_all(path).unwrap();
}

#[cfg(target_os = "linux")]
#[test]
fn fresh_aliases_are_valid_and_not_reused() {
    let a = mors_coordinator::native_transaction::fresh_alias().unwrap();
    let b = mors_coordinator::native_transaction::fresh_alias().unwrap();
    assert_ne!(a, b);
    let mut binding = owned();
    binding.alias = a;
    assert!(binding.valid());
    binding.alias = b;
    assert!(binding.valid());
}
