//! Linux durable journal. Directory descriptor is also the volatile kernel lock:
//! no PID, lockfile or lock token is persisted. Dedicated private directory only.
use crate::transaction::{Journal, Reason, Record, Result};
use rustix::fs::{self, AtFlags, FileType, FlockOperation, Mode, OFlags};
use std::{
    fs::File,
    io::{Read, Write},
    os::fd::OwnedFd,
    path::{Component, Path},
};
const LIMIT: u64 = 64 * 1024;
const CURRENT: &str = "transaction.json";
const PENDING: &str = ".transaction.pending";
pub struct FileJournal {
    root: OwnedFd,
    poisoned: bool,
    #[cfg(test)]
    fail_at: usize,
}
impl FileJournal {
    pub fn open(path: &Path) -> Result<Self> {
        if !path.is_absolute() {
            return Err(Reason::Journal);
        }
        let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
        let mut root = fs::open("/", flags, Mode::empty()).map_err(|_| Reason::Journal)?;
        for part in path.components() {
            match part {
                Component::RootDir => (),
                Component::Normal(name) => {
                    root = fs::openat(&root, name, flags, Mode::empty())
                        .map_err(|_| Reason::Journal)?
                }
                _ => return Err(Reason::Journal),
            }
        }
        let stat = fs::fstat(&root).map_err(|_| Reason::Journal)?;
        let kind = fs::fstatfs(&root).map_err(|_| Reason::Journal)?.f_type as i64;
        if stat.st_uid != rustix::process::geteuid().as_raw()
            || stat.st_mode & 0o7777 != 0o700
            || matches!(kind, 0x0102_1994 | 0x8584_58f6)
        {
            return Err(Reason::Journal);
        }
        fs::flock(&root, FlockOperation::NonBlockingLockExclusive).map_err(|e| {
            if e == rustix::io::Errno::WOULDBLOCK {
                Reason::Busy
            } else {
                Reason::Journal
            }
        })?;
        Ok(Self {
            root,
            poisoned: false,
            #[cfg(test)]
            fail_at: 0,
        })
    }
    fn read_file(&self, name: &str) -> Result<Option<Vec<u8>>> {
        let fd = match fs::openat(
            &self.root,
            name,
            OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        ) {
            Ok(fd) => fd,
            Err(e) if e == rustix::io::Errno::NOENT => return Ok(None),
            Err(_) => return Err(Reason::Journal),
        };
        let stat = fs::fstat(&fd).map_err(|_| Reason::Journal)?;
        if FileType::from_raw_mode(stat.st_mode) != FileType::RegularFile
            || stat.st_uid != rustix::process::geteuid().as_raw()
            || stat.st_mode & 0o7777 != 0o600
            || stat.st_nlink != 1
            || stat.st_size < 0
            || stat.st_size as u64 > LIMIT
        {
            return Err(Reason::Journal);
        }
        let mut bytes = vec![];
        File::from(fd)
            .take(LIMIT + 1)
            .read_to_end(&mut bytes)
            .map_err(|_| Reason::Journal)?;
        if bytes.len() as u64 > LIMIT {
            return Err(Reason::Journal);
        }
        Ok(Some(bytes))
    }
    fn checkpoint(&self, _point: usize) -> Result<()> {
        #[cfg(test)]
        if self.fail_at == _point {
            return Err(Reason::Journal);
        }
        Ok(())
    }
    fn write(&self, record: &Record) -> Result<()> {
        record.validate()?;
        // Reject an unsafe existing target even though rename would not follow it.
        self.read_file(CURRENT)?;
        if self.read_file(PENDING)?.is_some() {
            fs::unlinkat(&self.root, PENDING, AtFlags::empty()).map_err(|_| Reason::Journal)?;
        }
        let bytes = serde_json::to_vec(record).map_err(|_| Reason::Journal)?;
        if bytes.len() as u64 > LIMIT {
            return Err(Reason::Journal);
        }
        let fd = fs::openat(
            &self.root,
            PENDING,
            OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::from_raw_mode(0o600),
        )
        .map_err(|_| Reason::Journal)?;
        let mut file = File::from(fd);
        fs::fchmod(&file, Mode::from_raw_mode(0o600)).map_err(|_| Reason::Journal)?;
        file.write_all(&bytes).map_err(|_| Reason::Journal)?;
        self.checkpoint(1)?;
        file.sync_all().map_err(|_| Reason::Journal)?;
        self.checkpoint(2)?;
        fs::renameat(&self.root, PENDING, &self.root, CURRENT).map_err(|_| Reason::Journal)?;
        self.checkpoint(3)?;
        fs::fsync(&self.root).map_err(|_| Reason::Journal)?;
        self.checkpoint(4)
    }
}
impl Journal for FileJournal {
    fn load(&mut self) -> Result<Option<Record>> {
        if self.poisoned {
            return Err(Reason::Journal);
        }
        let bytes = match self.read_file(CURRENT)? {
            Some(bytes) => bytes,
            None => {
                let Some(bytes) = self.read_file(PENDING)? else {
                    return Ok(None);
                };
                let record: Record = serde_json::from_slice(&bytes).map_err(|_| Reason::Journal)?;
                record.validate().map_err(|_| Reason::Journal)?;
                // First prepare was not published. No effect was authorized.
                if record.phase != crate::transaction::Phase::Prepared {
                    return Err(Reason::Journal);
                }
                return Ok(Some(record));
            }
        };

        let record: Record = serde_json::from_slice(&bytes).map_err(|_| Reason::Journal)?;
        record.validate().map_err(|_| Reason::Journal)?;
        Ok(Some(record))
    }
    fn save(&mut self, record: &Record) -> Result<()> {
        if self.poisoned {
            return Err(Reason::Journal);
        }
        if self.write(record).is_err() {
            self.poisoned = true;
            return Err(Reason::Journal);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transaction::*;
    use std::{
        fs as stdfs,
        os::unix::fs::{symlink, PermissionsExt},
        path::PathBuf,
    };
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "mors-journal-{}",
                mors_storage::Store::new_id().unwrap().as_str()
            ));
            stdfs::create_dir(&path).unwrap();
            stdfs::set_permissions(&path, stdfs::Permissions::from_mode(0o700)).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            stdfs::remove_dir_all(&self.0).unwrap();
        }
    }
    fn prepared() -> Record {
        let changes = [
            Resource::UdpGuard,
            Resource::Config,
            Resource::Ca,
            Resource::Process,
            Resource::TcpRoute,
        ]
        .into_iter()
        .map(|resource| {
            let value = match resource {
                Resource::UdpGuard | Resource::TcpRoute => Value::Blocked,
                _ => Value::Absent,
            };
            let before = Cell {
                owner: 1,
                revision: 1,
                value,
            };
            let after = Cell {
                owner: 1,
                revision: 2,
                value: match resource {
                    Resource::UdpGuard => Value::Blocked,
                    Resource::Config | Resource::Ca => Value::Generation(1),
                    Resource::Process => Value::Running(1),
                    Resource::TcpRoute => Value::Proxy(1),
                },
            };
            Change {
                resource,
                before,
                after,
                restored: Cell {
                    revision: 3,
                    ..before
                },
            }
        })
        .collect();
        Record {
            schema: 1,
            plan: Plan {
                operation: 1,
                owner: 1,
                fence: Fence {
                    revision: 1,
                    epoch: 1,
                },
                changes,
            },
            phase: Phase::Prepared,
            attempted: 0,
            reason: None,
        }
    }
    #[test]
    fn durable_roundtrip_permissions_and_volatile_exclusion() {
        let dir = Fixture::new();
        let mut journal = FileJournal::open(&dir.0).unwrap();
        assert!(matches!(FileJournal::open(&dir.0), Err(Reason::Busy)));
        journal.save(&prepared()).unwrap();
        assert_eq!(
            stdfs::metadata(dir.0.join(CURRENT))
                .unwrap()
                .permissions()
                .mode()
                & 0o7777,
            0o600
        );
        assert_eq!(stdfs::read_dir(&dir.0).unwrap().count(), 1);
        drop(journal);
        assert_eq!(
            FileJournal::open(&dir.0).unwrap().load().unwrap(),
            Some(prepared())
        );
    }
    #[test]
    fn all_atomic_replace_failure_boundaries_poison_writer_and_reopen_valid_record() {
        for point in 1..=4 {
            let dir = Fixture::new();
            let mut journal = FileJournal::open(&dir.0).unwrap();
            journal.save(&prepared()).unwrap();
            journal.fail_at = point;
            let mut next = prepared();
            next.phase = Phase::Applying;
            next.attempted = 1;
            assert_eq!(journal.save(&next), Err(Reason::Journal));
            assert_eq!(journal.save(&next), Err(Reason::Journal));
            assert_eq!(journal.load(), Err(Reason::Journal));
            drop(journal);
            let mut reopened = FileJournal::open(&dir.0).unwrap();
            let observed = reopened.load().unwrap().unwrap();
            assert_eq!(observed, if point < 3 { prepared() } else { next.clone() });
            reopened.save(&next).unwrap();
        }
    }
    #[test]
    fn unsafe_files_directories_and_symlink_ancestors_are_rejected() {
        let dir = Fixture::new();
        let other = Fixture::new();
        symlink(&other.0, dir.0.join("link")).unwrap();
        assert!(FileJournal::open(&dir.0.join("link")).is_err());
        symlink(other.0.join("untouched"), dir.0.join(CURRENT)).unwrap();
        let mut journal = FileJournal::open(&dir.0).unwrap();
        assert!(journal.load().is_err());
        assert!(journal.save(&prepared()).is_err());
        assert!(!other.0.join("untouched").exists());
        drop(journal);
        stdfs::remove_file(dir.0.join(CURRENT)).unwrap();
        stdfs::write(dir.0.join(CURRENT), b"{}").unwrap();
        stdfs::set_permissions(dir.0.join(CURRENT), stdfs::Permissions::from_mode(0o644)).unwrap();
        assert!(FileJournal::open(&dir.0).unwrap().load().is_err());
        stdfs::set_permissions(dir.0.join(CURRENT), stdfs::Permissions::from_mode(0o600)).unwrap();
        stdfs::hard_link(dir.0.join(CURRENT), other.0.join("hardlink")).unwrap();
        assert!(FileJournal::open(&dir.0).unwrap().load().is_err());
        stdfs::set_permissions(dir.0.clone(), stdfs::Permissions::from_mode(0o755)).unwrap();
        assert!(FileJournal::open(&dir.0).is_err());
    }
    #[test]
    fn malformed_and_future_records_are_preserved() {
        for bytes in [
            b"{broken".to_vec(),
            serde_json::to_vec(&Record {
                schema: 9,
                ..prepared()
            })
            .unwrap(),
        ] {
            let dir = Fixture::new();
            stdfs::write(dir.0.join(CURRENT), &bytes).unwrap();
            stdfs::set_permissions(dir.0.join(CURRENT), stdfs::Permissions::from_mode(0o600))
                .unwrap();
            assert!(FileJournal::open(&dir.0).unwrap().load().is_err());
            assert_eq!(stdfs::read(dir.0.join(CURRENT)).unwrap(), bytes);
        }
    }
    #[test]
    fn subprocess_lock_probe() {
        let Some(path) = std::env::var_os("MORS_TEST_JOURNAL_PATH") else {
            return;
        };
        assert!(matches!(
            FileJournal::open(Path::new(&path)),
            Err(Reason::Busy)
        ));
    }
    #[test]
    fn independent_process_cannot_acquire_current_executor_lease() {
        let dir = Fixture::new();
        let lease = FileJournal::open(&dir.0).unwrap();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "transaction_journal::tests::subprocess_lock_probe",
            ])
            .env("MORS_TEST_JOURNAL_PATH", &dir.0)
            .status()
            .unwrap();
        assert!(status.success());
        drop(lease);
        assert!(FileJournal::open(&dir.0).is_ok());
    }

    #[test]
    fn initial_unpublished_intent_recovers_without_allowing_apply() {
        for point in 1..=4 {
            let dir = Fixture::new();
            let mut journal = FileJournal::open(&dir.0).unwrap();
            journal.fail_at = point;
            assert!(journal.save(&prepared()).is_err());
            drop(journal);
            let mut reopened = FileJournal::open(&dir.0).unwrap();
            let mut record = reopened.load().unwrap().unwrap();
            assert_eq!(record.phase, Phase::Prepared);
            record.phase = Phase::RolledBack;
            reopened.save(&record).unwrap();
            assert_eq!(reopened.load().unwrap().unwrap().phase, Phase::RolledBack);
        }
    }
    #[test]
    fn subprocess_crash_writer() {
        let Some(path) = std::env::var_os("MORS_TEST_CRASH_JOURNAL") else {
            return;
        };
        let mut journal = FileJournal::open(Path::new(&path)).unwrap();
        journal.save(&prepared()).unwrap();
        std::process::exit(73);
    }
    #[test]
    fn process_exit_releases_lease_and_preserves_intent() {
        let dir = Fixture::new();
        let status = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "transaction_journal::tests::subprocess_crash_writer",
            ])
            .env("MORS_TEST_CRASH_JOURNAL", &dir.0)
            .status()
            .unwrap();
        assert_eq!(status.code(), Some(73));
        assert_eq!(
            FileJournal::open(&dir.0).unwrap().load().unwrap(),
            Some(prepared())
        );
    }
}
