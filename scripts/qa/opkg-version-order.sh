#!/usr/bin/env bash
set -euo pipefail

opkg_bin="${1:?Usage: opkg-version-order.sh /path/to/host/opkg VERSION}"
package_version="${2:?Usage: opkg-version-order.sh /path/to/host/opkg VERSION}"
stable_version="${package_version%%~*}"

if [ "${package_version}" = "${stable_version}" ]; then
	"${opkg_bin}" --conf /dev/null compare-versions \
		"${package_version}" '=' "${stable_version}"
else
	"${opkg_bin}" --conf /dev/null compare-versions \
		"${package_version}" '<' "${stable_version}"
fi

printf 'opkg version order: %s <= %s\n' "${package_version}" "${stable_version}"
