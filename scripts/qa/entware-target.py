#!/usr/bin/env python3
"""Closed ABI selection for the immutable builder (not router discovery)."""

import hashlib
import json
import os
from pathlib import Path
import sys
import re

ROOT = Path(__file__).resolve().parents[2]


def selected():
    targets = json.loads((ROOT / "builder/entware/targets.json").read_text())
    name = os.environ.get("MORS_ENTWARE_TARGET", "aarch64-3.10")
    if name not in targets:
        raise ValueError(f"Unsupported Entware target: {name}")
    spec = dict(targets[name])
    spec.update(name=name, config=f"configs/{name}.config")
    spec["toolchain"] = f"toolchain-{spec['arch']}_{spec['cpu']}_gcc-8.4.0_glibc-2.27"
    spec["staging"] = f"target-{spec['arch']}_{spec['cpu']}_glibc-2.27"
    spec["root"] = f"root-{name}"
    return spec


def verify_config(entware, spec):
    digest = hashlib.sha256((entware / spec["config"]).read_bytes()).hexdigest()
    if digest != spec["config_sha256"]:
        raise ValueError("Entware target config digest mismatch")


def main():
    spec = selected()
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode == "manifest":
        for key in ("name", "config", "config_sha256", "toolchain", "staging", "root"):
            print(f"entware_target_{key}={spec[key]}")
    elif mode in ("verify", "verify-active"):
        entware = Path(os.environ.get("ENTWARE_DIR", "/opt/entware"))
        verify_config(entware, spec)
        if mode == "verify-active":
            config = (entware / ".config").read_text()
            for key, value in (("ARCH", spec["arch"]), ("CPU_TYPE", spec["cpu"]),
                               ("TARGET_ARCH_PACKAGES", spec["name"]),
                               ("TARGET_BOARD", spec["name"])):
                if re.findall(rf'^CONFIG_{key}="([^"]+)"$', config, re.MULTILINE) != [value]:
                    raise ValueError(f"Active Entware config {key} mismatch")
    elif mode in spec:
        print(spec[mode])
    else:
        raise ValueError("Usage: entware-target.py manifest|verify|<field>")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, OSError) as error:
        sys.exit(f"Entware target: {error}")
