#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

xray_binary="${1:?Usage: xray-compatibility.sh /path/to/xray expected-version}"
expected_version="${2:?Usage: xray-compatibility.sh /path/to/xray expected-version}"

# shellcheck source=../../opt/bin/libs/xray
source opt/bin/libs/xray

case "${expected_version}" in
	"${XRAY_MIN_VERSION}" | "${XRAY_TESTED_VERSION}") ;;
	*)
		echo "Version ${expected_version} is not declared in the Mors Xray policy" >&2
		exit 1
		;;
esac

XRAY="${xray_binary}"
actual_version="$(xray__get_version)"
if [ "${actual_version}" != "${expected_version}" ]; then
	echo "Expected Xray ${expected_version}, got ${actual_version}" >&2
	exit 1
fi

test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
config="${test_root}/mors.json"
cp opt/etc/conf/mors.vless "${config}"

sed -i \
	-e 's|/tmp/log/xray-access.log|/dev/null|' \
	-e 's|/tmp/log/xray-errors.log|/dev/null|' \
	-e 's|@VLESS_SSR_PORT|1097|' \
	-e 's|@VLESS_ADDRESS|192.0.2.1|' \
	-e 's|@VLESS_PORT|443|' \
	-e 's|@VLESS_ID|00000000-0000-4000-8000-000000000000|' \
	-e 's|@VLESS_NETWORK|tcp|' \
	-e 's|@VLESS_PUB_KEY|ioE61VC3V30U7IdRmQ3bjhOq2ij9tPhVIgAD4JZ4YRY|' \
	-e 's|@VLESS_BROWSER_FP|chrome|' \
	-e 's|@VLESS_SNI|example.com|' \
	-e 's|@VLESS_SHORT_ID|0123456789abcdef|' \
	"${config}"

"${XRAY}" run -test -c "${config}"
