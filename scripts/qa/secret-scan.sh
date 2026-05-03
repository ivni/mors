#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

patterns=(
	'ghp_[A-Za-z0-9_]{20,}'
	'github_pat_[A-Za-z0-9_]{20,}'
	'xox[baprs]-[A-Za-z0-9-]{10,}'
	'AKIA[0-9A-Z]{16}'
	'[0-9]{8,10}:[A-Za-z0-9_-]{35}'
	'-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----'
)

status=0
for pattern in "${patterns[@]}"; do
	if git grep -nIE -e "${pattern}" -- . ':!ipk/**' ':!logs/**'; then
		status=1
	fi
done

if [ "${status}" -ne 0 ]; then
	echo "Potential secret material found in tracked files" >&2
fi

exit "${status}"
