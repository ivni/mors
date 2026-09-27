"""Host-only supply gates: no router or external proxy is contacted."""

import importlib
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/qa"))
inputs = importlib.import_module("naiveproxy-inputs")
package = importlib.import_module("naiveproxy-package")
archives = importlib.import_module("entware-platform-package")
smoke = importlib.import_module("naiveproxy-package-smoke")
finalize = importlib.import_module("naiveproxy-runtime-finalize")


class FinalizationTests(unittest.TestCase):
    def test_only_exact_nonallocated_soft_float_attributes_are_normalized(self):
        record = finalize.MIPS_SOFT_ATTRIBUTES
        section = {"Flags": {"Value": 0}, "Offset": 0, "Size": len(record) * 3}
        self.assertEqual(finalize.canonical_attributes(record * 3, section), (record, 3))
        for data in (b"", record * 2 + record[:-1] + b"\xff", record * 2 + record[:-1]):
            with self.assertRaises(ValueError):
                finalize.canonical_attributes(data, section)
        section["Flags"]["Value"] = 2
        with self.assertRaises(ValueError):
            finalize.canonical_attributes(record * 3, section)

    def test_allocated_section_fingerprint_detects_content_and_metadata_changes(self):
        section = {"Flags": {"Value": 2}, "Offset": 0, "Size": 3,
                   "Type": {"Value": 1}, "Address": 4096, "AddressAlignment": 4}
        original = finalize.allocated(b"abc", {".text": section})
        self.assertNotEqual(original, finalize.allocated(b"abd", {".text": section}))
        section["Address"] += 4
        self.assertNotEqual(original, finalize.allocated(b"abc", {".text": section}))


class InputTests(unittest.TestCase):
    def test_changed_cached_download_is_rejected_without_network(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "asset").write_bytes(b"changed")
            lock = {"downloads": {"asset": {"url": "https://example.invalid/asset", "sha256": "0" * 64}}}
            with patch.object(inputs.urllib.request, "urlopen") as network:
                with self.assertRaisesRegex(ValueError, "missing or changed"):
                    inputs.download(root, lock)
                network.assert_not_called()

    def test_ca_archive_is_pinned_and_empty_bundle_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cert = root / "fixture.pem"
            subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                            "-subj", "/CN=Mors fixture CA", "-addext", "basicConstraints=critical,CA:TRUE",
                            "-keyout", str(root / "key.pem"), "-out", str(cert)],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            bundle, notice = cert.read_bytes(), b"fixture notice"
            wheel = root / "certifi-test-py3-none-any.whl"
            with zipfile.ZipFile(wheel, "w") as archive:
                archive.writestr("certifi/cacert.pem", bundle)
                archive.writestr("LICENSE", notice)
            with tarfile.open(root / "musl-1.2.5.tar.gz", "w:gz") as archive:
                member = tarfile.TarInfo("musl-1.2.5/COPYRIGHT")
                member.size = len(notice)
                archive.addfile(member, io.BytesIO(notice))
            for name in ("MPL-2.0.txt", "GPL-3.0.txt", "GCC-exception-3.1.txt"):
                (root / name).write_bytes(notice)
            lock = {"ca": {"version": "test", "bundle_member": "certifi/cacert.pem",
                           "bundle_sha256": inputs.sha256(bundle), "notice_member": "LICENSE",
                           "notice_sha256": inputs.sha256(notice)},
                    "downloads": {p.name: {"sha256": inputs.sha256(p.read_bytes())}
                                  for p in root.iterdir() if p.is_file()}}
            inputs.prepare_ca(root, root / "ready", lock)
            result = json.loads((root / "ready/ca-manifest.json").read_text())
            self.assertEqual(result["ca_count"], 1)
            self.assertEqual(list((root / "ready/empty-ca-directory").iterdir()), [])
            lock["ca"]["bundle_sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "content digest"):
                inputs.prepare_ca(root, root / "rejected", lock)
            self.assertFalse((root / "rejected").exists())


class RuntimePackageTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "Cleanup fixture requires POSIX sh")
    def test_postrm_removes_only_declared_empty_directories(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            owned = root / "owned"
            (owned / "empty").mkdir(parents=True)
            (owned / "user-directory").mkdir()
            prefix = owned.relative_to("/").as_posix()
            with patch.object(package, "PREFIX", prefix):
                body = package.cleanup_script({prefix, prefix + "/empty", "opt", "opt/apps"})
            script = root / "postrm"
            script.write_bytes(body)
            subprocess.run(["sh", str(script), "upgrade"], check=True)
            self.assertTrue((owned / "empty").exists())
            subprocess.run(["sh", str(script), "remove"], check=True)
            self.assertFalse((owned / "empty").exists())
            self.assertTrue((owned / "user-directory").exists())
            self.assertNotIn(b"rmdir /opt", body)

    def test_arm_package_cannot_reintroduce_required_crypto_extensions(self):
        with patch.dict(os.environ, MORS_ENTWARE_TARGET="aarch64-3.10"):
            spec = package.targets.selected()
            flags = ('target_os="openwrt"\nbuild_static=true\nchrome_pgo_phase=0\n'
                     'clang_base_path="//out/toolchain/usr/lib/llvm-23"\n'
                     'target_cpu="arm64"\narm_cpu="cortex-a53+nocrypto+nocrc"\n').encode()
            package.verify_gn_args(flags, spec)
            with self.assertRaisesRegex(ValueError, "ABI/ISA"):
                package.verify_gn_args(flags.replace(b"cortex-a53+nocrypto+nocrc", b"cortex-a53"), spec)

    def test_static_elf_rejects_wrong_abi_and_dynamic_linking(self):
        for target in ("mipsel-3.4", "aarch64-3.10"):
            with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, MORS_ENTWARE_TARGET=target):
                spec = package.targets.selected()
                binary = Path(tmp) / "naive"
                header = bytearray(64)
                header[:6] = b"\x7fELF" + bytes((spec["elf_class"], spec["elf_endian"]))
                struct.pack_into("<H", header, 16, 2)
                struct.pack_into("<H", header, 18, spec["elf_machine"])
                struct.pack_into("<I", header, 36, 0x70001005)
                binary.write_bytes(header)
                with patch.object(package.subprocess, "check_output", return_value="FP ABI: Soft float"):
                    package.static_elf(binary, spec)
                    binary.write_bytes(header[:5] + bytes([2]) + header[6:])
                    with self.assertRaises(ValueError):
                        package.static_elf(binary, spec)
                binary.write_bytes(header)
                for text in ("INTERP", "DYNAMIC", "(NEEDED)"):
                    with patch.object(package.subprocess, "check_output", return_value=text), self.assertRaises(ValueError):
                        package.static_elf(binary, spec)

    def test_archive_is_deterministic_and_cannot_contain_traversal(self):
        files = {"opt/apps/mors-naiveproxy/bin/naive": (b"fixture", 0o755)}
        directories = {"opt/apps/mors-naiveproxy/share/ca/empty"}
        first = package.tar_bytes(files, directories, 1234567890)
        self.assertEqual(first, package.tar_bytes(files, directories, 1234567890))
        self.assertEqual(archives.archive_files(first), files)
        with self.assertRaises(ValueError):
            package.tar_bytes({"../escape": (b"fixture", 0o644)}, set(), 1234567890)

    def test_missing_notices_or_wrong_source_cannot_create_package(self):
        with tempfile.TemporaryDirectory() as tmp, patch.dict(os.environ, MORS_ENTWARE_TARGET="mipsel-3.4"):
            root = Path(tmp)
            build, ca, notices = (root / name for name in ("build", "ca", "notices"))
            for directory in (build, ca, notices):
                directory.mkdir()
            lock = {"upstream_commit": "a" * 40, "upstream_version": "1.2.3", "package_release": 1,
                    "ca": {"version": "fixture", "bundle_sha256": inputs.sha256(b"fixture CA")}}
            lockfile = root / "lock.json"
            lockfile.write_text(json.dumps(lock))
            for name in ("naive", "args.gn", "naive.linkmap"):
                (build / name).write_bytes(name.encode())
            (build / "args.gn").write_text('target_os="openwrt"\nbuild_static=true\nchrome_pgo_phase=0\n'
                                           'clang_base_path="//out/toolchain/usr/lib/llvm-23"\n'
                                           'target_cpu="mipsel"\nmips_arch_variant="r2"\nmips_float_abi="soft"\n')
            receipt = {"target": "mipsel-3.4", "source_commit": lock["upstream_commit"],
                       "recipe_sha256": {name: inputs.sha256((inputs.ROOT / name).read_bytes()) for name in inputs.RECIPE_FILES},
                       "input_lock_sha256": inputs.sha256(lockfile.read_bytes()),
                       "source_date_epoch": 1234567890,
                       **{key: inputs.sha256((build / name).read_bytes()) for key, name in
                          (("elf_sha256", "naive"), ("args_sha256", "args.gn"), ("linkmap_sha256", "naive.linkmap"))}}
            (build / "build.json").write_text(json.dumps(receipt))
            (build / "naive.runtime").write_bytes((build / "naive").read_bytes())
            finalization = {"linked_elf_sha256": receipt["elf_sha256"], "elf_sha256": receipt["elf_sha256"],
                            "allocated_sections_unchanged": True, "program_headers_unchanged": True,
                            "recipe_sha256": inputs.sha256((inputs.ROOT / "scripts/qa/naiveproxy-runtime-finalize.py").read_bytes())}
            (build / "finalization.json").write_text(json.dumps(finalization))
            materials = {"schema": "mors-runtime-components-v1", "elf_sha256": receipt["elf_sha256"], "linkmap_sha256": receipt["linkmap_sha256"],
                         "linked_elf_sha256": receipt["elf_sha256"],
                         "notice_lock_sha256": inputs.sha256((inputs.ROOT / "builder/entware/naiveproxy-notices.json").read_bytes()),
                         "target_objects": 1, "components": [{"name": "fixture", "path": "fixture", "notices": ["LICENSE"]}],
                         "notices_sha256": {"LICENSE": inputs.sha256(b"notice")}}
            (notices / "components.json").write_text(json.dumps(materials))
            sbom = {"bomFormat": "CycloneDX", "specVersion": "1.6", "components": [{"name": "fixture", "bom-ref": "fixture"}],
                    "metadata": {"component": {"hashes": [{"alg": "SHA-256", "content": receipt["elf_sha256"]}]}}}
            (notices / "sbom.cdx.json").write_text(json.dumps(sbom))
            (ca / "ca-bundle.crt").write_bytes(b"fixture CA")
            (ca / "ca-manifest.json").write_text(json.dumps({"ca_version": "fixture", "ca_count": 1}))
            with patch.object(inputs, "LOCK", lockfile), patch.object(package, "static_elf", return_value="fixture"):
                with self.assertRaisesRegex(ValueError, "missing or changed"):
                    package.assemble(build, ca, notices, root / "absent-notice", package.targets.selected())
                self.assertFalse((root / "absent-notice").exists())
                (notices / "notices").mkdir()
                (notices / "notices/LICENSE").write_bytes(b"notice")
                package.assemble(build, ca, notices, root / "valid", package.targets.selected())
                ipk = next((root / "valid").glob("*.ipk"))
                outer = archives.archive_files(ipk.read_bytes())
                self.assertEqual(set(archives.archive_files(outer["control.tar.gz"][0])), {"control", "postrm"})
                smoke.verify(ipk, package.targets.selected())
                control = archives.archive_files(outer["control.tar.gz"][0])
                control["postinst"] = (b"#!/bin/sh\nexit 0\n", 0o755)
                outer["control.tar.gz"] = (package.tar_bytes(control, set(), 1234567890), 0o644)
                ipk.write_bytes(package.tar_bytes(outer, set(), 1234567890))
                with self.assertRaisesRegex(ValueError, "maintainer scripts"):
                    smoke.verify(ipk, package.targets.selected())
                receipt["source_commit"] = "b" * 40
                (build / "build.json").write_text(json.dumps(receipt))
                with self.assertRaisesRegex(ValueError, "source/target"):
                    package.assemble(build, ca, notices, root / "wrong-source", package.targets.selected())


if __name__ == "__main__":
    unittest.main()
