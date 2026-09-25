#!/usr/bin/env python3
"""Compile the scaffold using only an attested builder; do not install it."""

import hashlib
from importlib import import_module
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile

contract = import_module("entware-target")
ROOT = Path(__file__).resolve().parents[2]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect_elf(binary, readelf, spec):
    header = binary.read_bytes()[:52]
    if (len(header) < 52 or header[:4] != b"\x7fELF" or
            header[4:6] != bytes((spec["elf_class"], spec["elf_endian"]))):
        raise ValueError("Core ELF class/endianness mismatch")
    endian = "<" if spec["elf_endian"] == 1 else ">"
    if struct.unpack_from(endian + "H", header, 18)[0] != spec["elf_machine"]:
        raise ValueError("Core ELF machine mismatch")
    details = subprocess.check_output([str(readelf), "-l", "-d", "-A", str(binary)], text=True)
    if f"[Requesting program interpreter: {spec['interpreter']}]" not in details:
        raise ValueError("Core ELF interpreter mismatch")
    if spec["elf_machine"] == 8:
        flags = struct.unpack_from(endian + "I", header, 36)[0]
        # MIPS32r2 + O32, including an explicit rejection of the N32 ABI2 bit.
        if flags & 0xF000F020 != 0x70001000 or "Soft float" not in details:
            raise ValueError("Core MIPS ELF is not MIPS32r2 O32 soft-float")
    return details


def main():
    image = os.environ.get("MORS_ENTWARE_BUILDER_IMAGE")
    if image is not None and not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", image):
        raise ValueError("Core builder image must use an OCI digest")
    subprocess.run(["bash", str(ROOT / "scripts/qa/verify-entware-builder.sh")], check=True)
    spec = contract.selected()
    entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware")).resolve()
    staging = entware / "staging_dir" / spec["staging"]
    rust_bin = staging / "host/bin"
    target_bin = entware / "staging_dir" / spec["toolchain"] / "bin"
    linker = target_bin / (spec["rust_target"] + "-gcc")
    output = ROOT / "packages/core" / spec["name"]
    if any(path.is_symlink() for path in
           (ROOT / "packages", ROOT / "packages/core", output,
            *(output / name for name in ("mors-core", "elf.txt", "build.json", "builder.env")))):
        raise ValueError("Unsafe core output directory")
    with tempfile.TemporaryDirectory(prefix="mors-core-") as temporary:
        source = Path(temporary)
        # No user cargo config, cached artifacts, rustup or network resolution.
        inputs = [ROOT / "Cargo.toml", ROOT / "Cargo.lock"]
        inputs += sorted((ROOT / "crates").rglob("*"))
        source_hashes = {}
        for path in inputs:
            if path.is_symlink():
                raise ValueError("Symlink in core source inputs")
            if path.is_file():
                relative = path.relative_to(ROOT)
                dest = source / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
                source_hashes[str(relative)] = sha256(dest)
        env = {key: value for key, value in os.environ.items()
               if not key.startswith(("CARGO_", "RUST", "RUSTUP_"))}
        env.update(CARGO_HOME=str(source / ".cargo-home"),
                   CARGO_TARGET_DIR=str(source / "target"),
                   RUSTC=str(rust_bin / "rustc"),
                   RUSTDOC=str(rust_bin / "rustdoc"),
                   STAGING_DIR=str(staging),
                   CARGO_ENCODED_RUSTFLAGS="\x1f".join((
                       "-C", f"linker={linker}", "-C", "relocation-model=static",
                       "-C", "link-arg=-Wl,-rpath,/opt/lib",
                       f"--remap-path-prefix={source}=/mors")))
        subprocess.run([str(rust_bin / "cargo"), "build", "--workspace", "--release",
                        "--frozen", "--target", spec["rust_target"]],
                       cwd=source, env=env, check=True)
        binary = source / "target" / spec["rust_target"] / "release/mors-core"
        details = inspect_elf(binary, target_bin / (spec["rust_target"] + "-readelf"), spec)
        manifest_path = Path(os.environ.get("MORS_ENTWARE_BUILDER_MANIFEST",
                                           "/opt/mors-builder/manifest.env"))
        manifest = dict(line.split("=", 1) for line in manifest_path.read_text().splitlines())
        evidence = {"target": spec, "builder_manifest": manifest, "builder_image": image,
                    "build_helper_sha256": sha256(Path(__file__)),
                    "source_sha256": source_hashes, "elf_sha256": sha256(binary),
                    "execution": "not-tested"}
        output.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(binary, output / "mors-core")
        (output / "mors-core").chmod(0o755)
        (output / "elf.txt").write_text(details)
        (output / "build.json").write_text(json.dumps(evidence, indent=2) + "\n")
        shutil.copyfile(manifest_path, output / "builder.env")
    print(f"Core build verified: {spec['name']} -> {output}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Entware core: {error}")
