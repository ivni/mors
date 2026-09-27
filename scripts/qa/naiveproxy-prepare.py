#!/usr/bin/env python3
"""Prepare pinned public source and tools in a disposable Linux build directory."""

import argparse
from importlib import import_module
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

inputs = import_module("naiveproxy-inputs")
notice_inputs = import_module("naiveproxy-notice-inputs")


def checkout(url, revision, destination, gn=False):
    if destination.is_symlink():
        raise ValueError("Unsafe source checkout")
    if not destination.exists():
        destination.mkdir(parents=True)
        subprocess.run(["git", "-C", str(destination), "init", "-q"], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", url], check=True)
        subprocess.run(["git", "-C", str(destination), "fetch", "--depth=10000" if gn else "--depth=1",
                        "origin", revision], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"], check=True)
        if gn:
            subprocess.run(["git", "-C", str(destination), "fetch", "origin", "tag", "initial-commit"], check=True)
    actual = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise ValueError("Existing checkout has another revision; use a fresh build directory")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace", type=Path)
    args = parser.parse_args()
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise ValueError("Runtime build preparation requires disposable Linux x86_64")
    root = args.workspace.resolve()
    lock = json.loads(inputs.LOCK.read_text())
    inputs.download(root / "downloads", lock)
    notice_inputs.download(root / "notice-inputs")
    source, gn_source = root / "source", root / "gn-source"
    checkout("https://github.com/klzgrad/naiveproxy.git", lock["upstream_commit"], source)
    checkout("https://gn.googlesource.com/gn", lock["gn_commit"], gn_source, gn=True)
    subprocess.run(["git", "-C", str(gn_source), "diff", "--exit-code"], check=True, stdout=subprocess.DEVNULL)
    env = {**os.environ, "CC": "gcc", "CXX": "g++", "CXXFLAGS": "-Wno-error=comment"}
    subprocess.run(["python3", "build/gen.py"], cwd=gn_source, env=env, check=True)
    subprocess.run(["ninja", "-C", "out", "-j2", "gn"], cwd=gn_source, check=True)
    destination = source / "src/gn/out/gn"
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(gn_source / "out/gn", destination)
    ca = root / "ca-materials"
    if ca.exists():
        manifest = json.loads((ca / "ca-manifest.json").read_text())
        if manifest["input_lock_sha256"] != inputs.sha256(inputs.LOCK.read_bytes()):
            raise ValueError("Existing CA material uses another lock; choose a fresh workspace")
        for name, expected in manifest["sha256"].items():
            inputs.checked_file(ca / name, expected)
    else:
        inputs.prepare_ca(root / "downloads", ca, lock)
    evidence = {"input_lock_sha256": inputs.sha256(inputs.LOCK.read_bytes()),
                "gn_source": lock["gn_commit"], "gn_sha256": inputs.sha256(destination.read_bytes()),
                "host_packages": subprocess.check_output(["dpkg-query", "-W", "-f=${Package}=${Version}\n"], text=True).splitlines()}
    (root / "preparation.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print("Pinned runtime source, GN, downloads and CA material are prepared")


if __name__ == "__main__":
    main()
