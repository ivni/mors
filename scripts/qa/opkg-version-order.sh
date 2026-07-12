#!/usr/bin/env bash
set -euo pipefail

opkg_bin="${1:?Usage: opkg-version-order.sh /path/to/host/opkg}"

"${opkg_bin}" compare-versions 1.2.0 '<' '1.3.0~beta2'
"${opkg_bin}" compare-versions '1.3.0~beta2' '<' 1.3.0

printf '%s\n' 'opkg version order: 1.2.0 < 1.3.0~beta2 < 1.3.0'
