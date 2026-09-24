#!/bin/bash
# Research-only build. No release, install, router access or repository secrets.
set -euo pipefail
: "${RUNNER_TEMP:?Run only in a disposable CI runner}"
: "${GITHUB_WORKSPACE:?Missing checkout}"
source_sha=3ba967e2d36cc133a896e81a36257ad4c6ea20f4
work="$RUNNER_TEMP/naive63-source"
artifact="$RUNNER_TEMP/naive63-artifact"
patch="$GITHUB_WORKSPACE/docs/research/naiveproxy-63/idle-handshake-created-at.patch"
test ! -e "$work"
mkdir -p "$work" "$artifact" "$RUNNER_TEMP/naive63-tools"
git -C "$work" init
git -C "$work" remote add origin https://github.com/klzgrad/naiveproxy.git
git -C "$work" fetch --depth=1 origin "$source_sha"
git -C "$work" checkout --detach FETCH_HEAD
test "$(git -C "$work" rev-parse HEAD)" = "$source_sha"
git -C "$work" apply --check "$patch"
git -C "$work" apply "$patch"
git -C "$work" diff --check
test "$(git -C "$work" diff --name-only)" = src/net/tools/naive/naive_connection.cc
# Bound parallel compilation without changing upstream build flags.
printf '#!/bin/sh\nexec /usr/bin/ninja -j2 "$@"\n' > "$RUNNER_TEMP/naive63-tools/ninja"
chmod +x "$RUNNER_TEMP/naive63-tools/ninja"
export PATH="$RUNNER_TEMP/naive63-tools:$PATH"
export EXTRA_FLAGS='target_cpu="mipsel" target_os="openwrt" mips_arch_variant="r2" mips_float_abi="soft" build_static=true use_allocator_shim=false use_partition_alloc=false'
export OPENWRT_FLAGS='arch=mipsel_24kc-static release=24.10.0 gcc_ver=13.3.0 target=ramips subtarget=rt305x'
export CCACHE_MAXSIZE=200M
cd "$work/src"
./get-clang.sh
./build.sh
cp out/Release/naive "$artifact/naive"
cp "$work/LICENSE" "$artifact/LICENSE"
cp out/Release/args.gn "$artifact/args.gn"
cp third_party/llvm-build/Release+Asserts/cr_build_revision "$artifact/clang-revision.txt"
cp "$patch" "$artifact/idle-handshake-created-at.patch"
readelf -h -l -d "$artifact/naive" > "$artifact/elf.txt"
python3 - "$artifact" "$source_sha" <<'PY'
import hashlib,json,pathlib,sys,os
p=pathlib.Path(sys.argv[1])
data={'upstream_commit':sys.argv[2],'mors_commit':os.environ['GITHUB_SHA'],
      'run_id':os.environ['GITHUB_RUN_ID'],'target':'openwrt-mipsel_24kc-static',
      'openwrt':'24.10.0','gcc':'13.3.0','parallel_jobs':2,
      'sha256':{f.name:hashlib.sha256(f.read_bytes()).hexdigest()
                for f in p.iterdir() if f.is_file()}}
(p/'manifest.json').write_text(json.dumps(data,indent=2)+'\n')
PY
sha256sum "$artifact/naive"
