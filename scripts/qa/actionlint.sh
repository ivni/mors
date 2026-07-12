#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

if ! command -v actionlint >/dev/null 2>&1; then
	echo 'actionlint is not installed; skipping workflow lint'
	exit 0
fi

mapfile -t workflows < <(find .github/workflows -maxdepth 1 -type f \
	\( -name '*.yml' -o -name '*.yaml' \) -print | sort)
[ "${#workflows[@]}" -gt 0 ] || exit 0

shellcheck_args=(-shellcheck '')
if command -v shellcheck >/dev/null 2>&1; then
	export SHELLCHECK_OPTS='--severity=error --exclude=SC2068,SC2144,SC2283'
	shellcheck_args=(-shellcheck shellcheck)
fi

actionlint "${shellcheck_args[@]}" "${workflows[@]}"
