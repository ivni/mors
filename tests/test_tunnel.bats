#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	. "${REPO_ROOT}/opt/bin/libs/test_tunnel"
	MORS_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
}

@test "active tunnel kind comes from the Mors source of truth" {
	printf '%s\n' 'INFACE_CLI=shadowsocks' >"${MORS_CONF_FILE}"
	test_tunnel__detect_active
	[ "${MORS_TEST_ACTIVE_KIND}" = shadowsocks ]
	printf '%s\n' 'INFACE_CLI=Proxy21' >"${MORS_CONF_FILE}"
	test_tunnel__detect_active
	[ "${MORS_TEST_ACTIVE_KIND}" = vless ]
	printf '%s\n' 'INFACE_CLI=Wireguard0' >"${MORS_CONF_FILE}"
	test_tunnel__detect_active
	[ "${MORS_TEST_ACTIVE_KIND}" = keenetic_vpn ]
}

@test "only fixed HTTPS endpoint paths are generated" {
	[ "$(test_tunnel__target_url ifconfig.me)" = https://ifconfig.me/ip ]
	[ "$(test_tunnel__target_url api.ipify.org)" = https://api.ipify.org ]
	run test_tunnel__target_url example.org
	[ "${status}" -ne 0 ]
}
