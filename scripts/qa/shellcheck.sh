#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

if ! command -v shellcheck >/dev/null 2>&1; then
	echo "shellcheck is not installed; skipping advisory shell lint"
	exit 0
fi

mapfile -t shell_files < <(bash scripts/qa/list-shell-files.sh)
[ "${#shell_files[@]}" -gt 0 ] || exit 0

# The legacy runtime still contains Entware/BusyBox idioms and some bashisms under
# /bin/sh shebangs. Keep this job focused on ShellCheck parser/errors for now;
# warnings can be tightened later as the legacy surface is cleaned up.
shellcheck --severity=error "${shell_files[@]}"
