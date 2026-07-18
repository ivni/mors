#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	. "${REPO_ROOT}/opt/bin/libs/test_probe"
	. "${REPO_ROOT}/opt/bin/libs/test_tunnel"
	VLESS_REGISTRY_FILE=${BATS_TEST_TMPDIR}/missing-registry.json
	SHADOWSOCKS_CONF=${BATS_TEST_TMPDIR}/shadowsocks.json
	MORS_TEST_ACTIVE_KIND=vless
	MORS_TEST_ACTIVE_ID=vless-active
	MORS_TEST_DEADLINE=$(( $(test_probe__now_seconds) + 30 ))
}

@test "inventory excludes disabled VLESS connections" {
	VLESS_REGISTRY_FILE=${BATS_TEST_TMPDIR}/registry.json
	cat >"${VLESS_REGISTRY_FILE}" <<'JSON'
{"connections":[
  {"id":"enabled","enabled":true,"probe_port":11001},
  {"id":"disabled","enabled":false,"probe_port":11002}
]}
JSON
	MORS_TEST_CURL=false
	run test_tunnel__inventory
	[ "${status}" -eq 0 ]
	printf '%s\n' "${output}" | jq -e 'select(.id == "enabled")' >/dev/null
	! printf '%s\n' "${output}" | jq -e 'select(.id == "disabled")' >/dev/null
}

@test "inventory ignores an unconfigured Shadowsocks template" {
	cat >"${SHADOWSOCKS_CONF}" <<'JSON'
{"server":"127.0.0.1","server_port":8388,"password":"barfoo!","method":"aes-256-gcm"}
JSON
	! test_tunnel__shadowsocks_configured
	MORS_TEST_CURL=false
	run test_tunnel__inventory
	[ "${status}" -eq 0 ]
	! printf '%s\n' "${output}" | jq -e 'select(.id == "shadowsocks")' >/dev/null
}

@test "inventory includes a configured Shadowsocks client" {
	cat >"${SHADOWSOCKS_CONF}" <<'JSON'
{"server":"example.invalid","server_port":8388,"password":"secret-value","method":"aes-256-gcm"}
JSON
	test_tunnel__shadowsocks_configured
	MORS_TEST_CURL=false
	run test_tunnel__inventory
	[ "${status}" -eq 0 ]
	printf '%s\n' "${output}" | jq -e 'select(.id == "shadowsocks" and .desired == "enabled")' >/dev/null
}

@test "inventory accepts Keenetic object RCI without jq regex support" {
	local mock_curl=${BATS_TEST_TMPDIR}/curl
	cat >"${mock_curl}" <<'SH'
#!/bin/sh
cat <<'JSON'
{"Proxy21":{"id":"Proxy21","type":"Proxy","state":"up","interface-name":"Proxy21"},"Wireguard0":{"id":"Wireguard0","type":"Wireguard","role":"client","up":true,"state":"up","interface-name":"nwg0"},"OpenVPN0":{"id":"OpenVPN0","type":"OpenVPN","role":"server","up":true,"state":"up","interface-name":"ovpn0"}}
JSON
SH
	chmod +x "${mock_curl}"
	MORS_TEST_CURL=${mock_curl}
	run test_tunnel__inventory
	[ "${status}" -eq 0 ]
	printf '%s\n' "${output}" | jq -e 'select(.id == "Wireguard0" and .device == "nwg0")' >/dev/null
	! printf '%s\n' "${output}" | jq -e 'select(.id == "Proxy21" or .id == "OpenVPN0" or .kind == "inventory_error")' >/dev/null
}
