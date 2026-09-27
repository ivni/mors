//! Native VPN lifecycle for explicitly adopted, prepared interfaces.
//! No routing, protocol configuration, OS component or process operations.
use crate::keenetic::{Connected, Disposition, Interface, State};
use serde::{Deserialize, Serialize};
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Invalid,
    Ownership,
    StateChanged,
    Unsupported,
    Unknown,
    UserDown,
    Transport,
    Semantic,
    Timeout,
}

/// Issued by the ownership authority, never inferred from discovery/display names.
/// The random alias is the platform address; epoch/incarnation are local grant
/// generations. Copying the alias externally is an explicit contract limitation.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Owned {
    pub id: String,
    pub alias: String,
    pub system_name: String,
    pub kind: String,
    pub owner: u64,
    pub epoch: u64,
    pub incarnation: u64,
}
impl Owned {
    pub fn valid(&self) -> bool {
        self.alias.len() == 36
            && self.alias.starts_with("Mors")
            && self.alias[4..]
                .bytes()
                .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
            && !self.id.is_empty()
            && self.id.len() <= 128
            && self.id.bytes().all(|b| b.is_ascii_alphanumeric())
            && !self.system_name.is_empty()
            && self.owner != 0
            && self.epoch != 0
            && self.incarnation != 0
    }
}
#[derive(Clone)]
pub struct Observation {
    /// None means ownership cannot be proven, even if the ID still exists.
    pub ownership: Option<Owned>,
    pub interface: Interface,
    /// Explicit adoption must validate client role and Internet egress separately.
    pub validated_client: bool,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Status {
    /// Interface readiness only; does not assert TCP/UDP egress or pool admission.
    Ready,
    Down,
    Unknown,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    Up,
    Down,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum StartIntent {
    /// Explicit user command can lift a user's administrative down.
    User,
    /// An automatic attempt never lifts an observed administrative down.
    Automatic,
}

/// Platform boundary. Calls must honor the remaining deadline. Before writing,
/// revalidate the durable binding and administrative prestate under the common
/// Mors lease, then address ONLY its random alias, never the canonical ID.
/// Ordinary ID reuse loses the alias and must not gain mutation authority.
/// External copying/restoring the alias is outside this guarantee; RCI has no CAS
/// against external admin changes between validation and a user-requested write.
/// No create, rename, save, protocol edits, routing, processes or component setup.
/// The coordinator owns durable intent; preparation/adoption supplies a validated
/// client with an already installed unique alias. Errors never carry raw replies.
pub trait Source {
    fn observe(&mut self, owned: &Owned, timeout: Duration) -> Result<Observation, Error>;
    fn set(
        &mut self,
        owned: &Owned,
        before: State,
        action: Action,
        timeout: Duration,
    ) -> Result<(), Error>;
}

fn validate(owned: &Owned, observed: &Observation) -> Result<Status, Error> {
    if observed.ownership.as_ref() != Some(owned)
        || observed.interface.id.as_deref() != Some(owned.id.as_str())
        || observed.interface.system_name.as_deref() != Some(owned.system_name.as_str())
        || observed.interface.kind.as_deref() != Some(owned.kind.as_str())
    {
        return Err(Error::Ownership);
    }
    if !observed.validated_client
        || observed.interface.disposition != Disposition::VpnNeedsValidation
    {
        return Err(Error::Unsupported);
    }
    let i = &observed.interface;
    Ok(match (i.administrative, i.link, i.connected) {
        (State::Down, _, _) => Status::Down,
        (State::Up, State::Up, Connected::Yes) => Status::Ready,
        _ => Status::Unknown,
    })
}

pub struct Backend<S> {
    source: S,
    owned: Owned,
}
impl<S: Source> Backend<S> {
    pub fn new(source: S, owned: Owned) -> Result<Self, Error> {
        if !owned.valid() {
            return Err(Error::Invalid);
        }
        Ok(Self { source, owned })
    }
    pub fn owned(&self) -> &Owned {
        &self.owned
    }
    pub fn into_source(self) -> S {
        self.source
    }
    fn read(&mut self, deadline: Instant) -> Result<(Status, State), Error> {
        let remaining = remaining(deadline)?;
        let observed = self.source.observe(&self.owned, remaining)?;
        remaining_time_check(deadline)?;
        Ok((
            validate(&self.owned, &observed)?,
            observed.interface.administrative,
        ))
    }
    pub fn observe(&mut self, timeout: Duration) -> Result<Status, Error> {
        self.read(deadline(timeout)?).map(|(status, _)| status)
    }
    pub fn start(&mut self, intent: StartIntent, timeout: Duration) -> Result<Status, Error> {
        self.change(Action::Up, intent, timeout)
    }
    pub fn stop(&mut self, timeout: Duration) -> Result<Status, Error> {
        self.change(Action::Down, StartIntent::User, timeout)
    }
    fn change(
        &mut self,
        action: Action,
        intent: StartIntent,
        timeout: Duration,
    ) -> Result<Status, Error> {
        let deadline = deadline(timeout)?;
        let (status, before) = self.read(deadline)?;
        let target = match action {
            Action::Up => Status::Ready,
            Action::Down => Status::Down,
        };
        if status == target {
            return Ok(status);
        }
        if before == State::Unknown {
            return Err(Error::Unknown);
        }
        if action == Action::Up && intent == StartIntent::Automatic && before == State::Down {
            return Err(Error::UserDown);
        }
        // Already administratively up: observe connection progress, do not reset.
        if action == Action::Down || before != State::Up {
            let result = self
                .source
                .set(&self.owned, before, action, remaining(deadline)?);
            // Even a transport failure may have applied. Observe but never retry or
            // issue a compensating write; coordinator receives the original failure.
            let post = self.read(deadline);
            result?;
            if post?.0 == target {
                return Ok(target);
            }
        }
        loop {
            let delay = remaining(deadline)?.min(Duration::from_millis(25));
            std::thread::sleep(delay);
            let (status, _) = self.read(deadline)?;
            if status == target {
                return Ok(status);
            }
        }
    }
}
fn deadline(timeout: Duration) -> Result<Instant, Error> {
    if timeout.is_zero() || timeout > Duration::from_secs(60) {
        return Err(Error::Invalid);
    }
    Instant::now().checked_add(timeout).ok_or(Error::Invalid)
}
fn remaining(deadline: Instant) -> Result<Duration, Error> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or(Error::Timeout)
}
fn remaining_time_check(deadline: Instant) -> Result<(), Error> {
    remaining(deadline).map(|_| ())
}

#[cfg(target_os = "linux")]
mod rci;
#[cfg(target_os = "linux")]
pub use rci::LocalNative;
