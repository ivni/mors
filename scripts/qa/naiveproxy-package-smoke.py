#!/usr/bin/env python3
"""Inspect an optional runtime IPK and smoke only its extracted version/help."""

import argparse
from importlib import import_module
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile

package = import_module("naiveproxy-package")
archives = import_module("entware-platform-package")
EMULATORS = {"aarch64-3.10": ("qemu-aarch64-static", "cortex-a53"),
             "mipsel-3.4": ("qemu-mipsel-static", "24Kc")}


def verify(path, spec):
    lock = json.loads(package.inputs.LOCK.read_text())
    version = package.package_version(lock)
    if path.is_symlink() or path.name != f"mors-naiveproxy_{version}_{spec['name']}.ipk":
        raise ValueError("Runtime package name/ABI mismatch")
    outer = archives.archive_files(path.read_bytes())
    if set(outer) != {"debian-binary", "control.tar.gz", "data.tar.gz"} or outer["debian-binary"][0] != b"2.0\n":
        raise ValueError("Invalid runtime IPK container")
    control = archives.archive_files(outer["control.tar.gz"][0])
    if set(control) != {"control", "postrm"}:
        raise ValueError("Unreviewed maintainer scripts in passive runtime package")
    fields = {}
    for line in control["control"][0].decode().splitlines():
        key, value = line.split(":", 1)
        if key in fields:
            raise ValueError("Duplicate control field")
        fields[key] = value.strip()
    for key, value in {"Package": "mors-naiveproxy", "Version": version, "Architecture": spec["name"]}.items():
        if fields.get(key) != value:
            raise ValueError(f"Wrong runtime control {key}")
    if fields.get("Depends"):
        raise ValueError("Static runtime must not acquire undeclared dependencies")
    payload = archives.archive_files(outer["data.tar.gz"][0])
    prefix = package.PREFIX
    manifest_path = f"{prefix}/manifest.json"
    manifest = json.loads(payload[manifest_path][0])
    if manifest.get("schema") != "mors-naiveproxy-runtime-v1":
        raise ValueError("Unsupported runtime manifest schema")
    if manifest["architecture"] != spec["name"] or manifest["version"] != version:
        raise ValueError("Wrong runtime manifest identity")
    if manifest["lifecycle"] != {"installation": "passive", "activation_owner": "mors-core"}:
        raise ValueError("Wrong runtime lifecycle ownership")
    if manifest["build"]["input_lock_sha256"] != package.sha(package.inputs.LOCK.read_bytes()):
        raise ValueError("Wrong runtime input lock")
    if set(payload) != set(manifest["payload_sha256"]) | {manifest_path}:
        raise ValueError("Unexpected runtime payload or build residue")
    for name, (content, mode) in payload.items():
        if not name.startswith(prefix + "/"):
            raise ValueError("Runtime payload escapes its owned directory")
        expected_mode = 0o755 if name == f"{prefix}/bin/naive" else 0o644
        if mode != expected_mode:
            raise ValueError("Wrong runtime payload permissions")
        if name != manifest_path and package.sha(content) != manifest["payload_sha256"][name]:
            raise ValueError("Runtime payload digest mismatch")
    ca_name = f"{prefix}/share/ca/ca-bundle.crt"
    if package.sha(payload[ca_name][0]) != lock["ca"]["bundle_sha256"]:
        raise ValueError("Wrong pinned CA bundle")
    if manifest["trust"]["directory"] != f"/{prefix}/share/ca/empty" or manifest["trust"]["file"] != f"/{ca_name}":
        raise ValueError("Wrong isolated trust paths")
    with tarfile.open(fileobj=io.BytesIO(outer["data.tar.gz"][0]), mode="r:gz") as archive:
        empty = archive.getmember(f"./{prefix}/share/ca/empty")
        if not empty.isdir() or empty.mode != 0o755:
            raise ValueError("Missing owned empty CA directory")
        directories = {str(PurePosixPath(member.name)) for member in archive if member.isdir()}
        if any(member.isdir() and member.mode != 0o755 for member in archive):
            raise ValueError("Wrong runtime directory permissions")
    expected_directories = {f"{prefix}/share/ca/empty"}
    for name in (*payload, *expected_directories.copy()):
        expected_directories.update(str(parent) for parent in PurePosixPath(name).parents
                                    if str(parent) == prefix or str(parent).startswith(prefix + "/"))
    if directories != expected_directories:
        raise ValueError("Unexpected runtime directories outside the owned layout")
    if control["postrm"] != (package.cleanup_script(directories), 0o755):
        raise ValueError("Unreviewed postrm cleanup")
    if any(name.startswith(f"{prefix}/share/ca/empty/") for name in payload):
        raise ValueError("CA directory must remain empty")
    components = json.loads(payload[f"{prefix}/share/components.json"][0])
    expected = {manifest_path, f"{prefix}/bin/naive", ca_name,
                f"{prefix}/share/sbom.cdx.json", f"{prefix}/share/components.json"}
    expected.update(f"{prefix}/share/licenses/{name}" for name in components["notices_sha256"])
    if set(payload) != expected:
        raise ValueError("Runtime package contains undeclared files/build residue")
    if any(data.startswith(b"\x7fELF") for name, (data, _) in payload.items() if name != f"{prefix}/bin/naive"):
        raise ValueError("Runtime package contains an extra ELF")
    elf = payload[f"{prefix}/bin/naive"][0]
    if components["elf_sha256"] != package.sha(elf) or manifest["runtime_sha256"] != package.sha(elf):
        raise ValueError("Wrong component/ELF correspondence")
    if manifest["finalization"]["elf_sha256"] != package.sha(elf) or manifest["finalization"]["linked_elf_sha256"] != manifest["build"]["elf_sha256"]:
        raise ValueError("Wrong finalization provenance")
    for name, digest in components["notices_sha256"].items():
        if package.sha(payload[f"{prefix}/share/licenses/{name}"][0]) != digest:
            raise ValueError("Runtime notice content mismatch")
    return manifest, elf


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipk", type=Path)
    parser.add_argument("--opkg", required=True, type=Path)
    args = parser.parse_args()
    spec = package.targets.selected()
    manifest, elf = verify(args.ipk, spec)
    results = {}
    with tempfile.TemporaryDirectory(prefix="mors-naive-smoke-") as tmp:
        root = Path(tmp)
        binary = root / "naive"
        binary.write_bytes(elf)
        binary.chmod(0o755)
        package.static_elf(binary, spec)
        qemu, cpu = EMULATORS[spec["name"]]
        for flag in ("--version", "--help"):
            completed = subprocess.run([qemu, "-cpu", cpu, str(binary), flag],
                                       capture_output=True, text=True, check=True, timeout=60, cwd=root)
            text = completed.stdout + completed.stderr
            if flag == "--version" and "naive " + manifest["version"].rsplit("-", 1)[0] not in text:
                raise ValueError("Unexpected NaiveProxy version")
            if flag == "--help" and "--" not in text:
                raise ValueError("Unexpected NaiveProxy help")
            results[flag] = {"exit_code": 0, "output": text}
        opkg_results = {}
        for arch in ("aarch64-3.10", "mipsel-3.4", "mips-3.4"):
            offline = root / arch
            (offline / "tmp").mkdir(parents=True)
            conf = root / f"{arch}.conf"
            conf.write_text(f"dest root /\narch all 1\narch {arch} 10\n")
            completed = subprocess.run([str(args.opkg), "-f", str(conf), "-o", str(offline),
                                        "--noaction", "install", str(args.ipk.resolve())],
                                       capture_output=True, text=True, timeout=30)
            compatible = arch == spec["name"]
            if (completed.returncode == 0) != compatible:
                raise ValueError(f"Unexpected opkg architecture result: {completed.stdout}{completed.stderr}")
            if not compatible and "incompatible with the architectures" not in completed.stdout + completed.stderr:
                raise ValueError("opkg failed for an unrelated reason")
            if (offline / package.PREFIX).exists():
                raise ValueError("Dry-run unexpectedly installed payload")
            opkg_results[arch] = {"exit_code": completed.returncode, "compatible": compatible}
    evidence = {"package": args.ipk.name, "sha256": package.sha(args.ipk.read_bytes()),
                "architecture": spec["name"], "qemu_cpu": cpu, "execution": results,
                "opkg_noaction": opkg_results, "router_tested": False, "release_admitted": False}
    dest = args.ipk.with_suffix(".smoke.json")
    if dest.exists() or dest.is_symlink():
        raise ValueError("Smoke evidence already exists")
    dest.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Runtime IPK and smoke verified: {args.ipk.name}")


if __name__ == "__main__":
    main()
