#!/usr/bin/env python3
"""Build the passive runtime from pinned source, SDK and host compiler inputs."""

import argparse
from importlib import import_module
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

inputs = import_module("naiveproxy-inputs")
ROOT = Path(__file__).resolve().parents[2]
TARGETS = {
    "mipsel-3.4": ("ramips-rt305x", "mipsel_24kc-static",
                   'target_cpu="mipsel" mips_arch_variant="r2" mips_float_abi="soft"'),
    "aarch64-3.10": ("sunxi-cortexa53", "aarch64_cortex-a53-static",
                     'target_cpu="arm64" arm_cpu="cortex-a53+nocrypto+nocrc"'),
}


def run(*args, **kwargs):
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def apply_patch(source, patch):
    check = subprocess.run(["git", "-C", str(source), "apply", "--check", str(patch)],
                           capture_output=True)
    if check.returncode == 0:
        run("git", "-C", source, "apply", patch)
    else:
        run("git", "-C", source, "apply", "--reverse", "--check", patch)


def verify_source(source, patches):
    allowed = ["src/net/BUILD.gn", "src/net/tools/naive/naive_connection.cc"]
    changed = subprocess.check_output(["git", "-C", str(source), "diff", "--name-only"], text=True).splitlines()
    unknown = subprocess.check_output(["git", "-C", str(source), "ls-files", "--others", "--exclude-standard"], text=True)
    if sorted(changed) != allowed or unknown.strip():
        raise ValueError("Unexpected source modifications or untracked inputs")
    with tempfile.TemporaryDirectory(prefix="mors-source-check-") as tmp:
        expected = Path(tmp)
        for name in allowed:
            dest = expected / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(subprocess.check_output(["git", "-C", str(source), "show", f"HEAD:{name}"]))
        for patch in patches:
            run("git", "apply", patch, cwd=expected)
        if any((source / name).read_bytes() != (expected / name).read_bytes() for name in allowed):
            raise ValueError("Source differs from the exact approved patches")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("target", choices=TARGETS)
    parser.add_argument("source", type=Path)
    parser.add_argument("cache", type=Path)
    args = parser.parse_args()
    args.cache = args.cache.resolve()
    source = args.source.resolve()
    src = source / "src"
    lock = json.loads(inputs.LOCK.read_text())
    revision = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if revision != lock["upstream_commit"]:
        raise ValueError("Wrong NaiveProxy source revision")
    idle = ROOT / "docs/research/naiveproxy-63/idle-handshake-created-at.patch"
    inputs.checked_file(idle, lock["idle_patch_sha256"])
    patches = (idle, ROOT / "builder/entware/naiveproxy-linkmap.patch")
    for patch in patches:
        apply_patch(source, patch)
    verify_source(source, patches)
    recipe = {name: inputs.sha256((ROOT / name).read_bytes()) for name in inputs.RECIPE_FILES}
    for name, entry in lock["downloads"].items():
        inputs.checked_file(args.cache / name, entry["sha256"])
    compiler = src / "out/toolchain"
    compiler.mkdir(parents=True, exist_ok=True)
    for archive in sorted(args.cache.glob("*.deb")):
        if archive.name not in lock["downloads"]:
            raise ValueError("Unpinned compiler package")
        run("dpkg-deb", "-x", archive, compiler)
    env = dict(os.environ)
    env["LD_LIBRARY_PATH"] = str(compiler / "usr/lib/x86_64-linux-gnu")
    version = subprocess.check_output([str(compiler / "usr/lib/llvm-23/bin/clang"), "--version"], env=env, text=True)
    if f"clang version {lock['compiler']['version']}" not in version:
        raise ValueError("Wrong compiler version")
    platform, arch, target_flags = TARGETS[args.target]
    sdk = f"openwrt-toolchain-24.10.0-{platform}_gcc-13.3.0_musl.Linux-x86_64.tar.zst"
    sysroot = src / "out/sysroot-build/openwrt/24.10.0" / arch
    sysroot_hashes = {}
    with tempfile.TemporaryDirectory(prefix="mors-sdk-") as tmp:
        run("tar", "--zstd", "-xf", args.cache / sdk, "-C", tmp)
        roots = list(Path(tmp).glob("*/toolchain-*_gcc-13.3.0_musl"))
        if len(roots) != 1:
            raise ValueError("Ambiguous SDK root")
        if not sysroot.exists():
            sysroot.mkdir(parents=True)
            for directory in ("include", "lib", "usr"):
                shutil.copytree(roots[0] / directory, sysroot / directory, symlinks=True)
        if not sysroot.resolve().is_relative_to(src) or not (sysroot / "lib/libc.a").is_file():
            raise ValueError("Unsafe or incomplete sysroot")
        # Accept upstream's minimal extraction and the full SDK subset, but never
        # trust a reused header/library merely because its directory exists.
        for path in sorted(sysroot.rglob("*")):
            if not path.resolve().is_relative_to(sysroot):
                raise ValueError("Sysroot symlink escapes its private directory")
            if path.is_file():
                relative = path.relative_to(sysroot)
                original = roots[0] / relative
                value = inputs.sha256(path.read_bytes())
                if not original.is_file() or value != inputs.sha256(original.read_bytes()):
                    raise ValueError(f"Sysroot input differs from pinned SDK: {relative}")
                sysroot_hashes[relative.as_posix()] = value
    gn = src / "gn/out/gn"
    gn_version = subprocess.check_output([str(gn), "--version"], text=True).strip()
    if lock["gn_commit"][:12] not in gn_version:
        raise ValueError("Wrong GN revision")
    epoch = subprocess.check_output(["git", "-C", str(source), "show", "-s", "--format=%ct", "HEAD"], text=True).strip()
    env["SOURCE_DATE_EPOCH"] = epoch
    flags = (ROOT / "builder/entware/naiveproxy-common.gn").read_text()
    flags += f'\ntarget_sysroot="//out/sysroot-build/openwrt/24.10.0/{arch}"\n{target_flags}\n'
    build = src / "out" / f"mors-{args.target}"
    run(gn, "gen", build, f"--args={flags}", cwd=src, env=env)
    run("bash", ROOT / "scripts/qa/naiveproxy-ninja.sh", "-C", build, "naive", cwd=src, env=env)
    verify_source(source, patches)
    if recipe != {name: inputs.sha256((ROOT / name).read_bytes()) for name in inputs.RECIPE_FILES}:
        raise ValueError("Build recipe changed during compilation")
    receipt = {"source_commit": revision, "source_date_epoch": int(epoch), "target": args.target,
               "compiler": version.strip(), "gn": gn_version,
               "gn_sha256": inputs.sha256(gn.read_bytes()), "recipe_sha256": recipe,
               "sysroot_sha256": sysroot_hashes,
               "input_lock_sha256": inputs.sha256(inputs.LOCK.read_bytes()),
               "source_diff_sha256": inputs.sha256(subprocess.check_output(["git", "-C", str(source), "diff"])),
               "args_sha256": inputs.sha256((build / "args.gn").read_bytes()),
               "elf_sha256": inputs.sha256((build / "naive").read_bytes()),
               "linkmap_sha256": inputs.sha256((build / "naive.linkmap").read_bytes()),
               "base_image": os.environ.get("MORS_NAIVE_BASE_IMAGE")}
    (build / "build.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"Runtime build completed: {args.target}")


if __name__ == "__main__":
    main()
