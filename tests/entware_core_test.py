"""Negative ELF admission tests; these fixtures do not claim cross-compilation."""

import importlib
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/qa"))
core = importlib.import_module("entware-core-build")


class CoreElfTests(unittest.TestCase):
    def test_active_config_cannot_switch_abi_or_duplicate_fields(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.dict(os.environ, MORS_ENTWARE_TARGET="mipsel-3.4", ENTWARE_DIR=tmp):
            spec = core.contract.selected()
            root = Path(tmp)
            config = root / spec["config"]
            config.parent.mkdir()
            config.write_text("pinned config\n")
            spec["config_sha256"] = core.sha256(config)
            active = (f'CONFIG_ARCH="{spec["arch"]}"\n'
                      f'CONFIG_CPU_TYPE="{spec["cpu"]}"\n'
                      f'CONFIG_TARGET_BOARD="{spec["name"]}"\n'
                      f'CONFIG_TARGET_ARCH_PACKAGES="{spec["name"]}"\n')
            with patch.object(core.contract, "selected", return_value=spec), \
                    patch.object(sys, "argv", ["entware-target.py", "verify-active"]):
                (root / ".config").write_text(active)
                core.contract.main()
                for invalid in (active.replace('"mipsel"', '"mips"'),
                                active + 'CONFIG_ARCH="mipsel"\n', ""):
                    (root / ".config").write_text(invalid)
                    with self.assertRaisesRegex(ValueError, "Active Entware config"):
                        core.contract.main()
                (root / ".config").write_text(active)
                config.write_text("changed config\n")
                with self.assertRaisesRegex(ValueError, "digest mismatch"):
                    core.contract.main()

    def test_build_is_frozen_isolated_and_records_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Cargo.toml").write_text("[workspace]\n")
            (root / "Cargo.lock").write_text("version = 4\n")
            (root / "crates/example/src").mkdir(parents=True)
            (root / "crates/example/src/main.rs").write_text("fn main() {}\n")
            (root / ".cargo").mkdir()
            (root / ".cargo/config.toml").write_text("untrusted configuration")
            manifest = root / "manifest.env"
            manifest.write_text("builder_id=fixture\n")
            calls = []

            def command(args, **kwargs):
                calls.append(args)
                if args[0] == "bash":
                    self.assertTrue(args[1].endswith("verify-entware-builder.sh"))
                    return
                self.assertEqual(args[1:], ["build", "--workspace", "--release", "--frozen",
                                           "--target", "aarch64-openwrt-linux-gnu"])
                source = kwargs["cwd"]
                env = kwargs["env"]
                self.assertNotEqual(env["CARGO_ENCODED_RUSTFLAGS"], "poison")
                self.assertNotIn("RUSTFLAGS", env)
                self.assertNotIn("RUSTC_WRAPPER", env)
                self.assertFalse((source / ".cargo/config.toml").exists())
                self.assertTrue((source / "Cargo.lock").is_file())
                binary = source / "target/aarch64-openwrt-linux-gnu/release/mors-core"
                binary.parent.mkdir(parents=True)
                binary.write_bytes(b"mock compiler output")

            with patch.object(core, "ROOT", root), patch.dict(os.environ, {
                "MORS_ENTWARE_TARGET": "aarch64-3.10", "ENTWARE_DIR": str(root / "entware"),
                "MORS_ENTWARE_BUILDER_MANIFEST": str(manifest),
                "MORS_ENTWARE_BUILDER_IMAGE": "example/builder@sha256:" + "a" * 64,
                "CARGO_ENCODED_RUSTFLAGS": "poison", "RUSTC_WRAPPER": "poison",
            }), patch.object(core.subprocess, "run", side_effect=command), \
                    patch.object(core, "inspect_elf", return_value="ELF fixture"):
                core.main()
            self.assertEqual(len(calls), 2)
            output = root / "packages/core/aarch64-3.10"
            evidence = core.json.loads((output / "build.json").read_text())
            self.assertEqual(evidence["elf_sha256"], core.sha256(output / "mors-core"))
            self.assertEqual(evidence["builder_manifest"], {"builder_id": "fixture"})
            self.assertIn("crates/example/src/main.rs", evidence["source_sha256"])
            self.assertEqual(evidence["execution"], "not-tested")

    def test_abi_and_linker_contract(self):
        for name in ("mips-3.4", "mipsel-3.4", "aarch64-3.10"):
            with self.subTest(target=name), patch.dict(os.environ, MORS_ENTWARE_TARGET=name):
                spec = core.contract.selected()
                endian = "<" if spec["elf_endian"] == 1 else ">"
                valid = bytearray(64)
                valid[:6] = b"\x7fELF" + bytes((spec["elf_class"], spec["elf_endian"]))
                struct.pack_into(endian + "H", valid, 18, spec["elf_machine"])
                struct.pack_into(endian + "I", valid, 36, 0x70001000)
                details = f"[Requesting program interpreter: {spec['interpreter']}]\nSoft float"
                with tempfile.TemporaryDirectory() as tmp:
                    binary = Path(tmp) / "core"
                    binary.write_bytes(valid)
                    with patch.object(core.subprocess, "check_output", return_value=details):
                        core.inspect_elf(binary, "readelf", spec)
                        for index in (0, 4, 5, 18):
                            broken = bytearray(valid)
                            broken[index] ^= 1
                            binary.write_bytes(broken)
                            with self.assertRaises(ValueError):
                                core.inspect_elf(binary, "readelf", spec)
                        if spec["elf_machine"] == 8:
                            for invalid_flags in (0x50001000, 0x70001020):
                                broken = bytearray(valid)
                                struct.pack_into(endian + "I", broken, 36, invalid_flags)
                                binary.write_bytes(broken)
                                with self.assertRaisesRegex(ValueError, "MIPS32r2"):
                                    core.inspect_elf(binary, "readelf", spec)
                    binary.write_bytes(valid)
                    with patch.object(core.subprocess, "check_output", return_value="wrong loader"):
                        with self.assertRaisesRegex(ValueError, "interpreter"):
                            core.inspect_elf(binary, "readelf", spec)
                    if spec["elf_machine"] == 8:
                        with patch.object(core.subprocess, "check_output",
                                          return_value=details.replace("Soft float", "Hard float")):
                            with self.assertRaisesRegex(ValueError, "soft-float"):
                                core.inspect_elf(binary, "readelf", spec)


if __name__ == "__main__":
    unittest.main()
