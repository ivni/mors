"""Host-only candidate archive tests. No router scripts are executed."""

import importlib
import io
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/qa"))
package = importlib.import_module("entware-platform-package")


def archive(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode="w:gz") as tar:
        for name, (data, mode) in files.items():
            info = tarfile.TarInfo("./" + name)
            info.size, info.mode = len(data), mode
            tar.addfile(info, io.BytesIO(data))
    return output.getvalue()


class PackageTests(unittest.TestCase):
    def test_stale_or_unattested_core_cannot_enter_a_package(self):
        with tempfile.TemporaryDirectory() as tmp, \
                patch.dict(os.environ, MORS_ENTWARE_TARGET="mipsel-3.4", ENTWARE_DIR=tmp):
            root = Path(tmp)
            spec = package.core.contract.selected()
            output = root / "packages/core" / spec["name"]
            output.mkdir(parents=True)
            (output / "mors-core").write_bytes(b"fixture")
            (output / "builder.env").write_text("builder_id=fixture\n")
            (root / "Cargo.toml").write_text("workspace")
            (root / "Cargo.lock").write_text("lock")
            (root / "crates/example/src").mkdir(parents=True)
            source = root / "crates/example/src/main.rs"
            source.write_text("fn main() {}")
            helper = root / "scripts/qa/entware-core-build.py"
            helper.parent.mkdir(parents=True)
            helper.write_text("fixture helper")
            staging = root / "staging_dir" / spec["staging"]
            stamps = staging / spec["root"] / "stamp"
            stamps.mkdir(parents=True)
            (staging / spec["root"] / "opt/lib").mkdir(parents=True)
            for dep in package.CORE_DEPENDENCIES | package.ENTWARE_BASE_DEPENDENCIES:
                (stamps / f".{dep}_installed").touch()
            for lib in package.LIBRARIES:
                (staging / spec["root"] / "opt/lib" / lib).touch()
            evidence = {"target": spec, "elf_sha256": package.core.sha256(output / "mors-core"),
                        "builder_image": "example/builder@sha256:" + "a" * 64,
                        "builder_manifest": {"builder_id": "fixture"},
                        "build_helper_sha256": package.core.sha256(helper),
                        "source_sha256": {p.relative_to(root).as_posix(): package.core.sha256(p)
                                          for p in (root / "Cargo.toml", root / "Cargo.lock", source)}}

            def check(value):
                (output / "build.json").write_text(json.dumps(value))
                return package.checked_inputs(spec)

            with patch.object(package, "ROOT", root):
                check(evidence)
                for key, value in (("builder_image", None), ("builder_image", "example/builder:latest"),
                                   ("elf_sha256", "0" * 64), ("source_sha256", {}),
                                   ("build_helper_sha256", "0" * 64), ("builder_manifest", {}),
                                   ("target", {**spec, "name": "mips-3.4"})):
                    with self.subTest(key=key), self.assertRaises(ValueError):
                        check({**evidence, key: value})
                source.write_text("changed source")
                with self.assertRaisesRegex(ValueError, "source evidence"):
                    check(evidence)
                source.write_text("fn main() {}")
                (stamps / ".libpthread_installed").unlink()
                with self.assertRaisesRegex(ValueError, "dependency not installed"):
                    check(evidence)

    def test_reject_unsafe_archives(self):
        for name, kind in (("../escape", tarfile.REGTYPE), ("/absolute", tarfile.REGTYPE),
                           ("link", tarfile.SYMTYPE), ("hard", tarfile.LNKTYPE),
                           ("device", tarfile.CHRTYPE)):
            with self.subTest(name=name):
                output = io.BytesIO()
                with tarfile.open(fileobj=output, mode="w:gz") as tar:
                    info = tarfile.TarInfo(name)
                    info.type = kind
                    tar.addfile(info)
                with self.assertRaises(ValueError):
                    package.archive_files(output.getvalue())
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode="w:gz") as tar:
            tar.addfile(tarfile.TarInfo("file"))
            tar.addfile(tarfile.TarInfo("./file"))
        with self.assertRaises(ValueError):
            package.archive_files(output.getvalue())

    def test_all_targets_reject_wrong_metadata_payload_and_hooks(self):
        for target in ("aarch64-3.10", "mips-3.4", "mipsel-3.4"):
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp, \
                    patch.dict(os.environ, MORS_ENTWARE_TARGET=target):
                root = Path(tmp)
                (root / "opt/bin").mkdir(parents=True)
                (root / "opt/bin/mors").write_bytes(b"#!/bin/sh\n")
                (root / "builder/entware").mkdir(parents=True)
                (root / "builder/entware/runtime-dependencies.mk").write_text("MORS_RUNTIME_DEPENDS:=+jq\n")
                hooks = {name: b"#!/bin/sh\nexit 0\n" for name in ("preinst", "postinst", "prerm", "postrm")}
                recipe = "PKG_VERSION:=1.3.0~rc2\nPKG_RELEASE:=1\n"
                for name, body in hooks.items():
                    recipe += f"define Package/mors/{name}\n{body.decode()}\nendef\n"
                (root / "Makefile").write_text(recipe)
                binary = root / "mors-core"
                binary.write_bytes(b"fixture ELF, inspected separately")
                spec = package.core.contract.selected()
                details = "\n".join(f"(NEEDED) [{lib}]" for lib in package.LIBRARIES)
                metadata = (f"Package: mors\nVersion: 1.3.0~rc2-1\nArchitecture: {target}\n"
                            "Depends: libc, libgcc, libpthread, libssp, librt, jq\n").encode()
                control = {name: (body, 0o755) for name, body in hooks.items()}
                control["control"] = (metadata, 0o644)
                payload = {"opt/apps/mors/bin/mors": (b"#!/bin/sh\n", 0o755),
                           package.CORE_PATH: (binary.read_bytes(), 0o755)}
                path = root / f"mors_1.3.0~rc2-1_{target}.ipk"

                def verify(changed_control=None, changed_payload=None):
                    path.write_bytes(archive({"debian-binary": (b"2.0\n", 0o644),
                                              "control.tar.gz": (archive(changed_control or control), 0o644),
                                              "data.tar.gz": (archive(changed_payload or payload), 0o644)}))
                    return package.verify(path, spec, binary, {"builder_image": "fixture"})

                with patch.object(package, "ROOT", root), \
                        patch.object(package.core, "inspect_elf", return_value=details):
                    self.assertFalse(verify()["release_admitted"])
                    for before, after in ((target.encode(), b"all"), (b"Package: mors", b"Package: wrong"),
                                          (b"rc2-1", b"rc1-1"), (b"libpthread, ", b"")):
                        with self.assertRaises(ValueError):
                            verify({**control, "control": (metadata.replace(before, after), 0o644)})
                    for key, value in ((package.CORE_PATH, (b"wrong ELF", 0o755)),
                                       ("opt/apps/mors/target/debug/residue", (b"residue", 0o644)),
                                       (package.CORE_PATH, (binary.read_bytes(), 0o644))):
                        with self.assertRaises(ValueError):
                            verify(changed_payload={**payload, key: value})
                    with self.assertRaises(ValueError):
                        verify({**control, "postinst": (b"#!/bin/sh\n/opt/apps/mors/bin/mors-core &\n", 0o755)})
                    with patch.object(package.core, "inspect_elf", return_value=details + "\n(NEEDED) [surprise.so]"):
                        with self.assertRaises(ValueError):
                            verify()


if __name__ == "__main__":
    unittest.main()
