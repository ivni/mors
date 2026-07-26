#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
entware_dir="${ENTWARE_DIR:-/opt/entware}"
package_version="$(sed -n 's/^PKG_VERSION:=//p; /^PKG_VERSION:=/q' "${repo_root}/Makefile")"
package_release="$(sed -n 's/^PKG_RELEASE:=//p; /^PKG_RELEASE:=/q' "${repo_root}/Makefile")"
expected_package="mors_${package_version}-${package_release}_all.ipk"
jobs="${JOBS:-$(nproc)}"

if [ -z "${package_version}" ] || [[ ! "${package_release}" =~ ^[1-9][0-9]*$ ]]; then
	echo 'Makefile has no valid PKG_VERSION/PKG_RELEASE pair.' >&2
	exit 1
fi
if [[ ! "${jobs}" =~ ^[1-9][0-9]*$ ]]; then
	echo "Invalid package build parallelism: ${jobs}" >&2
	exit 1
fi

# The direct package submake is safe only after the immutable image has proved
# that the exact locked Entware tree, toolchain and runtime dependencies exist.
bash "${repo_root}/scripts/qa/verify-entware-builder.sh"

cd "${entware_dir}"
if [ ! -d package ] || [ -L package ]; then
	echo 'Entware builder package directory is not a real directory.' >&2
	exit 1
fi
if [ -e package/mors ] || [ -L package/mors ]; then
	echo 'Entware builder package source is not clean before packaging.' >&2
	exit 1
fi
if [ ! -f "${repo_root}/Makefile" ] ||
	[ ! -d "${repo_root}/opt" ] ||
	[ -L "${repo_root}/opt" ] ||
	[ ! -f "${repo_root}/builder/entware/runtime-dependencies.mk" ]; then
	echo 'Mors package inputs are missing or have an unsafe type.' >&2
	exit 1
fi

source_parent="$(mktemp -d "${entware_dir}/.mors-package-source.XXXXXX")"
case "${source_parent}" in
	"${entware_dir}"/.mors-package-source.*) ;;
	*)
		echo "Unexpected temporary package source path: ${source_parent}" >&2
		exit 1
		;;
esac
source_dir="${source_parent}/mors"
package_link="${entware_dir}/package/mors"
cleanup() {
	if [ -L "${package_link}" ] &&
		[ "$(readlink "${package_link}")" = "${source_dir}" ]; then
		rm -f "${package_link}"
	fi
	if [ -d "${source_parent}" ] && [ ! -L "${source_parent}" ]; then
		rm -rf -- "${source_parent}"
	fi
}
trap cleanup EXIT

# Copy only package inputs. Keeping logs, .git and previous artifacts outside
# this tree makes OpenWrt's source hash stable for the whole submake.
mkdir -p "${source_dir}/builder/entware"
cp -p "${repo_root}/Makefile" "${source_dir}/Makefile"
cp -a "${repo_root}/opt" "${source_dir}/opt"
cp -p "${repo_root}/builder/entware/runtime-dependencies.mk" \
	"${source_dir}/builder/entware/runtime-dependencies.mk"
ln -s "${source_dir}" "${package_link}"

packages_dir="${repo_root}/packages"
if [ -L "${packages_dir}" ] ||
	{ [ -e "${packages_dir}" ] && [ ! -d "${packages_dir}" ]; }; then
	echo "Unsafe package output directory: ${packages_dir}" >&2
	exit 1
fi
mkdir -p "${packages_dir}"
find "${packages_dir}" -maxdepth 1 -type f \
	-name 'mors_*_all.ipk' -exec rm -f {} +
find bin/targets -type f -name 'mors_*_all.ipk' -exec rm -f {} +

package_make=(
	make -w -r -C package/mors
	"TOPDIR=${entware_dir}"
	BUILD_SUBDIR=package/mors
	BUILD_VARIANT=
	ALL_VARIANTS=
)

"${package_make[@]}" clean V=sc
build_started_at="$(date +%s)"
"${package_make[@]}" -j"${jobs}" compile V=sc
build_elapsed_seconds="$(($(date +%s) - build_started_at))"

mapfile -t built_packages < <(
	find bin/targets -type f -name 'mors_*_all.ipk' -print
)
if [ "${#built_packages[@]}" -ne 1 ]; then
	echo "Expected exactly one Mors IPK, found ${#built_packages[@]}." >&2
	exit 1
fi
if [ "$(basename "${built_packages[0]}")" != "${expected_package}" ]; then
	echo "Unexpected Mors IPK: ${built_packages[0]}" >&2
	exit 1
fi

cp -p "${built_packages[0]}" "${packages_dir}/${expected_package}"
"${package_make[@]}" clean V=sc
rm -f "${built_packages[0]}"

printf 'Builder package compile: %s seconds\n' "${build_elapsed_seconds}"
printf 'Built package: %s\n' "${packages_dir}/${expected_package}"
sha256sum "${packages_dir}/${expected_package}"
