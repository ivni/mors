#!/usr/bin/env python3
"""Strip non-runtime sections while proving runtime headers/sections unchanged."""

import argparse
from importlib import import_module
import json
import os
from pathlib import Path
import subprocess
import tempfile

inputs = import_module("naiveproxy-inputs")
MIPS_SOFT_ATTRIBUTES = bytes.fromhex("410f000000676e750001070000000403")


def sections(binary, readobj, env):
    data = json.loads(subprocess.check_output([str(readobj), "--elf-output-style=JSON", "--file-headers",
                                              "--program-headers", "--sections", str(binary)], env=env, text=True))[0]
    return data, {item["Section"]["Name"]["Name"]: item["Section"] for item in data["Sections"]}


def allocated(data, descriptors):
    result = {}
    for name, section in descriptors.items():
        if section["Flags"]["Value"] & 2:
            content = b"" if section["Type"]["Value"] == 8 else data[section["Offset"]:section["Offset"] + section["Size"]]
            result[name] = {"address": section["Address"], "size": section["Size"],
                            "type": section["Type"]["Value"], "flags": section["Flags"]["Value"],
                            "alignment": section["AddressAlignment"], "sha256": inputs.sha256(content)}
    return result


def canonical_attributes(data, section):
    if section["Flags"]["Value"] & 2:
        raise ValueError("GNU attributes unexpectedly affect runtime memory")
    content = data[section["Offset"]:section["Offset"] + section["Size"]]
    count, remainder = divmod(len(content), len(MIPS_SOFT_ATTRIBUTES))
    if count < 1 or remainder or content != MIPS_SOFT_ATTRIBUTES * count:
        raise ValueError("Unrecognized GNU attributes; refuse to normalize")
    return MIPS_SOFT_ATTRIBUTES, count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", type=Path)
    args = parser.parse_args()
    build = args.build.resolve()
    receipt = json.loads((build / "build.json").read_text())
    original = inputs.checked_file(build / "naive", receipt["elf_sha256"])
    compiler = build.parent / "toolchain"
    tools = compiler / "usr/lib/llvm-23/bin"
    env = {**os.environ, "LD_LIBRARY_PATH": str(compiler / "usr/lib/x86_64-linux-gnu")}
    before, before_sections = sections(build / "naive", tools / "llvm-readobj", env)
    destination = build / "naive.runtime"
    evidence_path = build / "finalization.json"
    if destination.exists() or destination.is_symlink() or evidence_path.exists() or evidence_path.is_symlink():
        raise ValueError("Finalized runtime already exists")
    copies = 0
    with tempfile.TemporaryDirectory(prefix="mors-elf-finalize-") as tmp:
        command = [str(tools / "llvm-objcopy"), "--strip-all"]
        if ".gnu.attributes" in before_sections:
            if before["ElfHeader"]["Machine"]["Value"] != 8:
                raise ValueError("Unreviewed GNU attributes on non-MIPS runtime")
            canonical, copies = canonical_attributes(original, before_sections[".gnu.attributes"])
            attribute_file = Path(tmp) / "attributes"
            attribute_file.write_bytes(canonical)
            command.extend(["--keep-section=.gnu.attributes", f"--update-section=.gnu.attributes={attribute_file}"])
        candidate = Path(tmp) / "naive.runtime"
        subprocess.run(command + [str(build / "naive"), str(candidate)], check=True, env=env)
        after, after_sections = sections(candidate, tools / "llvm-readobj", env)
        expected_header = dict(before["ElfHeader"])
        actual_header = dict(after["ElfHeader"])
        for name in ("SectionHeaderOffset", "SectionHeaderCount", "StringTableSectionIndex"):
            expected_header.pop(name)
            actual_header.pop(name)
        if expected_header != actual_header or before["ProgramHeaders"] != after["ProgramHeaders"]:
            raise ValueError("Finalization changed runtime ELF headers")
        finalized = candidate.read_bytes()
        runtime_sections = allocated(original, before_sections)
        if runtime_sections != allocated(finalized, after_sections):
            raise ValueError("Finalization changed an allocated section")
        if any(name.startswith(".debug") or name == ".symtab" for name in after_sections):
            raise ValueError("Unstripped build residue remains")
        # GNU readelf must now accept the complete ABI view, including attributes.
        subprocess.run(["readelf", "-h", "-l", "-d", "-A", str(candidate)], check=True, stdout=subprocess.DEVNULL)
        destination.write_bytes(finalized)
        destination.chmod(0o755)
    evidence = {"schema": "mors-runtime-finalization-v1", "linked_elf_sha256": receipt["elf_sha256"],
                "elf_sha256": inputs.sha256(finalized), "allocated_sections": runtime_sections,
                "allocated_sections_unchanged": True, "program_headers_unchanged": True,
                "gnu_attribute_records_before": copies, "gnu_attribute_records_after": min(copies, 1),
                "objcopy_sha256": inputs.sha256((tools / "llvm-objcopy").read_bytes()),
                "recipe_sha256": inputs.sha256(Path(__file__).read_bytes())}
    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n")
    print(f"Runtime finalized without changing allocated sections: {destination}")


if __name__ == "__main__":
    main()
