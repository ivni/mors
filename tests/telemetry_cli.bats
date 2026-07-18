#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	export MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	export TELEMETRY_CONFIG_ROOT="${BATS_TEST_TMPDIR}/etc"
	export TELEMETRY_CONFIG_FILE="${TELEMETRY_CONFIG_ROOT}/config.json"
	export TELEMETRY_KEY_FILE="${TELEMETRY_CONFIG_ROOT}/monium.key"
	export TELEMETRY_CURL_CONFIG="${TELEMETRY_CONFIG_ROOT}/curl.conf"
	export TELEMETRY_CURSOR_FILE="${TELEMETRY_CONFIG_ROOT}/cursor"
	export TELEMETRY_STATE_ROOT="${BATS_TEST_TMPDIR}/run"
	export TELEMETRY_STATE_FILE="${TELEMETRY_STATE_ROOT}/state.json"
	export TELEMETRY_DATA_ROOT="${BATS_TEST_TMPDIR}/data"
	export TELEMETRY_QUEUE_FILE="${TELEMETRY_DATA_ROOT}/outbox.jsonl"
	export TELEMETRY_ADMIN_LOCK_DIR="${BATS_TEST_TMPDIR}/admin.lock"
	export TELEMETRY_PROCESS_ROOT="${BATS_TEST_TMPDIR}/proc"
	export TELEMETRY_PID_FILE="${TELEMETRY_STATE_ROOT}/sender.pid"
	export TELEMETRY_PROCESS_LOCK_DIR="${TELEMETRY_STATE_ROOT}/sender.lock"
	export TELEMETRY_INIT="${BATS_TEST_TMPDIR}/init/S98mors-telemetry"
	export TELEMETRY_INIT_SOURCE="${BATS_TEST_TMPDIR}/fake-init"
	export TELEMETRY_SENDER_PROGRAM="${BATS_TEST_TMPDIR}/fake-sender"
	export MORS_LIFECYCLE_ROOT="${BATS_TEST_TMPDIR}/lifecycle"
	export MORS_LIFECYCLE_LOCK_DIR="${BATS_TEST_TMPDIR}/lifecycle.lock"
	export MORS_LIFECYCLE_STATE_FILE="${MORS_LIFECYCLE_ROOT}/state.json"
	export MORS_LIFECYCLE_TRANSACTION_ROOT="${MORS_LIFECYCLE_ROOT}/transactions"
	export MORS_LIFECYCLE_ACTIVE_FILE="${MORS_LIFECYCLE_ROOT}/active"
	export MORS_LIFECYCLE_CONF_FILE="${BATS_TEST_TMPDIR}/mors.conf"
	export MORS_LIFECYCLE_LEGACY_START_FILE="${BATS_TEST_TMPDIR}/S96mors"
	export VLESS_EVENTS_FILE="${BATS_TEST_TMPDIR}/events.jsonl"
	mkdir -p "${MORS_LIFECYCLE_ROOT}" "$(dirname "${TELEMETRY_INIT}")"
	printf '%s\n' '{"schema_version":1,"state":"ready","updated_at":"2026-07-18T18:00:00Z","source":"test"}' >"${MORS_LIFECYCLE_STATE_FILE}"
	printf '%s\n' 'SETUP_FINISHED=true' 'INFACE_CLI=Proxy21' >"${MORS_LIFECYCLE_CONF_FILE}"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"${TELEMETRY_INIT_SOURCE}"
	printf '%s\n' '#!/bin/sh' 'exit 0' >"${TELEMETRY_SENDER_PROGRAM}"
	chmod +x "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_SENDER_PROGRAM}"
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/key"
	. "${MORS_LIB_DIR}/lifecycle_state"
	. "${MORS_LIB_DIR}/telemetry"
}

@test "noninteractive enable requires explicit confirmation" {
	run cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key"
	[ "${status}" -eq 64 ]
	[ ! -e "${TELEMETRY_CONFIG_FILE}" ]
}

@test "successful enable persists protected config and activates init service" {
	run cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	[ "${status}" -eq 0 ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = true ]
	[ -L "${TELEMETRY_INIT}" ]
	data=$(cmd_telemetry_status --json)
	[ "$(printf '%s\n' "${data}" | jq -r '.project')" = folder__test ]
	[ "$(printf '%s\n' "${data}" | jq -r '.queue_overflow')" = false ]
	[ "$(printf '%s\n' "${data}" | jq -r '.dropped_samples')" -eq 0 ]
	! printf '%s\n' "${data}" | grep -q AQVN
	run cmd_telemetry_status
	[ "${status}" -eq 0 ]
	[[ "${output}" == *'ОШИБКА: SENDER НЕ РАБОТАЕТ'* ]]
}

@test "failed test delivery leaves initial configuration disabled" {
	printf '%s\n' '#!/bin/sh' 'exit 1' >"${TELEMETRY_SENDER_PROGRAM}"
	chmod +x "${TELEMETRY_SENDER_PROGRAM}"
	run cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	[ "${status}" -eq 2 ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
	[ ! -e "${TELEMETRY_INIT}" ]
}

@test "failed retest preserves an existing enabled configuration" {
	cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	printf '%s\n' '#!/bin/sh' 'exit 1' >"${TELEMETRY_SENDER_PROGRAM}"
	chmod +x "${TELEMETRY_SENDER_PROGRAM}"
	run cmd_telemetry_enable monium --yes
	[ "${status}" -eq 2 ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = true ]
	[ -L "${TELEMETRY_INIT}" ]
}

@test "enable never overwrites an unexpected init hook" {
	printf '%s\n' 'operator-owned' >"${TELEMETRY_INIT}"
	run cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	[ "${status}" -eq 1 ]
	[ "$(cat "${TELEMETRY_INIT}")" = operator-owned ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
}

@test "disable never executes or removes an unexpected init hook" {
	cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	rm -f "${TELEMETRY_INIT}"
	cat >"${TELEMETRY_INIT}" <<EOF
#!/bin/sh
touch '${BATS_TEST_TMPDIR}/unexpected-executed'
EOF
	chmod +x "${TELEMETRY_INIT}"
	run cmd_telemetry_disable --yes
	[ "${status}" -eq 4 ]
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
	[ -f "${TELEMETRY_INIT}" ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
}

@test "enable is rejected while a lifecycle mutation owns the outer lock" {
	mkdir -p "${MORS_LIFECYCLE_LOCK_DIR}"
	printf '%s\n' "$$" >"${MORS_LIFECYCLE_LOCK_DIR}/pid"
	printf '%s\n' other-operation >"${MORS_LIFECYCLE_LOCK_DIR}/token"
	run cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	[ "${status}" -eq 3 ]
	[ ! -e "${TELEMETRY_CONFIG_FILE}" ]
}

@test "purge disable removes credentials queue and init hook" {
	cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	printf '%s\n' '{}' >"${TELEMETRY_QUEUE_FILE}"
	run cmd_telemetry_disable --purge --yes
	[ "${status}" -eq 0 ]
	[ ! -e "${TELEMETRY_CONFIG_ROOT}" ]
	[ ! -e "${TELEMETRY_INIT}" ]
}

@test "status rejects a corrupt derived state without exposing config" {
	cmd_telemetry_enable monium --project folder__test --key-file "${BATS_TEST_TMPDIR}/key" --yes
	printf '%s\n' '{"schema_version":1,"last_attempt_at":"2026-07-19T00:00:00Z","last_success_at":null,"last_error":"AQVN_SECRET","last_http_code":null,"queue_depth":0}' >"${TELEMETRY_STATE_FILE}"
	run cmd_telemetry_status --json
	[ "${status}" -eq 4 ]
	! printf '%s\n' "${output}" | grep -q AQVN
}
