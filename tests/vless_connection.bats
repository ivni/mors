#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source <(sed '/^\. \/opt\/apps\/mors\/bin\/libs\//d' "${REPO_ROOT}/opt/bin/libs/vless")

	PROXY_LOCAL_IP=127.0.0.1
	PROXY_VLESS_PORT=1097
	PROXY_VLESS_DESC=Mors-proxy-vless
	DOMAIN_FOR_CHECK=https://ifconfig.me/ip
	IP_FILTER='[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'

	ready() { :; }
	when_ok() { printf '%s\n' "$*"; }
	when_bad() { printf '%s\n' "$*"; }
	error() { printf '%s\n' "$*"; }
	print_line() { :; }
	has_xray_enable() { return 0; }
}

@test "VLESS check uses the local Xray SOCKS5 endpoint" {
	curl() {
		[[ " $* " == *" --proxy socks5h://127.0.0.1:1097 "* ]]
		[[ " $* " == *" https://ifconfig.me/ip "* ]]
		printf '%s\n' '203.0.113.7'
	}

	run test_vless_proxy
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"УСПЕШНО (203.0.113.7)"* ]]
}

@test "VLESS check returns curl diagnostics" {
	curl() {
		printf '%s\n' 'curl: (7) Failed to connect'
		return 7
	}

	run test_vless_proxy
	[ "${status}" -eq 1 ]
	[[ "${output}" == *"кодом curl 7"* ]]
	[[ "${output}" == *"Failed to connect"* ]]
}

@test "VLESS check accepts an IPv6 egress address" {
	curl() {
		printf '%s\n' '2001:db8::7'
	}

	run test_vless_proxy
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"УСПЕШНО (2001:db8::7)"* ]]
}

@test "VLESS check fails before curl when Xray is stopped" {
	has_xray_enable() { return 1; }
	curl() { return 99; }

	run test_vless_proxy
	[ "${status}" -eq 1 ]
	[[ "${output}" == *"Сервис Xray не запущен"* ]]
}

@test "legacy Proxy21 adoption changes only its description" {
	LEGACY_PROXY_VLESS_DESC=Kvas-proxy-vless
	PROXY_VLESS_NAME=Proxy21
	PROXY_VLESS_PROTO=socks5
	captured=''
	api_post_query() { captured=$1; }
	delete_proxy_interface() { return 99; }

	rename_proxy_interface "${PROXY_VLESS_DESC}"

	[ "$(jq -r '.[0].interface.name' <<<"${captured}")" = Proxy21 ]
	[ "$(jq -r '.[0].interface.description' <<<"${captured}")" = Mors-proxy-vless ]
	[ "$(jq -r '.[0].interface | keys | sort | join(",")' <<<"${captured}")" = description,name ]
	[ "$(jq -r '.[0].interface.proxy // empty' <<<"${captured}")" = '' ]
}
