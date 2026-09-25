#!/usr/bin/env python3
"""Build/attest the pinned Entware compiler, never install a router runtime."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def unique(pattern, base):
    paths = list(base.glob(pattern))
    require(len(paths) == 1, f"Expected one Rust builder path: {base}/{pattern}")
    return paths[0]


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    require(mode in ("manifest", "build", "verify"),
            "Usage: entware-rust.py manifest|build|verify")
    lock_path = ROOT / "builder/entware/rust-toolchain.json"
    lock = json.loads(lock_path.read_text())
    require(set(lock) == {"schema", "version", "release", "commit", "llvm",
                          "source_sha256", "host", "target", "gcc_version", "tools"},
            "Unexpected Rust lock fields")
    require(lock["schema"] == 1, "Unsupported Rust lock schema")
    for key in ("version", "llvm", "gcc_version"):
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", lock[key]), f"Invalid Rust {key}")
    require(lock["release"] == lock["version"] + "-nightly", "Invalid patched release")
    for key, length in (("commit", 40), ("source_sha256", 64)):
        require(re.fullmatch(f"[0-9a-f]{{{length}}}", lock[key]), f"Invalid Rust {key}")
    require(lock["host"] == "x86_64-unknown-linux-gnu" and
            lock["target"] == "aarch64-openwrt-linux-gnu", "Unsupported builder ABI")
    require(lock["tools"] == ["gcc", "g++", "ld", "ar", "ranlib", "readelf"],
            "Incomplete Rust target tools")
    host_lock = tomllib.loads((ROOT / "rust-toolchain.toml").read_text())
    require(host_lock["toolchain"]["channel"] == lock["version"],
            "Host and Entware Rust source versions differ")
    feeds = [line.split() for line in (ROOT / "scripts/qa/entware.lock").read_text().splitlines()
             if line.startswith("rustlang ")]
    require(len(feeds) == 1 and len(feeds[0]) == 3 and
            re.fullmatch(r"[0-9a-f]{40}", feeds[0][2]), "Missing pinned rustlang feed")
    if mode == "manifest":
        print("rust_contract_sha256=" + hashlib.sha256(lock_path.read_bytes()).hexdigest())
        for key in ("version", "release", "commit", "llvm", "source_sha256", "host", "target",
                    "gcc_version"):
            print(f"rust_{key}={lock[key]}")
        print("rust_feed_revision=" + feeds[0][2])
        return

    entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware")).resolve()
    feed = entware / "feeds/rustlang"
    require(run("git", "-C", str(feed), "rev-parse", "HEAD") == feeds[0][2],
            "Rust feed revision mismatch")
    require(not run("git", "-C", str(feed), "status", "--porcelain", "--untracked-files=all"),
            "Rust feed has modified or untracked inputs")
    recipe = (feed / "rustc-dev/Makefile").read_text()
    for key, value in (("PKG_VERSION", lock["version"]), ("PKG_HASH", lock["source_sha256"]),
                       ("PRE_COMMIT_HASH", lock["commit"])):
        require(re.findall(rf"^{key}:=(\S+)$", recipe, re.MULTILINE) == [value],
                f"Rust recipe {key} mismatch")
    if mode == "build":
        # The locked feed owns bootstrap downloads and their checksums. No rustup,
        # nightly channel resolution or external engine download belongs here.
        jobs = os.environ.get("JOBS", "2")
        require(re.fullmatch(r"[1-9][0-9]*", jobs), "Invalid Rust build parallelism")
        for target in ("host/compile", "compile"):
            subprocess.run(["make", "-j" + jobs,
                            "package/feeds/rustlang/rustc-dev/" + target, "V=s"],
                           cwd=entware, check=True)

    staging = entware / "staging_dir"
    target = unique("target-aarch64*", staging)
    toolchain = unique("toolchain-aarch64*", staging)
    rust_home = target / "host"
    rustc = rust_home / "bin/rustc"
    cargo = rust_home / "bin/cargo"
    for tool in (rustc, cargo):
        require(tool.is_file() and os.access(tool, os.X_OK), f"Missing Rust tool: {tool}")
    info = dict(line.split(": ", 1) for line in run(str(rustc), "-vV").splitlines() if ": " in line)
    for key, expected in (("release", lock["release"]), ("commit-hash", lock["commit"]),
                          ("host", lock["host"]), ("LLVM version", lock["llvm"])):
        require(info.get(key) == expected, f"Rust compiler {key} mismatch")
    require(re.fullmatch(r"cargo " + re.escape(lock["version"]) +
                         r"(?:-nightly)? \([0-9a-f]+ [0-9-]+\)", run(str(cargo), "--version")),
            "Rust Cargo version mismatch")
    require(lock["target"] in run(str(rustc), "--print", "target-list").splitlines(),
            "Patched Rust target missing")
    require(Path(run(str(rustc), "--print", "sysroot")).resolve() == rust_home.resolve(),
            "Rust compiler sysroot is outside the attested staging tree")
    for triple in (lock["host"], lock["target"]):
        lib = rust_home / "lib/rustlib" / triple / "lib"
        for crate in ("std", "core"):
            libraries = list(lib.glob(f"lib{crate}-*.rlib"))
            require(libraries and all(path.is_file() and path.stat().st_size > 0
                                      for path in libraries),
                    f"Missing or empty Rust {triple} {crate}")
    for name in lock["tools"]:
        tool = toolchain / "bin" / (lock["target"] + "-" + name)
        require(tool.is_file() and os.access(tool, os.X_OK), f"Missing Rust target tool: {name}")
        run(str(tool), "--version")
        if name in ("gcc", "g++"):
            require(run(str(tool), "-dumpfullversion") == lock["gcc_version"],
                    f"Rust target {name} version mismatch")
            require(run(str(tool), "-dumpmachine") == lock["target"],
                    f"Rust target {name} ABI mismatch")
    print("Entware Rust toolchain verified: " + lock["release"] + " / " + lock["target"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Entware Rust: {error}")
