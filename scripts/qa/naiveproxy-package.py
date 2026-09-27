#!/usr/bin/env python3
"""Assemble a passive optional IPK from verified runtime, notices and CA inputs."""

import argparse
import gzip
import hashlib
from importlib import import_module
import io
import json
from pathlib import Path, PurePosixPath
import re
import shlex
import struct
import subprocess
import tarfile
import tomllib

inputs = import_module("naiveproxy-inputs")
targets = import_module("entware-target")
PREFIX = "opt/apps/mors-naiveproxy"
PACKAGE = "mors-naiveproxy"


def package_version(lock):
    release = lock["package_release"]
    if type(release) is not int or release < 1 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){2,3}", lock["upstream_version"]):
        raise ValueError("Invalid runtime package version/release")
    return f"{lock['upstream_version']}-{release}"


def verify_gn_args(data, spec):
    # Our generated GN arguments use only TOML-compatible scalar assignments.
    args = tomllib.loads(data.decode())
    required = {"target_os": "openwrt", "build_static": True, "chrome_pgo_phase": 0,
                "clang_base_path": "//out/toolchain/usr/lib/llvm-23"}
    if spec["name"] == "mipsel-3.4":
        required.update(target_cpu="mipsel", mips_arch_variant="r2", mips_float_abi="soft")
    elif spec["name"] == "aarch64-3.10":
        required.update(target_cpu="arm64", arm_cpu="cortex-a53+nocrypto+nocrc")
    else:
        raise ValueError("Unsupported runtime ISA")
    if any(args.get(key) != value for key, value in required.items()):
        raise ValueError("Runtime GN arguments violate the pinned ABI/ISA contract")
    return args


def sha(data):
    return hashlib.sha256(data).hexdigest()


def safe_relative(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or str(path) != name or name == ".":
        raise ValueError("Unsafe package member name")
    return path


def cleanup_script(directories):
    owned = [name for name in directories if name == PREFIX or name.startswith(PREFIX + "/")]
    if not owned:
        raise ValueError("No owned runtime directories")
    owned.sort(key=lambda name: (-len(PurePosixPath(name).parts), name))
    for name in owned:
        safe_relative(name)
    paths = " ".join(shlex.quote("/" + name) for name in owned)
    return ("#!/bin/sh\n[ \"${1:-}\" = remove ] || exit 0\n"
            f"rmdir {paths} 2>/dev/null || true\n").encode()


def static_elf(binary, spec):
    data = binary.read_bytes()
    if len(data) < 64 or data[:4] != b"\x7fELF" or data[4:6] != bytes((spec["elf_class"], spec["elf_endian"])):
        raise ValueError("Runtime ELF class/endian mismatch")
    endian = "<" if spec["elf_endian"] == 1 else ">"
    if struct.unpack_from(endian + "H", data, 16)[0] != 2:
        raise ValueError("Runtime must be a static executable ELF")
    if struct.unpack_from(endian + "H", data, 18)[0] != spec["elf_machine"]:
        raise ValueError("Runtime ELF machine mismatch")
    details = subprocess.check_output(["readelf", "-h", "-l", "-d", "-A", str(binary)], text=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    if "INTERP" in details or "DYNAMIC" in details or "(NEEDED)" in details:
        raise ValueError("Runtime must have no interpreter or dynamic dependencies")
    if spec["elf_machine"] == 8:
        flags = struct.unpack_from(endian + "I", data, 36)[0]
        if flags & 0xF000F020 != 0x70001000 or not re.search(r"^\s*FP ABI:\s+Soft float\s*$", details, re.M):
            raise ValueError("Runtime must be MIPS32r2 O32 soft-float")
    return details


def tar_bytes(files, directories, epoch):
    result = io.BytesIO()
    with gzip.GzipFile(fileobj=result, mode="wb", filename="", mtime=epoch) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.USTAR_FORMAT) as archive:
            for name in sorted(directories):
                safe_relative(name)
                info = tarfile.TarInfo("./" + name)
                info.type, info.mode, info.mtime = tarfile.DIRTYPE, 0o755, epoch
                archive.addfile(info)
            for name, (data, mode) in sorted(files.items()):
                safe_relative(name)
                info = tarfile.TarInfo("./" + name)
                info.size, info.mode, info.mtime = len(data), mode, epoch
                archive.addfile(info, io.BytesIO(data))
    return result.getvalue()


def assemble(build, ca, notices, output, spec):
    lock = json.loads(inputs.LOCK.read_text())
    if spec["name"] not in ("mipsel-3.4", "aarch64-3.10"):
        raise ValueError("No NaiveProxy supplier for this ABI")
    receipt = json.loads((build / "build.json").read_text())
    if receipt["target"] != spec["name"] or receipt["source_commit"] != lock["upstream_commit"]:
        raise ValueError("Runtime source/target mismatch")
    if receipt["input_lock_sha256"] != sha(inputs.LOCK.read_bytes()):
        raise ValueError("Runtime was built against a different input lock")
    if set(receipt["recipe_sha256"]) != set(inputs.RECIPE_FILES):
        raise ValueError("Incomplete runtime build recipe evidence")
    for name, expected in receipt["recipe_sha256"].items():
        inputs.checked_file(inputs.ROOT / name, expected)
    inputs.checked_file(build / "naive", receipt["elf_sha256"])
    finalization = json.loads((build / "finalization.json").read_text())
    if finalization["linked_elf_sha256"] != receipt["elf_sha256"] or not finalization["allocated_sections_unchanged"] or not finalization["program_headers_unchanged"]:
        raise ValueError("Unverified runtime finalization")
    inputs.checked_file(inputs.ROOT / "scripts/qa/naiveproxy-runtime-finalize.py", finalization["recipe_sha256"])
    binary = inputs.checked_file(build / "naive.runtime", finalization["elf_sha256"])
    arguments = inputs.checked_file(build / "args.gn", receipt["args_sha256"])
    verify_gn_args(arguments, spec)
    inputs.checked_file(build / "naive.linkmap", receipt["linkmap_sha256"])
    elf = static_elf(build / "naive.runtime", spec)
    materials = json.loads((notices / "components.json").read_text())
    if materials.get("schema") != "mors-runtime-components-v1":
        raise ValueError("Unsupported runtime inventory schema")
    notice_lock = inputs.ROOT / "builder/entware/naiveproxy-notices.json"
    if materials.get("notice_lock_sha256") != sha(notice_lock.read_bytes()):
        raise ValueError("Runtime notices use another metadata lock")
    if materials["elf_sha256"] != sha(binary) or materials["linkmap_sha256"] != receipt["linkmap_sha256"]:
        raise ValueError("Notices/SBOM do not belong to this linked ELF")
    if materials.get("linked_elf_sha256") != receipt["elf_sha256"]:
        raise ValueError("Notices lost the original link provenance")
    if not materials["components"] or not materials["target_objects"]:
        raise ValueError("Empty runtime component inventory")
    sbom_bytes = (notices / "sbom.cdx.json").read_bytes()
    sbom = json.loads(sbom_bytes)
    if sbom["bomFormat"] != "CycloneDX" or sbom.get("specVersion") != "1.6" or sbom["metadata"]["component"]["hashes"] != [{"alg": "SHA-256", "content": sha(binary)}]:
        raise ValueError("Wrong SBOM application hash")
    if len(sbom["components"]) != len(materials["components"]):
        raise ValueError("SBOM component inventory mismatch")
    if {item["bom-ref"] for item in sbom["components"]} != {item["path"] for item in materials["components"]}:
        raise ValueError("SBOM component identities mismatch")
    expected_notices = set(materials["notices_sha256"])
    referenced = {name for item in materials["components"] for name in item["notices"]}
    if not referenced <= expected_notices:
        raise ValueError("A runtime component is missing notices")
    ca_bytes = inputs.checked_file(ca / "ca-bundle.crt", lock["ca"]["bundle_sha256"])
    ca_evidence = json.loads((ca / "ca-manifest.json").read_text())
    if ca_evidence["ca_version"] != lock["ca"]["version"] or ca_evidence["ca_count"] < 1:
        raise ValueError("Wrong CA bundle metadata")
    files = {f"{PREFIX}/bin/naive": (binary, 0o755),
             f"{PREFIX}/share/ca/ca-bundle.crt": (ca_bytes, 0o644),
             f"{PREFIX}/share/sbom.cdx.json": (sbom_bytes, 0o644),
             f"{PREFIX}/share/components.json": ((notices / "components.json").read_bytes(), 0o644)}
    for name, expected in materials["notices_sha256"].items():
        safe_relative(name)
        data = inputs.checked_file(notices / "notices" / name, expected)
        if not data.strip():
            raise ValueError("Empty notice")
        files[f"{PREFIX}/share/licenses/{name}"] = (data, 0o644)
    version = package_version(lock)
    manifest = {"schema": "mors-naiveproxy-runtime-v1", "package": PACKAGE, "version": version,
                "architecture": spec["name"], "build": receipt, "finalization": finalization,
                "runtime_sha256": sha(binary),
                "runtime_path": f"/{PREFIX}/bin/naive", "capabilities": {"tcp": True, "udp_associate": False},
                "abi": {"elf_class": spec["elf_class"], "elf_endian": spec["elf_endian"],
                        "elf_machine": spec["elf_machine"], "static": True,
                        "baseline": "mips32r2-o32-soft" if spec["name"] == "mipsel-3.4" else "armv8-a-fp-asimd"},
                "trust": {"file": f"/{PREFIX}/share/ca/ca-bundle.crt", "directory": f"/{PREFIX}/share/ca/empty",
                          "version": ca_evidence["ca_version"], "sha256": sha(ca_bytes),
                          "embedded_chrome_root_store": True},
                "lifecycle": {"installation": "passive", "activation_owner": "mors-core"},
                "payload_sha256": {name: sha(data) for name, (data, _) in files.items()}}
    files[f"{PREFIX}/manifest.json"] = ((json.dumps(manifest, indent=2) + "\n").encode(), 0o644)
    directories = {f"{PREFIX}/share/ca/empty"}
    for name in (*files, *directories.copy()):
        directories.update(str(parent) for parent in PurePosixPath(name).parents if str(parent) != ".")
    directories = {name for name in directories if name == PREFIX or name.startswith(PREFIX + "/")}
    epoch = receipt["source_date_epoch"]
    control = (f"Package: {PACKAGE}\nVersion: {version}\nArchitecture: {spec['name']}\n"
               f"Installed-Size: {sum(len(data) for data, _ in files.values())}\n"
               "Section: net\nDescription: Закреплённый пассивный runtime NaiveProxy для Mors\n").encode()
    outer = {"debian-binary": (b"2.0\n", 0o644),
             "control.tar.gz": (tar_bytes({"control": (control, 0o644),
                                            "postrm": (cleanup_script(directories), 0o755)}, set(), epoch), 0o644),
             "data.tar.gz": (tar_bytes(files, directories, epoch), 0o644)}
    content = tar_bytes(outer, set(), epoch)
    output.mkdir(parents=True, exist_ok=True)
    if output.is_symlink():
        raise ValueError("Unsafe package output directory")
    dest = output / f"{PACKAGE}_{version}_{spec['name']}.ipk"
    for path in (dest, dest.with_suffix(".json"), dest.with_suffix(".elf.txt")):
        if path.exists() or path.is_symlink():
            raise ValueError("Candidate output already exists")
    with dest.open("xb") as stream:
        stream.write(content)
    summary = {"schema": "mors-naiveproxy-candidate-v1", "package": dest.name, "sha256": sha(content),
               "size": len(content), "manifest": manifest, "release_admitted": False, "execution": "not-tested"}
    dest.with_suffix(".json").write_text(json.dumps(summary, indent=2) + "\n")
    dest.with_suffix(".elf.txt").write_text(elf)
    print(f"Passive runtime package created: {dest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("build", "ca", "notices", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    assemble(args.build, args.ca, args.notices, args.output, targets.selected())


if __name__ == "__main__":
    main()
