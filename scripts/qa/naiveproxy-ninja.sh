#!/usr/bin/env bash
set -euo pipefail
jobs="${MORS_NAIVE_JOBS:-2}"
[[ "${jobs}" =~ ^[12]$ ]] || { echo 'Naive build allows 1 or 2 jobs.' >&2; exit 1; }
exec /usr/bin/ninja -j"${jobs}" -d keeprsp "$@"
