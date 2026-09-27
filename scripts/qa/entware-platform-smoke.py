#!/usr/bin/env python3
"""Host-only QEMU and opkg --noaction checks; never execute maintainer scripts."""

from importlib import import_module
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib

package = import_module("entware-platform-package")
EMULATORS = {"aarch64-3.10": ("qemu-aarch64", "cortex-a53"),
             "mips-3.4": ("qemu-mips", "24Kc"),
             "mipsel-3.4": ("qemu-mipsel", "24Kc")}


def main():
    if len(sys.argv) != 2:
        raise ValueError("Usage: entware-platform-smoke.py IPK")
    path = Path(sys.argv[1]).resolve()
    spec = package.core.contract.selected()
    binary, evidence = package.checked_inputs(spec)
    result = package.verify(path, spec, binary, evidence)
    entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware"))
    sysroot = entware / "staging_dir" / spec["staging"] / spec["root"]
    opkg = entware / "staging_dir/host/bin/opkg"
    expected_version = tomllib.loads((package.ROOT / "Cargo.toml").read_text())["workspace"]["package"]["version"]
    outer = package.archive_files(path.read_bytes())
    payload = package.archive_files(outer["data.tar.gz"][0])
    with tempfile.TemporaryDirectory(prefix="mors-platform-smoke-") as tmp:
        root = Path(tmp)
        extracted = root / "mors-core"
        extracted.write_bytes(payload[package.CORE_PATH][0])
        extracted.chmod(0o755)
        qemu, cpu = EMULATORS[spec["name"]]
        command = [qemu, "-cpu", cpu, "-L", str(sysroot), str(extracted)]
        outputs = {}
        for flag in ("--version", "--help"):
            completed = subprocess.run(command + [flag], capture_output=True, text=True, timeout=30, check=True)
            if completed.stderr:
                raise ValueError("Unexpected core smoke stderr")
            outputs[flag] = completed.stdout
        if outputs["--version"] != f"mors-core {expected_version}\n":
            raise ValueError("Core version does not match the packaged workspace")
        if not all(flag in outputs["--help"] for flag in ("mors-core", "--help", "--version")):
            raise ValueError("Unexpected core help")
        opkg_results = {}
        for arch in EMULATORS:
            offline = root / arch
            (offline / "tmp").mkdir(parents=True)
            # Host opkg resolves dependencies even with --nodeps/--force-depends.
            # Model installed names only; real dependency/ELF checks run above.
            status = offline / "usr/lib/opkg/status"
            status.parent.mkdir(parents=True)
            status.write_text("".join(
                f"Package: {name}\nVersion: 1\nArchitecture: all\nStatus: install ok installed\n\n"
                for name in result["dependencies"]))
            config = root / f"{arch}.conf"
            config.write_text(f"dest root /\narch all 1\narch {arch} 10\n")
            completed = subprocess.run([str(opkg), "-f", str(config), "-o", str(offline),
                                        "--noaction", "install", str(path)],
                                       capture_output=True, text=True, timeout=30)
            expected_success = arch == spec["name"]
            if (completed.returncode == 0) != expected_success:
                raise ValueError(f"Unexpected opkg architecture result for {arch}: {completed.stdout}{completed.stderr}")
            if not expected_success and "incompatible with the architectures" not in completed.stdout + completed.stderr:
                raise ValueError("opkg failed for a reason other than incompatible architecture")
            # A dry run must not place the payload or execute its postinst.
            if (offline / package.CORE_PATH).exists() or (offline / "opt/etc/mors.conf").exists():
                raise ValueError("opkg dry run unexpectedly installed payload/configuration")
            opkg_results[arch] = {"exit_code": completed.returncode,
                                  "compatible": expected_success, "mode": "noaction",
                                  "dependency_inventory": "fixture-installed-names"}
    result["execution"] = {"kind": "qemu-user", "cpu": cpu, "version": outputs["--version"].strip(),
                           "help_exit_code": 0, "router_tested": False}
    result["opkg_architecture"] = opkg_results
    destination = path.with_suffix(".smoke.json")
    if destination.is_symlink():
        raise ValueError("Unsafe smoke evidence path")
    destination.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Platform smoke passed: {path.name}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError) as error:
        sys.exit(f"Platform smoke: {error}")
