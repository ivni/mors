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

# The legacy runtime still contains Entware/BusyBox idioms and known findings.
# Keep this job focused on newly visible serious issues; tighten exclusions as
# the legacy shell surface is cleaned up.
shellcheck \
	--severity=error \
	--exclude=SC2068,SC2144,SC2283 \
	"${shell_files[@]}"
