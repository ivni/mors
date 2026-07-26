#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	NDM=${REPO_ROOT}/opt/bin/libs/ndm
	EVENTS=${BATS_TEST_TMPDIR}/events
	: >"${EVENTS}"
}

load_ndm_function() {
	local name=${1}
	eval "$(sed -n "/^${name}()/,/^}/p" "${NDM}" | tr -d '\r')"
}

load_ndm_chain_readiness() {
	load_ndm_function ip4__chain__print_semantic_rule
	load_ndm_function ip4__chain__semantic_rules
	load_ndm_function ip4__chain__expected_source_rules
	load_ndm_function ip4__data_chain__expected_rules
	load_ndm_function ip4__dnat_chain_has_required_rules
	load_ndm_function ip4__mark__has_required_rules
	load_ndm_function ip4__dns_chain_has_required_rules
}

load_ndm_prerouting_readiness() {
	load_ndm_function ip4__prerouting_jump_semantic_rules
	load_ndm_function ip4__prerouting_jump_has_required_rule
	load_ndm_function ip4__prerouting_jump_delete_near_misses
}

load_ndm_dns_chain_builder() {
	load_ndm_function ip4__dns__deactivate_partial_chain
	load_ndm_function ip4__dns__create_chain
}

@test "MARK builder stops at the first per-IP failure" {
	load_ndm_function ip4_mark_vpn_network
	ip4__mark__create_chain() { return 0; }
	ip4__add_routing_for_ip_from_config() { return 7; }
	ip4__add_routing_by_list_for_net_from_config() { printf 'guest\n' >>"${EVENTS}"; }
	ip4__mark__add_routing_for_home() { printf 'home\n' >>"${EVENTS}"; }

	run ip4_mark_vpn_network

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "SSR builder does not mask create-chain failure with a home rule" {
	load_ndm_function ip4_firewall_set_all_rules
	is_shadowsocks_enabled() { return 0; }
	ip4__shadowsocks__create_chain() { return 9; }
	ip4__add_routing_for_ip_from_config() { printf 'ip\n' >>"${EVENTS}"; }
	ip4__add_routing_by_list_for_net_from_config() { printf 'guest\n' >>"${EVENTS}"; }
	ip4__shadowsocks__add_routing_for_home() { printf 'home\n' >>"${EVENTS}"; }

	run ip4_firewall_set_all_rules

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "per-IP loop propagates a non-final rule failure" {
	load_ndm_function ip4__add_routing_for_ip_from_config
	get_regexp_ip_or_range() { printf '%s\n' '[0-9.]*'; }
	get_config_value() {
		case "$1" in
			route_full_ip) printf '%s\n' '192.0.2.1+192.0.2.2' ;;
			route_by_list_ip) : ;;
		esac
	}
	ip4__get_subrule_for_ip() { printf '%s\n' "-s $1"; }
	is_shadowsocks_enabled() { return 1; }
	ip4__add_routing() { printf '%s\n' "$3" >>"${EVENTS}"; return 8; }
	TABLE_MARK=mangle
	CHAIN_MARK=MORS_MARK

	run ip4__add_routing_for_ip_from_config

	[ "${status}" -ne 0 ]
	[ "$(wc -l <"${EVENTS}")" -eq 1 ]
}

@test "flush stops after the first failed cleanup step" {
	load_ndm_function ip4__flush
	ip4__delete_routing_by_list_for_net_from_config() { return 6; }
	ip4__delete_routing_for_ip_from_config() { printf 'ip\n' >>"${EVENTS}"; }
	ip4__rule__delete_mark_to_table() { printf 'rule\n' >>"${EVENTS}"; }
	ip4__route__flush_table() { :; }
	ip4__chain__delete_jump() { :; }
	ip4__chain__delete() { :; }
	ip4__ipset__destroy_destination_excluded() { :; }
	ip4__ipset__destroy_list() { :; }

	run ip4__flush 'net ip chain table'

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "home DNS routing propagates ipset creation failure" {
	load_ndm_function ip4__dns__add_routing_for_home
	ip4__ipset__create_list() { return 5; }
	get_local_inface() { printf '%s\n' br0; }
	ip4__dns__add_routing() { printf 'routing\n' >>"${EVENTS}"; }

	run ip4__dns__add_routing_for_home

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "partial MARK chain is discarded and the next attempt rebuilds it" {
	load_ndm_function ip4__mark__create_chain
	printf '%s\n' missing >"${BATS_TEST_TMPDIR}/chain-state"
	: >"${BATS_TEST_TMPDIR}/fail-save"
	ip4__chain__is_exist() { [ "$(cat "${BATS_TEST_TMPDIR}/chain-state")" = exists ]; }
	ip4__chain__has_rule_fragments() { return 1; }
	ip4__chain__delete_jump() { printf 'delete-jump\n' >>"${EVENTS}"; }
	ip4__chain__delete() { printf '%s\n' missing >"${BATS_TEST_TMPDIR}/chain-state"; }
	ip4__chain__discard_partial() {
		printf 'discard\n' >>"${EVENTS}"
		printf '%s\n' missing >"${BATS_TEST_TMPDIR}/chain-state"
		return 1
	}
	ip4__chain__create_for_data() { printf '%s\n' exists >"${BATS_TEST_TMPDIR}/chain-state"; }
	ip4__route__add_table() { :; }
	ip4__rule__add_mark_to_table() { :; }
	is_vless_over_proxy_enabled() { return 1; }
	log_warning() { :; }
	error() { :; }
	iptab() {
		printf '%s\n' "$*" >>"${EVENTS}"
		if [[ "$*" == *"CONNMARK --save-mark"* ]] && [ -e "${BATS_TEST_TMPDIR}/fail-save" ]; then
			return 7
		fi
	}
	TABLE_MARK=mangle
	CHAIN_MARK=MORS_MARK
	MARK_NUM=0xd1000

	run ip4__mark__create_chain
	[ "${status}" -ne 0 ]
	[ "$(cat "${BATS_TEST_TMPDIR}/chain-state")" = missing ]
	grep -q '^discard$' "${EVENTS}"

	rm -f "${BATS_TEST_TMPDIR}/fail-save"
	run ip4__mark__create_chain
	[ "${status}" -eq 0 ]
	[ "$(cat "${BATS_TEST_TMPDIR}/chain-state")" = exists ]
	grep -q 'CONNMARK --save-mark' "${EVENTS}"
}

@test "cleanup probes propagate system read errors instead of treating them as absence" {
	load_ndm_function iptables__delete_rules
	load_ndm_function ip4__ipset__destroy
	load_ndm_function ip4__route__flush_table
	error() { :; }
	save_iptables() { return 9; }
	iptables__delete_rule() { printf 'delete-rule\n' >>"${EVENTS}"; }
	run iptables__delete_rules mangle MORS_MARK
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]

	ip4__ipset__is_exist() { return 2; }
	run ip4__ipset__destroy MORS_LIST
	[ "${status}" -ne 0 ]

	ROUTE_TABLE_ID=1001
	ip4__route__is_exist_table() { return 2; }
	run ip4__route__flush_table
	[ "${status}" -ne 0 ]
}

@test "NDM finish releases the lock and preserves the original mutator error" {
	load_ndm_function ndm_runtime__finish
	ndm_runtime__end() { printf 'released\n' >>"${EVENTS}"; return 6; }

	run ndm_runtime__finish 9
	[ "${status}" -eq 9 ]
	[ "$(cat "${EVENTS}")" = released ]

	run ndm_runtime__finish 0
	[ "${status}" -eq 6 ]
}

@test "missing policy table is absence while other ip errors remain failures" {
	load_ndm_function ip4__route__show_table
	load_ndm_function ip4__route__is_exist_table
	error() { printf 'error:%s\n' "$*" >>"${EVENTS}"; }
	ip4() {
		if [ "${IP_FAILURE_MODE}" = missing ]; then
			printf '%s\n' 'Error: ipv4: FIB table does not exist.' >&2
			return 2
		fi
		printf '%s\n' 'RTNETLINK answers: Operation not permitted' >&2
		return 2
	}

	IP_FAILURE_MODE=missing
	run ip4__route__show_table 1001
	[ "${status}" -eq 1 ]
	[ -z "${output}" ]
	run ip4__route__is_exist_table 1001
	[ "${status}" -eq 1 ]
	[ ! -s "${EVENTS}" ]

	IP_FAILURE_MODE=error
	run ip4__route__show_table 1001
	[ "${status}" -eq 2 ]
	grep -q 'Operation not permitted' "${EVENTS}"
}

@test "clean install creates the first route after a missing-table response" {
	load_ndm_function ip4__route__show_table
	load_ndm_function ip4__route__add_table
	get_config_value() {
		case "$1" in
			INFACE_ENT) printf '%s\n' t2s21 ;;
			ADDR_MAN) : ;;
		esac
	}
	ip4() {
		case "$*" in
			'route show table 1001')
				printf '%s\n' 'Error: ipv4: FIB table does not exist.' >&2
				return 2
				;;
			'route add table 1001 default dev t2s21')
				printf 'route-add\n' >>"${EVENTS}"
				return 0
				;;
		esac
		return 9
	}
	ip4__route__flush_cache() { printf 'cache-flush\n' >>"${EVENTS}"; }
	log_warning() { :; }
	error() { :; }
	ROUTE_TABLE_ID=1001
	PROXY_VLESS_ENTWARE=t2s21

	run ip4__route__add_table
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = $'route-add\ncache-flush' ]
}

@test "complete MARK chain reconciles a missing policy table and rule" {
	load_ndm_function ip4__mark__create_chain
	ip4__chain__is_exist() { return 0; }
	ip4__mark__has_required_rules() { return 0; }
	ip4__ipset__fill_destination_excluded() { printf 'excluded\n' >>"${EVENTS}"; }
	ip4__route__add_table() { printf 'route\n' >>"${EVENTS}"; }
	ip4__rule__add_mark_to_table() { printf 'rule\n' >>"${EVENTS}"; }
	ip4__chain__create_for_data() { printf 'rebuild\n' >>"${EVENTS}"; }

	run ip4__mark__create_chain
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = $'excluded\nroute\nrule' ]
}

@test "complete proxy chain restores destination exclusions on retry" {
	load_ndm_function ip4__dnat_to_port__create_chain
	ip4__chain__is_exist() { return 0; }
	ip4__dnat_chain_has_required_rules() { return 0; }
	ip4__ipset__fill_destination_excluded() { printf 'excluded\n' >>"${EVENTS}"; }

	run ip4__dnat_to_port__create_chain nat MORS_PROXY 1090
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = 'excluded' ]
}

@test "TCP-only proxy chain is deleted and rebuilt with UDP and TCP" {
	load_ndm_function ip4__dnat_to_port__create_chain
	ip4__chain__is_exist() { return 0; }
	ip4__dnat_chain_has_required_rules() { return 1; }
	ip4__chain__delete_jump() { printf 'delete-jump\n' >>"${EVENTS}"; }
	ip4__chain__delete() { printf 'delete-chain\n' >>"${EVENTS}"; }
	ip4__chain__create_for_data() { printf 'create-chain\n' >>"${EVENTS}"; }
	ip4__chain__discard_partial() { return 1; }
	iptab() { printf 'iptables:%s\n' "$*" >>"${EVENTS}"; }
	error() { :; }

	run ip4__dnat_to_port__create_chain nat MORS_PROXY 1090
	[ "${status}" -eq 0 ]
	grep -q '^delete-chain$' "${EVENTS}"
	grep -q -- '-p udp' "${EVENTS}"
	grep -q -- '-p tcp' "${EVENTS}"
}

@test "MARK readiness accepts Keenetic set-xmark serialization" {
	load_ndm_chain_readiness
	save_iptables() {
		printf '%s\n' \
			'-A MORS_MARK -m set --match-set MORS_DESTINATION_EXCLUDED dst -j RETURN' \
			'-A MORS_MARK -p udp -m udp --dport 53 -j RETURN' \
			'-A MORS_MARK -p tcp -m tcp --dport 53 -j RETURN' \
			'-A MORS_MARK -p icmp -j RETURN' \
			'-A MORS_MARK -j CONNMARK --restore-mark --nfmask 0xffffffff --ctmask 0xffffffff' \
			'-A MORS_MARK -m mark --mark 0xd1000 -j RETURN' \
			'-A MORS_MARK -m conntrack ! --ctstate NEW -j RETURN' \
			'-A MORS_MARK -j MARK --set-xmark 0xd1000/0xffffffff' \
			'-A MORS_MARK -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff'
	}
	get_config_value() { :; }
	is_vless_over_proxy_enabled() { return 0; }
	TABLE_MARK=mangle
	CHAIN_MARK=MORS_MARK
	MARK_NUM=0xd1000
	IPSET_DESTINATION_EXCLUDED=MORS_DESTINATION_EXCLUDED

	run ip4__mark__has_required_rules
	[ "${status}" -eq 0 ]
}

@test "canonical proxy readiness rejects near-miss ports and shadowing rules" {
	load_ndm_chain_readiness
	local rules=${BATS_TEST_TMPDIR}/proxy-rules
	save_iptables() { cat "${rules}"; }
	get_config_value() { :; }
	get_regexp_ip_or_range() { printf '%s\n' '^[0-9.]+(/[0-9]+)?$'; }
	IPSET_DESTINATION_EXCLUDED=MORS_DESTINATION_EXCLUDED
	printf '%s\n' \
		'-A MORS_PROXY -m set --match-set MORS_DESTINATION_EXCLUDED dst -j RETURN' \
		'-A MORS_PROXY -p udp -m udp --dport 53 -j RETURN' \
		'-A MORS_PROXY -p tcp -m tcp --dport 53 -j RETURN' \
		'-A MORS_PROXY -p udp -m udp -j REDIRECT --to-ports 1090' \
		'-A MORS_PROXY -p tcp -m tcp -j REDIRECT --to-ports 1090' >"${rules}"

	run ip4__dnat_chain_has_required_rules nat MORS_PROXY 1090
	[ "${status}" -eq 0 ]
	sed -i 's/--to-ports 1090/--to-ports 10900/' "${rules}"
	run ip4__dnat_chain_has_required_rules nat MORS_PROXY 1090
	[ "${status}" -ne 0 ]
	sed -i 's/--to-ports 10900/--to-ports 1090/' "${rules}"
	sed -i '/-p udp -m udp -j REDIRECT/i -A MORS_PROXY -j RETURN' "${rules}"
	run ip4__dnat_chain_has_required_rules nat MORS_PROXY 1090
	[ "${status}" -ne 0 ]
}

@test "canonical MARK readiness rejects a larger mark" {
	load_ndm_chain_readiness
	local rules=${BATS_TEST_TMPDIR}/mark-rules
	save_iptables() { cat "${rules}"; }
	get_config_value() { :; }
	get_regexp_ip_or_range() { printf '%s\n' '^[0-9.]+(/[0-9]+)?$'; }
	is_vless_over_proxy_enabled() { return 0; }
	TABLE_MARK=mangle
	CHAIN_MARK=MORS_MARK
	MARK_NUM=0xd1000
	IPSET_DESTINATION_EXCLUDED=MORS_DESTINATION_EXCLUDED
	printf '%s\n' \
		'-A MORS_MARK -m set --match-set MORS_DESTINATION_EXCLUDED dst -j RETURN' \
		'-A MORS_MARK -p udp -m udp --dport 53 -j RETURN' \
		'-A MORS_MARK -p tcp -m tcp --dport 53 -j RETURN' \
		'-A MORS_MARK -p icmp -j RETURN' \
		'-A MORS_MARK -j CONNMARK --restore-mark --nfmask 0xffffffff --ctmask 0xffffffff' \
		'-A MORS_MARK -m mark --mark 0xd1000 -j RETURN' \
		'-A MORS_MARK -m conntrack ! --ctstate NEW -j RETURN' \
		'-A MORS_MARK -j MARK --set-xmark 0xd10000/0xffffffff' \
		'-A MORS_MARK -j CONNMARK --save-mark --nfmask 0xffffffff --ctmask 0xffffffff' >"${rules}"

	run ip4__mark__has_required_rules
	[ "${status}" -ne 0 ]
}

@test "DNS readiness tracks exact target and current source exclusions" {
	load_ndm_chain_readiness
	local rules=${BATS_TEST_TMPDIR}/dns-rules
	save_iptables() { cat "${rules}"; }
	get_config_value() { [ "$1" = route_excluded_ip ] && printf '%s\n' "${EXCLUDED}"; }
	get_regexp_ip_or_range() { printf '%s\n' '^[0-9.]+(/[0-9]+)?$'; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53
	EXCLUDED=192.0.2.2
	printf '%s\n' \
		'-A MORS_DNS -s 192.0.2.2/32 -j RETURN' \
		'-A MORS_DNS -p udp -m udp --dport 53 -j DNAT --to-destination 127.0.0.1:53' \
		'-A MORS_DNS -p tcp -m tcp --dport 53 -j DNAT --to-destination 127.0.0.1:53' >"${rules}"

	run ip4__dns_chain_has_required_rules
	[ "${status}" -eq 0 ]
	EXCLUDED=192.0.2.2/32
	run ip4__dns_chain_has_required_rules
	[ "${status}" -eq 0 ]
	sed -i 's/127.0.0.1:53/127.0.0.1:5300/g' "${rules}"
	run ip4__dns_chain_has_required_rules
	[ "${status}" -ne 0 ]
	sed -i 's/127.0.0.1:5300/127.0.0.1:53/g' "${rules}"
	EXCLUDED=192.0.2.3
	run ip4__dns_chain_has_required_rules
	[ "${status}" -ne 0 ]
}

@test "PREROUTING readiness is token exact and preserves other network rules" {
	load_ndm_prerouting_readiness
	local rules=${BATS_TEST_TMPDIR}/prerouting-rules
	save_iptables() { cat "${rules}"; }
	printf '%s\n' \
		'-A PREROUTING -i br0 -m set --match-set MORS_LIST dst -j MORS_MARK' \
		'-A PREROUTING -i br1 -m set --match-set MORS_LIST dst -j MORS_MARK' >"${rules}"

	run ip4__prerouting_jump_has_required_rule mangle '-i br0 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -eq 0 ]
	sed -i '1s/-i br0/-s 192.0.2.2\/32 -i br0/' "${rules}"
	run ip4__prerouting_jump_has_required_rule mangle '-i br0 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -ne 0 ]
	sed -i '1s/-s 192.0.2.2\/32 //' "${rules}"
	sed -i '1s/-j MORS_MARK/-p tcp -j MORS_MARK/' "${rules}"
	run ip4__prerouting_jump_has_required_rule mangle '-i br0 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -ne 0 ]
	sed -i '1s/-p tcp -j MORS_MARK/-j MORS_MARK_OLD/' "${rules}"
	run ip4__prerouting_jump_has_required_rule mangle '-i br0 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -ne 0 ]
}

@test "PREROUTING reconciliation deletes exact-scope near misses only" {
	load_ndm_prerouting_readiness
	local rules=${BATS_TEST_TMPDIR}/prerouting-rules
	save_iptables() { cat "${rules}"; }
	iptables__delete_rule() { printf '%s\n' "$2" >>"${EVENTS}"; }
	printf '%s\n' \
		'-A PREROUTING -s 192.0.2.2/32 -i br0 -m set --match-set MORS_LIST dst -j MORS_MARK' \
		'-A PREROUTING -i br0 -m set --match-set MORS_LIST dst -j MORS_MARK_OLD' \
		'-A PREROUTING -i br1 -m set --match-set MORS_LIST dst -j MORS_MARK' >"${rules}"

	ip4__prerouting_jump_delete_near_misses mangle '-i br0 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "$(wc -l <"${EVENTS}" | tr -d ' ')" -eq 1 ]
	! grep -q -- '-s 192.0.2.2/32 -i br0' "${EVENTS}"
	grep -q -- '-j MORS_MARK_OLD' "${EVENTS}"
	! grep -q -- '-i br1' "${EVENTS}"
}

@test "source-only and source-interface PREROUTING scopes coexist" {
	load_ndm_prerouting_readiness
	local rules=${BATS_TEST_TMPDIR}/prerouting-rules
	save_iptables() { cat "${rules}"; }
	iptables__delete_rule() { printf '%s\n' "$2" >>"${EVENTS}"; }
	printf '%s\n' \
		'-A PREROUTING -s 192.0.2.0/24 -m set --match-set MORS_LIST dst -j MORS_MARK' \
		'-A PREROUTING -s 192.0.2.0/24 -i xfrms+ -m set --match-set MORS_LIST dst -j MORS_MARK' >"${rules}"

	run ip4__prerouting_jump_has_required_rule mangle '-s 192.0.2.0/24 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -eq 0 ]
	run ip4__prerouting_jump_has_required_rule mangle '-s 192.0.2.0/24 -i xfrms+ -m set --match-set MORS_LIST dst' MORS_MARK
	[ "${status}" -eq 0 ]
	sed -i '1s/-j MORS_MARK/-j MORS_MARK_OLD/' "${rules}"
	ip4__prerouting_jump_delete_near_misses mangle '-s 192.0.2.0/24 -m set --match-set MORS_LIST dst' MORS_MARK
	[ "$(wc -l <"${EVENTS}" | tr -d ' ')" -eq 1 ]
	grep -q -- '-j MORS_MARK_OLD' "${EVENTS}"
	! grep -q -- '-i xfrms+' "${EVENTS}"
}

@test "DNS insertion stops when the checked position snapshot fails" {
	load_ndm_function ip4__get_rulenum
	load_ndm_function ip4__dns__get_rulenum
	load_ndm_function ip4__dns__add_routing
	ip4__prerouting_jump_has_required_rule() { return 1; }
	ip4__prerouting_jump_delete_near_misses() { return 0; }
	save_iptables() { return 7; }
	ip4__dns__create_chain() { printf 'create\n' >>"${EVENTS}"; }
	iptab() { printf 'insert\n' >>"${EVENTS}"; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS

	run ip4__dns__add_routing '-i br0'
	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = 'create' ]
}

@test "DNS rule position uses one checked NAT snapshot" {
	load_ndm_function ip4__get_rulenum
	load_ndm_function ip4__dns__get_rulenum
	local calls=${BATS_TEST_TMPDIR}/snapshot-calls
	: >"${calls}"
	save_iptables() {
		printf 'call\n' >>"${calls}"
		printf '%s\n' \
			'-A PREROUTING -m comment --comment NDM_DNS_REDIRECT -j SOMETHING_ELSE' \
			'-A PREROUTING -j NDM_DNAT_BACKUP' \
			'-A PREROUTING -j NDM_DNAT' \
			'-A PREROUTING -j SOMETHING_ELSE'
	}
	TABLE_DNS=nat

	run ip4__dns__get_rulenum
	[ "${status}" -eq 0 ]
	[ "${output}" = 4 ]
	[ "$(wc -l <"${calls}" | tr -d ' ')" -eq 1 ]
}

@test "canonical DNS jump still validates the managed chain" {
	load_ndm_function ip4__dns__add_routing
	ip4__dns__create_chain() { printf 'validate-chain\n' >>"${EVENTS}"; }
	ip4__prerouting_jump_has_required_rule() { return 0; }
	ip4__prerouting_jump_delete_near_misses() { printf 'unexpected-cleanup\n' >>"${EVENTS}"; }
	ip4__dns__get_rulenum() { printf 'unexpected-position\n' >>"${EVENTS}"; }
	iptab() { printf 'unexpected-insert\n' >>"${EVENTS}"; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS

	run ip4__dns__add_routing '-i br0'
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = 'validate-chain' ]
}

@test "DNS rebuild and jump cleanup precede the checked insertion snapshot" {
	load_ndm_function ip4__dns__add_routing
	ip4__dns__create_chain() { printf 'validate-chain\n' >>"${EVENTS}"; }
	ip4__prerouting_jump_has_required_rule() { return 1; }
	ip4__prerouting_jump_delete_near_misses() { printf 'cleanup-jump\n' >>"${EVENTS}"; }
	ip4__dns__get_rulenum() { printf 'position-snapshot\n' >>"${EVENTS}"; printf '1\n'; }
	iptab() { printf 'insert-jump\n' >>"${EVENTS}"; }
	log_warning() { :; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS

	run ip4__dns__add_routing '-i br0'
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = $'validate-chain\ncleanup-jump\nposition-snapshot\ninsert-jump' ]
}

@test "TCP-only DNS chain is rebuilt in place with UDP and TCP" {
	load_ndm_dns_chain_builder
	ip4__chain__is_exist() { return 0; }
	ip4__dns_chain_has_required_rules() { return 1; }
	ip4__chain__delete_jump() { printf 'delete-jump\n' >>"${EVENTS}"; }
	ip4__chain__delete() { printf 'delete-chain\n' >>"${EVENTS}"; }
	ip4__chain__exclude_source_by_config() { :; }
	iptab() { printf 'iptables:%s\n' "$*" >>"${EVENTS}"; }
	log_warning() { :; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53

	run ip4__dns__create_chain
	[ "${status}" -eq 0 ]
	grep -q '^iptables:-F MORS_DNS ' "${EVENTS}"
	! grep -q '^delete-' "${EVENTS}"
	grep -q -- '-p udp' "${EVENTS}"
	grep -q -- '-p tcp' "${EVENTS}"
}

@test "malformed DNS repair preserves home and guest jump scopes" {
	load_ndm_dns_chain_builder
	load_ndm_function ip4__dns__add_routing
	local jumps=${BATS_TEST_TMPDIR}/dns-jumps
	printf '%s\n' \
		'-A PREROUTING -i br0 -j MORS_DNS' \
		'-A PREROUTING -i br1 -j MORS_DNS' >"${jumps}"
	ip4__chain__is_exist() { return 0; }
	ip4__dns_chain_has_required_rules() { return 1; }
	ip4__chain__exclude_source_by_config() { :; }
	ip4__chain__delete_jump() { : >"${jumps}"; printf 'delete-jumps\n' >>"${EVENTS}"; }
	ip4__prerouting_jump_has_required_rule() { grep -q -- '-i br0 -j MORS_DNS' "${jumps}"; }
	ip4__prerouting_jump_delete_near_misses() { printf 'unexpected-cleanup\n' >>"${EVENTS}"; }
	ip4__dns__get_rulenum() { printf 'unexpected-position\n' >>"${EVENTS}"; }
	iptab() { printf 'iptables:%s\n' "$*" >>"${EVENTS}"; }
	log_warning() { :; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53

	run ip4__dns__add_routing '-i br0'
	[ "${status}" -eq 0 ]
	[ "$(wc -l <"${jumps}" | tr -d ' ')" -eq 2 ]
	grep -q -- '-i br0 -j MORS_DNS' "${jumps}"
	grep -q -- '-i br1 -j MORS_DNS' "${jumps}"
	! grep -q '^delete-jumps$' "${EVENTS}"
	grep -q '^iptables:-F MORS_DNS ' "${EVENTS}"
	grep -q -- '-p udp' "${EVENTS}"
	grep -q -- '-p tcp' "${EVENTS}"
}

@test "failed in-place DNS repair flushes partial chain contents" {
	load_ndm_dns_chain_builder
	ip4__chain__is_exist() { return 0; }
	ip4__dns_chain_has_required_rules() { return 1; }
	ip4__chain__exclude_source_by_config() { return 0; }
	iptab() {
		printf 'iptables:%s\n' "$*" >>"${EVENTS}"
		case "$*" in *'-p tcp'*) return 7 ;; esac
	}
	log_warning() { :; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53

	run ip4__dns__create_chain
	[ "${status}" -ne 0 ]
	[ "$(grep -c '^iptables:-F MORS_DNS ' "${EVENTS}")" -eq 2 ]
	[ "$(tail -n 1 "${EVENTS}")" = 'iptables:-F MORS_DNS -w -t nat' ]
}

@test "failed cleanup flush guards a partial DNS chain with RETURN" {
	load_ndm_dns_chain_builder
	local flush_count=0
	ip4__chain__is_exist() { return 0; }
	ip4__dns_chain_has_required_rules() { return 1; }
	ip4__chain__exclude_source_by_config() { return 0; }
	ip4__chain__delete_jump() { printf 'unexpected-detach\n' >>"${EVENTS}"; }
	iptab() {
		printf 'iptables:%s\n' "$*" >>"${EVENTS}"
		case "$*" in
			'-F MORS_DNS -w -t nat')
				flush_count=$((flush_count + 1))
				[ "${flush_count}" -eq 1 ]
				;;
			*'-p tcp'*) return 7 ;;
			*) return 0 ;;
		esac
	}
	log_warning() { :; }
	error() { :; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53

	run ip4__dns__create_chain
	[ "${status}" -ne 0 ]
	grep -q '^iptables:-I MORS_DNS 1 -w -t nat -j RETURN$' "${EVENTS}"
	! grep -q '^unexpected-detach$' "${EVENTS}"
}

@test "failed cleanup and guard detach every DNS jump scope" {
	load_ndm_function ip4__dns__deactivate_partial_chain
	local jumps=${BATS_TEST_TMPDIR}/dns-jumps
	printf '%s\n' \
		'-A PREROUTING -i br0 -j MORS_DNS' \
		'-A PREROUTING -i br1 -j MORS_DNS' >"${jumps}"
	iptab() { printf 'iptables:%s\n' "$*" >>"${EVENTS}"; return 7; }
	ip4__chain__delete_jump() { : >"${jumps}"; printf 'detach-all\n' >>"${EVENTS}"; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS

	run ip4__dns__deactivate_partial_chain
	[ "${status}" -eq 0 ]
	[ ! -s "${jumps}" ]
	grep -q '^detach-all$' "${EVENTS}"
}

@test "failed final DNS detach propagates with a safety diagnostic" {
	load_ndm_dns_chain_builder
	local flush_count=0
	ip4__chain__is_exist() { return 0; }
	ip4__dns_chain_has_required_rules() { return 1; }
	ip4__chain__exclude_source_by_config() { return 0; }
	ip4__chain__delete_jump() { printf 'detach-failed\n' >>"${EVENTS}"; return 9; }
	iptab() {
		printf 'iptables:%s\n' "$*" >>"${EVENTS}"
		case "$*" in
			'-F MORS_DNS -w -t nat')
				flush_count=$((flush_count + 1))
				[ "${flush_count}" -eq 1 ]
				;;
			*'-p tcp'*) return 7 ;;
			'-I MORS_DNS 1 -w -t nat -j RETURN') return 8 ;;
			*) return 0 ;;
		esac
	}
	log_warning() { :; }
	error() { printf 'error:%s\n' "$*" >>"${EVENTS}"; }
	TABLE_DNS=nat
	CHAIN_DNS=MORS_DNS
	DNS_PORT=53

	run ip4__dns__create_chain
	[ "${status}" -ne 0 ]
	grep -q '^detach-failed$' "${EVENTS}"
	grep -q '^error:.*Не удалось безопасно отключить частичную DNS-цепочку$' "${EVENTS}"
}

@test "route reconciliation replaces conflicting default routes" {
	load_ndm_function ip4__route__show_table
	load_ndm_function ip4__route__has_canonical_default
	load_ndm_function ip4__route__add_table
	ROUTE_STATE=conflicting
	get_config_value() {
		case "$1" in
			INFACE_ENT) printf '%s\n' t2s21 ;;
			ADDR_MAN) : ;;
		esac
	}
	ip4() {
		case "$*" in
			'route show table 1001')
				if [ "${ROUTE_STATE}" = conflicting ]; then
					printf '%s\n' 'default dev eth0 metric 10' 'default dev t2s21 metric 100'
				else
					printf '%s\n' 'Error: ipv4: FIB table does not exist.' >&2
					return 2
				fi
				;;
			'route flush table 1001')
				printf 'route-flush\n' >>"${EVENTS}"
				ROUTE_STATE=missing
				;;
			'route add table 1001 default dev t2s21') printf 'route-add\n' >>"${EVENTS}" ;;
			*) return 9 ;;
		esac
	}
	ip4__route__flush_cache() { printf 'cache-flush\n' >>"${EVENTS}"; }
	log_warning() { :; }
	error() { :; }
	ROUTE_TABLE_ID=1001
	PROXY_VLESS_ENTWARE=t2s21

	run ip4__route__add_table
	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = $'route-flush\nroute-add\ncache-flush' ]
}

@test "add probes stop on iptables snapshot errors without inserting jumps" {
	load_ndm_function ip4__add_routing_for_home
	load_ndm_function ip4__dns__add_routing
	load_ndm_function ip4__add_routing
	save_iptables() { return 9; }
	ip4__dns__create_chain() { return 0; }
	get_local_inface() { printf '%s\n' br0; }
	iptab() { printf 'iptables:%s\n' "$*" >>"${EVENTS}"; }
	log_warning() { :; }
	IPSET_TABLE_NAME=MORS_LIST
	CHAIN_DNS=MORS_DNS
	TABLE_DNS=nat

	run ip4__add_routing_for_home mangle MORS_MARK VPN
	[ "${status}" -ne 0 ]
	run ip4__dns__add_routing '-i br0'
	[ "${status}" -ne 0 ]
	run ip4__add_routing mangle MORS_MARK '-i br0'
	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}
