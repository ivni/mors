//! Volatile snapshots and a read-only local API. Runtime ownership, lifecycle,
//! routing application and durable journals remain separate integration gates.
#[cfg(target_os = "linux")]
pub mod local_api;
pub mod snapshot;
