"""Probe premature SOCKS authentication closure on an authorized test target.

Private settings JSON: a list of objects with label, host, port, username,
password. Never commit that file. Output contains labels and numeric outcomes,
not endpoints or credentials. Run on the Pi test runner, after target checks.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import socket
import time


def receive(sock, size):
    data = b""
    while len(data) < size:
        part = sock.recv(size - len(data))
        if not part:
            break
        data += part
    return data


def authenticate(profile, hold):
    result = {"label": profile["label"], "hold_seconds": hold,
              "started": time.time()}
    started = time.monotonic()
    try:
        with socket.create_connection((profile["host"], profile["port"]), 5) as sock:
            sock.settimeout(5)
            sock.sendall(b"\x05\x01\x02")
            if receive(sock, 2) != b"\x05\x02":
                result["outcome"] = "greeting_failed"
                return result
            time.sleep(hold)
            user = profile["username"].encode()
            password = profile["password"].encode()
            sock.sendall(b"\x01" + bytes([len(user)]) + user
                         + bytes([len(password)]) + password)
            reply = receive(sock, 2)
            result["outcome"] = ("authenticated" if reply == b"\x01\x00"
                                 else "closed" if not reply else "auth_rejected")
    except OSError as error:
        result.update(outcome="socket_error", errno=error.errno)
    finally:
        result["elapsed"] = time.monotonic() - started
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("settings", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    profiles = json.loads(args.settings.read_text())
    if not 1 <= len(profiles) <= 2:
        raise SystemExit("Expected one or two test profiles")
    for profile in profiles:
        if profile["label"] not in {"default", "control"}:
            raise SystemExit("Use the closed labels default/control")
        if not all(1 <= len(profile[key].encode()) <= 255
                   for key in ["username", "password"]):
            raise SystemExit("Invalid credential length")
        if authenticate(profile, 0)["outcome"] != "authenticated":
            raise SystemExit("Readiness/authentication precondition failed")

    def delayed(index, profile):
        time.sleep(index * 5)
        return {"index": index, **authenticate(profile, 10)}

    with concurrent.futures.ThreadPoolExecutor(max_workers=28) as pool:
        futures = [pool.submit(delayed, index, profile)
                   for index in range(14) for profile in profiles]
        rows = [future.result() for future in futures]
    args.output.write_text(json.dumps(rows, indent=2) + "\n")
    for profile in profiles:
        chosen = [row for row in rows if row["label"] == profile["label"]]
        failed = sum(row["outcome"] != "authenticated" for row in chosen)
        print(profile["label"], "attempts", len(chosen), "failed", failed)


if __name__ == "__main__":
    main()
