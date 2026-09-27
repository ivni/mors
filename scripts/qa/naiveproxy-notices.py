#!/usr/bin/env python3
"""Create runtime notices from actual target compilation and link inputs."""

import argparse
from functools import cache
import hashlib
from importlib import import_module
import json
from pathlib import Path
import re
import subprocess

inputs_module = import_module("naiveproxy-inputs")
NOTICE_LOCK = inputs_module.ROOT / "builder/entware/naiveproxy-notices.json"
CHROMIUM_GLUE = {
    "third_party/blink/public/common/common_export.h",
    "third_party/blink/public/common/user_agent/user_agent_metadata.h",
    "third_party/blink/public/common/user_agent/user_agent_brand_version_type.h",
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(build, *args):
    return subprocess.check_output(["ninja", "-C", str(build), "-t", *args], text=True)


def runtime_sources(source, build, require_link=True):
    @cache
    def resolve(name):
        return (build / name).resolve()

    inputs = {str(resolve(item)) for item in command(build, "inputs", "naive").splitlines()}
    compilations = json.loads(command(build, "compdb"))
    objects = set()
    files = set()
    for entry in compilations:
        output = (Path(entry["directory"]) / entry["output"]).resolve()
        relative = output.relative_to(build).as_posix()
        if str(output) not in inputs or relative.startswith("clang_x64/") or output.suffix != ".o":
            continue
        objects.add(str(output))
        files.add((Path(entry["directory"]) / entry["file"]).resolve())
    current = None
    dependency_records = set()
    for line in command(build, "deps").splitlines():
        match = re.match(r"^(.*): #deps [0-9]+,", line)
        if match:
            current = str(resolve(match[1]))
            dependency_records.add(current)
        elif current in objects and line.startswith("    "):
            files.add(resolve(line.strip()))
    if not objects or not files:
        raise ValueError("No real target compilation evidence")
    if require_link:
        if not (build / "naive.linkmap").is_file() or not (build / "naive").is_file():
            raise ValueError("Final ELF/link map missing")
        if not objects <= dependency_records or any(not Path(path).is_file() for path in objects):
            raise ValueError("Incomplete target object/dependency evidence")
    outside = [path for path in files if not path.is_relative_to(source)]
    if outside:
        raise ValueError(f"Unclassified compiler input outside pinned source: {outside[0]}")
    return files, len(objects)


def metadata(path):
    result = {}
    for line in path.read_text().splitlines():
        match = re.match(r"^([A-Za-z][A-Za-z /-]*):\s*(.*)$", line)
        if match and match[1] not in result:
            result[match[1]] = match[2]
    return result


def component_for(path, source, overrides=None):
    relative = path.relative_to(source).as_posix()
    for library in ("libc++", "libc++abi", "libunwind"):
        if relative.startswith(f"buildtools/third_party/{library}/"):
            return source / "third_party" / library
    for parent in path.parents:
        if parent == source:
            return source
        if not parent.is_relative_to(source):
            break
        if overrides and parent.relative_to(source).as_posix() in overrides:
            return parent
        if (parent / "README.chromium").is_file():
            return parent
    raise ValueError(f"Cannot classify source file: {path}")


def collect(source, build, ca, output, notice_cache=None):
    source, build = source.resolve(), build.resolve()
    notice_cache = notice_cache or ca.parent / "notice-inputs"
    notice_lock = json.loads(NOTICE_LOCK.read_text())
    build_receipt = json.loads((build / "build.json").read_text())
    finalization = json.loads((build / "finalization.json").read_text())
    if finalization["linked_elf_sha256"] != build_receipt["elf_sha256"] or not finalization["allocated_sections_unchanged"]:
        raise ValueError("Unverified runtime finalization")
    actual_commit = subprocess.check_output(["git", "-C", str(source.parent), "rev-parse", "HEAD"], text=True).strip()
    if notice_lock["upstream_commit"] != build_receipt["source_commit"] or actual_commit != build_receipt["source_commit"]:
        raise ValueError("Notice metadata belongs to another source revision")
    source_diff = subprocess.check_output(["git", "-C", str(source.parent), "diff"])
    if hashlib.sha256(source_diff).hexdigest() != build_receipt["source_diff_sha256"]:
        raise ValueError("Source changed since compilation")
    if output.exists() or output.is_symlink():
        raise ValueError("Notices output must be new")
    files, object_count = runtime_sources(source, build)
    groups = {}
    generated = []
    compiler_headers = []
    sysroot_inputs = []
    unclassified = []
    for path in sorted(files):
        relative = path.relative_to(source).as_posix()
        if path.is_relative_to(build):
            generated.append(relative)
            continue
        if relative.startswith("out/sysroot-build/"):
            sysroot_inputs.append(relative)
            continue
        if relative.startswith(("third_party/llvm-build/", "out/toolchain/")):
            compiler_headers.append(relative)
            continue
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"Missing or unsafe runtime source: {relative}")
        owner = component_for(path, source, notice_lock["components"])
        if owner == source and "third_party" in path.relative_to(source).parts and relative not in CHROMIUM_GLUE:
            unclassified.append(relative)
            continue
        groups.setdefault(owner, []).append(relative)
    if unclassified:
        raise ValueError("Third-party inputs have no component metadata: " + ", ".join(unclassified))
    if not sysroot_inputs:
        raise ValueError("No sysroot compilation evidence")
    components = []
    materials = {}
    for owner, owned_files in sorted(groups.items()):
        relative = owner.relative_to(source).as_posix()
        info = notice_lock["components"].get(relative)
        if info is None:
            info = metadata(owner / "README.chromium") if owner != source else {
            "Name": "Chromium/NaiveProxy", "License": "BSD-3-Clause", "License File": "LICENSE",
            "Version": (source.parent / "CHROMIUM_VERSION").read_text().strip()}
        if "Name" not in info or "License" not in info:
            raise ValueError(f"Missing component identity/license: {relative}")
        notice_paths = []
        if "Notice Header" in info:
            location = (owner / info["Notice Header"]).resolve()
            if not location.is_relative_to(owner):
                raise ValueError("Unsafe copyright header")
            content = location.read_bytes()
            if info["Header Style"] == "c-comment" and content.startswith(b"/* Copyright"):
                content = content.split(b"*/", 1)[0] + b"*/\n"
            elif info["Header Style"] == "line-comments" and content.startswith(b"// Copyright"):
                content = content.split(b"\n#ifndef ", 1)[0] + b"\n"
            else:
                raise ValueError("Unrecognized copyright header format")
            if not all(token in content for token in (b"Copyright", b"Redistribution and use", b"THIS SOFTWARE")):
                raise ValueError("Incomplete embedded license")
            notice = location.relative_to(source).as_posix() + ".NOTICE.txt"
            materials[notice] = content
            notice_paths.append(notice)
            license_names = []
        else:
            license_names = info.get("License File", "LICENSE").split(",")
        for name in license_names:
            name = name.strip()
            if name.startswith("@download/"):
                leaf = name.split("/", 1)[1]
                if Path(leaf).name != leaf:
                    raise ValueError("Unsafe downloaded notice name")
                content = inputs_module.checked_file(notice_cache / leaf, notice_lock["downloads"][leaf]["sha256"])
                notice = "external/" + leaf
                materials[notice] = content
                notice_paths.append(notice)
                continue
            location = (source / name[2:] if name.startswith("//") else owner / name).resolve()
            if not location.is_relative_to(source) or not location.is_file():
                raise ValueError(f"Missing component notice: {relative}/{name}")
            notice = location.relative_to(source).as_posix()
            materials[notice] = location.read_bytes()
            notice_paths.append(notice)
        components.append({"name": info["Name"], "path": relative,
                           "version": info.get("Version"), "revision": info.get("Revision"),
                           "url": info.get("URL"),
                           "license": info["License"], "notices": notice_paths,
                           "sources": owned_files,
                           "source_sha256": {name: digest(source / name) for name in owned_files}})
    for name in ("certifi-NOTICE.txt", "MPL-2.0.txt", "GPL-3.0.txt", "GCC-exception-3.1.txt", "musl-COPYRIGHT.txt"):
        materials[f"external/{name}"] = (ca / name).read_bytes()
    materials["external/LLVM-LICENSE.txt"] = (source / "third_party/libc++/src/LICENSE.TXT").read_bytes()
    materials["external/compiler-COPYRIGHT.txt"] = (source / "out/toolchain/usr/share/doc/libclang-common-23-dev/copyright").read_bytes()
    linkmap = (build / "naive.linkmap").read_text()
    if "libc.a(" not in linkmap:
        raise ValueError("No static musl link evidence")
    gcc_linked = any(marker in linkmap for marker in ("libgcc.a(", "libgcc_eh.a(", "libatomic.a(", "crtbegin", "crtend"))
    components.append({"name": "musl", "version": "1.2.5", "license": "MIT and notices in COPYRIGHT",
                       "path": "external/musl", "notices": ["external/musl-COPYRIGHT.txt"], "sources": sysroot_inputs})
    if gcc_linked:
        components.append({"name": "GCC runtime", "version": "13.3.0", "license": "GPL-3.0-only WITH GCC-exception-3.1",
                           "path": "external/gcc-runtime", "notices": ["external/GPL-3.0.txt", "external/GCC-exception-3.1.txt"], "sources": []})
    if compiler_headers:
        components.append({"name": "LLVM compiler headers", "version": "23.1.2",
                           "license": "Apache-2.0 WITH LLVM-exception", "path": "external/clang-headers",
                           "notices": ["external/LLVM-LICENSE.txt", "external/compiler-COPYRIGHT.txt"], "sources": compiler_headers})
    ca_manifest = json.loads((ca / "ca-manifest.json").read_text())
    components.append({"name": "certifi Mozilla CA bundle", "version": ca_manifest["ca_version"],
                       "license": "MPL-2.0", "path": "external/ca", "sources": [],
                       "notices": ["external/certifi-NOTICE.txt", "external/MPL-2.0.txt"]})
    output.mkdir(parents=True)
    for name, content in materials.items():
        dest = output / "notices" / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(content)
    evidence = {"schema": "mors-runtime-components-v1", "elf_sha256": digest(build / "naive.runtime"),
                "linked_elf_sha256": digest(build / "naive"),
                "notice_lock_sha256": digest(NOTICE_LOCK),
                "linkmap_sha256": digest(build / "naive.linkmap"), "target_objects": object_count,
                "components": components, "generated_inputs": generated,
                "notices_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in materials.items()}}
    (output / "components.json").write_text(json.dumps(evidence, indent=2) + "\n")
    sbom = {"bomFormat": "CycloneDX", "specVersion": "1.6", "version": 1,
            "metadata": {"component": {"type": "application", "name": "NaiveProxy",
                         "version": (source.parent / "CHROMIUM_VERSION").read_text().strip(),
                         "hashes": [{"alg": "SHA-256", "content": evidence["elf_sha256"]}]}},
            "components": [{"type": "library" if item["path"] != "external/ca" else "data",
                            "bom-ref": item["path"], "name": item["name"],
                            "version": item["version"] if item.get("version") not in (None, "N/A") else item.get("revision") or "source-snapshot",
                            "licenses": [{"license": {"name": item["license"]}}],
                            "properties": [{"name": "mors:source-component", "value": item["path"]}]}
                           for item in components]}
    source_url = "https://github.com/klzgrad/naiveproxy/tree/" + build_receipt["source_commit"]
    sbom["metadata"]["component"]["externalReferences"] = [{"type": "vcs", "url": source_url}]
    sbom["metadata"]["properties"] = [
        {"name": "mors:evidence", "value": "target compilation dependencies and final link map"},
        {"name": "mors:source-diff-sha256", "value": build_receipt["source_diff_sha256"]},
        {"name": "mors:input-lock-sha256", "value": build_receipt["input_lock_sha256"]},
    ]
    for item, component in zip(components, sbom["components"]):
        if not item["path"].startswith("external/"):
            component["externalReferences"] = [{"type": "vcs", "url": source_url + "/src/" + item["path"]}]
            tree = json.dumps(item["source_sha256"], sort_keys=True, separators=(",", ":")).encode()
            component["properties"].append({"name": "mors:source-tree-sha256", "value": hashlib.sha256(tree).hexdigest()})
        if item.get("url"):
            component.setdefault("externalReferences", []).append({"type": "website", "url": item["url"]})
        if item.get("revision"):
            component["properties"].append({"name": "mors:upstream-revision", "value": item["revision"]})
    (output / "sbom.cdx.json").write_text(json.dumps(sbom, indent=2) + "\n")
    print(f"Recorded {len(components)} runtime components and {len(materials)} notice files")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "build", "ca", "output"):
        parser.add_argument(name, type=Path)
    parser.add_argument("--notice-cache", type=Path)
    args = parser.parse_args()
    collect(args.source, args.build, args.ca, args.output, args.notice_cache)


if __name__ == "__main__":
    main()
