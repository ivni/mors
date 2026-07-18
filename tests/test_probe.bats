#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIFECYCLE_ROOT=${BATS_TEST_TMPDIR}/lifecycle
	MORS_LIFECYCLE_STATE_FILE=${MORS_LIFECYCLE_ROOT}/state.json
	MORS_LIFECYCLE_TRANSACTION_ROOT=${MORS_LIFECYCLE_ROOT}/transactions
	MORS_LIFECYCLE_ACTIVE_FILE=${MORS_LIFECYCLE_ROOT}/active
	MORS_LIFECYCLE_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_LIFECYCLE_LEGACY_START_FILE=${BATS_TEST_TMPDIR}/S96mors
	export MORS_LIFECYCLE_ROOT MORS_LIFECYCLE_STATE_FILE
	export MORS_LIFECYCLE_TRANSACTION_ROOT MORS_LIFECYCLE_ACTIVE_FILE
	export MORS_LIFECYCLE_CONF_FILE MORS_LIFECYCLE_LEGACY_START_FILE
	. "${REPO_ROOT}/opt/bin/libs/lifecycle_state"
	. "${REPO_ROOT}/opt/bin/libs/test_probe"
	MORS_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_LIST_FILE=${BATS_TEST_TMPDIR}/mors.list
}

@test "strict IPv4 parser rejects partial and out of range values" {
	test_probe__valid_ipv4 203.0.113.7
	! test_probe__valid_ipv4 203.0.113
	! test_probe__valid_ipv4 203.0.113.999
	! test_probe__valid_ipv4 '203.0.113.7 text'
}

@test "configuration reports unconfigured without mutation" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_CONF_FILE}"
	printf '%s\n' ifconfig.me >"${MORS_LIST_FILE}"
	! test_probe__configuration
	[ "${MORS_PROBE_STATUS}" = unconfigured ]
	[ "$(cat "${MORS_CONF_FILE}")" = 'SETUP_FINISHED=' ]
}

@test "configuration accepts only lifecycle ready" {
	printf '%s\n' 'SETUP_FINISHED=true' >"${MORS_CONF_FILE}"
	printf '%s\n' ifconfig.me >"${MORS_LIST_FILE}"
	! test_probe__configuration
	[ "${MORS_PROBE_STATUS}" = unconfigured ] || [ "${MORS_PROBE_STATUS}" = error ]
	lifecycle_state__write ready test
	test_probe__configuration
}

@test "target selection only uses a configured built-in endpoint" {
	printf '%s\n' example.org '  api.ipify.org  # probe' >"${MORS_LIST_FILE}"
	test_probe__target
	[ "${MORS_TEST_TARGET}" = api.ipify.org ]
	printf '%s\n' example.org >"${MORS_LIST_FILE}"
	run test_probe__target
	[ "${status}" -ne 0 ]
}

@test "DNS probe queries the active Mors backend port" {
	local timeout_mock=${BATS_TEST_TMPDIR}/timeout
	local calls=${BATS_TEST_TMPDIR}/calls
	printf '%s\n' '#!/bin/sh' \
		'printf "%s\n" "$@" >"${MORS_MOCK_CALLS}"' \
		'printf "%s\n" 203.0.113.7' >"${timeout_mock}"
	chmod +x "${timeout_mock}"
	kdig() { :; }
	get_config_value() { [ "${1}" = DNSMASQ_PORT ] && printf '%s\n' 9753; }
	MORS_TEST_TIMEOUT_CMD=${timeout_mock}
	MORS_MOCK_CALLS=${calls}; export MORS_MOCK_CALLS
	MORS_TEST_DNS_BACKEND=dnsmasq
	MORS_TEST_DEADLINE=$(( $(test_probe__now_seconds) + 10 ))

	[ "$(test_probe__dns_command api.ipify.org)" = 203.0.113.7 ]
	grep -Fxq '@127.0.0.1' "${calls}"
	grep -Fxq -- '-p' "${calls}"
	grep -Fxq 9753 "${calls}"
	grep -Fxq api.ipify.org "${calls}"
	grep -Fxq A "${calls}"
}

@test "AdGuard probe uses the managed main DNS port" {
	MORS_TEST_DNS_BACKEND=adguard
	MAIN_DNS_PORT=9753
	[ "$(test_probe__dns_port)" = 9753 ]
}

@test "firewall probe requires the selected chain mark rule and active route" {
	local iptables_save=${BATS_TEST_TMPDIR}/iptables-save
	local ip=${BATS_TEST_TMPDIR}/ip
	printf '%s\n' '#!/bin/sh' \
		'echo "-A PREROUTING -m set --match-set MORS_LIST dst -j MORS_MARK"' \
		'echo "-A MORS_MARK -j MARK --set-xmark 0xd1000/0xffffffff"' >"${iptables_save}"
	printf '%s\n' '#!/bin/sh' \
		'case "$1" in' \
		' rule) echo "1778: from all fwmark 0xd1000/0xd1000 lookup 1001";;' \
		' route) echo "default dev Proxy21";;' \
		'esac' >"${ip}"
	chmod +x "${iptables_save}" "${ip}"
	MORS_TEST_IPTABLES_SAVE=${iptables_save}
	MORS_TEST_IP=${ip}
	MORS_TEST_ACTIVE_KIND=vless
	MORS_TEST_ACTIVE_DEVICE=Proxy21
	IPSET_TABLE_NAME=MORS_LIST
	test_probe__firewall_route
	[ "${MORS_PROBE_STATUS}" = working ]
}

@test "network retries are additional attempts and stop after success" {
	local counter=${BATS_TEST_TMPDIR}/attempts
	local mock_curl=${BATS_TEST_TMPDIR}/curl
	printf '%s\n' 0 >"${counter}"
	printf '%s\n' '#!/bin/sh' \
		'counter=${MORS_MOCK_COUNTER}' \
		'n=$(cat "${counter}")' \
		'n=$((n + 1)); printf "%s\n" "${n}" >"${counter}"' \
		'[ "${n}" -ge 3 ] || exit 28' \
		'printf "%s\n" 203.0.113.7' >"${mock_curl}"
	chmod +x "${mock_curl}"
	MORS_TEST_CURL=${mock_curl}
	MORS_MOCK_COUNTER=${counter}; export MORS_MOCK_COUNTER
	MORS_TEST_RETRIES=2
	MORS_TEST_DEADLINE=$(( $(test_probe__now_seconds) + 10 ))
	test_probe__http_ipv4 https://example.invalid plain
	[ "${MORS_TEST_HTTP_ATTEMPTS}" -eq 3 ]
	[ "$(cat "${counter}")" -eq 3 ]
}
