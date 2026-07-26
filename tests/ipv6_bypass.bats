#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MOCK_BIN=${BATS_TEST_TMPDIR}/bin
	IP_COMMAND=${MOCK_BIN}/ip
	mkdir -p "${MOCK_BIN}"
cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$*" in
	'-6 route show default')
		case "${MORS_MOCK_IPV6_DEFAULT:-none}" in
			usable) printf '%s\n' 'default via 2001:db8::1 dev eth0' ;;
			unreachable) printf '%s\n' 'unreachable default dev lo metric 1024' ;;
		esac
		;;
	'-6 addr show dev br0 scope global')
		[ "${MORS_MOCK_IPV6_LAN:-false}" = true ] && \
			printf '%s\n' 'inet6 2001:db8:1::1/64 scope global dynamic'
		;;
esac
EOF
	cat >"${MOCK_BIN}/timeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
	cat >"${MOCK_BIN}/kdig" <<'EOF'
#!/bin/sh
printf '%s\n' '2001:db8::53'
EOF
	chmod +x "${MOCK_BIN}"/*
	export PATH="${MOCK_BIN}:${PATH}"
	MORS_IPV6_IP_COMMAND=${IP_COMMAND}
	MORS_IPV6_HOME_INTERFACE=br0
	export MORS_IPV6_IP_COMMAND MORS_IPV6_HOME_INTERFACE
	. "${REPO_ROOT}/opt/bin/libs/ipv6_bypass"
	has_adguard_enable() { return 1; }
	get_config_value() { printf '%s\n' 9753; }
	hint__commands_title() { printf '%s\n' 'Команды:'; }
	MAIN_DNS_PORT=9753
	YELLOW=''; NOCL=''
	source <(sed -n '/^ipv6_bypass__active_dns_aaaa()/,/^SUFF=/p' \
		"${REPO_ROOT}/opt/bin/libs/vpn" | sed '$d' | tr -d '\r')
}

ipv6_answer() {
	printf '%s\n' '2001:db8::99'
}

@test "IPv6 answer or tunnel egress without a default route is not bypass" {
	! ipv6_bypass__detect example.com ipv6_answer
	[ "${MORS_IPV6_BYPASS_REASON}" = no_ipv6_bypass_evidence ]
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.global_route')" = false ]

	run hint__if_dns_ipv6
	[ "${status}" -eq 0 ]
	[ -z "${output}" ]
}

@test "router default route without client-facing LAN IPv6 is not bypass" {
	MORS_MOCK_IPV6_DEFAULT=usable
	export MORS_MOCK_IPV6_DEFAULT

	! ipv6_bypass__detect example.com ipv6_answer
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.global_route')" = true ]
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.client_facing_lan')" = false ]
}

@test "unreachable IPv6 default is not a usable client path" {
	MORS_MOCK_IPV6_DEFAULT=unreachable
	MORS_MOCK_IPV6_LAN=true
	export MORS_MOCK_IPV6_DEFAULT MORS_MOCK_IPV6_LAN

	! ipv6_bypass__detect example.com ipv6_answer
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.global_route')" = false ]
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.client_facing_lan')" = true ]
}

@test "AAAA usable default and client-facing LAN IPv6 are reported" {
	MORS_MOCK_IPV6_DEFAULT=usable
	MORS_MOCK_IPV6_LAN=true
	export MORS_MOCK_IPV6_DEFAULT MORS_MOCK_IPV6_LAN

	ipv6_bypass__detect example.com ipv6_answer
	[ "${MORS_IPV6_BYPASS_REASON}" = ipv6_bypass_risk ]
	[ "$(printf '%s\n' "${MORS_IPV6_BYPASS_EVIDENCE}" | jq -r '.aaaa and .global_route and .client_facing_lan and (.mors_ipv6 | not)')" = true ]

	run hint__if_dns_ipv6
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"IPv6-путь"* ]]
}

@test "test architecture documents all three client-facing bypass factors" {
	local architecture=${REPO_ROOT}/docs/test-architecture.md
	grep -q 'оценка AAAA' "${architecture}"
	grep -q 'usable default IPv6 route' "${architecture}"
	grep -q 'client-facing global IPv6 на домашнем интерфейсе' "${architecture}"
	grep -q 'WAN-only IPv6' "${architecture}"
	grep -q 'unreachable/blackhole' "${architecture}"
}
