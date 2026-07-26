#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source <(sed '/^\. \/opt\/apps\/mors\/bin\/libs\//d' "${REPO_ROOT}/opt/bin/libs/vpn")
	DNSCRYPT_CONFIG=${BATS_TEST_TMPDIR}/dnscrypt-proxy.toml
	DNSMASQ_CONFIG=${BATS_TEST_TMPDIR}/dnsmasq.conf
	ERROR_LOG_FILE=${BATS_TEST_TMPDIR}/error.log
	EVENTS=${BATS_TEST_TMPDIR}/events
	export DNSCRYPT_CONFIG DNSMASQ_CONFIG ERROR_LOG_FILE EVENTS
	cat >"${DNSCRYPT_CONFIG}" <<'EOF'
listen_addresses = ['127.0.0.1:53']
ipv6_servers = true
doh_servers = true
require_dnssec = false
block_ipv6 = false
cache = false
cache_min_ttl = 2400
cache_max_ttl = 86400
cache_neg_min_ttl = 60
cache_neg_max_ttl = 600
server_names = ['example']
EOF
	printf '%s\n' '# filter-rr=HTTPS' 'server=9.9.9.9' >"${DNSMASQ_CONFIG}"
	: >"${ERROR_LOG_FILE}"
	: >"${EVENTS}"
	exit_when_adguard_on() { status=0; }
	get_config_value() { [ "$1" = DNS_CRYPT_PORT ] && printf '%s\n' 9153; }
	get_dns_crypt_status() { printf '%s\n' off; }
	ready() { :; }
	when_ok() { :; }
	when_bad() { :; }
	ready_status() { return "$1"; }
	dns_crypt_port_change() { printf 'port:%s:%s\n' "$1" "$2" >>"${EVENTS}"; }
	cmd_mors_init() { printf 'init:%s\n' "$1" >>"${EVENTS}"; }
}

@test "prepare writes a valid local DNSCrypt profile without runtime restart" {
	cmd_dns_crypt_on prepare

	grep -Fq "listen_addresses = ['127.0.0.1:9153']" "${DNSCRYPT_CONFIG}"
	grep -Fq 'ipv6_servers = false' "${DNSCRYPT_CONFIG}"
	grep -Fq 'doh_servers = false' "${DNSCRYPT_CONFIG}"
	grep -Fq 'require_dnssec = true' "${DNSCRYPT_CONFIG}"
	grep -Fq 'block_ipv6 = true' "${DNSCRYPT_CONFIG}"
	grep -Fq 'cache_min_ttl = 5' "${DNSCRYPT_CONFIG}"
	grep -Fq 'cache_max_ttl = 129600' "${DNSCRYPT_CONFIG}"
	grep -Fq '# server_names =' "${DNSCRYPT_CONFIG}"
	[ "$(cat "${EVENTS}")" = 'port:9153:norestart' ]
}

@test "interactive activation performs one runtime init after preparation" {
	cmd_dns_crypt_on runtime

	[ "$(grep -c '^port:9153:norestart$' "${EVENTS}")" -eq 1 ]
	[ "$(grep -c '^init:no$' "${EVENTS}")" -eq 1 ]
}

@test "setup commit propagates every dataplane stage failure" {
	mors_hosts__ensure_readable() { printf '%s\n' hosts >>"${EVENTS}"; }
	has_ssr_enable() { return 1; }
	reset_all_connection() { printf '%s\n' reset >>"${EVENTS}"; }
	update_iptables() { printf '%s\n' iptables >>"${EVENTS}"; return 1; }
	update_ipset() { printf '%s\n' ipset >>"${EVENTS}"; }
	update_adblock() { printf '%s\n' adblock >>"${EVENTS}"; }
	warning() { :; }
	print_line() { :; }
	source <(sed -n '/^cmd_mors_init()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/vpn")

	run cmd_mors_init setup_commit

	[ "${status}" -ne 0 ]
	grep -q '^hosts$' "${EVENTS}"
	grep -q '^reset$' "${EVENTS}"
	grep -q '^iptables$' "${EVENTS}"
	! grep -q '^ipset$' "${EVENTS}"
	! grep -q '^adblock$' "${EVENTS}"
}
