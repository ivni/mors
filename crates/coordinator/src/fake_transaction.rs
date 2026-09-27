//! Deliberately inert NaiveProxy simulation; never launches a process or network I/O.
use crate::transaction::*;
use mors_storage::{Id, Kind, Profile, Registry};
use std::collections::BTreeMap;

#[derive(Clone)]
pub struct FakeNaiveProxy {
    pub current_fence: Fence,
    pub owner: u64,
    pub config_valid: bool,
    pub ca_valid: bool,
    pub start_ok: bool,
    pub tcp_ok: bool,
    pub policy_ok: bool,
    cells: BTreeMap<u8, Cell>,
    pub fail_after: Option<Resource>,
}
fn key(r: Resource) -> u8 {
    r as u8
}
impl FakeNaiveProxy {
    /// Consume only validated metadata. Secret/auth/endpoint/CA bytes are never
    /// copied into the plan, journal, errors or Debug.
    pub fn new(registry: &Registry, id: &Id, owner: u64, epoch: u64) -> Result<Self> {
        registry.validate().map_err(|_| Reason::Config)?;
        let connection = registry
            .connections
            .iter()
            .find(|c| &c.id == id)
            .ok_or(Reason::Config)?;
        if !connection.enabled
            || !connection.confirmed
            || connection.kind != Kind::NaiveProxy
            || !matches!(connection.profile, Some(Profile::NaiveProxy { .. }))
            || owner == 0
            || epoch == 0
        {
            return Err(Reason::Config);
        }
        let mut cells = BTreeMap::new();
        for resource in [
            Resource::UdpGuard,
            Resource::Config,
            Resource::Ca,
            Resource::Process,
            Resource::TcpRoute,
        ] {
            let value = if matches!(resource, Resource::UdpGuard | Resource::TcpRoute) {
                Value::Blocked
            } else {
                Value::Absent
            };
            cells.insert(
                key(resource),
                Cell {
                    owner,
                    revision: 1,
                    value,
                },
            );
        }
        Ok(Self {
            current_fence: Fence {
                revision: registry.revision,
                epoch,
            },
            owner,
            config_valid: true,
            ca_valid: true,
            start_ok: true,
            tcp_ok: true,
            policy_ok: true,
            cells,
            fail_after: None,
        })
    }
    pub fn observe(&self, resource: Resource) -> Cell {
        self.cells[&key(resource)]
    }
    /// Test-only external writer; increments revision even when a value is restored.
    pub fn external_edit(&mut self, resource: Resource, owner: u64, value: Value) {
        let cell = self.cells.get_mut(&key(resource)).expect("fixed resource");
        cell.owner = owner;
        cell.value = value;
        cell.revision += 1;
    }
    fn check(&self, fence: Fence, owner: u64) -> Result<()> {
        if owner != self.owner || fence.epoch != self.current_fence.epoch {
            return Err(Reason::OwnershipConflict);
        }
        if fence.revision != self.current_fence.revision {
            return Err(Reason::RevisionConflict);
        }
        Ok(())
    }
}
impl TransactionAdapter for FakeNaiveProxy {
    fn fence(&self) -> Fence {
        self.current_fence
    }
    fn prepare(&self, operation: u64, expected: Fence) -> Result<Plan> {
        self.check(expected, self.owner)?;
        let mut changes = vec![];
        for resource in [
            Resource::UdpGuard,
            Resource::Config,
            Resource::Ca,
            Resource::Process,
            Resource::TcpRoute,
        ] {
            let before = self.observe(resource);
            if before.owner != self.owner {
                return Err(Reason::OwnershipConflict);
            }
            let value = match resource {
                Resource::UdpGuard => Value::Blocked,
                Resource::Config | Resource::Ca => Value::Generation(operation),
                Resource::Process => Value::Running(operation),
                Resource::TcpRoute => Value::Proxy(operation),
            };
            let after = Cell {
                owner: self.owner,
                revision: before.revision.checked_add(1).ok_or(Reason::Invalid)?,
                value,
            };
            let restored = Cell {
                revision: after.revision.checked_add(1).ok_or(Reason::Invalid)?,
                ..before
            };
            changes.push(Change {
                resource,
                before,
                after,
                restored,
            });
        }
        Ok(Plan {
            operation,
            owner: self.owner,
            fence: expected,
            changes,
        })
    }
    fn validate(&self, plan: &Plan) -> Result<()> {
        self.check(plan.fence, plan.owner)?;
        if !self.config_valid {
            return Err(Reason::Config);
        }
        if !self.ca_valid {
            return Err(Reason::Ca);
        }
        if !self.policy_ok || self.observe(Resource::UdpGuard).value != Value::Blocked {
            return Err(Reason::Policy);
        }
        Ok(())
    }
    fn apply(&mut self, plan: &Plan, change: &Change) -> Result<()> {
        self.check(plan.fence, plan.owner)?;
        self.validate(plan)?;
        if self.observe(change.resource) != change.before {
            return Err(Reason::RevisionConflict);
        }
        if change.resource == Resource::Process && !self.start_ok {
            return Err(Reason::Start);
        }
        if change.resource == Resource::TcpRoute {
            if self.observe(Resource::Process).value != Value::Running(plan.operation)
                || !self.tcp_ok
            {
                return Err(Reason::Tcp);
            }
            if !self.policy_ok {
                return Err(Reason::Policy);
            }
        }
        self.cells.insert(key(change.resource), change.after);
        if self.fail_after == Some(change.resource) {
            return Err(Reason::Unknown);
        }
        Ok(())
    }
    fn verify(&self, plan: &Plan) -> Result<()> {
        self.check(plan.fence, plan.owner)?;
        if !self.tcp_ok {
            return Err(Reason::Tcp);
        }
        if !self.policy_ok
            || plan
                .changes
                .iter()
                .any(|c| self.observe(c.resource) != c.after)
        {
            return Err(Reason::Policy);
        }
        Ok(())
    }
    fn restore(&mut self, plan: &Plan, change: &Change, authority: Fence) -> Result<()> {
        self.check(authority, plan.owner)?;
        let current = self.observe(change.resource);
        if current == change.before || current == change.restored {
            return Ok(());
        }
        if current != change.after {
            return Err(Reason::RestoreConflict);
        }
        // TCP is restored/blocked before config/process. An external TCP route
        // prevents removal of the process it may still reference.
        if matches!(
            change.resource,
            Resource::Process | Resource::Config | Resource::Ca
        ) {
            let route = &plan.changes[4];
            let current_route = self.observe(Resource::TcpRoute);
            if current_route != route.before && current_route != route.restored {
                return Err(Reason::RestoreConflict);
            }
        }
        self.cells.insert(key(change.resource), change.restored);
        Ok(())
    }
}
