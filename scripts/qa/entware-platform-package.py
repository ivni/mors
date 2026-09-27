#!/usr/bin/env python3
"""Verify candidate IPKs, independently of the legacy release consumer (#116)."""

import hashlib
from importlib import import_module
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile
import tempfile

core = import_module("entware-core-build")
ROOT = Path(__file__).resolve().parents[2]
CORE_PATH = "opt/apps/mors/bin/mors-core"
CORE_DEPENDENCIES = {"libc", "libgcc", "libpthread"}
ENTWARE_BASE_DEPENDENCIES = {"libc", "libssp", "librt", "libpthread"}
LIBRARIES = {"libc.so.6", "libgcc_s.so.1", "libpthread.so.0"}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def package_version():
    recipe = (ROOT / "Makefile").read_text()
    version = re.findall(r"^PKG_VERSION:=(\S+)$", recipe, re.M)
    release = re.findall(r"^PKG_RELEASE:=([1-9][0-9]*)$", recipe, re.M)
    if len(version) != 1 or len(release) != 1:
        raise ValueError("Invalid package version/release")
    return f"{version[0]}-{release[0]}"


def archive_files(data):
    """Read without extracting; reject links, duplicate names and traversal."""
    result = {}
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        for member in archive:
            path = PurePosixPath(member.name)
            name = str(path)
            if path.is_absolute() or ".." in path.parts or name in seen:
                raise ValueError("Unsafe or duplicate archive member")
            seen.add(name)
            if member.isdir():
                continue
            if not member.isfile() or member.mode & 0o7000:
                raise ValueError("Unexpected archive member type/mode")
            result[name] = (archive.extractfile(member).read(), member.mode)
    return result


def checked_inputs(spec):
    output = ROOT / "packages/core" / spec["name"]
    platform = ROOT / "packages/platform" / spec["name"]
    for path in (output, platform):
        if any(parent.is_symlink() for parent in (path, *path.parents)):
            raise ValueError("Symlink in package output path")
    binary = output / "mors-core"
    for name in ("mors-core", "build.json", "builder.env"):
        if (output / name).is_symlink() or not (output / name).is_file():
            raise ValueError("Missing or unsafe core build evidence")
    evidence = json.loads((output / "build.json").read_text())
    image = evidence.get("builder_image")
    if not isinstance(image, str) or not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", image):
        raise ValueError("Platform package requires an immutable builder image digest")
    if evidence["target"] != spec or evidence["elf_sha256"] != core.sha256(binary):
        raise ValueError("Core target or digest mismatch")
    inputs = [ROOT / "Cargo.toml", ROOT / "Cargo.lock"]
    inputs += sorted(path for path in (ROOT / "crates").rglob("*") if path.is_file())
    if any(path.is_symlink() for path in inputs):
        raise ValueError("Symlink in core inputs")
    current = {path.relative_to(ROOT).as_posix(): core.sha256(path) for path in inputs}
    if evidence["source_sha256"] != current:
        raise ValueError("Core source evidence does not match the current checkout")
    if evidence["build_helper_sha256"] != core.sha256(ROOT / "scripts/qa/entware-core-build.py"):
        raise ValueError("Core build helper changed")
    manifest = dict(line.split("=", 1) for line in (output / "builder.env").read_text().splitlines())
    if evidence["builder_manifest"] != manifest:
        raise ValueError("Core builder manifest mismatch")
    entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware"))
    staging = entware / "staging_dir" / spec["staging"]
    for dependency in CORE_DEPENDENCIES | ENTWARE_BASE_DEPENDENCIES:
        stamp = staging / spec["root"] / "stamp" / f".{dependency}_installed"
        if not stamp.is_file() or stamp.is_symlink():
            raise ValueError(f"Core dependency not installed: {dependency}")
    for library in LIBRARIES:
        if not (staging / spec["root"] / "opt/lib" / library).is_file():
            raise ValueError(f"Core library not staged: {library}")
    return binary, evidence


def verify(path, spec, binary, evidence):
    version = package_version()
    if path.is_symlink() or path.name != f"mors_{version}_{spec['name']}.ipk":
        raise ValueError("Unexpected platform package filename")
    outer = archive_files(path.read_bytes())
    if set(outer) != {"debian-binary", "control.tar.gz", "data.tar.gz"}:
        raise ValueError("Unexpected IPK container members")
    if outer["debian-binary"][0] != b"2.0\n":
        raise ValueError("Invalid IPK format marker")
    control = archive_files(outer["control.tar.gz"][0])
    if set(control) != {"control", "preinst", "postinst", "prerm", "postrm"}:
        raise ValueError("Unexpected package control scripts")
    metadata = {}
    for line in control["control"][0].decode().splitlines():
        if line.startswith(" ") or not line:
            continue
        key, value = line.split(":", 1)
        if key in metadata:
            raise ValueError("Duplicate control field")
        metadata[key] = value.strip()
    for key, value in {"Package": "mors", "Version": version, "Architecture": spec["name"]}.items():
        if metadata.get(key) != value:
            raise ValueError(f"Unexpected control {key}")
    dependencies = {part.strip().split(" ")[0] for part in metadata.get("Depends", "").split(",")}
    canonical = (ROOT / "builder/entware/runtime-dependencies.mk").read_text()
    required = set(re.findall(r"\+([\w.-]+)", canonical)) | CORE_DEPENDENCIES | ENTWARE_BASE_DEPENDENCIES
    if dependencies != required:
        raise ValueError("Unexpected package dependency set")
    for name in ("preinst", "postinst", "prerm", "postrm"):
        # Keep the established lifecycle scripts byte-equivalent to the recipe.
        recipe = (ROOT / "Makefile").read_text()
        body = recipe.split(f"define Package/mors/{name}\n", 1)[1].split("\nendef", 1)[0]
        body = body.replace("$(PKG_VERSION)", version.rsplit("-", 1)[0])
        body = body.replace("$(PKG_RELEASE)", version.rsplit("-", 1)[1]).replace("$$", "$")
        body = re.sub(r"[ \t]*\\\n[ \t]*", " ", body)
        if control[name][0].decode().strip() != body.strip():
            raise ValueError(f"Unexpected lifecycle script: {name}")
    payload = archive_files(outer["data.tar.gz"][0])
    expected = {}
    for source in (ROOT / "opt").rglob("*"):
        if source.is_symlink():
            raise ValueError("Symlink in package source")
        if source.is_file():
            name = "opt/apps/mors/" + source.relative_to(ROOT / "opt").as_posix()
            expected[name] = source.read_bytes()
    expected[CORE_PATH] = binary.read_bytes()
    if set(payload) != set(expected):
        raise ValueError("Unexpected package payload (missing files or build residue)")
    for name, content in expected.items():
        if payload[name][0] != content:
            raise ValueError(f"Payload content mismatch: {name}")
    if payload[CORE_PATH][1] != 0o755:
        raise ValueError("Core is not executable with mode 0755")
    entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware"))
    readelf = entware / "staging_dir" / spec["toolchain"] / "bin" / (spec["rust_target"] + "-readelf")
    with tempfile.TemporaryDirectory(prefix="mors-ipk-verify-") as tmp:
        extracted = Path(tmp) / "mors-core"
        extracted.write_bytes(payload[CORE_PATH][0])
        details = core.inspect_elf(extracted, readelf, spec)
    if set(re.findall(r"\(NEEDED\).*?\[(.*?)\]", details)) != LIBRARIES:
        raise ValueError("Unexpected core dynamic libraries")
    result = {"schema": "mors-platform-candidate-v1", "package": path.name,
              "version": version, "architecture": spec["name"],
              "sha256": core.sha256(path), "size": path.stat().st_size,
              "core_sha256": digest(payload[CORE_PATH][0]),
              "builder_image": evidence["builder_image"],
              "dependencies": sorted(dependencies), "release_admitted": False,
              "execution": "not-tested", "core_build": evidence}
    return result


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else ""
    if mode not in ("inputs", "verify") or len(sys.argv) != (2 if mode == "inputs" else 3):
        raise ValueError("Usage: entware-platform-package.py inputs|verify IPK")
    spec = core.contract.selected()
    binary, evidence = checked_inputs(spec)
    if mode == "verify":
        path = Path(sys.argv[2])
        result = verify(path, spec, binary, evidence)
        destination = path.with_suffix(".json")
        if destination.is_symlink():
            raise ValueError("Unsafe candidate evidence path")
        destination.write_text(json.dumps(result, indent=2) + "\n")
        print(f"Platform package verified: {path.name}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        sys.exit(f"Platform package: {error}")
