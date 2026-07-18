#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	export MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	export TELEMETRY_CONFIG_ROOT="${BATS_TEST_TMPDIR}/etc/telemetry"
	export TELEMETRY_CONFIG_FILE="${TELEMETRY_CONFIG_ROOT}/config.json"
	export TELEMETRY_KEY_FILE="${TELEMETRY_CONFIG_ROOT}/monium.key"
	export TELEMETRY_CURL_CONFIG="${TELEMETRY_CONFIG_ROOT}/curl.conf"
	export TELEMETRY_CURSOR_FILE="${TELEMETRY_CONFIG_ROOT}/cursor"
	export TELEMETRY_STATE_ROOT="${BATS_TEST_TMPDIR}/run"
	export TELEMETRY_STATE_FILE="${TELEMETRY_STATE_ROOT}/state.json"
	export TELEMETRY_DATA_ROOT="${BATS_TEST_TMPDIR}/data"
	export TELEMETRY_QUEUE_FILE="${TELEMETRY_DATA_ROOT}/outbox.jsonl"
	export TELEMETRY_INIT="${BATS_TEST_TMPDIR}/init/S98mors-telemetry"
	export TELEMETRY_INIT_SOURCE="${BATS_TEST_TMPDIR}/packaged-init"
	export MORS_TELEMETRY_INIT="${TELEMETRY_INIT}"
	export MORS_TELEMETRY_INIT_SOURCE="${TELEMETRY_INIT_SOURCE}"
	export TELEMETRY_PID_FILE="${BATS_TEST_TMPDIR}/pid/sender.pid"
	export TELEMETRY_PROCESS_LOCK_DIR="${BATS_TEST_TMPDIR}/pid/sender.lock"
	export TELEMETRY_PROCESS_ROOT="${BATS_TEST_TMPDIR}/proc"
	export TELEMETRY_ADMIN_LOCK_DIR="${BATS_TEST_TMPDIR}/pid/admin.lock"
	export MORS_LIFECYCLE_LOCK_DIR="${BATS_TEST_TMPDIR}/lifecycle.lock"
	export MORS_LIFECYCLE_ROOT="${BATS_TEST_TMPDIR}/lifecycle"
	export MORS_LIFECYCLE_STATE_FILE="${MORS_LIFECYCLE_ROOT}/state.json"
	export MORS_LIFECYCLE_TRANSACTION_ROOT="${MORS_LIFECYCLE_ROOT}/transactions"
	export MORS_LIFECYCLE_ACTIVE_FILE="${MORS_LIFECYCLE_ROOT}/active"
	export SERVICE_STATE_FILE="${BATS_TEST_TMPDIR}/service-state"
	mkdir -p "$(dirname "${TELEMETRY_INIT}")" "${MORS_LIFECYCLE_ROOT}"
	cat >"${TELEMETRY_INIT_SOURCE}" <<'SH'
#!/bin/sh
case "${1:-}" in
	status) [ "$(cat "${SERVICE_STATE_FILE}" 2>/dev/null)" = running ] && echo alive || echo dead ;;
	start|restart) printf '%s\n' running >"${SERVICE_STATE_FILE}" ;;
	stop|kill) printf '%s\n' stopped >"${SERVICE_STATE_FILE}" ;;
	*) exit 2 ;;
esac
SH
	chmod +x "${TELEMETRY_INIT_SOURCE}"
	printf '%s\n' stopped >"${SERVICE_STATE_FILE}"
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/key"
	. "${MORS_LIB_DIR}/lifecycle_state"
	. "${MORS_LIB_DIR}/lifecycle_snapshot"
	. "${MORS_LIB_DIR}/telemetry"
}

prepare_config() {
	telemetry_store__write_config folder__test home mors true aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	telemetry_store__write_key "${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_curl_config
	printf '%s\n' cursor-value >"${TELEMETRY_CURSOR_FILE}"
	chmod 600 "${TELEMETRY_CURSOR_FILE}"
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
}

begin_snapshot() {
	lifecycle_state__write ready test
	lifecycle_transaction__begin upgrade ready ready >/dev/null
	lifecycle_snapshot__files() { printf '%s\n' "${TELEMETRY_INIT}"; }
	lifecycle_snapshot__directories() { printf '%s\n' "${TELEMETRY_CONFIG_ROOT}"; }
	lifecycle_snapshot__services() { printf '%s\n' "${TELEMETRY_INIT}"; }
}

@test "package and core setup remain passive until telemetry enable" {
	run grep -F '/opt/etc/init.d/S98mors-telemetry' "${REPO_ROOT}/Makefile"
	[ "${status}" -ne 0 ]
	setup_body=$(sed -n '/^setup__activate_core_hooks()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")
	! printf '%s\n' "${setup_body}" | grep -q S98mors-telemetry
}

@test "uninstall deactivates telemetry before stopping data-plane services" {
	uninstall_body=$(sed -n '/^setup__cmd_uninstall_unlocked()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")
	telemetry_line=$(printf '%s\n' "${uninstall_body}" | grep -n 'telemetry_lifecycle__deactivate' | head -n 1 | cut -d: -f1)
	vless_line=$(printf '%s\n' "${uninstall_body}" | grep -n 'vless_runtime__supervisor_service stop' | head -n 1 | cut -d: -f1)
	[ "${telemetry_line}" -lt "${vless_line}" ]
}

@test "snapshot restores protected telemetry credentials hook cursor and running service" {
	prepare_config
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	begin_snapshot
	lifecycle_snapshot__capture

	rm -f "${TELEMETRY_INIT}"
	rm -rf "${TELEMETRY_CONFIG_ROOT}"
	printf '%s\n' stopped >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore

	[ -L "${TELEMETRY_INIT}" ]
	[ "$(readlink "${TELEMETRY_INIT}")" = "${TELEMETRY_INIT_SOURCE}" ]
	[ "$(jq -r '.project' "${TELEMETRY_CONFIG_FILE}")" = folder__test ]
	[ "$(cat "${TELEMETRY_CURSOR_FILE}")" = cursor-value ]
	[ "$(stat -c '%a' "${TELEMETRY_CONFIG_ROOT}")" = 700 ]
	[ "$(stat -c '%a' "${TELEMETRY_KEY_FILE}")" = 600 ]
	[ "$(cat "${SERVICE_STATE_FILE}")" = running ]
}

@test "snapshot restores stopped telemetry without starting it" {
	prepare_config
	begin_snapshot
	lifecycle_snapshot__capture
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
}

@test "snapshot preserves a missing telemetry hook" {
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore
	[ ! -e "${TELEMETRY_INIT}" ]
	[ ! -L "${TELEMETRY_INIT}" ]
}

@test "snapshot never executes or replaces an unexpected telemetry hook" {
	cat >"${TELEMETRY_INIT}" <<EOF
#!/bin/sh
touch '${BATS_TEST_TMPDIR}/unexpected-executed'
EOF
	chmod +x "${TELEMETRY_INIT}"
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
	printf '%s\n' operator-updated >"${TELEMETRY_INIT}"
	lifecycle_snapshot__restore
	[ "$(cat "${TELEMETRY_INIT}")" = operator-updated ]
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
}

@test "dedicated upgrade restore restarts a previously running managed sender" {
	prepare_config
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	begin_snapshot
	lifecycle_snapshot__capture
	printf '%s\n' stopped >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore_telemetry_service
	[ "$(cat "${SERVICE_STATE_FILE}")" = running ]
}

@test "dedicated upgrade restore keeps a previously stopped managed sender stopped" {
	prepare_config
	begin_snapshot
	lifecycle_snapshot__capture
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore_telemetry_service
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
}

@test "dedicated upgrade restore removes a managed hook absent from the snapshot" {
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	lifecycle_snapshot__restore_telemetry_service
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
	[ ! -e "${TELEMETRY_INIT}" ]
	[ ! -L "${TELEMETRY_INIT}" ]
}

@test "dedicated upgrade restore preserves and never executes an external hook" {
	cat >"${TELEMETRY_INIT}" <<EOF
#!/bin/sh
touch '${BATS_TEST_TMPDIR}/unexpected-executed'
EOF
	chmod +x "${TELEMETRY_INIT}"
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	printf '%s\n' operator-updated >"${TELEMETRY_INIT}"
	lifecycle_snapshot__restore_telemetry_service
	[ "$(cat "${TELEMETRY_INIT}")" = operator-updated ]
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
}

@test "setup rollback with an external hook passes passive runtime verification" {
	printf '%s\n' operator-owned >"${TELEMETRY_INIT}"
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	printf '%s\n' operator-updated >"${TELEMETRY_INIT}"
	lifecycle_snapshot__restore
	telemetry_lifecycle__passive_runtime_removed
	[ "$(cat "${TELEMETRY_INIT}")" = operator-updated ]
}

@test "passive runtime rejects a managed telemetry hook" {
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
	run telemetry_lifecycle__passive_runtime_removed
	[ "${status}" -ne 0 ]
}

@test "passive runtime rejects a validated sender behind an external hook" {
	printf '%s\n' operator-owned >"${TELEMETRY_INIT}"
	telemetry_process__running_pid() { printf '%s\n' 123; }
	run telemetry_lifecycle__passive_runtime_removed
	[ "${status}" -ne 0 ]
}

@test "restore preserves an unexpected telemetry hook that appeared after capture" {
	begin_snapshot
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__capture
	cat >"${TELEMETRY_INIT}" <<EOF
#!/bin/sh
touch '${BATS_TEST_TMPDIR}/unexpected-executed'
EOF
	chmod +x "${TELEMETRY_INIT}"
	run lifecycle_snapshot__restore
	[ "${status}" -ne 0 ]
	[ -f "${TELEMETRY_INIT}" ]
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
}

@test "ordinary teardown stops telemetry and preserves disabled credentials and queue" {
	prepare_config
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	mkdir -p "${TELEMETRY_DATA_ROOT}"
	printf '%s\n' queued >"${TELEMETRY_QUEUE_FILE}"
	telemetry_lifecycle__deactivate false
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
	[ -f "${TELEMETRY_KEY_FILE}" ]
	[ -f "${TELEMETRY_QUEUE_FILE}" ]
	[ ! -e "${TELEMETRY_INIT}" ]
}

@test "full teardown purges telemetry after stopping it" {
	prepare_config
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	telemetry_lifecycle__deactivate true
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
	[ ! -e "${TELEMETRY_CONFIG_ROOT}" ]
	[ ! -e "${TELEMETRY_DATA_ROOT}" ]
	[ ! -e "${TELEMETRY_INIT}" ]
}

@test "teardown preserves an unexpected hook while disabling valid telemetry" {
	prepare_config
	rm -f "${TELEMETRY_INIT}"
	printf '%s\n' operator-owned >"${TELEMETRY_INIT}"
	run telemetry_lifecycle__deactivate false
	[ "${status}" -eq 4 ]
	[ "$(cat "${TELEMETRY_INIT}")" = operator-owned ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
}
