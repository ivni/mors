#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

echo "== package layout =="
bash scripts/qa/package-layout.sh

echo "== secret scan =="
bash scripts/qa/secret-scan.sh

echo "== line endings =="
if git grep -Il $'\r' -- . ':!ipk/**' ':!logs/**'; then
	echo "CRLF line endings found in tracked text files" >&2
	exit 1
fi

echo "== shell syntax =="
bash scripts/qa/shell-syntax.sh

echo "== shellcheck =="
bash scripts/qa/shellcheck.sh

echo "== actionlint =="
bash scripts/qa/actionlint.sh
