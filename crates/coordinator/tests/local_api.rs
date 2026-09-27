#![cfg(target_os = "linux")]
use mors_coordinator::{local_api::*, snapshot::*};
use std::{
    fs,
    io::{Read, Write},
    os::unix::{
        fs::{MetadataExt, PermissionsExt},
        net::UnixStream,
        process::CommandExt,
    },
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant},
};

static COUNTER: AtomicU64 = AtomicU64::new(0);
struct Directory(PathBuf);
impl Directory {
    fn new(base: &str) -> Self {
        let path = PathBuf::from(format!(
            "{base}/mors72-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}
fn root() -> bool {
    rustix::process::geteuid().is_root()
}
fn serve(server: &Server) -> std::io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        match server.serve_one() {
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock && Instant::now() < deadline => {
                std::thread::yield_now()
            }
            value => return value,
        }
    }
}

#[test]
fn root_roundtrip_all_operations_and_no_reader_filesystem_writes() {
    if !root() {
        return;
    }
    let directory = Directory::new("/dev/shm");
    let (_, reader) = channel([3; 16], Some(mors_domain::selection::ConnectionId(42)));
    let server = Server::bind(&directory.0, reader).unwrap();
    let path = directory.0.join(SOCKET_NAME);
    assert_eq!(fs::metadata(&path).unwrap().mode() & 0o777, 0o600);
    let before = fs::metadata(&directory.0).unwrap();
    println!("MORS72_READ_BEGIN");
    for _ in 0..25 {
        for operation in [
            ReadOperation::Handshake,
            ReadOperation::Status,
            ReadOperation::List,
            ReadOperation::Events,
        ] {
            std::thread::scope(|scope| {
                let handle = scope.spawn(|| query(&path, operation).unwrap());
                serve(&server).unwrap();
                let response: serde_json::Value =
                    serde_json::from_str(&handle.join().unwrap()).unwrap();
                assert_eq!(response["protocol_version"], 1);
                if operation != ReadOperation::Handshake {
                    assert_eq!(response["sequence"], 0);
                    assert_eq!(response["not_ready"], true);
                    assert!(response["current_active"].is_null());
                }
            });
        }
    }
    println!("MORS72_READ_END");
    let after = fs::metadata(&directory.0).unwrap();
    assert_eq!(
        (
            before.mtime(),
            before.mtime_nsec(),
            before.ctime(),
            before.ctime_nsec()
        ),
        (
            after.mtime(),
            after.mtime_nsec(),
            after.ctime(),
            after.ctime_nsec()
        )
    );
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    drop(server);
    assert_eq!(
        query(&path, ReadOperation::Status),
        Err(ClientError::CoreUnavailable)
    );
    assert!(!path.exists());
}

#[test]
fn rejects_disk_insecure_directory_symlink_and_existing_socket() {
    if !root() {
        return;
    }
    let (_, reader) = channel([0; 16], None);
    let disk = Directory::new(std::env::current_dir().unwrap().to_str().unwrap());
    assert!(Server::bind(&disk.0, reader.clone()).is_err());
    let ram = Directory::new("/dev/shm");
    fs::set_permissions(&ram.0, fs::Permissions::from_mode(0o755)).unwrap();
    assert!(Server::bind(&ram.0, reader.clone()).is_err());
    fs::set_permissions(&ram.0, fs::Permissions::from_mode(0o700)).unwrap();
    let link = ram.0.join("link");
    std::os::unix::fs::symlink(&ram.0, &link).unwrap();
    assert!(Server::bind(&link, reader.clone()).is_err());
    let server = Server::bind(&ram.0, reader.clone()).unwrap();
    assert!(Server::bind(&ram.0, reader).is_err());
    assert!(ram.0.join(SOCKET_NAME).exists());
    drop(server);
}

#[test]
fn malformed_version_mutation_and_secret_input_are_closed_errors() {
    if !root() {
        return;
    }
    let directory = Directory::new("/dev/shm");
    let (_, reader) = channel([0; 16], None);
    let server = Server::bind(&directory.0, reader).unwrap();
    for request in [
        b"MORS/2 status\n".as_slice(),
        b"MORS/1 probe SECRET_MARKER\n",
        &[b'X'; 32],
        b"\xff\n",
    ] {
        let mut client = UnixStream::connect(directory.0.join(SOCKET_NAME)).unwrap();
        client.write_all(request).unwrap();
        server.serve_one().unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        assert_eq!(
            response,
            "{\"protocol_version\":1,\"error\":\"invalid_request\"}\n"
        );
        assert!(!response.contains("SECRET_MARKER"));
    }
}

#[test]
fn idle_client_is_bounded_and_does_not_prevent_next_reader() {
    if !root() {
        return;
    }
    let directory = Directory::new("/dev/shm");
    let (_, reader) = channel([0; 16], None);
    let server = Server::bind(&directory.0, reader).unwrap();
    let _idle = UnixStream::connect(directory.0.join(SOCKET_NAME)).unwrap();
    let started = Instant::now();
    assert!(server.serve_one().is_err());
    assert!(started.elapsed() < Duration::from_secs(2));
    std::thread::scope(|scope| {
        let handle = scope.spawn(|| query(&directory.0.join(SOCKET_NAME), ReadOperation::Status));
        serve(&server).unwrap();
        assert!(handle.join().unwrap().is_ok());
    });
}

#[test]
fn unprivileged_peer_is_rejected_even_if_socket_permissions_are_relaxed() {
    if !root() {
        return;
    }
    let directory = Directory::new("/dev/shm");
    let (_, reader) = channel([0; 16], None);
    let server = Server::bind(&directory.0, reader).unwrap();
    fs::set_permissions(&directory.0, fs::Permissions::from_mode(0o755)).unwrap();
    let path = directory.0.join(SOCKET_NAME);
    fs::set_permissions(&path, fs::Permissions::from_mode(0o666)).unwrap();
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "unprivileged_child"])
        .env("MORS72_SOCKET", &path)
        .uid(65534)
        .gid(65534)
        .spawn()
        .unwrap();
    assert_eq!(
        serve(&server).unwrap_err().kind(),
        std::io::ErrorKind::PermissionDenied
    );
    assert!(child.wait().unwrap().success());
}

#[test]
fn unprivileged_child() {
    let Some(path) = std::env::var_os("MORS72_SOCKET") else {
        return;
    };
    assert!(!root());
    let mut stream = UnixStream::connect(path).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap();
    let mut byte = [0];
    assert_eq!(stream.read(&mut byte).unwrap(), 0);
}
