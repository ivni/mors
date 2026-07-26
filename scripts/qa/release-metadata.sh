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

if [[ "${package_version}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
	core_version=${BASH_REMATCH[1]}
	expected_tag="v${core_version}"
	history_version="${core_version}"
elif [[ "${package_version}" =~ ^([0-9]+\.[0-9]+\.[0-9]+)~(beta|rc)([1-9][0-9]*)$ ]]; then
	core_version=${BASH_REMATCH[1]}
	prerelease_kind=${BASH_REMATCH[2]}
	prerelease_number=${BASH_REMATCH[3]}
	expected_tag="v${core_version}-${prerelease_kind}.${prerelease_number}"
	history_version="${core_version} ${prerelease_kind} ${prerelease_number}"
else
	echo "Unsupported Entware package version: ${package_version}." >&2
	exit 1
fi

if [ "${tag}" != "${expected_tag}" ]; then
	echo "Release tag ${tag} does not match Makefile version ${package_version}." >&2
	echo "Expected tag: ${expected_tag}" >&2
	exit 1
fi

first_history_heading="$(sed -n 's/^## //p; /^## /q' "${repo_root}/HISTORY.md")"
case "${first_history_heading}" in
	"${history_version}"|"${history_version} -"*) ;;
	*)
		echo "HISTORY.md does not start with release ${history_version}." >&2
		exit 1
		;;
esac

printf '%s\n' "${package_version}-${package_release}"
