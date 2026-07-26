#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	. "${REPO_ROOT}/opt/bin/libs/test_probe"
	. "${REPO_ROOT}/opt/bin/libs/test_tunnel"
	MORS_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_TEST_DEADLINE=$(( $(test_probe__now_seconds) + 30 ))
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

@test "active VLESS snapshot waits for an in-progress supervisor decision" {
	VLESS_STATE_FILE=${BATS_TEST_TMPDIR}/state.json
	VLESS_DECISION_LOCK_DIR=${BATS_TEST_TMPDIR}/decision.lock
	mkdir "${VLESS_DECISION_LOCK_DIR}"
	printf '%s\n' '{"active_id":"connection-1","connections":{"connection-1":{"status":"unstable"}}}' \
		>"${VLESS_STATE_FILE}"
	vless_runtime__active_id() { printf '%s\n' connection-1; }
	sleep() {
		rmdir "${VLESS_DECISION_LOCK_DIR}"
		printf '%s\n' '{"active_id":"connection-1","connections":{"connection-1":{"status":"active"}}}' \
			>"${VLESS_STATE_FILE}"
	}
	MORS_TEST_ACTIVE_KIND=vless
	test_tunnel__active_status
	[ "${MORS_PROBE_STATUS}" = working ]
	[ "${MORS_TEST_ACTIVE_ID}" = connection-1 ]
}

@test "active VLESS id is retained when the health snapshot is unavailable" {
	VLESS_STATE_FILE=${BATS_TEST_TMPDIR}/state.json
	VLESS_DECISION_LOCK_DIR=${BATS_TEST_TMPDIR}/missing-decision.lock
	printf '%s\n' '{"active_id":"connection-1","connections":{"connection-1":{"status":"unavailable"}}}' \
		>"${VLESS_STATE_FILE}"
	vless_runtime__active_id() { printf '%s\n' connection-1; }
	MORS_TEST_ACTIVE_KIND=vless
	! test_tunnel__active_status
	[ "${MORS_TEST_ACTIVE_ID}" = connection-1 ]
}
