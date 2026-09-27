//! Linux-only root IPC. Bind is an explicit setup operation; serving readers
//! performs socket I/O and RAM reads only. No fallback listener or shell path.
use crate::snapshot::{ReadOperation, Reader, MAX_RESPONSE_BYTES};
use rustix::{
    fs::{fstat, fstatfs, open, Mode, OFlags},
    net::{
        connect, socket_with, sockopt::socket_peercred, AddressFamily, SocketAddrUnix, SocketFlags,
        SocketType,
    },
};
use std::{
    fs,
    io::{self, Read, Write},
    os::{
        fd::{AsRawFd, OwnedFd},
        unix::{
            fs::PermissionsExt,
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

pub const SOCKET_NAME: &str = "read.sock";
pub const IO_DEADLINE: Duration = Duration::from_millis(250);
const MAX_REQUEST_BYTES: usize = 32;
// Linux UAPI include/uapi/linux/magic.h (rustix does not export this constant).
const TMPFS_MAGIC: i64 = 0x0102_1994;
const BAD_REQUEST: &[u8] = b"{\"protocol_version\":1,\"error\":\"invalid_request\"}\n";
const UNAVAILABLE: &[u8] = b"{\"protocol_version\":1,\"error\":\"core_unavailable\"}\n";

pub struct Server {
    listener: UnixListener,
    directory: OwnedFd,
    socket_path: PathBuf,
    reader: Reader,
}
fn denied() -> io::Error {
    io::Error::from(io::ErrorKind::PermissionDenied)
}
fn authorize(stream: &UnixStream) -> io::Result<()> {
    if socket_peercred(stream)?.uid.as_raw() != 0 {
        return Err(denied());
    }
    Ok(())
}
fn remaining(deadline: Instant) -> io::Result<Duration> {
    deadline
        .checked_duration_since(Instant::now())
        .filter(|d| !d.is_zero())
        .ok_or_else(|| io::Error::from(io::ErrorKind::TimedOut))
}
fn write_bounded(stream: &mut UnixStream, mut bytes: &[u8], deadline: Instant) -> io::Result<()> {
    while !bytes.is_empty() {
        stream.set_write_timeout(Some(remaining(deadline)?))?;
        let n = stream.write(bytes)?;
        if n == 0 {
            return Err(io::ErrorKind::WriteZero.into());
        }
        bytes = &bytes[n..];
    }
    Ok(())
}
fn operation(line: &[u8]) -> Option<ReadOperation> {
    match line {
        b"MORS/1 handshake\n" => Some(ReadOperation::Handshake),
        b"MORS/1 status\n" => Some(ReadOperation::Status),
        b"MORS/1 list\n" => Some(ReadOperation::List),
        b"MORS/1 events\n" => Some(ReadOperation::Events),
        _ => None,
    }
}
impl Server {
    /// Caller creates a dedicated root-owned 0700 directory on tmpfs. Do not
    /// guess that /opt/var/run is volatile; reject disk filesystems and symlinks.
    /// Existing socket paths are never removed/replaced, including on restart.
    pub fn bind(directory: &Path, reader: Reader) -> io::Result<Self> {
        if !rustix::process::geteuid().is_root() {
            return Err(denied());
        }
        if !directory.is_absolute() || fs::canonicalize(directory)? != directory {
            return Err(denied());
        }
        let fd = open(
            directory,
            OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
            Mode::empty(),
        )?;
        let stat = fstat(&fd)?;
        if stat.st_uid != 0
            || stat.st_mode & 0o7777 != 0o700
            || fstatfs(&fd)?.f_type as i64 != TMPFS_MAGIC
        {
            return Err(denied());
        }
        // Resolve through the held directory FD, avoiding pathname replacement
        // between validation, bind, chmod and cleanup.
        let socket_path =
            PathBuf::from(format!("/proc/self/fd/{}/{}", fd.as_raw_fd(), SOCKET_NAME));
        let listener = UnixListener::bind(&socket_path)?;
        if let Err(error) = fs::set_permissions(&socket_path, fs::Permissions::from_mode(0o600)) {
            let _ = fs::remove_file(&socket_path);
            return Err(error);
        }
        let server = Self {
            listener,
            directory: fd,
            socket_path,
            reader,
        };
        server.listener.set_nonblocking(true)?;
        rustix::net::listen(&server.listener, 8)?;
        Ok(server)
    }
    /// At most one client per call, no spawned workers or unbounded queues.
    /// WouldBlock means no pending reader; the host event loop decides when to poll.
    pub fn serve_one(&self) -> io::Result<()> {
        let (mut stream, _) = self.listener.accept()?;
        authorize(&stream)?;
        let deadline = Instant::now() + IO_DEADLINE;
        let mut request = [0; MAX_REQUEST_BYTES];
        let mut len = 0;
        while len < request.len() {
            stream.set_read_timeout(Some(remaining(deadline)?))?;
            if stream.read(&mut request[len..len + 1])? == 0 {
                break;
            }
            len += 1;
            if request[len - 1] == b'\n' {
                break;
            }
        }
        let response = operation(&request[..len]).map(|op| self.reader.read(op));
        let bytes = match &response {
            Some(Ok(value)) => value.as_bytes(),
            Some(Err(_)) => UNAVAILABLE,
            None => BAD_REQUEST,
        };
        write_bounded(&mut stream, bytes, deadline)
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        // directory remains alive through unlink; never follows a replacement parent.
        let _keep_alive = &self.directory;
        let _ = fs::remove_file(&self.socket_path);
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClientError {
    CoreUnavailable,
    AccessDenied,
    InvalidResponse,
}
/// A read-only primitive for future CLI integration. It never starts the core,
/// launches a probe, reads a saved health file or retries via legacy routing.
pub fn query(path: &Path, op: ReadOperation) -> Result<String, ClientError> {
    let fd = socket_with(
        AddressFamily::UNIX,
        SocketType::STREAM,
        SocketFlags::CLOEXEC | SocketFlags::NONBLOCK,
        None,
    )
    .map_err(|_| ClientError::CoreUnavailable)?;
    let address = SocketAddrUnix::new(path).map_err(|_| ClientError::CoreUnavailable)?;
    connect(&fd, &address).map_err(|e| {
        if e == rustix::io::Errno::ACCESS {
            ClientError::AccessDenied
        } else {
            ClientError::CoreUnavailable
        }
    })?;
    let mut stream = UnixStream::from(fd);
    stream
        .set_nonblocking(false)
        .map_err(|_| ClientError::CoreUnavailable)?;
    authorize(&stream).map_err(|_| ClientError::AccessDenied)?;
    let request = match op {
        ReadOperation::Handshake => b"MORS/1 handshake\n".as_slice(),
        ReadOperation::Status => b"MORS/1 status\n".as_slice(),
        ReadOperation::List => b"MORS/1 list\n".as_slice(),
        ReadOperation::Events => b"MORS/1 events\n".as_slice(),
    };
    let deadline = Instant::now() + IO_DEADLINE;
    write_bounded(&mut stream, request, deadline).map_err(|_| ClientError::CoreUnavailable)?;
    let mut bytes = Vec::with_capacity(1024);
    let mut chunk = [0; 4096];
    loop {
        stream
            .set_read_timeout(Some(
                remaining(deadline).map_err(|_| ClientError::CoreUnavailable)?,
            ))
            .map_err(|_| ClientError::CoreUnavailable)?;
        let n = stream
            .read(&mut chunk)
            .map_err(|_| ClientError::CoreUnavailable)?;
        if n == 0 {
            break;
        }
        if bytes.len() + n > MAX_RESPONSE_BYTES {
            return Err(ClientError::InvalidResponse);
        }
        bytes.extend_from_slice(&chunk[..n]);
    }
    if bytes == UNAVAILABLE {
        return Err(ClientError::CoreUnavailable);
    }
    if !bytes.starts_with(b"{\"protocol_version\":1,") || !bytes.ends_with(b"}\n") {
        return Err(ClientError::InvalidResponse);
    }
    String::from_utf8(bytes).map_err(|_| ClientError::InvalidResponse)
}
