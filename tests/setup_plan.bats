#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_SETUP_PLAN_INTERFACE_JSON='[
		{"id":"ISP","interface-name":"eth2","description":"Провайдер","type":"PPPOE","defaultgw":true,"state":"up"},
		{"id":"Wireguard0","interface-name":"nwg0","description":"Рабочий VPN","type":"Wireguard","defaultgw":false,"state":"up"},
		{"id":"Proxy7","interface-name":"opkg7","description":"Чужой Proxy","type":"Proxy","defaultgw":false,"state":"up"},
		{"id":"Proxy21","interface-name":"opkg21","description":"Mors VLESS","type":"Proxy","defaultgw":false,"state":"down"},
		{"id":"Bridge0","interface-name":"br0","description":"Домашняя сеть","type":"Bridge","defaultgw":false,"state":"up"}
	]'
	export MORS_SETUP_PLAN_INTERFACE_JSON
	PROXY_VLESS_NAME=Proxy21
	export PROXY_VLESS_NAME
	. "${REPO_ROOT}/opt/bin/libs/setup_plan"
}

@test "read-only inventory includes supported clients and only managed Proxy" {
	run setup_plan__inventory_json
	[ "${status}" -eq 0 ]
	[ "$(jq -r 'length' <<<"${output}")" -eq 2 ]
	[ "$(jq -r '.[0].cli' <<<"${output}")" = Proxy21 ]
	[ "$(jq -r '.[1].cli' <<<"${output}")" = Wireguard0 ]
	! grep -q 'Proxy7\|ISP\|Bridge0' <<<"${output}"
}

@test "selection resolves an exact live interface without filesystem writes" {
	local empty=${BATS_TEST_TMPDIR}/empty
	mkdir "${empty}"
	before=$(find "${empty}" -mindepth 1 -print)

	setup_plan__select Wireguard0 dnscrypt

	[ "${MORS_SETUP_INTERFACE_CLI}" = Wireguard0 ]
	[ "${MORS_SETUP_INTERFACE_ENTWARE}" = nwg0 ]
	[ "${MORS_SETUP_DNS_BACKEND}" = dnscrypt ]
	[ "$(find "${empty}" -mindepth 1 -print)" = "${before}" ]
}

@test "AdGuard can be selected only when an existing local instance is complete" {
	MORS_SETUP_ADGUARD_BIN=${BATS_TEST_TMPDIR}/AdGuardHome
	MORS_SETUP_ADGUARD_INIT=${BATS_TEST_TMPDIR}/S99adguardhome
	MORS_SETUP_ADGUARD_CONFIG=${BATS_TEST_TMPDIR}/AdGuardHome.yaml
	export MORS_SETUP_ADGUARD_BIN MORS_SETUP_ADGUARD_INIT MORS_SETUP_ADGUARD_CONFIG

	run setup_plan__select Wireguard0 adguard
	[ "${status}" -eq 3 ]

	printf '#!/bin/sh\n' >"${MORS_SETUP_ADGUARD_BIN}"
	printf '#!/bin/sh\n' >"${MORS_SETUP_ADGUARD_INIT}"
	printf 'dns: {}\n' >"${MORS_SETUP_ADGUARD_CONFIG}"
	chmod +x "${MORS_SETUP_ADGUARD_BIN}" "${MORS_SETUP_ADGUARD_INIT}"
	setup_plan__select Wireguard0 adguard
	[ "${MORS_SETUP_DNS_BACKEND}" = adguard ]
}

@test "selected plan round-trips through the durable transaction journal" {
	MORS_LIFECYCLE_ROOT=${BATS_TEST_TMPDIR}/lifecycle
	MORS_LIFECYCLE_STATE_FILE=${MORS_LIFECYCLE_ROOT}/state.json
	MORS_LIFECYCLE_TRANSACTION_ROOT=${MORS_LIFECYCLE_ROOT}/transactions
	MORS_LIFECYCLE_ACTIVE_FILE=${MORS_LIFECYCLE_ROOT}/active
	MORS_LIFECYCLE_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	export MORS_LIFECYCLE_ROOT MORS_LIFECYCLE_STATE_FILE
	export MORS_LIFECYCLE_TRANSACTION_ROOT MORS_LIFECYCLE_ACTIVE_FILE MORS_LIFECYCLE_CONF_FILE
	. "${REPO_ROOT}/opt/bin/libs/lifecycle_state"
	printf 'SETUP_FINISHED=\n' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	setup_plan__select Wireguard0 dnscrypt
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	setup_plan__journal_store
	unset MORS_SETUP_INTERFACE_CLI MORS_SETUP_INTERFACE_ENTWARE MORS_SETUP_DNS_BACKEND

	setup_plan__journal_load

	[ "${MORS_SETUP_INTERFACE_CLI}" = Wireguard0 ]
	[ "${MORS_SETUP_INTERFACE_ENTWARE}" = nwg0 ]
	[ "${MORS_SETUP_DNS_BACKEND}" = dnscrypt ]
	[ "$(jq -r '.plan.interface_cli' "$(lifecycle_transaction__journal_file)")" = Wireguard0 ]
}

@test "setup apply has no legacy interface or AdGuard prompts" {
	local setup_file=${REPO_ROOT}/opt/bin/main/setup
	local install_body
	install_body=$(sed -n '/^setup__cmd_install_unlocked()/,/^setup__activate_core_hooks()/p' "${setup_file}" | tr -d '\r')
	! grep -q 'cmd_interface_change\|read_ynq\|read -r' <<<"${install_body}"
	! grep -q 'cmd_install_proxy_package' <<<"${install_body}"
	grep -q 'switch_vpn_on "${MORS_SETUP_INTERFACE_ENTWARE}"' <<<"${install_body}"
}
