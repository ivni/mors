#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Keep the buildroot outside the package source. package/mors is a symlink to
# repo_root, so nesting Entware below it creates a recursive filesystem loop.
entware_dir="${ENTWARE_DIR:-${repo_root}.entware-build}"
entware_repo="${ENTWARE_REPO_URL:-https://github.com/Entware/Entware.git}"
entware_config="${ENTWARE_CONFIG:-configs/aarch64-3.10.config}"
jobs="${JOBS:-$(nproc)}"
python2_compat_dir=''

cleanup() {
	[ -n "${python2_compat_dir}" ] && rm -rf "${python2_compat_dir}"
}
trap cleanup EXIT

# Entware globally probes Python 2.7 although only node_legacy needs it.
# Ubuntu 24.04 no longer ships Python 2. The narrow shim satisfies `-V`, but
# fails loudly if an unexpectedly selected package tries to execute Python 2.
if ! command -v python2.7 >/dev/null 2>&1; then
	python2_compat_dir=$(mktemp -d)
	cat >"${python2_compat_dir}/python2.7" <<'EOF'
#!/bin/sh
if [ "${1:-}" = '-V' ] || [ "${1:-}" = '--version' ]; then
	printf '%s\n' 'Python 2.7.18'
	exit 0
fi
printf '%s\n' 'Python 2 compatibility shim cannot execute build scripts.' >&2
exit 127
EOF
	chmod +x "${python2_compat_dir}/python2.7"
	export PATH="${python2_compat_dir}:${PATH}"
fi

mkdir -p "$(dirname "${entware_dir}")"

if [ ! -d "${entware_dir}/.git" ]; then
	git clone --depth=1 "${entware_repo}" "${entware_dir}"
fi

cd "${entware_dir}"
git fetch --depth=1 origin

scripts/feeds update -a
scripts/feeds install -a

if [ ! -f .config ]; then
	if [ ! -f "${entware_config}" ]; then
		entware_config="$(find configs -maxdepth 1 -type f -name 'aarch64-*.config' | sort | head -n 1)"
	fi
	test -n "${entware_config}"
	cp "${entware_config}" .config
fi

mkdir -p package
ln -sfn "${repo_root}" package/mors

if grep -q '^CONFIG_PACKAGE_mors=' .config; then
	sed -i 's/^CONFIG_PACKAGE_mors=.*/CONFIG_PACKAGE_mors=m/' .config
else
	printf '\nCONFIG_PACKAGE_mors=m\n' >> .config
fi

make defconfig
make -j"${jobs}" tools/install || make tools/install V=sc
make -j"${jobs}" package/opkg/host/compile || make package/opkg/host/compile V=sc

host_opkg=$(find -L staging_dir/host/bin -maxdepth 1 -type f -name opkg -print -quit)
if [ -z "${host_opkg}" ] || [ ! -x "${host_opkg}" ]; then
	echo 'Entware host opkg was not built.' >&2
	exit 1
fi
bash "${repo_root}/scripts/qa/opkg-version-order.sh" "${host_opkg}"

make -j"${jobs}" toolchain/install || make toolchain/install V=sc
make -j"${jobs}" tools/go-src/compile || make tools/go-src/compile V=sc
make -j"${jobs}" package/mors/compile || make package/mors/compile V=sc

find bin/targets -type f -name 'mors_1.3.0~beta3-1_all.ipk' -print -quit | grep -q .
mkdir -p "${repo_root}/packages"
find bin/targets -type f -name 'mors_*_all.ipk' -exec cp -f {} "${repo_root}/packages/" \;

echo "Built packages:"
find "${repo_root}/packages" -maxdepth 1 -type f -name 'mors_*_all.ipk' -print
