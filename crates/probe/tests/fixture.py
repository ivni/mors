"""Local-only HTTP/TLS/SOCKS fixtures. Ephemeral test CA; no internet access."""
import json
import select
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

stats = {"requests": 0, "connects": 0, "command": 0, "host": "", "closed": 0}
lock = threading.Lock()
mode = sys.argv[1]

class HTTP(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        with lock:
            stats["requests"] += 1
        if self.path == "/slow":
            time.sleep(3)
        body = b"203.0.113.9\n"
        status = 200
        if self.path == "/wrong":
            body = b"203.0.113.10\n"
        elif self.path == "/status":
            status, body = 204, b""
        elif self.path == "/bad":
            status, body = 503, b"unavailable"
        elif self.path == "/large":
            body = b"x" * 65536
        elif self.path == "/redirect":
            status, body = 302, b""
        try:
            self.send_response(status)
            if self.path == "/redirect":
                self.send_header("Location", "/ip")
            if self.path == "/headers":
                self.send_header("X-Padding", "x" * 9000)
            if self.path == "/chunked":
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for _ in range(64):
                    self.wfile.write(b"400\r\n" + b"x" * 1024 + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        except (OSError, ssl.SSLError):
            pass


def exact(conn, size):
    data = b""
    while len(data) < size:
        piece = conn.recv(size - len(data))
        if not piece:
            raise OSError("closed")
        data += piece
    return data

class SOCKS(socketserver.BaseRequestHandler):
    def handle(self):
        conn = self.request
        conn.settimeout(4)
        try:
            greeting = exact(conn, 2)
            exact(conn, greeting[1])
            with lock:
                stats["connects"] += 1
            if mode == "auth":
                conn.sendall(b"\x05\xff")
                return
            conn.sendall(b"\x05\x00")
            header = exact(conn, 4)
            # Require remote hostname resolution and SOCKS CONNECT, never UDP ASSOCIATE.
            if header[3] != 3:
                return
            host = exact(conn, exact(conn, 1)[0]).decode("ascii")
            port = int.from_bytes(exact(conn, 2), "big")
            with lock:
                stats.update(command=header[1], host=host)
            if mode == "reject" or header[1] != 1 or port not in (http.server_port, https.server_port):
                conn.sendall(b"\x05\x04\x00\x01" + b"\x00" * 6)
                return
            with socket.create_connection(("127.0.0.1", port), timeout=4) as target:
                conn.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
                while True:
                    readable, _, _ = select.select([conn, target], [], [], 4)
                    if not readable:
                        return
                    for src in readable:
                        data = src.recv(4096)
                        if not data:
                            return
                        (target if src is conn else conn).sendall(data)
        except OSError:
            pass
        finally:
            with lock:
                stats["closed"] += 1

class SocksServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    def handle_error(self, *_):
        pass

with tempfile.TemporaryDirectory(prefix="mors-probe-fixture-") as scratch:
    cert = Path(scratch) / "ca.pem"
    key = Path(scratch) / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=probe.invalid", "-addext", "subjectAltName=DNS:probe.invalid",
                    "-keyout", str(key), "-out", str(cert)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    http = ThreadingHTTPServer(("127.0.0.1", 0), HTTP)
    https = ThreadingHTTPServer(("127.0.0.1", 0), HTTP)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    https.socket = context.wrap_socket(https.socket, server_side=True)
    socks = SocksServer(("127.0.0.1", 0), SOCKS)
    for server in (http, https, socks):
        threading.Thread(target=server.serve_forever, daemon=True).start()
    print(json.dumps({"http": http.server_port, "https": https.server_port, "socks": socks.server_address[1], "ca": str(cert)}), flush=True)
    for line in sys.stdin:
        if line.strip() == "stats":
            with lock:
                print(json.dumps(stats), flush=True)
