#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	VPN=${REPO_ROOT}/opt/bin/libs/vpn
	EVENTS=${BATS_TEST_TMPDIR}/events
	FAKE_ROOT=${BATS_TEST_TMPDIR}/runtime
	mkdir -p "${FAKE_ROOT}"
	: >"${EVENTS}"
	export EVENTS
}

load_vpn_function() {
	local name=${1}
	eval "$(sed -n "/^${name}()/,/^}/p" "${VPN}" | tr -d '\r')"
}

load_function() {
	local file=${1} name=${2}
	eval "$(sed -n "/^${name}()/,/^}/p" "${file}" | tr -d '\r')"
}

prepare_runtime_script() {
	local input=${1} output=${2}
	sed \
		-e "s|/opt/apps/mors/bin/libs/lifecycle_state|${FAKE_ROOT}/lifecycle_state|g" \
		-e "s|/opt/apps/mors/bin/libs/runtime_lock|${FAKE_ROOT}/runtime_lock|g" \
		-e "s|/opt/apps/mors/bin/libs/test_cold|${FAKE_ROOT}/test_cold|g" \
		-e "s|/opt/apps/mors/bin/libs/vpn|${FAKE_ROOT}/vpn|g" \
		-e "s|/opt/apps/mors/bin/libs/ndm|${FAKE_ROOT}/ndm|g" \
		-e "s|/opt/etc/init.d/rc.func|${FAKE_ROOT}/rc.func|g" \
		"${input}" >"${output}"
	chmod +x "${output}"
}

@test "switch_vpn_on stops when interface mutation fails" {
	load_vpn_function switch_vpn_on
	ndm_interface_change() { return 7; }
	vpn__service_state() { printf 'called\n' >>"${EVENTS}"; }

	run switch_vpn_on tun0 Normal

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "switch_vpn_on propagates guest loop failure" {
	load_vpn_function switch_vpn_on
	ndm_interface_change() { :; }
	vpn__service_state() { printf '%s\n' stopped; }
	vless_runtime__supervisor_service() { :; }
	shadowsocks_off() { :; }
	vpn_on() { :; }
	cmd_mors_init() { :; }
	get_guest_inface_list_from_config() { printf '%s\n' br1 br2; }
	bridge_vpn_access_add() { printf '%s\n' "$1" >>"${EVENTS}"; return 8; }
	XRAY_INIT=${BATS_TEST_TMPDIR}/S24xray
	VLESS_SUPERVISOR_INIT=${BATS_TEST_TMPDIR}/missing-supervisor
	SSR_ENTWARE_TEMPL=ss-local
	PROXY_VLESS_NAME=Mors-proxy-vless
	is_install_stage=install
	MORS_DEFER_SYSTEM_HOOKS=true

	run switch_vpn_on tun0 Normal

	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = br1 ]
}

@test "S96 boot exits nonzero and releases its lock after init failure" {
	local script=${BATS_TEST_TMPDIR}/S96mors
	printf '%s\n' \
		'lifecycle_state__active_id() { return 1; }' \
		'lifecycle_state__boot_gate() { return 0; }' >"${FAKE_ROOT}/lifecycle_state"
	printf '%s\n' \
		'runtime_mutation_lock__acquire_wait() { printf "begin:%s\n" "$1" >>"${EVENTS}"; }' \
		'runtime_mutation_lock__release() { printf "release\n" >>"${EVENTS}"; }' >"${FAKE_ROOT}/runtime_lock"
	printf '%s\n' \
		'cmd_mors_init() { printf "init:%s\n" "$1" >>"${EVENTS}"; return 17; }' \
		'has_ssr_enable() { printf "ssr-probe\n" >>"${EVENTS}"; return 1; }' \
		'is_vless_over_proxy_enabled() { return 1; }' >"${FAKE_ROOT}/vpn"
	printf "MORS_COLD_JOURNAL_DIR='%s'\n" "${FAKE_ROOT}/missing-cold" >"${FAKE_ROOT}/test_cold"
	prepare_runtime_script "${REPO_ROOT}/opt/etc/init.d/S96mors" "${script}"

	run bash "${script}" start
	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = $'begin:mors init service\ninit:no\nrelease' ]
}

@test "S99 AdGuard start does not reach rc.func after dataplane failure" {
	local script=${BATS_TEST_TMPDIR}/S99adguard
	printf '%s\n' \
		'runtime_mutation_lock__acquire() { printf "begin:%s\n" "$1" >>"${EVENTS}"; }' \
		'runtime_mutation_lock__release() { printf "release\n" >>"${EVENTS}"; }' >"${FAKE_ROOT}/runtime_lock"
	printf '%s\n' \
		'cmd_mors_init() { printf "init:%s\n" "$1" >>"${EVENTS}"; return 17; }' \
		'ready() { :; }' >"${FAKE_ROOT}/vpn"
	printf '%s\n' 'printf "rc-func\n" >>"${EVENTS}"' >"${FAKE_ROOT}/rc.func"
	prepare_runtime_script "${REPO_ROOT}/opt/etc/init.d/S99adguard" "${script}"

	run bash "${script}" start
	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = $'begin:mors adguard service\ninit:initd\nrelease' ]
}

@test "guest configuration returns the DNS mutation error" {
	load_vpn_function bridge_access_add
	printf '%s\n' 'INFACE_GUEST_ENT=br1' >"${BATS_TEST_TMPDIR}/mors.conf"
	curl() { printf '%s\n' 'fake-rci'; }
	jq() { cat >/dev/null; printf '%s\n' 'Guest'; }
	ip4() { printf '%s\n' 'inet 192.0.2.1/24 scope global br1'; }
	cmd_adguardhome_status() { printf '%s\n' 'ВЫКЛЮЧЕН'; }
	ready() { :; }
	when_alert() { printf 'success\n' >>"${EVENTS}"; }
	MORS_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	DNSMASQ_CONFIG=${BATS_TEST_TMPDIR}/missing/dnsmasq.conf
	ADGUARDHOME_CONFIG=${BATS_TEST_TMPDIR}/missing/AdGuardHome.yaml
	INFACE_REQUEST=http://router/interface

	run bridge_access_add br1
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "vpn_on returns the dataplane rebuild error" {
	load_vpn_function vpn_on
	printf '%s\n' 'Proxy1|tun0|Test VPN' >"${BATS_TEST_TMPDIR}/interfaces"
	ready() { :; }
	ready_status() { printf 'ready-status:%s\n' "$1" >>"${EVENTS}"; }
	ndm_interface_change() { printf 'interface\n' >>"${EVENTS}"; }
	get_value_interface_field() { printf '%s\n' up; }
	update_iptables() { printf 'dataplane\n' >>"${EVENTS}"; return 19; }
	sleep() { :; }
	INFACE_NAMES_FILE=${BATS_TEST_TMPDIR}/interfaces
	ERROR_LOG_FILE=${BATS_TEST_TMPDIR}/vpn.error
	MORS_DEFER_SYSTEM_HOOKS=true

	run vpn_on tun0
	[ "${status}" -ne 0 ]
	grep -q '^interface$' "${EVENTS}"
	grep -q '^dataplane$' "${EVENTS}"
}

@test "Shadowsocks reset and switch propagate dataplane and interface failures" {
	load_vpn_function cmd_shadowsocks_iptable_reset
	load_vpn_function shadowsocks_on
	ready() { :; }
	when_ok() { :; }
	when_bad() { :; }
	get_router_ip() { printf '%s\n' 192.0.2.1; }
	get_inface_by_ip() { printf '%s\n' br0; }
	get_config_value() { printf '%s\n' 1090; }
	update_iptables() { return 8; }
	run cmd_shadowsocks_iptable_reset
	[ "${status}" -ne 0 ]

	get_ssr_entware_interface() { printf '%s\n' ss-redir0; }
	ndm_interface_change() { return 7; }
	cmd_shadowsocks_iptable_reset() { printf 'reset\n' >>"${EVENTS}"; }
	MORS_DEFER_SYSTEM_HOOKS=true
	run shadowsocks_on
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "Shadowsocks off reports a failed firewall flush" {
	load_vpn_function shadowsocks_off
	ready() { :; }
	when_ok() { :; }
	when_bad() { :; }
	cmd_shadowsocks_iptable_flush() { return 6; }
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/missing.json

	run shadowsocks_off
	[ "${status}" -ne 0 ]
}

@test "valid Shadowsocks config is an idempotent successful backup" {
	load_vpn_function shadowsocks_backup
	local init=${BATS_TEST_TMPDIR}/S22shadowsocks
	SSR_CMD=${BATS_TEST_TMPDIR}/ss-redir
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/shadowsocks.json
	printf '%s\n' '#!/bin/sh' 'PROCS=ss-local' >"${init}"
	printf '%s\n' '#!/bin/sh' >"${SSR_CMD}"
	printf '%s\n' '{"server":"198.51.100.8","password":"secret"}' >"${SHADOWSOCKS_CONF}"
	shadowsocks_init__path() { printf '%s\n' "${init}"; }
	vpn__service_state() { printf '%s\n' stopped; }
	shadowsocks_read_data() { printf 'unexpected-read\n' >>"${EVENTS}"; return 7; }
	error() { :; }

	run shadowsocks_backup
	[ "${status}" -eq 0 ]
	[ ! -s "${EVENTS}" ]
	grep -q 'ss-redir' "${init}"
}

@test "Shadowsocks backup recognizes and restores a valid mors archive" {
	load_vpn_function shadowsocks_backup
	local init=${BATS_TEST_TMPDIR}/S22shadowsocks
	SSR_CMD=${BATS_TEST_TMPDIR}/ss-redir
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/shadowsocks.json
	printf '%s\n' '#!/bin/sh' 'PROCS=ss-local' >"${init}"
	printf '%s\n' '#!/bin/sh' >"${SSR_CMD}"
	printf '%s\n' '{"server":"198.51.100.8","password":"secret"}' >"${SHADOWSOCKS_CONF}.mors"
	shadowsocks_init__path() { printf '%s\n' "${init}"; }
	vpn__service_state() { printf '%s\n' stopped; }
	active_backup_config() { printf 'restore-archive\n' >>"${EVENTS}"; }
	shadowsocks_read_data() { printf 'unexpected-read\n' >>"${EVENTS}"; return 7; }
	error() { :; }

	run shadowsocks_backup
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = restore-archive ]
}

@test "manual Shadowsocks input returns a sed mutation failure" {
	load_vpn_function shadowsocks_read_config
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/shadowsocks.json
	printf '%s\n' '{}' >"${SHADOWSOCKS_CONF}"
	read_value() {
		case "$2" in
			SSR_SERVER_IP) printf -v "$2" '%s' 198.51.100.8 ;;
			SSR_SERVER_PORT) printf -v "$2" '%s' 443 ;;
			SSR_SERVER_CRYPT) printf -v "$2" '%s' aes-256-gcm ;;
			SSR_SERVER_PASSWD) printf -v "$2" '%s' secret ;;
		esac
	}
	escape_sed() { printf '%s\n' "$1"; }
	get_config_value() { printf '%s\n' 1090; }
	print_line() { :; }
	ready() { :; }
	when_ok() { printf 'ok\n' >>"${EVENTS}"; }
	when_bad() { printf 'bad\n' >>"${EVENTS}"; }
	sed() { return 9; }

	run shadowsocks_read_config
	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = bad ]
}

@test "AdGuard dataplane rebuild stops at the first failed stage" {
	load_vpn_function adguardhome_rebuild_dataplane
	ip4__flush() { printf 'flush\n' >>"${EVENTS}"; }
	ip4__dns__add_routing_for_home() { printf 'dns\n' >>"${EVENTS}"; return 7; }
	ip4_firewall_set_all_rules() { printf 'firewall\n' >>"${EVENTS}"; }

	run adguardhome_rebuild_dataplane
	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = $'flush\ndns' ]
}

@test "guest add wrapper does not restart DNS after routing failure" {
	load_vpn_function cmd_bridge_vpn_access_add
	bridge_inface_select() { printf -v "$1" '%s' br1; }
	bridge_vpn_access_add() { return 7; }
	cmd_adguardhome_status() { printf 'ВКЛЮЧЕН\n'; }
	ready() { :; }
	when_alert() { :; }
	when_bad() { :; }

	run cmd_bridge_vpn_access_add
	[ "${status}" -ne 0 ]
}

@test "IKEv2 delete wrapper returns the routing error" {
	load_vpn_function ikev2_net_access_del
	ready() { :; }
	when_alert() { :; }
	when_bad() { :; }
	ip4__delete_routing_by_list_for_net() { return 8; }

	run ikev2_net_access_del
	[ "${status}" -ne 0 ]
}

@test "route refresh stops before rebuild after cleanup failure" {
	load_function "${REPO_ROOT}/opt/bin/libs/route" cmd_route_refresh
	ip4__flush() { return 5; }
	ip4__dns__add_routing_for_home() { printf 'dns\n' >>"${EVENTS}"; }
	ip4_firewall_set_all_rules() { printf 'firewall\n' >>"${EVENTS}"; }

	run cmd_route_refresh
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "pause and unpause return runtime mutation failures" {
	local setup_script=${REPO_ROOT}/opt/bin/main/setup
	load_function "${setup_script}" cmd_pause_mors
	load_function "${setup_script}" cmd_unpause_mors
	ready() { :; }
	when_ok() { :; }
	when_bad() { :; }
	ip4__flush() { return 4; }
	run cmd_pause_mors
	[ "${status}" -ne 0 ]

	MORS_BACKUP_PATH=${BATS_TEST_TMPDIR}/backup
	mkdir -p "${MORS_BACKUP_PATH}"
	cmd_mors_init() { return 3; }
	restart_all_services() { printf 'restart\n' >>"${EVENTS}"; }
	run cmd_unpause_mors
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "NDM hooks execute finish and preserve the mutator failure" {
	local source script name table_value
	printf '%s\n' \
		'lifecycle_state__boot_gate() { return 0; }' \
		'lifecycle_state__runtime_allowed() { return 0; }' >"${FAKE_ROOT}/lifecycle_state"
	printf '%s\n' \
		'ndm_runtime__begin() { printf "begin:%s\n" "$1" >>"${EVENTS}"; }' \
		'ndm_runtime__finish() { printf "finish:%s\nrelease\n" "$1" >>"${EVENTS}"; return "$1"; }' \
		'ip4__ipset__create_list() { printf "mutate:ipset\n" >>"${EVENTS}"; return 17; }' \
		'ip4__dns__add_routing_for_home() { printf "mutate:dns\n" >>"${EVENTS}"; return 17; }' \
		'ip4_firewall_set_all_rules() { printf "mutate:firewall\n" >>"${EVENTS}"; return 17; }' >"${FAKE_ROOT}/ndm"
	printf "MORS_COLD_JOURNAL_DIR='%s'\n" "${FAKE_ROOT}/missing-cold" >"${FAKE_ROOT}/test_cold"

	script=${BATS_TEST_TMPDIR}/15-mors-start.sh
	prepare_runtime_script "${REPO_ROOT}/opt/etc/ndm/fs.d/15-mors-start.sh" "${script}"
	run bash "${script}" start
	[ "${status}" -eq 17 ]
	[ "$(cat "${EVENTS}")" = $'begin:filesystem_start\nmutate:ipset\nfinish:17\nrelease' ]

	for source in 100-dns-local 100-vpn-mark 100-proxy-redirect; do
		: >"${EVENTS}"
		case "${source}" in
			100-dns-local) table_value=nat; name=dns ;;
			100-vpn-mark) table_value=mangle; name=firewall ;;
			100-proxy-redirect) table_value=nat; name=firewall ;;
		esac
		script=${BATS_TEST_TMPDIR}/${source}
		prepare_runtime_script "${REPO_ROOT}/opt/etc/ndm/netfilter.d/${source}" "${script}"
		run env EVENTS="${EVENTS}" type=iptables table="${table_value}" bash "${script}"
		[ "${status}" -eq 17 ]
		grep -q "^mutate:${name}$" "${EVENTS}"
		grep -q '^finish:17$' "${EVENTS}"
		[ "$(tail -n 1 "${EVENTS}")" = release ]
	done
}
