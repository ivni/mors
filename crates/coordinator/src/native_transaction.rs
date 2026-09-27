//! Durable native ownership and lifecycle intent. Recovery only observes: it never
//! replays a stale up/down or overwrites an external administrative change.
use crate::{
    native::{lifecycle, Request},
    transaction::{Failure, Reason},
};
use mors_adapters::native::{Backend, Owned, Source, Status};
use serde::{Deserialize, Serialize};
use std::time::Duration;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Phase {
    Prepared,
    Applying,
    Committed,
    RecoveryRequired,
    Reconciled,
}
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Record {
    pub native_schema: u32,
    pub owned: Owned,
    pub revision: u64,
    pub operation: u64,
    /// None is the initial explicit ownership grant, not a lifecycle command.
    pub request: Option<Request>,
    pub phase: Phase,
    pub excluded: bool,
    pub user_down: bool,
    /// Losing the binding revokes this grant; rediscovery never restores it.
    pub revoked: bool,
    pub reason: Option<Reason>,
}
impl Record {
    pub fn validate(&self) -> Result<(), Reason> {
        if self.native_schema != 2
            || !self.owned.valid()
            || self.revision == 0
            || self.operation == 0
            || self.request == Some(Request::Observe)
            || (self.revoked && self.phase != Phase::RecoveryRequired)
            || (matches!(
                self.phase,
                Phase::Prepared | Phase::Applying | Phase::Committed
            ) && self.reason.is_some())
            || (matches!(self.phase, Phase::RecoveryRequired | Phase::Reconciled)
                && self.reason.is_none())
            || (self.phase == Phase::Applying && self.request.is_none())
            || (self.request == Some(Request::ExcludeFromPool) && !self.excluded)
            || (self.request == Some(Request::StopVpn) && !self.user_down)
            || (self.revoked && self.reason != Some(Reason::OwnershipConflict))
        {
            return Err(Reason::Invalid);
        }
        Ok(())
    }
    fn terminal(&self) -> bool {
        matches!(self.phase, Phase::Committed | Phase::Reconciled)
    }
}
/// Journal implementors must serialize writers and poison uncertain saves.
/// The production implementation reuses #73's descriptor-relative Linux journal.
pub trait Journal {
    fn load(&mut self) -> Result<Option<Record>, Reason>;
    fn save(&mut self, record: &Record) -> Result<(), Reason>;
}
#[cfg(target_os = "linux")]
impl crate::transaction_journal::DurableRecord for Record {
    const CURRENT: &'static str = "native.json";
    const PENDING: &'static str = ".native.pending";
    fn validate(&self) -> Result<(), Reason> {
        Record::validate(self)
    }
    fn is_prepared(&self) -> bool {
        self.phase == Phase::Prepared
    }
}
#[cfg(target_os = "linux")]
pub type FileJournal = crate::transaction_journal::RecordJournal<Record>;
#[cfg(target_os = "linux")]
impl Journal for FileJournal {
    fn load(&mut self) -> Result<Option<Record>, Reason> {
        self.load_record()
    }
    fn save(&mut self, record: &Record) -> Result<(), Reason> {
        self.save_record(record)
    }
}
fn failure(reason: Reason, recovery_required: bool) -> Failure {
    Failure {
        reason,
        recovery_required,
    }
}

pub struct Executor<J, S> {
    journal: J,
    backend: Backend<S>,
    poisoned: bool,
}
impl<J: Journal, S: Source> Executor<J, S> {
    pub fn new(journal: J, backend: Backend<S>) -> Self {
        Self {
            journal,
            backend,
            poisoned: false,
        }
    }
    pub fn into_parts(self) -> (J, Backend<S>) {
        (self.journal, self.backend)
    }
    fn load(&mut self) -> Result<Option<Record>, Failure> {
        if self.poisoned {
            return Err(failure(Reason::Journal, true));
        }
        let record = self
            .journal
            .load()
            .map_err(|_| failure(Reason::Journal, true))?;
        if let Some(record) = &record {
            record
                .validate()
                .map_err(|_| failure(Reason::Journal, true))?;
            if &record.owned != self.backend.owned() {
                return Err(failure(Reason::OwnershipConflict, true));
            }
        }
        Ok(record)
    }
    fn save(&mut self, record: &Record) -> Result<(), Failure> {
        if self.poisoned || record.validate().is_err() || self.journal.save(record).is_err() {
            self.poisoned = true;
            return Err(failure(Reason::Journal, true));
        }
        Ok(())
    }
    /// Explicit grant only. The Source must independently prove the binding;
    /// this does not infer ownership from discovery or implement the #92 wizard.
    pub fn grant(&mut self, operation: u64, timeout: Duration) -> Result<(), Failure> {
        if operation == 0 {
            return Err(failure(Reason::Invalid, false));
        }
        if self.load()?.is_some() {
            return Err(failure(Reason::Busy, false));
        }
        let status = lifecycle(&mut self.backend, Request::Observe, timeout)?;
        let mut record = Record {
            native_schema: 2,
            owned: self.backend.owned().clone(),
            revision: 1,
            operation,
            request: None,
            phase: Phase::Prepared,
            excluded: false,
            user_down: status == Some(Status::Down),
            revoked: false,
            reason: None,
        };
        self.save(&record)?;
        record.phase = Phase::Committed;
        self.save(&record)
    }
    /// Caller supplies the current durable revision (CAS) and a strictly increasing
    /// operation ID. Journal lease serializes this with every native operation.
    pub fn execute(
        &mut self,
        operation: u64,
        revision: u64,
        request: Request,
        timeout: Duration,
    ) -> Result<Option<Status>, Failure> {
        let mut record = self
            .load()?
            .ok_or(failure(Reason::OwnershipConflict, false))?;
        if record.revoked {
            return Err(failure(Reason::OwnershipConflict, true));
        }
        if !record.terminal() {
            return Err(failure(Reason::Busy, true));
        }
        if record.revision != revision {
            return Err(failure(Reason::RevisionConflict, false));
        }
        if operation <= record.operation || request == Request::Observe {
            return Err(failure(Reason::Invalid, false));
        }
        if request == Request::AutomaticStart && (record.user_down || record.excluded) {
            return Err(failure(Reason::Policy, false));
        }
        record.revision = record
            .revision
            .checked_add(1)
            .ok_or(failure(Reason::Invalid, false))?;
        record.operation = operation;
        record.request = Some(request);
        record.phase = Phase::Prepared;
        record.reason = None;
        match request {
            Request::ExcludeFromPool => record.excluded = true,
            Request::StopVpn => record.user_down = true,
            Request::UserStart => record.user_down = false,
            _ => (),
        }
        self.save(&record)?;
        record.phase = Phase::Applying;
        self.save(&record)?;
        let result = lifecycle(&mut self.backend, request, timeout);
        match result {
            Ok(status) => {
                record.phase = Phase::Committed;
                self.save(&record)?;
                Ok(status)
            }
            Err(error) => {
                record.phase = Phase::RecoveryRequired;
                record.reason = Some(error.reason);
                record.revoked = error.reason == Reason::OwnershipConflict;
                self.save(&record)?;
                Err(failure(error.reason, true))
            }
        }
    }
    /// Recover never changes the router. A Ready result reconciles observed state
    /// but does not promote the interrupted operation to Committed. A new explicit
    /// operation is required for any further mutation; user down survives restart.
    pub fn recover(&mut self, timeout: Duration) -> Result<Record, Failure> {
        let mut record = self
            .load()?
            .ok_or(failure(Reason::OwnershipConflict, false))?;
        if record.revoked {
            return Err(failure(Reason::OwnershipConflict, true));
        }
        if record.terminal() {
            return Ok(record);
        }
        if record.request == Some(Request::ExcludeFromPool) {
            record.phase = Phase::Reconciled;
            record.reason = Some(Reason::Unknown);
            self.save(&record)?;
            return Ok(record);
        }
        match lifecycle(&mut self.backend, Request::Observe, timeout) {
            Ok(Some(status @ (Status::Ready | Status::Down))) => {
                if status == Status::Down {
                    record.user_down = true;
                }
                record.phase = Phase::Reconciled;
                record.reason.get_or_insert(Reason::Unknown);
                self.save(&record)?;
                Ok(record)
            }
            Ok(_) => Err(failure(Reason::Unknown, true)),
            Err(error) => {
                record.phase = Phase::RecoveryRequired;
                record.reason = Some(error.reason);
                record.revoked = error.reason == Reason::OwnershipConflict;
                self.save(&record)?;
                Err(failure(error.reason, true))
            }
        }
    }
}

/// Allocate a fresh 128-bit alias for explicit preparation/adoption. This alone
/// grants no rights and does not rename or save router configuration.
#[cfg(target_os = "linux")]
pub fn fresh_alias() -> Result<String, Reason> {
    let id = mors_storage::Store::new_id().map_err(|_| Reason::Unknown)?;
    Ok(format!("Mors{}", id.as_str()))
}
