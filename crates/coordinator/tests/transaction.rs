use mors_coordinator::{fake_transaction::FakeNaiveProxy, transaction::*};
use mors_storage::{Connection, Endpoint, Id, Kind, Profile, Registry, Tls, Trust};
use std::sync::{Arc, Mutex};
#[derive(Clone, Default)]
struct Memory {
    record: Arc<Mutex<Option<Record>>>,
    writes: usize,
    crash: Option<usize>,
}
impl Journal for Memory {
    fn load(&mut self) -> Result<Option<Record>> {
        Ok(self.record.lock().unwrap().clone())
    }
    fn save(&mut self, record: &Record) -> Result<()> {
        self.writes += 1;
        if self.crash == Some(self.writes * 2 - 1) {
            panic!("power cut before persist");
        }
        *self.record.lock().unwrap() = Some(record.clone());
        if self.crash == Some(self.writes * 2) {
            panic!("power cut after persist");
        }
        Ok(())
    }
}
fn fake() -> FakeNaiveProxy {
    let id = Id::new("11111111111111111111111111111111").unwrap();
    let registry = Registry {
        revision: 9,
        connections: vec![Connection {
            id: id.clone(),
            kind: Kind::NaiveProxy,
            name: "private-name-marker".into(),
            enabled: true,
            confirmed: true,
            revision: 1,
            profile: Some(Profile::NaiveProxy {
                version: 1,
                endpoint: Endpoint {
                    host: "private-endpoint.invalid".into(),
                    port: 443,
                },
                auth: id.clone(),
                tls: Tls {
                    server_name: "private-sni.invalid".into(),
                    revision: 1,
                    trust: Trust::System,
                },
            }),
        }],
        ..Registry::default()
    };
    FakeNaiveProxy::new(&registry, &id, 7, 3).unwrap()
}
const FENCE: Fence = Fence {
    revision: 9,
    epoch: 3,
};
fn safe(adapter: &FakeNaiveProxy) {
    assert_eq!(adapter.observe(Resource::UdpGuard).value, Value::Blocked);
    assert!(matches!(
        adapter.observe(Resource::TcpRoute).value,
        Value::Blocked | Value::Proxy(_)
    ));
}
#[test]
fn success_requires_verified_commit_and_journal_is_private_metadata() {
    let mut executor = Executor::new(Memory::default(), fake());
    executor.execute(1, FENCE, || false).unwrap();
    let (journal, adapter) = executor.into_parts();
    safe(&adapter);
    let record = journal.record.lock().unwrap().clone().unwrap();
    assert_eq!(record.phase, Phase::Committed);
    let text = serde_json::to_string(&record).unwrap();
    for marker in ["private-", "endpoint", "auth", "server_name", "password"] {
        assert!(!text.contains(marker));
    }
}
#[test]
fn classified_validation_start_tcp_and_policy_failures_never_succeed() {
    for reason in [
        Reason::Config,
        Reason::Ca,
        Reason::Start,
        Reason::Tcp,
        Reason::Policy,
    ] {
        let mut adapter = fake();
        match reason {
            Reason::Config => adapter.config_valid = false,
            Reason::Ca => adapter.ca_valid = false,
            Reason::Start => adapter.start_ok = false,
            Reason::Tcp => adapter.tcp_ok = false,
            Reason::Policy => adapter.policy_ok = false,
            _ => unreachable!(),
        }
        let mut executor = Executor::new(Memory::default(), adapter);
        assert_eq!(
            executor.execute(1, FENCE, || false),
            Err(Failure {
                reason,
                recovery_required: false
            })
        );
        safe(executor.adapter());
        assert_eq!(
            executor.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
    }
}
#[test]
fn stale_revision_and_foreign_ownership_are_rejected_without_journal_writes() {
    for reason in [Reason::RevisionConflict, Reason::OwnershipConflict] {
        let mut adapter = fake();
        if reason == Reason::OwnershipConflict {
            adapter.external_edit(Resource::Ca, 999, Value::Absent);
        }
        let expected = if reason == Reason::RevisionConflict {
            Fence {
                revision: 8,
                ..FENCE
            }
        } else {
            FENCE
        };
        let mut executor = Executor::new(Memory::default(), adapter);
        assert_eq!(
            executor.execute(1, expected, || false).unwrap_err().reason,
            reason
        );
        assert_eq!(executor.into_parts().0.writes, 0);
    }
}
#[test]
fn partial_apply_errors_restore_all_owned_steps() {
    for resource in [
        Resource::UdpGuard,
        Resource::Config,
        Resource::Ca,
        Resource::Process,
        Resource::TcpRoute,
    ] {
        let mut adapter = fake();
        adapter.fail_after = Some(resource);
        let mut executor = Executor::new(Memory::default(), adapter);
        assert_eq!(
            executor.execute(1, FENCE, || false),
            Err(Failure {
                reason: Reason::Unknown,
                recovery_required: false
            })
        );
        assert_eq!(
            executor.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
        assert_eq!(
            executor.adapter().observe(Resource::Process).value,
            Value::Absent
        );
        executor.recover(FENCE).unwrap();
        safe(executor.adapter());
    }
}
#[test]
fn cancellation_at_every_boundary_restores_and_never_reports_success() {
    for boundary in 1..=6 {
        let mut executor = Executor::new(Memory::default(), fake());
        let mut calls = 0;
        let error = executor
            .execute(1, FENCE, || {
                calls += 1;
                calls == boundary
            })
            .unwrap_err();
        assert_eq!(error.reason, Reason::Cancelled);
        assert!(!error.recovery_required);
        assert_eq!(
            executor.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
    }
}
#[test]
fn power_loss_at_every_forward_journal_boundary_is_recoverable() {
    // prepared + five intents + verifying + committed; before/after each save.
    for boundary in 1..=16 {
        let journal = Memory {
            crash: Some(boundary),
            ..Memory::default()
        };
        let mut executor = Executor::new(journal, fake());
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| executor.execute(
                1,
                FENCE,
                || false
            )))
            .is_err()
        );
        let (mut journal, adapter) = executor.into_parts();
        journal.crash = None;
        let committed = journal
            .record
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|r| r.phase == Phase::Committed);
        let mut reboot = Executor::new(journal, adapter);
        reboot.recover(FENCE).unwrap();
        reboot.recover(FENCE).unwrap();
        safe(reboot.adapter());
        assert_eq!(
            reboot.adapter().observe(Resource::TcpRoute).value,
            if committed {
                Value::Proxy(1)
            } else {
                Value::Blocked
            }
        );
    }
}
fn applied() -> (Record, FakeNaiveProxy) {
    let mut adapter = fake();
    let plan = adapter.prepare(1, FENCE).unwrap();
    for change in &plan.changes {
        adapter.apply(&plan, change).unwrap();
    }
    (
        Record {
            schema: 1,
            plan,
            phase: Phase::Verifying,
            attempted: 5,
            reason: None,
        },
        adapter,
    )
}
#[test]
fn restore_preserves_external_values_including_aba_and_foreign_objects() {
    for resource in [
        Resource::Config,
        Resource::Ca,
        Resource::Process,
        Resource::TcpRoute,
    ] {
        for foreign in [false, true] {
            let (record, mut adapter) = applied();
            let old_value = adapter.observe(resource).value;
            adapter.external_edit(resource, if foreign { 99 } else { 7 }, old_value);
            let external = adapter.observe(resource);
            let journal = Memory::default();
            *journal.record.lock().unwrap() = Some(record);
            let mut executor = Executor::new(journal, adapter);
            assert!(executor.recover(FENCE).unwrap_err().recovery_required);
            assert_eq!(executor.adapter().observe(resource), external);
            assert!(executor.recover(FENCE).is_err());
            assert_eq!(executor.adapter().observe(resource), external);
            safe(executor.adapter());
            assert_eq!(
                executor.execute(2, FENCE, || false).unwrap_err().reason,
                Reason::Busy
            );
        }
    }
}
#[test]
fn old_epoch_cannot_apply_or_restore_but_new_authority_can_recover() {
    let (record, mut adapter) = applied();
    adapter.current_fence.epoch += 1;
    assert_eq!(
        adapter.apply(&record.plan, &record.plan.changes[0]),
        Err(Reason::OwnershipConflict)
    );
    let current = adapter.current_fence;
    let journal = Memory::default();
    *journal.record.lock().unwrap() = Some(record);
    let mut executor = Executor::new(journal, adapter);
    assert!(executor.recover(FENCE).is_err());
    executor.recover(current).unwrap();
    assert_eq!(
        executor.adapter().observe(Resource::TcpRoute).value,
        Value::Blocked
    );
}
#[test]
fn power_loss_during_restore_repeats_only_scoped_idempotent_changes() {
    for boundary in 1..=4 {
        let (record, adapter) = applied();
        let journal = Memory {
            crash: Some(boundary),
            ..Memory::default()
        };
        *journal.record.lock().unwrap() = Some(record);
        let mut executor = Executor::new(journal, adapter);
        assert!(
            std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| executor.recover(FENCE)))
                .is_err()
        );
        let (mut journal, adapter) = executor.into_parts();
        journal.crash = None;
        let mut reboot = Executor::new(journal, adapter);
        reboot.recover(FENCE).unwrap();
        reboot.recover(FENCE).unwrap();
        assert_eq!(
            reboot.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
    }
}
#[test]
fn restore_can_restart_after_each_individual_effect() {
    for completed in 0..=5 {
        let (mut record, mut adapter) = applied();
        record.phase = Phase::Restoring;
        for change in record.plan.changes.iter().rev().take(completed) {
            adapter.restore(&record.plan, change, FENCE).unwrap();
        }
        let journal = Memory::default();
        *journal.record.lock().unwrap() = Some(record);
        let mut reboot = Executor::new(journal, adapter);
        reboot.recover(FENCE).unwrap();
        assert_eq!(
            reboot.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
        assert_eq!(
            reboot.adapter().observe(Resource::Process).value,
            Value::Absent
        );
    }
}
#[test]
fn invalid_or_future_journal_blocks_all_mutations() {
    let (record, adapter) = applied();
    for kind in 0..3 {
        let mut bad = record.clone();
        match kind {
            0 => bad.schema = 99,
            1 => bad.attempted = 100,
            _ => bad.plan.changes.reverse(),
        }
        let journal = Memory::default();
        *journal.record.lock().unwrap() = Some(bad);
        let mut executor = Executor::new(journal, adapter.clone());
        assert_eq!(executor.recover(FENCE).unwrap_err().reason, Reason::Journal);
        assert_eq!(
            executor.execute(2, FENCE, || false).unwrap_err().reason,
            Reason::Journal
        );
    }
}

#[derive(Clone)]
struct Drift {
    inner: FakeNaiveProxy,
    step: usize,
    at: usize,
    epoch: bool,
}
impl TransactionAdapter for Drift {
    fn fence(&self) -> Fence {
        self.inner.fence()
    }
    fn prepare(&self, operation: u64, expected: Fence) -> Result<Plan> {
        self.inner.prepare(operation, expected)
    }
    fn validate(&self, plan: &Plan) -> Result<()> {
        self.inner.validate(plan)
    }
    fn apply(&mut self, plan: &Plan, change: &Change) -> Result<()> {
        self.step += 1;
        if self.step == self.at {
            if self.epoch {
                self.inner.current_fence.epoch += 1;
            } else {
                self.inner.current_fence.revision += 1;
            }
        }
        self.inner.apply(plan, change)
    }
    fn verify(&self, plan: &Plan) -> Result<()> {
        self.inner.verify(plan)?;
        if self.at == 6 {
            Err(Reason::Tcp)
        } else {
            Ok(())
        }
    }
    fn restore(&mut self, plan: &Plan, change: &Change, authority: Fence) -> Result<()> {
        self.inner.restore(plan, change, authority)
    }
}
#[test]
fn drift_between_steps_fences_old_worker_and_requires_current_recovery_authority() {
    for at in 1..=5 {
        for epoch in [false, true] {
            let adapter = Drift {
                inner: fake(),
                step: 0,
                at,
                epoch,
            };
            let mut executor = Executor::new(Memory::default(), adapter);
            let error = executor.execute(1, FENCE, || false).unwrap_err();
            assert_eq!(
                error.reason,
                if epoch {
                    Reason::OwnershipConflict
                } else {
                    Reason::RevisionConflict
                }
            );
            assert!(error.recovery_required);
            let current = executor.adapter().fence();
            executor.recover(current).unwrap();
            safe(&executor.adapter().inner);
            assert_eq!(
                executor.adapter().inner.observe(Resource::TcpRoute).value,
                Value::Blocked
            );
        }
    }
}
#[cfg(target_os = "linux")]
#[test]
fn file_journal_restart_recovers_each_partial_apply() {
    use mors_coordinator::transaction_journal::FileJournal;
    use std::{fs, os::unix::fs::PermissionsExt};
    for attempted in 1..=5 {
        let dir = std::env::temp_dir().join(format!(
            "mors-executor-{}",
            mors_storage::Store::new_id().unwrap().as_str()
        ));
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        let mut adapter = fake();
        let plan = adapter.prepare(1, FENCE).unwrap();
        let mut journal = FileJournal::open(&dir).unwrap();
        let record = Record {
            schema: 1,
            plan,
            phase: Phase::Applying,
            attempted,
            reason: None,
        };
        journal.save(&record).unwrap();
        for change in record.plan.changes.iter().take(attempted) {
            adapter.apply(&record.plan, change).unwrap();
        }
        drop(journal);
        let mut reboot = Executor::new(FileJournal::open(&dir).unwrap(), adapter);
        reboot.recover(FENCE).unwrap();
        reboot.recover(FENCE).unwrap();
        assert_eq!(
            reboot.adapter().observe(Resource::TcpRoute).value,
            Value::Blocked
        );
        let (mut journal, _) = reboot.into_parts();
        assert_eq!(journal.load().unwrap().unwrap().phase, Phase::RolledBack);
        drop(journal);
        fs::remove_dir_all(dir).unwrap();
    }
}

#[test]
fn failed_final_verification_rolls_back_instead_of_committing() {
    let adapter = Drift {
        inner: fake(),
        step: 0,
        at: 6,
        epoch: false,
    };
    let mut executor = Executor::new(Memory::default(), adapter);
    assert_eq!(
        executor.execute(1, FENCE, || false),
        Err(Failure {
            reason: Reason::Tcp,
            recovery_required: false
        })
    );
    let (journal, adapter) = executor.into_parts();
    assert_eq!(
        journal.record.lock().unwrap().as_ref().unwrap().phase,
        Phase::RolledBack
    );
    assert_eq!(
        adapter.inner.observe(Resource::TcpRoute).value,
        Value::Blocked
    );
}
