#!/usr/bin/env bash
set -euo pipefail

tag="${1:?Usage: release-metadata.sh vX.Y.Z[-prerelease]}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [[ ! "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
	echo "Invalid release tag: ${tag}" >&2
	exit 1
fi

package_version="$(sed -n 's/^PKG_VERSION:=//p; /^PKG_VERSION:=/q' "${repo_root}/Makefile")"
package_release="$(sed -n 's/^PKG_RELEASE:=//p; /^PKG_RELEASE:=/q' "${repo_root}/Makefile")"

if [ -z "${package_version}" ] || [[ ! "${package_release}" =~ ^[1-9][0-9]*$ ]]; then
	echo 'Makefile has no valid PKG_VERSION/PKG_RELEASE pair.' >&2
	exit 1
fi

expected_tag="v${package_version//\~/-}"
if [ "${tag}" != "${expected_tag}" ]; then
	echo "Release tag ${tag} does not match Makefile version ${package_version}." >&2
	echo "Expected tag: ${expected_tag}" >&2
	exit 1
fi

history_version="$(printf '%s\n' "${package_version}" | sed -E \
	-e 's/~beta([0-9]+)/ beta \1/' \
	-e 's/~rc([0-9]+)/ rc \1/')"
first_history_heading="$(sed -n 's/^## //p; /^## /q' "${repo_root}/HISTORY.md")"
case "${first_history_heading}" in
	"${history_version}"|"${history_version} -"*) ;;
	*)
		echo "HISTORY.md does not start with release ${history_version}." >&2
		exit 1
		;;
esac

printf '%s\n' "${package_version}-${package_release}"
