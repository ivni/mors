#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	RULES=${BATS_TEST_TMPDIR}/iptables-save
	IP_COMMAND=${BATS_TEST_TMPDIR}/ip
	REFRESHES=${BATS_TEST_TMPDIR}/refreshes
	printf '%s\n' 0 >"${REFRESHES}"
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from all fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'default dev t2s21' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"
	IPSET_TABLE_NAME=MORS_LIST
	SSR_ENTWARE_TEMPL='^ss-redir$'
	MORS_SETUP_INTERFACE_ENTWARE=t2s21
	MORS_SETUP_HOME_INTERFACE=br0
	MORS_SETUP_IP_COMMAND=${IP_COMMAND}
	MARK_NUM=0xd1000
	ROUTE_TABLE_ID=1001
	save_iptables() { cat "${RULES}"; }
	get_config_value() { :; }
	error() { printf '%s\n' "$*" >&2; }
	setup__verify_failed() { error "Lifecycle verification: ${1}"; return 1; }
	source <(sed -n '/^setup__dataplane_ip_command()/,/^setup__verify_committed()/p' \
		"${REPO_ROOT}/opt/bin/main/setup" | sed '$d')
}

valid_rules() {
	cat >"${RULES}" <<'EOF'
*nat
:MORS_DNS - [0:0]
COMMIT
*mangle
:MORS_MARK - [0:0]
-A PREROUTING -i br0 -m set --match-set MORS_LIST dst -j MORS_MARK
-A MORS_MARK -j MARK --set-xmark 0xd1000/0xffffffff
COMMIT
EOF
}

valid_ssr_rules() {
	cat >"${RULES}" <<'EOF'
*nat
:MORS_DNAT_TO_PORT - [0:0]
-A PREROUTING -i br0 -m set --match-set MORS_LIST dst -j MORS_DNAT_TO_PORT
-A MORS_DNAT_TO_PORT -p tcp -j REDIRECT --to-ports 1181
-A MORS_DNAT_TO_PORT -p udp -j REDIRECT --to-ports 1181
COMMIT
EOF
}

select_ssr_dataplane() {
	MORS_SETUP_INTERFACE_ENTWARE=ss-redir
	get_config_value() {
		[ "${1}" = SSR_DNS_PORT ] && printf '%s\n' 1181
	}
}

@test "MORS_DNS alone cannot satisfy setup dataplane verification" {
	printf '%s\n' '*nat' ':MORS_DNS - [0:0]' 'COMMIT' >"${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"MORS_LIST"*"MORS_MARK"* ]]
}

@test "exact MORS_LIST mark policy and default route satisfy verification" {
	valid_rules
	setup__dataplane_validate
}

@test "missing fwmark policy rule is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from all lookup 1001' ;;
	route) printf '%s\n' 'default dev t2s21' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__verify_dataplane
	[ "${status}" -ne 0 ]
}

@test "guest jump cannot replace the required home PREROUTING jump" {
	valid_rules
	sed -i 's/-i br0 /-i br1 /' "${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"домашний интерфейс br0"* ]]
}

@test "inverted home interface cannot satisfy the PREROUTING invariant" {
	valid_rules
	sed -i 's/-A PREROUTING -i br0 /-A PREROUTING ! -i br0 /' "${RULES}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "suffixed jump target cannot satisfy the exact home chain invariant" {
	valid_rules
	sed -i 's/-j MORS_MARK$/-j MORS_MARK_OLD/' "${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
}

@test "larger substring mark cannot satisfy the exact MARK invariant" {
	valid_rules
	sed -i 's/0xd1000\/0xffffffff/0xd10000\/0xffffffff/' "${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
}

@test "conditional MARK rule cannot satisfy the unconditional invariant" {
	valid_rules
	sed -i 's/-A MORS_MARK /-A MORS_MARK -s 192.0.2.1 /' "${RULES}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "inverted fwmark policy rule is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: not from all fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'default dev t2s21' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "source-restricted fwmark policy rule is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from 192.0.2.0/24 fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'default dev t2s21' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "unusable default route is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from all fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'unreachable default metric 42760' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "default route through another interface is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from all fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'default dev eth0' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__dataplane_validate
	[ "${status}" -ne 0 ]
}

@test "conflicting default outranking the tunnel route is rejected" {
	valid_rules
	cat >"${IP_COMMAND}" <<'EOF'
#!/bin/sh
case "$1" in
	rule) printf '%s\n' '1778: from all fwmark 0xd1000/0xd1000 lookup 1001' ;;
	route) printf '%s\n' 'default dev eth0 metric 10' 'default dev t2s21 metric 100' ;;
esac
EOF
	chmod +x "${IP_COMMAND}"

	run setup__dataplane_validate
	[ "${status}" -ne 0 ]
}

@test "commit convergence repairs a late netfilter regeneration" {
	local sleep_calls=0
	setup__refresh_dataplane() {
		local count
		count=$(cat "${REFRESHES}")
		printf '%s\n' $((count + 1)) >"${REFRESHES}"
		valid_rules
	}
	sleep() {
		sleep_calls=$((sleep_calls + 1))
		if [ "${sleep_calls}" -eq 1 ]; then
			printf '%s\n' '*nat' ':MORS_DNS - [0:0]' 'COMMIT' >"${RULES}"
		fi
	}
	MORS_SETUP_DATAPLANE_ATTEMPTS=2
	MORS_SETUP_DATAPLANE_STABLE_CHECKS=2
	MORS_SETUP_DATAPLANE_SETTLE_INTERVAL=1

	setup__converge_dataplane

	[ "$(cat "${REFRESHES}")" -eq 2 ]
}

@test "SSR exact TCP and UDP redirects to configured port satisfy verification" {
	select_ssr_dataplane
	valid_ssr_rules

	setup__dataplane_validate
}

@test "SSR redirect to another port is rejected" {
	select_ssr_dataplane
	valid_ssr_rules
	sed -i 's/--to-ports 1181/--to-ports 11810/g' "${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"порт 1181"* ]]
}

@test "SSR dataplane without UDP redirect is rejected" {
	select_ssr_dataplane
	valid_ssr_rules
	sed -i '/-p udp /d' "${RULES}"

	run setup__verify_dataplane

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"UDP redirect"* ]]
}

@test "source-restricted SSR redirect is rejected" {
	select_ssr_dataplane
	valid_ssr_rules
	sed -i 's/-A MORS_DNAT_TO_PORT -p tcp /-A MORS_DNAT_TO_PORT -s 192.0.2.1 -p tcp /' "${RULES}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}

@test "inverted SSR protocol is rejected" {
	select_ssr_dataplane
	valid_ssr_rules
	sed -i 's/-A MORS_DNAT_TO_PORT -p tcp /-A MORS_DNAT_TO_PORT ! -p tcp /' "${RULES}"

	run setup__dataplane_validate

	[ "${status}" -ne 0 ]
}
