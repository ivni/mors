#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	export MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	export TELEMETRY_CONFIG_ROOT="${BATS_TEST_TMPDIR}/etc"
	export TELEMETRY_CONFIG_FILE="${TELEMETRY_CONFIG_ROOT}/config.json"
	export TELEMETRY_KEY_FILE="${TELEMETRY_CONFIG_ROOT}/monium.key"
	export TELEMETRY_CURL_CONFIG="${TELEMETRY_CONFIG_ROOT}/curl.conf"
	export TELEMETRY_STATE_ROOT="${BATS_TEST_TMPDIR}/run"
	export TELEMETRY_STATE_FILE="${TELEMETRY_STATE_ROOT}/state.json"
	export TELEMETRY_DATA_ROOT="${BATS_TEST_TMPDIR}/data"
	export TELEMETRY_QUEUE_FILE="${TELEMETRY_DATA_ROOT}/outbox.jsonl"
	export TELEMETRY_PID_FILE="${TELEMETRY_STATE_ROOT}/sender.pid"
	export TELEMETRY_PROCESS_LOCK_DIR="${TELEMETRY_STATE_ROOT}/sender.lock"
	export TELEMETRY_SENDER_PROGRAM="${BATS_TEST_TMPDIR}/fake-sender"
	export TELEMETRY_SENDER_ARGUMENT=run
	export TELEMETRY_INIT_WAIT_STEPS=5
	export TELEMETRY_INIT_WAIT_DELAY=1
	export MORS_LIFECYCLE_ROOT="${BATS_TEST_TMPDIR}/lifecycle"
	export MORS_LIFECYCLE_STATE_FILE="${MORS_LIFECYCLE_ROOT}/state.json"
	export MORS_LIFECYCLE_TRANSACTION_ROOT="${MORS_LIFECYCLE_ROOT}/transactions"
	export MORS_LIFECYCLE_ACTIVE_FILE="${MORS_LIFECYCLE_ROOT}/active"
	export MORS_LIFECYCLE_CONF_FILE="${BATS_TEST_TMPDIR}/mors.conf"
	export MORS_LIFECYCLE_LEGACY_START_FILE="${BATS_TEST_TMPDIR}/S96mors"
	mkdir -p "${MORS_LIFECYCLE_ROOT}"
	printf '%s\n' '{"schema_version":1,"state":"ready","updated_at":"2026-07-18T18:00:00Z","source":"test"}' >"${MORS_LIFECYCLE_STATE_FILE}"
	printf '%s\n' 'SETUP_FINISHED=true' 'INFACE_CLI=Proxy21' >"${MORS_LIFECYCLE_CONF_FILE}"
	. "${MORS_LIB_DIR}/telemetry_store"
	telemetry_store__write_config folder__test home mors true aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_key "${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_curl_config
}

teardown() {
	if [ -r "${TELEMETRY_PID_FILE}" ]; then
		pid=$(cat "${TELEMETRY_PID_FILE}")
		kill -TERM "${pid}" 2>/dev/null || true
	fi
}

@test "process validation rejects a reused pid with different argv" {
	export TELEMETRY_PROCESS_ROOT="${BATS_TEST_TMPDIR}/proc"
	mkdir -p "${TELEMETRY_PROCESS_ROOT}/123"
	printf '/bin/sh\0/other/program\0%s\0run\0' "${TELEMETRY_SENDER_PROGRAM}" >"${TELEMETRY_PROCESS_ROOT}/123/cmdline"
	. "${MORS_LIB_DIR}/telemetry_process"
	run telemetry_process__pid_is_sender 123
	[ "${status}" -ne 0 ]
}

@test "fresh metadata-free process lock is not reclaimed" {
	mkdir -p "${TELEMETRY_PROCESS_LOCK_DIR}"
	. "${MORS_LIB_DIR}/telemetry_process"
	run telemetry_process__cleanup_stale
	[ "${status}" -ne 0 ]
	[ -d "${TELEMETRY_PROCESS_LOCK_DIR}" ]
}

@test "process acquire never follows a symlink at the pid path" {
	mkdir -p "$(dirname "${TELEMETRY_PID_FILE}")"
	printf '%s\n' keep-me >"${BATS_TEST_TMPDIR}/target"
	ln -s "${BATS_TEST_TMPDIR}/target" "${TELEMETRY_PID_FILE}"
	. "${MORS_LIB_DIR}/telemetry_process"
	run telemetry_process__acquire
	[ "${status}" -ne 0 ]
	[ "$(cat "${BATS_TEST_TMPDIR}/target")" = keep-me ]
	[ -L "${TELEMETRY_PID_FILE}" ]
}

@test "init starts and stops only the validated telemetry sender" {
	cat >"${TELEMETRY_SENDER_PROGRAM}" <<'SH'
#!/bin/sh
. "${MORS_LIB_DIR}/telemetry_process"
telemetry_process__acquire || exit 1
trap 'telemetry_process__release; exit 0' INT TERM EXIT
while :; do sleep 1; done
SH
	chmod +x "${TELEMETRY_SENDER_PROGRAM}"

	run sh "${REPO_ROOT}/opt/etc/init.d/S98mors-telemetry" start
	[ "${status}" -eq 0 ]
	. "${MORS_LIB_DIR}/telemetry_process"
	pid=$(telemetry_process__running_pid)
	[ -n "${pid}" ]
	run sh "${REPO_ROOT}/opt/etc/init.d/S98mors-telemetry" stop
	[ "${status}" -eq 0 ]
	run telemetry_process__running_pid
	[ "${status}" -ne 0 ]
}

@test "init remains passive when telemetry is disabled" {
	telemetry_store__set_enabled false
	printf '%s\n' '#!/bin/sh' 'exit 99' >"${TELEMETRY_SENDER_PROGRAM}"
	chmod +x "${TELEMETRY_SENDER_PROGRAM}"
	run sh "${REPO_ROOT}/opt/etc/init.d/S98mors-telemetry" start
	[ "${status}" -eq 0 ]
	[ ! -e "${TELEMETRY_PID_FILE}" ]
}
