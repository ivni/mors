#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
entware_dir="${ENTWARE_DIR:-${repo_root}/.qa/entware}"
entware_repo="${ENTWARE_REPO_URL:-https://github.com/Entware/Entware.git}"
entware_config="${ENTWARE_CONFIG:-configs/aarch64-3.10.config}"
jobs="${JOBS:-$(nproc)}"

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

# Current Entware still declares Python 2.7 for the unrelated node_legacy
# package. Ubuntu 24.04 no longer ships it; Mors does not build node_legacy.
# FORCE=1 bypasses that global host-prerequisite gate without selecting or
# compiling any additional package.
make FORCE=1 defconfig
make FORCE=1 -j"${jobs}" package/mors/compile || make FORCE=1 package/mors/compile V=sc

mkdir -p "${repo_root}/packages"
find bin/targets -type f -name 'mors_*_all.ipk' -exec cp -f {} "${repo_root}/packages/" \;

echo "Built packages:"
find "${repo_root}/packages" -maxdepth 1 -type f -name 'mors_*_all.ipk' -print
