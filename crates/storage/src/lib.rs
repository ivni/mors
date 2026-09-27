//! Durable registry only. No engine configuration, routing, RCI or runtime health.
//! Linux filesystem guarantees are deliberately unavailable on other platforms.
mod model;
pub use model::*;
#[cfg(target_os = "linux")]
mod store;
#[cfg(target_os = "linux")]
pub use store::Store;

/// Closed errors never carry paths, parser excerpts, endpoints or secret material.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Error {
    Io,
    Invalid,
    Schema,
    UnsafePath,
    Conflict,
    Missing,
    /// Rename may have occurred: reread under the writer lock before retrying.
    DurabilityUncertain,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "storage: {self:?}")
    }
}
impl std::error::Error for Error {}
pub type Result<T> = std::result::Result<T, Error>;
