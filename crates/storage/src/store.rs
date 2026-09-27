use crate::{Error, Id, Registry, Result};
use rustix::fs::{self, AtFlags, FlockOperation, Mode, OFlags};
use std::fs::File;
use std::io::{Read, Write};
use std::os::fd::OwnedFd;
use std::path::{Component, Path};

const MAX_BYTES: u64 = 4 * 1024 * 1024;
const CURRENT: &str = "registry.json";
const BACKUP: &str = "registry.previous.json";

/// Root must already exist, be owned by the effective uid and have mode 0700.
/// Ancestors are walked descriptor-relative without following symlinks.
/// The coordinator is the sole semantic writer; flock also serializes store users.
pub struct Store {
    root: OwnedFd,
    #[cfg(test)]
    fail_at: std::cell::Cell<usize>,
}
struct Lock(OwnedFd);
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::flock(&self.0, FlockOperation::Unlock);
    }
}
impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute() {
            return Err(Error::UnsafePath);
        }
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let mut root = fs::open("/", flags, Mode::empty()).map_err(|_| Error::Io)?;
        for component in path.components() {
            match component {
                Component::RootDir => (),
                Component::Normal(name) => {
                    root = fs::openat(&root, name, flags, Mode::empty())
                        .map_err(|_| Error::UnsafePath)?
                }
                _ => return Err(Error::UnsafePath),
            }
        }
        let stat = fs::fstat(&root).map_err(|_| Error::Io)?;
        if stat.st_uid != rustix::process::geteuid().as_raw() || stat.st_mode & 0o7777 != 0o700 {
            return Err(Error::UnsafePath);
        }
        Ok(Self {
            root,
            #[cfg(test)]
            fail_at: std::cell::Cell::new(0),
        })
    }
    fn lock(&self, exclusive: bool) -> Result<Lock> {
        let fd = fs::openat(
            &self.root,
            ".",
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|_| Error::Io)?;
        fs::flock(
            &fd,
            if exclusive {
                FlockOperation::LockExclusive
            } else {
                FlockOperation::LockShared
            },
        )
        .map_err(|_| Error::Io)?;
        Ok(Lock(fd))
    }
    fn read_file(&self, name: &str) -> Result<Vec<u8>> {
        let fd = fs::openat(
            &self.root,
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|e| {
            if e == rustix::io::Errno::NOENT {
                Error::Missing
            } else {
                Error::UnsafePath
            }
        })?;
        let stat = fs::fstat(&fd).map_err(|_| Error::Io)?;
        if fs::FileType::from_raw_mode(stat.st_mode) != fs::FileType::RegularFile
            || stat.st_mode & 0o7777 != 0o600
            || stat.st_nlink != 1
            || stat.st_uid != rustix::process::geteuid().as_raw()
            || stat.st_size < 0
            || stat.st_size as u64 > MAX_BYTES
        {
            return Err(Error::UnsafePath);
        }
        let mut bytes = vec![];
        File::from(fd)
            .take(MAX_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Error::Io)?;
        if bytes.len() as u64 > MAX_BYTES {
            return Err(Error::Invalid);
        }
        Ok(bytes)
    }
    fn registry(&self, name: &str) -> Result<Registry> {
        let bytes = match self.read_file(name) {
            Err(Error::Missing) if name == CURRENT => return Ok(Registry::default()),
            result => result?,
        };
        // Inspect version first: never reinterpret a newer schema as current data.
        let envelope: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
        if envelope.get("schema").and_then(|v| v.as_u64()) != Some(crate::SCHEMA as u64) {
            return Err(Error::Schema);
        }
        let registry: Registry = serde_json::from_slice(&bytes).map_err(|_| Error::Invalid)?;
        registry.validate()?;
        for c in &registry.connections {
            if let Some(profile) = &c.profile {
                for id in profile.references() {
                    self.read_file(&format!("secret-{}", id.as_str()))?;
                }
            }
        }
        Ok(registry)
    }
    /// Does not create, repair, chmod, migrate or write lock files. OS atime policy applies.
    pub fn read(&self) -> Result<Registry> {
        let _lock = self.lock(false)?;
        self.registry(CURRENT)
    }
    pub fn new_id() -> Result<Id> {
        let mut bytes = [0u8; 16];
        let mut offset = 0;
        while offset < bytes.len() {
            let n = rustix::rand::getrandom(
                &mut bytes[offset..],
                rustix::rand::GetRandomFlags::empty(),
            )
            .map_err(|_| Error::Io)?;
            if n == 0 {
                return Err(Error::Io);
            }
            offset += n;
        }
        Id::new(&bytes.iter().map(|b| format!("{b:02x}")).collect::<String>())
    }
    fn sync_root(&self) -> Result<()> {
        fs::fsync(&self.root).map_err(|_| Error::DurabilityUncertain)
    }
    fn write_new(&self, name: &str, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() || bytes.len() as u64 > MAX_BYTES {
            return Err(Error::Invalid);
        }
        let fd = fs::openat(
            &self.root,
            name,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )
        .map_err(|_| Error::Io)?;
        let mut file = File::from(fd);
        // Set exact mode even with an unusually restrictive process umask.
        let result = (|| {
            fs::fchmod(&file, Mode::from_raw_mode(0o600)).map_err(|_| Error::Io)?;
            file.write_all(bytes).map_err(|_| Error::Io)?;
            file.sync_all().map_err(|_| Error::Io)
        })();
        if result.is_err() {
            let _ = fs::unlinkat(&self.root, name, AtFlags::empty());
        }
        result
    }
    fn checkpoint(&self, error: Error) -> Result<()> {
        #[cfg(not(test))]
        let _ = error;
        #[cfg(test)]
        if self.fail_at.get() > 0 {
            self.fail_at.set(self.fail_at.get() - 1);
            if self.fail_at.get() == 0 {
                return Err(error);
            }
        }
        Ok(())
    }
    fn replace(&self, name: &str, bytes: &[u8]) -> Result<()> {
        // Refuse unsafe existing targets instead of silently replacing them.
        match self.read_file(name) {
            Ok(_) | Err(Error::Missing) => (),
            Err(e) => return Err(e),
        }
        let temporary = format!("pending-{}", Self::new_id()?.as_str());
        self.write_new(&temporary, bytes)?;
        self.checkpoint(Error::Io)?;
        if fs::renameat(&self.root, &temporary, &self.root, name).is_err() {
            let _ = fs::unlinkat(&self.root, &temporary, AtFlags::empty());
            return Err(Error::Io);
        }
        self.checkpoint(Error::DurabilityUncertain)?;
        self.sync_root()?;
        self.checkpoint(Error::DurabilityUncertain)
    }
    /// Immutable protected bytes. No automatic GC: old revisions/backups retain refs.
    pub fn put_secret(&self, bytes: &[u8]) -> Result<Id> {
        let _lock = self.lock(true)?;
        // A newer or damaged registry blocks all durable mutations.
        self.registry(CURRENT)?;
        let id = Self::new_id()?;
        self.write_new(&format!("secret-{}", id.as_str()), bytes)?;
        self.sync_root()?;
        Ok(id)
    }
    /// Explicit privileged adapter access. Never use this in diagnostics/events.
    pub fn read_secret(&self, id: &Id) -> Result<Vec<u8>> {
        if !id.valid() {
            return Err(Error::Invalid);
        }
        let _lock = self.lock(false)?;
        self.read_file(&format!("secret-{}", id.as_str()))
    }
    /// CAS on registry revision. Store owns all revision increments.
    /// Equal content returns the existing revision without any durable writes.
    pub fn commit(&self, expected: u64, desired: Registry) -> Result<Registry> {
        let _lock = self.lock(true)?;
        self.commit_locked(expected, desired)
    }
    fn commit_locked(&self, expected: u64, mut desired: Registry) -> Result<Registry> {
        let current = self.registry(CURRENT)?;
        if expected != current.revision {
            return Err(Error::Conflict);
        }
        desired.validate()?;
        desired.connections.sort_by(|a, b| a.id.cmp(&b.id));
        for c in &mut desired.connections {
            if let Some(old) = current.connections.iter().find(|old| old.id == c.id) {
                if old.kind != c.kind {
                    return Err(Error::Invalid);
                }
                c.revision = old.revision;
                if c != old {
                    c.revision = old.revision.checked_add(1).ok_or(Error::Invalid)?;
                }
            } else {
                c.revision = 1;
            }
            if let Some(profile) = &c.profile {
                for id in profile.references() {
                    self.read_file(&format!("secret-{}", id.as_str()))?;
                }
            }
        }
        desired.revision = current.revision;
        if desired == current {
            return Ok(current);
        }
        desired.revision = current.revision.checked_add(1).ok_or(Error::Invalid)?;
        // Validate backup hazards before changing either durable registry file.
        match self.read_file(BACKUP) {
            Ok(_) => {
                self.registry(BACKUP)?;
            }
            Err(Error::Missing) => (),
            Err(e) => return Err(e),
        }
        let previous = serde_json::to_vec(&current).map_err(|_| Error::Invalid)?;
        let next = serde_json::to_vec(&desired).map_err(|_| Error::Invalid)?;
        self.replace(BACKUP, &previous)?;
        self.replace(CURRENT, &next)?;
        Ok(desired)
    }
    /// Previous accepted contents become a NEW revision; concurrent edits fence it.
    /// Only registry data is restored, never RCI, runtime health or routing state.
    pub fn rollback(&self, expected: u64) -> Result<Registry> {
        let _lock = self.lock(true)?;
        let previous = self.registry(BACKUP)?;
        self.commit_locked(expected, previous)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Connection, Kind};
    use std::os::unix::fs::PermissionsExt;
    #[test]
    fn interruption_at_every_replace_boundary_preserves_complete_state() {
        for step in 1..=6 {
            let path = std::env::temp_dir()
                .join(format!("mors-crash-{}", Store::new_id().unwrap().as_str()));
            std::fs::create_dir(&path).unwrap();
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
            let store = Store::open(&path).unwrap();
            let old = store
                .commit(
                    0,
                    Registry {
                        connections: vec![Connection {
                            id: Store::new_id().unwrap(),
                            kind: Kind::NaiveProxy,
                            name: "old".into(),
                            enabled: false,
                            confirmed: false,
                            revision: 1,
                            profile: None,
                        }],
                        ..Registry::default()
                    },
                )
                .unwrap();
            let mut new = old.clone();
            new.connections[0].name = "new".into();
            store.fail_at.set(step);
            assert!(store.commit(1, new).is_err());
            drop(store);
            let reopened = Store::open(&path).unwrap();
            let actual = reopened.read().unwrap();
            assert_eq!(
                actual.connections[0].name,
                if step <= 4 { "old" } else { "new" }
            );
            assert_eq!(actual.revision, if step <= 4 { 1 } else { 2 });
            assert_eq!(
                reopened.registry(BACKUP).unwrap(),
                if step == 1 { Registry::default() } else { old }
            );
            let mut retry = actual.clone();
            retry.connections[0].name = "retry".into();
            assert!(reopened.commit(actual.revision, retry).is_ok());
            std::fs::remove_dir_all(path).unwrap();
        }
    }
}
