#!/usr/bin/env python3
"""Pinned host downloads and CA preparation. Never download on activation."""

import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import ssl
import tarfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / "builder/entware/naiveproxy-inputs.json"
RECIPE_FILES = (
    "builder/entware/naiveproxy-inputs.json",
    "builder/entware/naiveproxy-common.gn",
    "builder/entware/naiveproxy-linkmap.patch",
    "docs/research/naiveproxy-63/idle-handshake-created-at.patch",
    "scripts/qa/naiveproxy-inputs.py",
    "scripts/qa/naiveproxy-runtime-build.py",
    "scripts/qa/naiveproxy-ninja.sh",
)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def checked_file(path, expected):
    if path.is_symlink() or not path.is_file() or sha256(path.read_bytes()) != expected:
        raise ValueError(f"Pinned input missing or changed: {path.name}")
    return path.read_bytes()


def download(cache, lock):
    cache.mkdir(parents=True, exist_ok=True)
    if cache.is_symlink():
        raise ValueError("Unsafe download cache")
    for name, entry in lock["downloads"].items():
        if Path(name).name != name or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
            raise ValueError("Invalid download lock")
        dest = cache / name
        if dest.exists() or dest.is_symlink():
            checked_file(dest, entry["sha256"])
            continue
        if not entry["url"].startswith("https://"):
            raise ValueError("Download requires HTTPS")
        with urllib.request.urlopen(entry["url"], timeout=60) as response:
            content = response.read()
        if sha256(content) != entry["sha256"]:
            raise ValueError(f"Downloaded digest mismatch: {name}")
        with dest.open("xb") as stream:
            stream.write(content)
        print(f"Verified input: {name}")


def prepare_ca(cache, output, lock):
    if output.exists() or output.is_symlink():
        raise ValueError("CA output must be a new directory")
    wheel_name = f"certifi-{lock['ca']['version']}-py3-none-any.whl"
    wheel = checked_file(cache / wheel_name, lock["downloads"][wheel_name]["sha256"])
    with zipfile.ZipFile(io.BytesIO(wheel)) as archive:
        if len(archive.namelist()) != len(set(archive.namelist())):
            raise ValueError("Duplicate CA archive member")
        bundle = archive.read(lock["ca"]["bundle_member"])
        notice = archive.read(lock["ca"]["notice_member"])
    if sha256(bundle) != lock["ca"]["bundle_sha256"] or sha256(notice) != lock["ca"]["notice_sha256"]:
        raise ValueError("CA content digest mismatch")
    trust = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    trust.load_verify_locations(cadata=bundle.decode("ascii"))
    count = trust.cert_store_stats()["x509_ca"]
    if count == 0 or count != bundle.count(b"-----BEGIN CERTIFICATE-----"):
        raise ValueError("Invalid or duplicate CA certificate set")
    materials = {"ca-bundle.crt": bundle, "certifi-NOTICE.txt": notice}
    for name in ("MPL-2.0.txt", "GPL-3.0.txt", "GCC-exception-3.1.txt"):
        materials[name] = checked_file(cache / name, lock["downloads"][name]["sha256"])
    name = "musl-1.2.5.tar.gz"
    musl = checked_file(cache / name, lock["downloads"][name]["sha256"])
    with tarfile.open(fileobj=io.BytesIO(musl), mode="r:gz") as archive:
        member = archive.getmember("musl-1.2.5/COPYRIGHT")
        if not member.isfile():
            raise ValueError("Invalid musl copyright member")
        materials["musl-COPYRIGHT.txt"] = archive.extractfile(member).read()
    output.mkdir(parents=True)
    (output / "empty-ca-directory").mkdir(mode=0o755)
    for name, data in materials.items():
        (output / name).write_bytes(data)
        (output / name).chmod(0o644)
    evidence = {"ca_version": lock["ca"]["version"], "ca_count": count,
                "sha256": {name: sha256(data) for name, data in materials.items()},
                "input_lock_sha256": sha256(LOCK.read_bytes())}
    (output / "ca-manifest.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Prepared pinned CA bundle: {count} roots")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("download", "prepare-ca"))
    parser.add_argument("cache", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    lock = json.loads(LOCK.read_text())
    if args.mode == "download":
        download(args.cache, lock)
    else:
        if args.output is None:
            parser.error("prepare-ca requires output")
        prepare_ca(args.cache, args.output, lock)


if __name__ == "__main__":
    main()
