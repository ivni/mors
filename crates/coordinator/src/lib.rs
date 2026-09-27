//! Volatile read API and a durable transactional executor with fake adapters.
//! Real runtime ownership, lifecycle and routing remain integration gates.
#[cfg(target_os = "linux")]
pub mod local_api;
pub mod snapshot;

pub mod fake_transaction;
pub mod transaction;
#[cfg(target_os = "linux")]
pub mod transaction_journal;
