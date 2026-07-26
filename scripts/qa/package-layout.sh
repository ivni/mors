#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

required_paths=(
	Makefile
	opt/bin/mors
	opt/bin/libs/main
	opt/bin/libs/interaction
	opt/bin/libs/mors_purge
	opt/bin/libs/ndm
	opt/bin/libs/ownership
	opt/bin/libs/vpn
	opt/bin/libs/xray
	opt/bin/libs/vless_store
	opt/bin/libs/vless_config
	opt/bin/libs/vless_runtime
	opt/bin/libs/vless_process
	opt/bin/libs/lifecycle
	opt/bin/libs/lifecycle_state
	opt/bin/libs/lifecycle_snapshot
	opt/bin/libs/setup_plan
	opt/bin/libs/setup_dns
	opt/bin/libs/ipv6_bypass
	opt/bin/libs/service_action
	opt/bin/libs/runtime_lock
	opt/bin/libs/telemetry
	opt/bin/libs/telemetry_runtime
	opt/bin/libs/telemetry_store
	opt/bin/libs/telemetry_otlp
	opt/bin/libs/telemetry_process
	opt/bin/libs/telemetry_upgrade
	opt/bin/libs/upgrade_artifact
	opt/bin/libs/check
	opt/bin/libs/test
	opt/bin/libs/test_result
	opt/bin/libs/test_probe
	opt/bin/libs/test_tunnel
	opt/bin/libs/test_cold
	opt/bin/main/vless-supervisor
	opt/bin/main/vless-watchdog
	opt/bin/main/telemetry-sender
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
	opt/etc/init.d/S25mors-vless
	opt/etc/init.d/S98mors-telemetry
	opt/etc/ndm/fs.d/15-mors-start.sh
	opt/etc/ndm/iflayerchanged.d/100-mors-vpn
	opt/etc/ndm/netfilter.d/100-dns-local
	docs/test-architecture.md
	docs/lifecycle-architecture.md
	docs/telemetry-architecture.md
	tests/setup_plan.bats
	tests/interaction.bats
	tests/setup_dns.bats
	tests/setup_backup.bats
	tests/setup_dataplane.bats
	tests/ndm_failures.bats
	tests/ownership.bats
	tests/purge.bats
	tests/vpn_failures.bats
	tests/ipv6_bypass.bats
	tests/setup_proxy.bats
	tests/dns_prepare.bats
	tests/dnsmasq_worker.bats
	tests/telemetry_upgrade.bats
	tests/upgrade_artifact.bats
	tests/upgrade_safety.bats
	tests/entware_builder.bats
	scripts/qa/opkg-version-order.sh
	scripts/qa/entware-builder-id.sh
	scripts/qa/entware-builder-package.sh
	scripts/qa/verify-entware-builder.sh
	builder/entware/Dockerfile
	builder/entware/Dockerfile.dockerignore
	builder/entware/runtime-dependencies.mk
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

if grep -Fq '$(INSTALL_BIN) opt/etc/ndm/' Makefile || \
	grep -Fq '$(INSTALL_BIN) opt/etc/init.d/S96mors' Makefile; then
	echo "IPK must not install active Mors hooks before setup commit" >&2
	missing=1
fi

if grep -Fq '/opt/etc/init.d/S98mors-telemetry' Makefile; then
	echo "IPK lifecycle scripts must not activate or remove the opt-in telemetry hook." >&2
	missing=1
fi

exit "${missing}"
