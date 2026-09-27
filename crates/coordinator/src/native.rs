//! Typed native lifecycle result boundary; durable intent belongs to the caller.
//! This does not reuse the proxy-only five-resource transaction plan for a VPN.
use crate::transaction::{Failure, Reason};
use mors_adapters::native::{Backend, Error, Source, StartIntent, Status};
use std::time::Duration;

#[derive(Clone, Copy, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum Request {
    ExcludeFromPool,
    UserStart,
    AutomaticStart,
    StopVpn,
    Observe,
}
/// Caller must persist pool/administrative intent before calling and serialize
/// with the common decision owner. Exclusion has no VPN lifecycle side effect.
/// Failed writes require reconciliation, never a blind inverse up/down action.
pub fn lifecycle<S: Source>(
    backend: &mut Backend<S>,
    request: Request,
    timeout: Duration,
) -> Result<Option<Status>, Failure> {
    let result = match request {
        Request::ExcludeFromPool => return Ok(None),
        Request::UserStart => backend.start(StartIntent::User, timeout),
        Request::AutomaticStart => backend.start(StartIntent::Automatic, timeout),
        Request::StopVpn => backend.stop(timeout),
        Request::Observe => backend.observe(timeout),
    };
    result.map(Some).map_err(|error| Failure {
        reason: match error {
            Error::Invalid => Reason::Invalid,
            Error::Ownership => Reason::OwnershipConflict,
            Error::StateChanged => Reason::RevisionConflict,
            Error::Unsupported | Error::UserDown => Reason::Policy,
            Error::Semantic => Reason::Start,
            Error::Unknown | Error::Transport | Error::Timeout => Reason::Unknown,
        },
        // Conservative: ownership can be lost after an effect. Only errors proven
        // to precede any write are safe to mark as requiring no reconciliation.
        recovery_required: request != Request::Observe
            && !matches!(error, Error::Invalid | Error::UserDown),
    })
}
