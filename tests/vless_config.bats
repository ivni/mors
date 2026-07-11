#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	export VLESS_STORE_ROOT="${BATS_TEST_TMPDIR}/store"
	export VLESS_REGISTRY_FILE="${VLESS_STORE_ROOT}/registry.json"
	export VLESS_CONNECTIONS_DIR="${VLESS_STORE_ROOT}/connections"
	export VLESS_XRAY_CONFIG_FILE="${BATS_TEST_TMPDIR}/mors.json"
	source "${REPO_ROOT}/opt/bin/libs/vless_config"
}

secret_json() {
	local address="${1}"
	jq -n --arg address "${address}" '{
		user_id: "00000000-0000-4000-8000-000000000000",
		address: $address,
		port: 443,
		network: "tcp",
		security: "reality",
		public_key: "ioE61VC3V30U7IdRmQ3bjhOq2ij9tPhVIgAD4JZ4YRY",
		fingerprint: "chrome",
		server_name: "example.com",
		short_id: "0123456789abcdef",
		flow: "xtls-rprx-vision",
		spider_x: "/",
		encryption: "none"
	}'
}

@test "parser extracts Reality fields and suggested name" {
	local link='vless://00000000-0000-4000-8000-000000000000@192.0.2.10:443?type=tcp&security=reality&pbk=ioE61VC3V30U7IdRmQ3bjhOq2ij9tPhVIgAD4JZ4YRY&fp=chrome&sni=example.com&sid=0123456789abcdef&flow=xtls-rprx-vision#%D0%A4%D0%B8%D0%BD%D0%BB%D1%8F%D0%BD%D0%B4%D0%B8%D1%8F'

	vless_uri__parse "${link}" >"${BATS_TEST_TMPDIR}/parsed.json"
	output=$(cat "${BATS_TEST_TMPDIR}/parsed.json")
	[ "$(printf '%s\n' "${output}" | jq -r '.address')" = 192.0.2.10 ]
	[ "$(printf '%s\n' "${output}" | jq -r '.port')" -eq 443 ]
	[ "${VLESS_PARSED_NAME}" = "Финляндия" ]
}

@test "parser supports a bracketed IPv6 server" {
	local link='vless://00000000-0000-4000-8000-000000000000@[2001:db8::10]:8443?type=tcp&security=reality&pbk=ioE61VC3V30U7IdRmQ3bjhOq2ij9tPhVIgAD4JZ4YRY&fp=chrome&sni=example.com&sid=0123456789abcdef'

	run vless_uri__parse "${link}"
	[ "${status}" -eq 0 ]
	[ "$(printf '%s\n' "${output}" | jq -r '.address')" = '2001:db8::10' ]
	[ "$(printf '%s\n' "${output}" | jq -r '.port')" -eq 8443 ]
}

@test "parser rejects unsupported transports" {
	local link='vless://00000000-0000-4000-8000-000000000000@192.0.2.10:443?type=grpc&security=reality&pbk=key&fp=chrome&sni=example.com&sid=0123456789abcdef'

	run vless_uri__parse "${link}"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *"только транспорт tcp"* ]]
}

@test "generator creates one production and one probe inbound per enabled connection" {
	vless_store__ensure
	secret_json 192.0.2.10 | vless_store__write_secret vless-a
	secret_json 192.0.2.11 | vless_store__write_secret vless-b
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972

	vless_config__generate "${VLESS_XRAY_CONFIG_FILE}" vless-a

	[ "$(jq '[.inbounds[] | select(.tag == "mors-vless-in")] | length' "${VLESS_XRAY_CONFIG_FILE}")" -eq 1 ]
	[ "$(jq '[.inbounds[] | select(.tag | startswith("mors-vless-probe-"))] | length' "${VLESS_XRAY_CONFIG_FILE}")" -eq 2 ]
	[ "$(jq '[.outbounds[] | select(.protocol == "vless")] | length' "${VLESS_XRAY_CONFIG_FILE}")" -eq 2 ]
	[ "$(jq -r '.routing.balancers[0].fallbackTag' "${VLESS_XRAY_CONFIG_FILE}")" = mors-vless-vless-a ]
	[ "$(jq -r '.api.listen' "${VLESS_XRAY_CONFIG_FILE}")" = 127.0.0.1:10085 ]
}

@test "generator produces a fail-closed paused config with no enabled connection" {
	vless_store__ensure
	vless_config__generate "${VLESS_XRAY_CONFIG_FILE}" ''

	[ "$(jq -r '.routing.rules[0].outboundTag' "${VLESS_XRAY_CONFIG_FILE}")" = mors-block ]
	[ "$(jq '.routing.balancers // [] | length' "${VLESS_XRAY_CONFIG_FILE}")" -eq 0 ]
}

@test "global pause keeps enabled choices but generates a fail-closed config" {
	vless_store__ensure
	secret_json 192.0.2.10 | vless_store__write_secret vless-a
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__set_paused true

	vless_config__generate "${VLESS_XRAY_CONFIG_FILE}" vless-a

	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
	[ "$(jq '[.outbounds[] | select(.protocol == "vless")] | length' "${VLESS_XRAY_CONFIG_FILE}")" -eq 0 ]
	[ "$(jq -r '.routing.rules[0].outboundTag' "${VLESS_XRAY_CONFIG_FILE}")" = mors-block ]
}
