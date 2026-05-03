#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

required_paths=(
	Makefile
	opt/bin/mors
	opt/bin/libs/main
	opt/bin/libs/vpn
	opt/bin/libs/check
	opt/bin/main/setup
	opt/bin/main/upgrade
	opt/etc/conf/mors.conf
	opt/etc/conf/mors.help
	opt/etc/conf/mors.list
	opt/etc/conf/adblock.sources
	opt/etc/conf/dnsmasq.conf
	opt/etc/conf/shadowsocks.json
	opt/etc/conf/mors.vless
	opt/etc/init.d/S96mors
	opt/etc/ndm/fs.d/15-mors-start.sh
	opt/etc/ndm/netfilter.d/100-dns-local
	opt/etc/ndm/ndm
)

missing=0
for path in "${required_paths[@]}"; do
	if [ ! -e "${path}" ]; then
		echo "Missing required package path: ${path}" >&2
		missing=1
	fi
done

if ! grep -q '^define Package/mors/install$' Makefile; then
	echo "Makefile does not define Package/mors/install" >&2
	missing=1
fi

if ! grep -q '^define Package/mors/postinst$' Makefile; then
	echo "Makefile does not define Package/mors/postinst" >&2
	missing=1
fi

if ! grep -q '^define Package/mors/postrm$' Makefile; then
	echo "Makefile does not define Package/mors/postrm" >&2
	missing=1
fi

exit "${missing}"
