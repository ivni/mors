//! Transaction model for simulations only; no runtime/shell ownership handoff.
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Reason {
    Busy,
    Invalid,
    RevisionConflict,
    OwnershipConflict,
    Config,
    Ca,
    Start,
    Tcp,
    Policy,
    Cancelled,
    Journal,
    Unknown,
    RestoreConflict,
}
impl std::fmt::Display for Reason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "transaction: {self:?}")
    }
}
impl std::error::Error for Reason {}
pub type Result<T> = std::result::Result<T, Reason>;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Fence {
    pub revision: u64,
    pub epoch: u64,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Resource {
    UdpGuard,
    Config,
    Ca,
    Process,
    TcpRoute,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Value {
    Blocked,
    Absent,
    Generation(u64),
    Running(u64),
    Proxy(u64),
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Cell {
    pub owner: u64,
    pub revision: u64,
    pub value: Value,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Change {
    pub resource: Resource,
    pub before: Cell,
    pub after: Cell,
    pub restored: Cell,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Plan {
    pub operation: u64,
    pub owner: u64,
    pub fence: Fence,
    pub changes: Vec<Change>,
}
impl Plan {
    pub fn validate(&self) -> Result<()> {
        let resources = [
            Resource::UdpGuard,
            Resource::Config,
            Resource::Ca,
            Resource::Process,
            Resource::TcpRoute,
        ];
        if self.operation == 0
            || self.owner == 0
            || self.fence.epoch == 0
            || self.changes.len() != resources.len()
        {
            return Err(Reason::Invalid);
        }
        for (change, resource) in self.changes.iter().zip(resources) {
            if change.resource != resource
                || change.before.owner != self.owner
                || change.after.owner != self.owner
                || change.restored.owner != self.owner
                || change.before.revision.checked_add(1) != Some(change.after.revision)
                || change.after.revision.checked_add(1) != Some(change.restored.revision)
                || change.restored.value != change.before.value
            {
                return Err(Reason::Invalid);
            }
            let valid = match resource {
                Resource::UdpGuard => {
                    change.before.value == Value::Blocked && change.after.value == Value::Blocked
                }
                Resource::Config | Resource::Ca => {
                    matches!(change.before.value, Value::Absent | Value::Generation(_))
                        && change.after.value == Value::Generation(self.operation)
                }
                Resource::Process => {
                    matches!(change.before.value, Value::Absent | Value::Running(_))
                        && change.after.value == Value::Running(self.operation)
                }
                Resource::TcpRoute => {
                    matches!(change.before.value, Value::Blocked | Value::Proxy(_))
                        && change.after.value == Value::Proxy(self.operation)
                }
            };
            if !valid {
                return Err(Reason::Invalid);
            }
        }
        Ok(())
    }
}
#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Prepared,
    Applying,
    Verifying,
    Restoring,
    RecoveryRequired,
    Committed,
    RolledBack,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub schema: u32,
    pub plan: Plan,
    pub phase: Phase,
    /// Includes the step whose durable intent exists, even if its effect is unknown.
    pub attempted: usize,
    pub reason: Option<Reason>,
}
impl Record {
    pub fn validate(&self) -> Result<()> {
        self.plan.validate()?;
        if self.schema != 1
            || self.attempted > self.plan.changes.len()
            || (self.phase == Phase::Prepared && self.attempted != 0)
            || (matches!(self.phase, Phase::Verifying | Phase::Committed)
                && self.attempted != self.plan.changes.len())
        {
            return Err(Reason::Invalid);
        }
        Ok(())
    }
    pub fn terminal(&self) -> bool {
        matches!(self.phase, Phase::Committed | Phase::RolledBack)
    }
}
/// Implementations hold an exclusive volatile lease for their entire lifetime.
/// save must sync file, atomically replace, then sync directory; uncertain writes
/// are errors. A failed save never permits a subsequent mutation.
pub trait Journal {
    fn load(&mut self) -> Result<Option<Record>>;
    fn save(&mut self, record: &Record) -> Result<()>;
}
/// All effects require an immediate fence/ownership/CAS check in the adapter.
/// This is a fake adapter contract, NOT proof that Keenetic supports atomic CAS.
pub trait TransactionAdapter {
    fn fence(&self) -> Fence;
    fn prepare(&self, operation: u64, expected: Fence) -> Result<Plan>;
    fn validate(&self, plan: &Plan) -> Result<()>;
    fn apply(&mut self, plan: &Plan, change: &Change) -> Result<()>;
    fn verify(&self, plan: &Plan) -> Result<()>;
    /// Must accept before, after, or the predetermined restored state only.
    /// Must preserve foreign/new values and keep protected traffic fail-closed.
    fn restore(&mut self, plan: &Plan, change: &Change, authority: Fence) -> Result<()>;
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Failure {
    pub reason: Reason,
    pub recovery_required: bool,
}
pub type Outcome = std::result::Result<(), Failure>;
pub struct Executor<J, A> {
    journal: J,
    adapter: A,
}
impl<J: Journal, A: TransactionAdapter> Executor<J, A> {
    pub fn new(journal: J, adapter: A) -> Self {
        Self { journal, adapter }
    }
    pub fn into_parts(self) -> (J, A) {
        (self.journal, self.adapter)
    }
    pub fn adapter(&self) -> &A {
        &self.adapter
    }
    fn persist(&mut self, record: &Record) -> Outcome {
        record
            .validate()
            .and_then(|()| self.journal.save(record))
            .map_err(|_| Failure {
                reason: Reason::Journal,
                recovery_required: true,
            })
    }
    fn load(&mut self) -> std::result::Result<Option<Record>, Failure> {
        let record = self.journal.load().map_err(|_| Failure {
            reason: Reason::Journal,
            recovery_required: true,
        })?;
        if let Some(record) = &record {
            record.validate().map_err(|_| Failure {
                reason: Reason::Journal,
                recovery_required: true,
            })?;
        }
        Ok(record)
    }
    /// Cooperative cancellation is observed between steps, including before commit.
    /// A crash/panic drops the volatile lease; startup must call recover.
    pub fn execute(
        &mut self,
        operation: u64,
        expected: Fence,
        mut cancelled: impl FnMut() -> bool,
    ) -> Outcome {
        if let Some(record) = self.load()? {
            if !record.terminal() || record.plan.operation == operation {
                return Err(Failure {
                    reason: Reason::Busy,
                    recovery_required: !record.terminal(),
                });
            }
        }
        let plan = self
            .adapter
            .prepare(operation, expected)
            .and_then(|p| {
                p.validate()?;
                self.adapter.validate(&p)?;
                Ok(p)
            })
            .map_err(|reason| Failure {
                reason,
                recovery_required: false,
            })?;
        let mut record = Record {
            schema: 1,
            plan,
            phase: Phase::Prepared,
            attempted: 0,
            reason: None,
        };
        self.persist(&record)?;
        for index in 0..record.plan.changes.len() {
            if cancelled() {
                return self.fail(record, Reason::Cancelled);
            }
            record.phase = Phase::Applying;
            record.attempted = index + 1;
            self.persist(&record)?;
            if let Err(reason) = self
                .adapter
                .apply(&record.plan, &record.plan.changes[index])
            {
                return self.fail(record, reason);
            }
        }
        record.phase = Phase::Verifying;
        self.persist(&record)?;
        if let Err(reason) = self.adapter.verify(&record.plan) {
            return self.fail(record, reason);
        }
        if cancelled() {
            return self.fail(record, Reason::Cancelled);
        }
        record.phase = Phase::Committed;
        self.persist(&record)
    }
    fn fail(&mut self, mut record: Record, reason: Reason) -> Outcome {
        record.reason = Some(reason);
        let authority = record.plan.fence;
        self.rollback(record, authority)?;
        Err(Failure {
            reason,
            recovery_required: false,
        })
    }
    fn rollback(&mut self, mut record: Record, authority: Fence) -> Outcome {
        record.phase = Phase::Restoring;
        self.persist(&record)?;
        let mut failure = None;
        // Each restore is idempotent. The entire rollback intent is durable first.
        for change in record.plan.changes[..record.attempted].iter().rev() {
            if let Err(reason) = self.adapter.restore(&record.plan, change, authority) {
                failure = Some(reason);
            }
        }
        record.phase = if failure.is_some() {
            Phase::RecoveryRequired
        } else {
            Phase::RolledBack
        };
        if record.reason.is_none() {
            record.reason = Some(Reason::Unknown);
        }
        self.persist(&record)?;
        match failure {
            Some(reason) => Err(Failure {
                reason,
                recovery_required: true,
            }),
            None => Ok(()),
        }
    }
    /// Recovery never promotes an incomplete operation to success, even if every
    /// effect happened. Current authority fences recovery, old plan fences apply.
    pub fn recover(&mut self, authority: Fence) -> Outcome {
        if self.adapter.fence() != authority {
            return Err(Failure {
                reason: Reason::OwnershipConflict,
                recovery_required: true,
            });
        }
        if let Some(record) = self.load()? {
            if !record.terminal() {
                self.rollback(record, authority)?;
            }
        }
        Ok(())
    }
}
