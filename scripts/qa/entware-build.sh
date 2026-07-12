#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
package_version="$(sed -n 's/^PKG_VERSION:=//p; /^PKG_VERSION:=/q' "${repo_root}/Makefile")"
package_release="$(sed -n 's/^PKG_RELEASE:=//p; /^PKG_RELEASE:=/q' "${repo_root}/Makefile")"
expected_package="mors_${package_version}-${package_release}_all.ipk"
if [ -z "${package_version}" ] || [[ ! "${package_release}" =~ ^[1-9][0-9]*$ ]]; then
	echo 'Makefile has no valid PKG_VERSION/PKG_RELEASE pair.' >&2
	exit 1
fi

entware_lock="${ENTWARE_LOCK_FILE:-${repo_root}/scripts/qa/entware.lock}"
if [ ! -r "${entware_lock}" ]; then
	echo "Entware revision lock is not readable: ${entware_lock}" >&2
	exit 1
fi

locked_feeds_file=''
python2_compat_dir=''
cleanup() {
	[ -n "${python2_compat_dir}" ] && rm -rf "${python2_compat_dir}"
	[ -z "${locked_feeds_file}" ] || rm -f "${locked_feeds_file}"
}
trap cleanup EXIT

locked_feeds_file="$(mktemp)"
locked_names=''
locked_feed_count=0
locked_entware_repo=''
locked_entware_revision=''
while read -r lock_name lock_repo lock_revision lock_extra; do
	case "${lock_name}" in
		''|'#'*) continue ;;
	esac
	case "${lock_repo}" in
		https://github.com/Entware/*.git) ;;
		*) lock_repo_invalid=true ;;
	esac
	if [ -n "${lock_extra}" ] ||
		[ "${lock_repo_invalid:-false}" = true ] ||
		[[ ! "${lock_name}" =~ ^[a-z][a-z0-9_-]*$ ]] ||
		[[ ! "${lock_revision}" =~ ^[0-9a-f]{40}$ ]]; then
		echo "Invalid Entware lock entry: ${lock_name} ${lock_repo} ${lock_revision} ${lock_extra}" >&2
		exit 1
	fi
	lock_repo_invalid=false
	case " ${locked_names} " in
		*" ${lock_name} "*)
			echo "Duplicate Entware lock entry: ${lock_name}" >&2
			exit 1
			;;
	esac
	locked_names="${locked_names} ${lock_name}"
	if [ "${lock_name}" = entware ]; then
		locked_entware_repo="${lock_repo}"
		locked_entware_revision="${lock_revision}"
	else
		printf 'src-git %s %s^%s\n' \
			"${lock_name}" "${lock_repo}" "${lock_revision}" >>"${locked_feeds_file}"
		locked_feed_count=$((locked_feed_count + 1))
	fi
done <"${entware_lock}"

if [ -z "${locked_entware_repo}" ] || [ -z "${locked_entware_revision}" ] ||
	[ "${locked_feed_count}" -eq 0 ]; then
	echo 'Entware lock must contain the buildroot and at least one feed.' >&2
	exit 1
fi

# Keep the buildroot outside the package source. package/mors is a symlink to
# repo_root, so nesting Entware below it creates a recursive filesystem loop.
entware_dir="${ENTWARE_DIR:-${repo_root}.entware-build}"
entware_repo="${ENTWARE_REPO_URL:-${locked_entware_repo}}"
entware_revision="${ENTWARE_REVISION:-${locked_entware_revision}}"
entware_config="${ENTWARE_CONFIG:-configs/aarch64-3.10.config}"
jobs="${JOBS:-$(nproc)}"

if [[ ! "${entware_revision}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "Invalid Entware revision: ${entware_revision}" >&2
	exit 1
fi

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
	mkdir -p "${entware_dir}"
	git -C "${entware_dir}" init
	git -C "${entware_dir}" remote add origin "${entware_repo}"
else
	git -C "${entware_dir}" remote set-url origin "${entware_repo}"
fi

git -C "${entware_dir}" fetch --depth=1 origin "${entware_revision}"
if git -C "${entware_dir}" ls-files --error-unmatch feeds.conf >/dev/null 2>&1; then
	git -C "${entware_dir}" restore --source=HEAD --worktree -- feeds.conf
fi
git -C "${entware_dir}" -c advice.detachedHead=false checkout --detach "${entware_revision}"

cd "${entware_dir}"
cp "${locked_feeds_file}" feeds.conf

printf 'Entware revision: %s\n' "${entware_revision}"
printf 'Entware cache hit: %s\n' "${ENTWARE_CACHE_HIT:-false}"

bash "${repo_root}/scripts/qa/entware-feed-lock.sh" \
	sync-existing "${entware_lock}" "${entware_dir}"
scripts/feeds update -a
bash "${repo_root}/scripts/qa/entware-feed-lock.sh" \
	verify "${entware_lock}" "${entware_dir}"
scripts/feeds install -a

if [ ! -f "${entware_config}" ]; then
	entware_config="$(find configs -maxdepth 1 -type f -name 'aarch64-*.config' | sort | head -n 1)"
fi
test -n "${entware_config}"
cp "${entware_config}" .config

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
bash "${repo_root}/scripts/qa/opkg-version-order.sh" "${host_opkg}" "${package_version}"

make -j"${jobs}" toolchain/install || make toolchain/install V=sc
make -j"${jobs}" tools/go-src/compile || make tools/go-src/compile V=sc

mkdir -p "${repo_root}/packages"
find "${repo_root}/packages" -maxdepth 1 -type f -name 'mors_*_all.ipk' -exec rm -f {} +
make package/mors/clean
find bin/targets -type f -name 'mors_*_all.ipk' -exec rm -f {} +
make -j"${jobs}" package/mors/compile || make package/mors/compile V=sc

find bin/targets -type f -name "${expected_package}" -print -quit | grep -q .
find bin/targets -type f -name 'mors_*_all.ipk' -exec cp -f {} "${repo_root}/packages/" \;

echo "Built packages:"
find "${repo_root}/packages" -maxdepth 1 -type f -name 'mors_*_all.ipk' -print

# Keep only reusable Entware state in the cache. The Mors package itself must
# always be rebuilt from the checked-out repository SHA.
make package/mors/clean
find bin/targets -type f -name 'mors_*_all.ipk' -exec rm -f {} +
rm -f package/mors
du -sh "${entware_dir}" | awk '{ print "Entware cache size: " $1 }'
