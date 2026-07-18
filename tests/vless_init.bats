#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	INIT_SCRIPT="${REPO_ROOT}/opt/etc/init.d/S25mors-vless"
	TEST_ROOT="${BATS_TEST_TMPDIR}/vless-init"
	PROGRAM="${TEST_ROOT}/fake-supervisor"
	PID_FILE="${TEST_ROOT}/run/supervisor.pid"
	LOCK_DIR="${TEST_ROOT}/run/supervisor.lock"
	LIFECYCLE_ROOT="${TEST_ROOT}/lifecycle"
	mkdir -p "${TEST_ROOT}" "${LIFECYCLE_ROOT}"
	printf '%s\n' '{"schema_version":1,"state":"ready","updated_at":"2026-07-18T00:00:00Z","source":"test"}' >"${LIFECYCLE_ROOT}/state.json"
	cat >"${PROGRAM}" <<'EOF'
#!/bin/sh
mkdir -p "${VLESS_SUPERVISOR_LOCK_DIR}"
cleanup() {
	rm -f "${VLESS_SUPERVISOR_PID_FILE}"
	rmdir "${VLESS_SUPERVISOR_LOCK_DIR}" 2>/dev/null || true
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT
while :; do sleep 1; done
EOF
	chmod +x "${PROGRAM}"
}

teardown() {
	run_init stop >/dev/null 2>&1 || true
	[ -z "${UNRELATED_PID:-}" ] || kill "${UNRELATED_PID}" 2>/dev/null || true
	[ -z "${ONCE_PID:-}" ] || kill "${ONCE_PID}" 2>/dev/null || true
}

run_init() {
	env \
		MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs" \
		MORS_LIFECYCLE_ROOT="${LIFECYCLE_ROOT}" \
		MORS_LIFECYCLE_STATE_FILE="${LIFECYCLE_ROOT}/state.json" \
		MORS_LIFECYCLE_ACTIVE_FILE="${LIFECYCLE_ROOT}/active" \
		VLESS_SUPERVISOR_PROGRAM="${PROGRAM}" \
		VLESS_SUPERVISOR_PID_FILE="${PID_FILE}" \
		VLESS_SUPERVISOR_LOCK_DIR="${LOCK_DIR}" \
		VLESS_SUPERVISOR_WAIT_STEPS=30 \
		VLESS_SUPERVISOR_WAIT_DELAY=0.1 \
		"${INIT_SCRIPT}" "$@"
}

@test "init status, restart and stop manage the shell supervisor by its PID file" {
	run run_init start
	[ "${status}" -eq 0 ]

	run run_init status
	[ "${status}" -eq 0 ]
	[[ "${output}" == *alive.* ]]
	first_pid=$(<"${PID_FILE}")

	run run_init restart
	[ "${status}" -eq 0 ]
	second_pid=$(<"${PID_FILE}")
	[ "${first_pid}" != "${second_pid}" ]
	! kill -0 "${first_pid}" 2>/dev/null

	run run_init stop
	[ "${status}" -eq 0 ]
	[ ! -e "${PID_FILE}" ]
	[ ! -e "${LOCK_DIR}" ]

	run run_init status
	[ "${status}" -eq 1 ]
	[[ "${output}" == *dead.* ]]
}

@test "stale reused PID never signals an unrelated process" {
	sleep 30 &
	UNRELATED_PID=$!
	mkdir -p "$(dirname "${PID_FILE}")" "${LOCK_DIR}"
	printf '%s\n' "${UNRELATED_PID}" >"${PID_FILE}"

	run run_init status
	[ "${status}" -eq 1 ]
	kill -0 "${UNRELATED_PID}"

	run run_init stop
	[ "${status}" -eq 0 ]
	kill -0 "${UNRELATED_PID}"
	[ ! -e "${PID_FILE}" ]
	[ ! -e "${LOCK_DIR}" ]
}

@test "stop does not signal or unlock a concurrent one-off supervisor" {
	"${PROGRAM}" once &
	ONCE_PID=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		tr '\000' '\n' <"/proc/${ONCE_PID}/cmdline" | grep -F -x "${PROGRAM}" >/dev/null && break
		sleep 0.1
	done
	mkdir -p "$(dirname "${PID_FILE}")" "${LOCK_DIR}"
	printf '%s\n' "${ONCE_PID}" >"${PID_FILE}"

	run run_init stop
	[ "${status}" -eq 0 ]
	kill -0 "${ONCE_PID}"
	[ -e "${PID_FILE}" ]
	[ -d "${LOCK_DIR}" ]
}
