#![cfg(target_os = "linux")]
use mors_storage::*;
use std::{
    fs,
    os::unix::fs::{symlink, MetadataExt, PermissionsExt},
    path::PathBuf,
};

struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let p =
            std::env::temp_dir().join(format!("mors-store-{}", Store::new_id().unwrap().as_str()));
        fs::create_dir(&p).unwrap();
        fs::set_permissions(&p, fs::Permissions::from_mode(0o700)).unwrap();
        Self(p)
    }
    fn store(&self) -> Store {
        Store::open(&self.0).unwrap()
    }
    fn write(&self, name: &str, content: &[u8]) {
        fs::write(self.0.join(name), content).unwrap();
        fs::set_permissions(self.0.join(name), fs::Permissions::from_mode(0o600)).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn draft() -> Connection {
    Connection {
        id: Store::new_id().unwrap(),
        kind: Kind::NaiveProxy,
        name: "private-name-marker".into(),
        enabled: true,
        confirmed: false,
        revision: 1,
        profile: None,
    }
}
fn registry(c: Connection) -> Registry {
    Registry {
        connections: vec![c],
        ..Registry::default()
    }
}
fn naive(store: &Store) -> Connection {
    let mut c = draft();
    c.confirmed = true;
    c.profile = Some(Profile::NaiveProxy {
        version: 1,
        endpoint: Endpoint {
            host: "private-endpoint.invalid".into(),
            port: 443,
        },
        auth: store.put_secret(b"private-auth-marker").unwrap(),
        tls: Tls {
            server_name: "private-sni.invalid".into(),
            revision: 1,
            trust: Trust::Custom {
                ca: store.put_secret(b"private-ca-marker").unwrap(),
                revision: 1,
            },
        },
    });
    c
}
#[test]
fn read_and_equal_updates_do_not_write() {
    let f = Fixture::new();
    let s = f.store();
    assert_eq!(s.read().unwrap(), Registry::default());
    assert_eq!(fs::read_dir(&f.0).unwrap().count(), 0);
    let first = s.commit(0, registry(draft())).unwrap();
    let path = f.0.join("registry.json");
    let meta = fs::metadata(&path).unwrap();
    let bytes = fs::read(&path).unwrap();
    assert_eq!(s.commit(1, first.clone()).unwrap(), first);
    assert_eq!(s.read().unwrap(), first);
    let after = fs::metadata(path).unwrap();
    assert_eq!(meta.ino(), after.ino());
    assert_eq!(meta.mtime_nsec(), after.mtime_nsec());
    assert_eq!(bytes, fs::read(f.0.join("registry.json")).unwrap());
    assert!(!first.connections[0].selection_candidate());
}
#[test]
fn revisions_conflicts_and_rollback_retain_secrets() {
    let f = Fixture::new();
    let s = f.store();
    let first = s.commit(0, registry(naive(&s))).unwrap();
    assert!(first.connections[0].selection_candidate());
    let mut next = first.clone();
    next.connections[0].name = "renamed".into();
    let next = s.commit(1, next).unwrap();
    assert_eq!(next.connections[0].revision, 2);
    assert_eq!(s.commit(1, first.clone()), Err(Error::Conflict));
    assert_eq!(s.rollback(1), Err(Error::Conflict));
    let restored = s.rollback(2).unwrap();
    assert_eq!(restored.revision, 3);
    assert_eq!(restored.connections[0].revision, 3);
    assert_eq!(
        restored.connections[0].profile,
        first.connections[0].profile
    );
    assert_eq!(restored.connections[0].name, first.connections[0].name);
    for entry in fs::read_dir(&f.0).unwrap() {
        assert_eq!(entry.unwrap().metadata().unwrap().mode() & 0o777, 0o600);
    }
}
#[test]
fn no_sensitive_output_or_embedded_auth() {
    let f = Fixture::new();
    let s = f.store();
    let r = s.commit(0, registry(naive(&s))).unwrap();
    let snapshot = serde_json::to_string(&r.snapshot()).unwrap();
    let debug = format!("{r:?} {:?}", r.connections[0]);
    for marker in [
        "private-name",
        "private-endpoint",
        "private-sni",
        "private-auth",
        "private-ca",
    ] {
        assert!(!snapshot.contains(marker));
        assert!(!debug.contains(marker));
    }
    let bytes = fs::read_to_string(f.0.join("registry.json")).unwrap();
    assert!(!bytes.contains("private-auth"));
    assert!(!bytes.contains("private-ca"));
    let mut invalid = r.clone();
    if let Some(Profile::NaiveProxy { endpoint, .. }) = &mut invalid.connections[0].profile {
        endpoint.host = "https://user:password@host".into();
    }
    assert_eq!(s.commit(1, invalid), Err(Error::Invalid));
}
#[test]
fn schema_and_invalid_data_are_preserved() {
    let f = Fixture::new();
    let s = f.store();
    for bytes in [
        br#"{"schema":2,"revision":0,"connections":[]}"#.as_slice(),
        br#"{"schema":1,"revision":0,"connections":[],"unknown":"secret-marker"}"#,
        br#"{"schema":1,"schema":1,"revision":0,"connections":[]}"#,
        b"secret-marker-corrupt",
    ] {
        f.write("registry.json", bytes);
        assert!(s.read().is_err());
        assert!(s.commit(0, registry(draft())).is_err());
        assert!(s.put_secret(b"data").is_err());
        assert_eq!(fs::read(f.0.join("registry.json")).unwrap(), bytes);
        assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
    }
}
#[test]
fn reject_symlinks_hardlinks_permissions_and_special_files() {
    let f = Fixture::new();
    let outside = Fixture::new();
    let s = f.store();
    outside.write("sentinel", b"unchanged");
    symlink(outside.0.join("sentinel"), f.0.join("registry.json")).unwrap();
    assert_eq!(s.read(), Err(Error::UnsafePath));
    assert!(s.commit(0, registry(draft())).is_err());
    fs::remove_file(f.0.join("registry.json")).unwrap();
    fs::hard_link(outside.0.join("sentinel"), f.0.join("registry.json")).unwrap();
    assert_eq!(s.read(), Err(Error::UnsafePath));
    fs::remove_file(f.0.join("registry.json")).unwrap();
    f.write(
        "registry.json",
        br#"{"schema":1,"revision":0,"connections":[]}"#,
    );
    fs::set_permissions(f.0.join("registry.json"), fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(s.read(), Err(Error::UnsafePath));
    fs::remove_file(f.0.join("registry.json")).unwrap();
    fs::create_dir(f.0.join("registry.json")).unwrap();
    assert_eq!(s.read(), Err(Error::UnsafePath));
    symlink(&f.0, outside.0.join("link")).unwrap();
    assert!(matches!(
        Store::open(&outside.0.join("link")),
        Err(Error::UnsafePath)
    ));
    assert_eq!(fs::read(outside.0.join("sentinel")).unwrap(), b"unchanged");
}
#[test]
fn bad_backup_and_missing_secret_leave_current_untouched() {
    let f = Fixture::new();
    let s = f.store();
    let first = s.commit(0, registry(draft())).unwrap();
    let mut next = first.clone();
    next.connections[0].profile = Some(Profile::Vless {
        version: 1,
        parameters: Store::new_id().unwrap(),
    });
    next.connections[0].kind = Kind::Vless;
    assert!(s.commit(1, next).is_err());
    let mut next = first.clone();
    next.connections[0].name = "new".into();
    fs::remove_file(f.0.join("registry.previous.json")).unwrap();
    symlink("registry.json", f.0.join("registry.previous.json")).unwrap();
    assert_eq!(s.commit(1, next), Err(Error::UnsafePath));
    assert_eq!(s.read().unwrap(), first);
}
#[test]
fn simultaneous_writers_are_fenced() {
    let f = Fixture::new();
    let first = f.store().commit(0, registry(draft())).unwrap();
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let mut handles = vec![];
    for name in ["one", "two"] {
        let s = f.store();
        let mut desired = first.clone();
        desired.connections[0].name = name.into();
        let barrier = barrier.clone();
        handles.push(std::thread::spawn(move || {
            barrier.wait();
            s.commit(1, desired)
        }));
    }
    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|r| **r == Err(Error::Conflict))
            .count(),
        1
    );
    assert_eq!(f.store().read().unwrap().revision, 2);
}

#[test]
fn unknown_payload_missing_secret_and_unsafe_root_are_rejected() {
    let f = Fixture::new();
    let s = f.store();
    let mut c = naive(&s);
    if let Some(Profile::NaiveProxy { version, .. }) = &mut c.profile {
        *version = 2;
    }
    assert_eq!(s.commit(0, registry(c)), Err(Error::Schema));
    let mut c = draft();
    c.kind = Kind::Vless;
    c.profile = Some(Profile::Vless {
        version: 1,
        parameters: Store::new_id().unwrap(),
    });
    assert_eq!(s.commit(0, registry(c)), Err(Error::Missing));
    let mut c = draft();
    c.confirmed = true;
    assert_eq!(s.commit(0, registry(c)), Err(Error::Invalid));
    fs::set_permissions(&f.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(matches!(Store::open(&f.0), Err(Error::UnsafePath)));
}
#[test]
fn newer_backup_is_never_overwritten() {
    let f = Fixture::new();
    let s = f.store();
    let first = s.commit(0, registry(draft())).unwrap();
    let bytes = br#"{"schema":2,"revision":9,"connections":[]}"#;
    f.write("registry.previous.json", bytes);
    let mut next = first.clone();
    next.connections[0].name = "new".into();
    assert_eq!(s.commit(1, next), Err(Error::Schema));
    assert_eq!(s.read().unwrap(), first);
    assert_eq!(fs::read(f.0.join("registry.previous.json")).unwrap(), bytes);
}

#[test]
fn auth_rotation_rollback_and_secret_link_hazard() {
    let f = Fixture::new();
    let s = f.store();
    let first = s.commit(0, registry(naive(&s))).unwrap();
    let old = match &first.connections[0].profile {
        Some(Profile::NaiveProxy { auth, .. }) => auth.clone(),
        _ => unreachable!(),
    };
    let replacement = s.put_secret(b"new-auth").unwrap();
    let mut next = first.clone();
    if let Some(Profile::NaiveProxy { auth, .. }) = &mut next.connections[0].profile {
        *auth = replacement.clone();
    }
    s.commit(1, next).unwrap();
    let restored = s.rollback(2).unwrap();
    assert_eq!(
        restored.connections[0].profile,
        first.connections[0].profile
    );
    assert_eq!(s.read_secret(&old).unwrap(), b"private-auth-marker");
    assert_eq!(s.read_secret(&replacement).unwrap(), b"new-auth");
    let secret = f.0.join(format!("secret-{}", old.as_str()));
    fs::remove_file(&secret).unwrap();
    symlink(format!("secret-{}", replacement.as_str()), secret).unwrap();
    assert_eq!(s.read_secret(&old), Err(Error::UnsafePath));
    assert_eq!(s.read(), Err(Error::UnsafePath));
}
#[test]
fn all_protocol_kinds_and_shared_store_writers() {
    let f = Fixture::new();
    let s = std::sync::Arc::new(f.store());
    let secret = s.put_secret(b"adapter-input").unwrap();
    let profiles = [
        Profile::Vless {
            version: 1,
            parameters: secret.clone(),
        },
        Profile::Shadowsocks {
            version: 1,
            parameters: secret,
        },
        Profile::NativeVpn {
            version: 1,
            object: Store::new_id().unwrap(),
        },
    ];
    let connections = profiles
        .into_iter()
        .map(|profile| {
            let mut c = draft();
            c.kind = profile.kind();
            c.profile = Some(profile);
            c.confirmed = true;
            c
        })
        .collect();
    let first = s
        .commit(
            0,
            Registry {
                connections,
                ..Registry::default()
            },
        )
        .unwrap();
    assert_eq!(s.read().unwrap(), first);
    let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
    let handles: Vec<_> = ["one", "two"]
        .into_iter()
        .map(|name| {
            let s = s.clone();
            let barrier = barrier.clone();
            let mut next = first.clone();
            next.connections[0].name = name.into();
            std::thread::spawn(move || {
                barrier.wait();
                s.commit(1, next)
            })
        })
        .collect();
    let results: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
    assert_eq!(results.iter().filter(|r| r.is_ok()).count(), 1);
    assert_eq!(
        results
            .iter()
            .filter(|r| **r == Err(Error::Conflict))
            .count(),
        1
    );
}
