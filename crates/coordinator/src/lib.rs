//! Volatile reads, fake proxy transactions and durable native lifecycle intents.
//! Shared runtime wiring and routing remain integration gates.
#[cfg(target_os = "linux")]
pub mod local_api;
pub mod snapshot;

pub mod fake_transaction;
pub mod native;
pub mod native_transaction;
pub mod supervisor;
pub mod transaction;
#[cfg(target_os = "linux")]
pub mod transaction_journal;
