#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_BACKUP_PATH=${BATS_TEST_TMPDIR}/backup
	MORS_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_CONFIG_BACKUP=${MORS_BACKUP_PATH}/mors.conf
	MORS_LIST_FILE=${BATS_TEST_TMPDIR}/mors.list
	MORS_LIST_FILE_BACKUP=${MORS_BACKUP_PATH}/mors.list
	ADGUARDHOME_CONFIG=${BATS_TEST_TMPDIR}/AdGuardHome.yaml
	ADGUARDHOME_CONFIG_BACKUP=${MORS_BACKUP_PATH}/AdGuardHome.yaml
	ADGUARD_IPSET_FILE=${BATS_TEST_TMPDIR}/mors.ipset
	ADGUARD_IPSET_FILE_BACKUP=${MORS_BACKUP_PATH}/mors.ipset
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/shadowsocks.json
	SHADOWSOCKS_CONF_BACKUP=${MORS_BACKUP_PATH}/shadowsocks.json
	DNSMASQ_CONFIG=${BATS_TEST_TMPDIR}/dnsmasq.conf
	DNSMASQ_CONFIG_BACKUP=${MORS_BACKUP_PATH}/dnsmasq.conf
	DNSMASQ_IPSET_HOSTS=${BATS_TEST_TMPDIR}/mors.dnsmasq
	DNSMASQ_IPSET_HOSTS_BACKUP=${MORS_BACKUP_PATH}/mors.dnsmasq
	VLESS_CONFIG_FILE=${BATS_TEST_TMPDIR}/mors.vless
	VLESS_CONFIG_FILE_BACKUP=${MORS_BACKUP_PATH}/mors.vless
	VLESS_STORE_ROOT=${BATS_TEST_TMPDIR}/vless-store
	DNSCRYPT_CONFIG=${BATS_TEST_TMPDIR}/dnscrypt-proxy.toml
	DNSCRYPT_CONFIG_BACKUP=${MORS_BACKUP_PATH}/dnscrypt-proxy.toml
	ADBLOCK_HOSTS_FILE=${BATS_TEST_TMPDIR}/ads.mors.list
	ADBLOCK_HOSTS_FILE_BACKUP=${MORS_BACKUP_PATH}/ads.mors.list
	ADBLOCK_SOURCES_LIST=${BATS_TEST_TMPDIR}/sources.list
	ADBLOCK_SOURCES_LIST_BACKUP=${MORS_BACKUP_PATH}/sources.list
	ADBLOCK_LIST_EXCEPTION=${BATS_TEST_TMPDIR}/exception.list
	ADBLOCK_LIST_EXCEPTION_BACKUP=${MORS_BACKUP_PATH}/exception.list

	source <(sed -n '/^backup_copy()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/main" | tr -d '\r')
	source <(sed -n '/^save_backups()/,/^list__backup()/p' "${REPO_ROOT}/opt/bin/main/setup" | sed '$d' | tr -d '\r')
	source <(sed -n '/^setup__develop_remove_service()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^all_services_rm_develop_mode()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^legacy_cleanup__run()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^setup__run_transaction_step()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^clear_previous_version_net_rules()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^setup__verify_legacy_dataplane_absent()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	source <(sed -n '/^setup__rollback_transaction()/,/^}$/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	ready() { :; }
	when_ok() { :; }
	when_bad() { :; }
}

@test "setup step wrapper records a failing command without changing its exit code" {
	local events=${BATS_TEST_TMPDIR}/step-events
	lifecycle_transaction__step() { printf 'step:%s\n' "$1" >>"${events}"; }
	lifecycle_transaction__failure() { printf 'failure:%s:%s\n' "$1" "$2" >>"${events}"; }
	failing_step() { return 7; }

	run setup__run_transaction_step setup.switch_vpn failing_step

	[ "${status}" -eq 7 ]
	[ "$(cat "${events}")" = $'step:setup.switch_vpn\nfailure:setup.switch_vpn:7' ]
}

@test "missing optional backup inputs are a successful no-op" {
	run save_backups
	[ "${status}" -eq 0 ]
	[ ! -e "${ADBLOCK_LIST_EXCEPTION_BACKUP}" ]
}

@test "copy failure for an existing backup input is blocking" {
	printf '%s\n' configured >"${MORS_CONF_FILE}"

	run save_backups

	[ "${status}" -ne 0 ]
	[ "$(cat "${MORS_CONF_FILE}")" = configured ]
}

@test "develop uninstall aborts when AdGuard status is unknown" {
	local opkg_called=${BATS_TEST_TMPDIR}/opkg.called
	ADGUARDHOME_DEMON=${BATS_TEST_TMPDIR}/adguard-init
	printf '%s\n' '#!/bin/sh' 'exit 0' >"${ADGUARDHOME_DEMON}"
	chmod +x "${ADGUARDHOME_DEMON}"
	setup_dns__service_state() { return 1; }
	opkg() { : >"${opkg_called}"; }
	has_ssr_enable() { return 1; }

	run all_services_rm_develop_mode

	[ "${status}" -ne 0 ]
	[ ! -e "${opkg_called}" ]
}

@test "develop uninstall propagates opkg removal failure" {
	local service=${BATS_TEST_TMPDIR}/service config=${BATS_TEST_TMPDIR}/service.conf
	printf '%s\n' '#!/bin/sh' 'exit 0' >"${service}"
	printf '%s\n' configured >"${config}"
	chmod +x "${service}"
	setup_dns__stop_service() { return 0; }
	opkg() { return 9; }

	run setup__develop_remove_service "${service}" test-service "${config}" test-package

	[ "${status}" -ne 0 ]
}

@test "legacy dataplane cleanup stops at a non-final deletion failure" {
	local events=${BATS_TEST_TMPDIR}/cleanup-events
	: >"${events}"
	ip4__rule__delete_mark_to_table() { printf 'rule\n' >>"${events}"; }
	ip4__route__flush_table() { printf 'route\n' >>"${events}"; }
	ip4__chain__delete_jump() {
		printf 'jump:%s:%s\n' "$1" "$2" >>"${events}"
		[ "$2" != MORS_DNS ]
	}
	ip4__chain__delete() { printf 'chain:%s:%s\n' "$1" "$2" >>"${events}"; }
	iptables__delete_rules() { printf 'rules:%s:%s\n' "$1" "$2" >>"${events}"; }
	ip4__ipset__destroy() { printf 'ipset:%s\n' "$1" >>"${events}"; }

	run clear_previous_version_net_rules
	[ "${status}" -ne 0 ]
	[ "$(cat "${events}")" = $'rule\nroute\njump:nat:MORS_DNS' ]
}

@test "rollback legacy cleanup attempts every step and retains an early failure" {
	local events=${BATS_TEST_TMPDIR}/cleanup-events
	: >"${events}"
	ip4__rule__delete_mark_to_table() { printf 'rule\n' >>"${events}"; }
	ip4__route__flush_table() { printf 'route\n' >>"${events}"; }
	ip4__chain__delete_jump() {
		printf 'jump:%s:%s\n' "$1" "$2" >>"${events}"
		[ "$2" != MORS_DNS ]
	}
	ip4__chain__delete() { printf 'chain:%s:%s\n' "$1" "$2" >>"${events}"; }
	iptables__delete_rules() { printf 'rules:%s:%s\n' "$1" "$2" >>"${events}"; }
	ip4__ipset__destroy() { printf 'ipset:%s\n' "$1" >>"${events}"; }

	run clear_previous_version_net_rules best_effort
	[ "${status}" -ne 0 ]
	grep -q '^jump:nat:MORS_DNS$' "${events}"
	[ "$(tail -n 1 "${events}")" = 'ipset:unblock' ]
}

@test "committed verifier rejects an exact surviving legacy jump" {
	local diagnostic=${BATS_TEST_TMPDIR}/diagnostic
	save_iptables() {
		printf '%s\n' \
			':MORS_MARK - [0:0]' \
			'-A PREROUTING -j MORS_VPN'
	}
	ipset() { [ "$*" = 'list -n' ] && return 0; return 1; }
	setup__verify_failed() { printf '%s\n' "$*" >"${diagnostic}"; return 1; }

	run setup__verify_legacy_dataplane_absent
	[ "${status}" -ne 0 ]
	grep -q 'legacy firewall object MORS_VPN' "${diagnostic}"
}

@test "rollback fault continues restoration but never publishes success" {
	local events=${BATS_TEST_TMPDIR}/rollback-events
	: >"${events}"
	lifecycle_transaction__journal_file() { printf '%s\n' unused; }
	jq() {
		case "$2" in
			.previous_state) printf '%s\n' ready ;;
			.phase) printf '%s\n' applying ;;
			*) return 1 ;;
		esac
	}
	lifecycle_transaction__phase() { printf 'phase:%s\n' "$1" >>"${events}"; }
	setup__quiesce_managed_vless_runtime() { printf 'quiesce\n' >>"${events}"; }
	clear_previous_version_net_rules() { printf 'cleanup:%s\n' "$1" >>"${events}"; return 7; }
	setup__deactivate_core_hooks() { printf 'hooks\n' >>"${events}"; }
	setup__rollback_provisioned_interface() { printf 'interface\n' >>"${events}"; }
	lifecycle_snapshot__restore() { printf 'snapshot\n' >>"${events}"; }
	setup__bind_transaction_dns_log() { printf 'dns-log\n' >>"${events}"; }
	cmd_mors_init() { printf 'init\n' >>"${events}"; }
	setup__converge_dataplane() { printf 'converge\n' >>"${events}"; }
	setup__verify_committed() { printf 'verify-legacy\n' >>"${events}"; return 1; }
	lifecycle_transaction__rollback_finish() { printf 'unexpected-finish\n' >>"${events}"; }

	run setup__rollback_transaction
	[ "${status}" -ne 0 ]
	grep -q '^cleanup:best_effort$' "${events}"
	grep -q '^snapshot$' "${events}"
	grep -q '^verify-legacy$' "${events}"
	! grep -q '^unexpected-finish$' "${events}"
}

@test "rollback publishes restored unconfigured state despite superseded cleanup errors" {
	local events=${BATS_TEST_TMPDIR}/rollback-events
	: >"${events}"
	MORS_SETUP_DNS_LOG=${BATS_TEST_TMPDIR}/rollback-services.log
	lifecycle_transaction__journal_file() { printf '%s\n' unused; }
	jq() {
		case "$2" in
			.previous_state) printf '%s\n' unconfigured ;;
			.phase) printf '%s\n' applying ;;
			*) return 1 ;;
		esac
	}
	lifecycle_transaction__phase() { printf 'phase:%s\n' "$1" >>"${events}"; }
	setup_dns__log_path() { printf '%s\n' "${MORS_SETUP_DNS_LOG}"; }
	setup__quiesce_managed_vless_runtime() { return 7; }
	clear_previous_version_net_rules() { return 8; }
	setup__deactivate_core_hooks() { return 9; }
	setup__rollback_provisioned_interface() { printf 'interface\n' >>"${events}"; }
	lifecycle_snapshot__restore() { printf 'snapshot\n' >>"${events}"; }
	setup__verify_runtime_removed() { printf 'verify\n' >>"${events}"; }
	lifecycle_transaction__rollback_finish() { printf 'finish\n' >>"${events}"; }

	run setup__rollback_transaction

	[ "${status}" -eq 0 ]
	[ "$(cat "${events}")" = $'phase:rolling_back\ninterface\nsnapshot\nverify\nfinish' ]
	grep -q 'step=quiesce-vless exit=7' "${MORS_SETUP_DNS_LOG}"
	grep -q 'step=cleanup-dataplane exit=8' "${MORS_SETUP_DNS_LOG}"
	grep -q 'step=deactivate-hooks exit=9' "${MORS_SETUP_DNS_LOG}"
}
