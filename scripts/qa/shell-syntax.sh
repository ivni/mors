#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

status=0

while IFS= read -r file; do
	printf 'bash -n %s\n' "${file}"
	if ! bash -n "${file}"; then
		status=1
	fi
done < <(bash scripts/qa/list-shell-files.sh)

exit "${status}"
