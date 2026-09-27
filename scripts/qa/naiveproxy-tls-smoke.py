#!/usr/bin/env python3
"""Loopback TLS/auth/CONNECT checks under QEMU; not a router routing test."""

import argparse
from importlib import import_module
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import uuid

smoke = import_module("naiveproxy-package-smoke")
ROOT = Path(__file__).resolve().parents[2]


def wait_port(port, process):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise ValueError("Fixture/runtime exited before becoming ready")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                return
        except OSError:
            time.sleep(0.1)
    raise ValueError("Loopback readiness timed out")


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def stats(root):
    for _ in range(20):
        try:
            return json.loads((root / "stats.json").read_text())
        except (OSError, json.JSONDecodeError):
            time.sleep(0.05)
    raise ValueError("Fixture statistics are unavailable")


def receive(sock, count):
    result = b""
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise ValueError("SOCKS reply was truncated")
        result += chunk
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipk", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists() or args.output.is_symlink():
        raise ValueError("TLS evidence output must be new")
    spec = smoke.package.targets.selected()
    _, binary = smoke.verify(args.ipk, spec)
    for port in range(18443, 18450):
        with socket.socket() as check:
            check.bind(("127.0.0.1", port))
    results = {}
    fixture = None
    with tempfile.TemporaryDirectory(prefix="mors-naive-tls-") as tmp:
        root = Path(tmp)
        previous_umask = os.umask(0o077)
        try:
            subprocess.run(["python3", str(ROOT / "docs/research/naiveproxy-63/make-fixture-certs.py"), str(root)],
                           check=True, capture_output=True, text=True)
            executable = root / "naive"
            executable.write_bytes(binary)
            executable.chmod(0o700)
            payload = smoke.archives.archive_files(smoke.archives.archive_files(args.ipk.read_bytes())["data.tar.gz"][0])
            ca_bytes = payload[f"{smoke.package.PREFIX}/share/ca/ca-bundle.crt"][0]
            (root / "packaged.pem").write_bytes(ca_bytes)
            (root / "custom.pem").write_bytes(ca_bytes + (root / "root.pem").read_bytes())
            with (root / "fixture.log").open("wb") as log:
                fixture = subprocess.Popen(["node", str(ROOT / "docs/research/naiveproxy-63/tls-fixture.cjs"), str(root)],
                                           stdout=log, stderr=log)
            wait_port(18443, fixture)
            cases = [("packaged-ca-rejects-private-root", 18443, "packaged.pem", False),
                     ("custom-ca-valid", 18443, "custom.pem", True),
                     ("wrong-name", 18445, "custom.pem", False),
                     ("expired", 18446, "custom.pem", False),
                     ("incomplete-chain", 18447, "custom.pem", False),
                     ("full-chain", 18448, "custom.pem", True),
                     ("unknown-ca", 18449, "custom.pem", False)]
            for label, proxy_port, ca_file, success in cases:
                with socket.socket() as reservation:
                    reservation.bind(("127.0.0.1", 0))
                    port = reservation.getsockname()[1]
                config = {"listen": f"socks://127.0.0.1:{port}",
                          "proxy": f"https://fixture:fixture-password@proxy.fixture.invalid:{proxy_port}",
                          "host-resolver-rules": "MAP proxy.fixture.invalid 127.0.0.1, MAP nonce.fixture.invalid 127.0.0.1"}
                config_path = root / f"{label}.json"
                config_path.write_text(json.dumps(config))
                env = {**os.environ, "SSL_CERT_FILE": str(root / ca_file),
                       "SSL_CERT_DIR": str(root / "empty-dir"), "NO_PROXY": "", "no_proxy": ""}
                qemu, cpu = smoke.EMULATORS[spec["name"]]
                process = None
                try:
                    with (root / f"{label}.log").open("wb") as log:
                        process = subprocess.Popen([qemu, "-cpu", cpu, str(executable), str(config_path)],
                                                   env=env, stdout=log, stderr=log, cwd=root)
                    wait_port(port, process)
                    before = stats(root)
                    nonce = uuid.uuid4().hex
                    response = subprocess.run(["curl", "--silent", "--show-error", "--max-time", "20",
                                               "--socks5-hostname", f"127.0.0.1:{port}",
                                               "--cacert", str(root / "root.pem"),
                                               f"https://nonce.fixture.invalid:18444/nonce?value={nonce}"],
                                              env=env, capture_output=True, text=True, timeout=25)
                    observed = response.returncode == 0 and response.stdout == nonce
                    if observed != success:
                        raise ValueError(f"Unexpected TLS result: {label}, curl exit {response.returncode}")
                    after = stats(root)
                    if process.poll() is not None or fixture.poll() is not None:
                        raise ValueError("Runtime/fixture exited during the probe")
                    variant = {"packaged-ca-rejects-private-root": "valid", "custom-ca-valid": "valid",
                               "unknown-ca": "unknown", "incomplete-chain": "incomplete"}.get(label, label)
                    if success:
                        if nonce not in after["nonces"] or after["connects"].get(variant, 0) <= before["connects"].get(variant, 0):
                            raise ValueError("Successful probe did not traverse the CONNECT fixture")
                    else:
                        for _ in range(20):
                            if after["tlsErrors"].get(variant, 0) > before["tlsErrors"].get(variant, 0):
                                break
                            time.sleep(0.05)
                            after = stats(root)
                        if nonce in after["nonces"] or after["tlsErrors"].get(variant, 0) <= before["tlsErrors"].get(variant, 0):
                            raise ValueError("Negative probe was not a confirmed TLS rejection")
                    results[label] = {"expected_success": success, "observed_success": observed,
                                      "curl_exit_code": response.returncode}
                    if label == "custom-ca-valid":
                        with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                            sock.sendall(b"\x05\x01\x00")
                            if receive(sock, 2) != b"\x05\x00":
                                raise ValueError("Unexpected SOCKS greeting")
                            sock.sendall(b"\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
                            reply = receive(sock, 2)
                            if reply[1] != 7:
                                raise ValueError("UDP ASSOCIATE was not rejected")
                            results["udp-associate"] = {"reply": reply[1], "supported": False}
                finally:
                    stop(process)
        finally:
            stop(fixture)
            os.umask(previous_umask)
    evidence = {"package": args.ipk.name, "sha256": smoke.package.sha(args.ipk.read_bytes()),
                "architecture": spec["name"], "scope": "loopback-QEMU-HTTP2-CONNECT-no-padding",
                "cases": results, "temporary_files_cleaned": not root.exists(), "router_tested": False}
    args.output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"TLS/CONNECT/UDP-negative smoke passed: {spec['name']}")


if __name__ == "__main__":
    main()
