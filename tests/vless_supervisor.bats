#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	export VLESS_STORE_ROOT="${BATS_TEST_TMPDIR}/store"
	export VLESS_REGISTRY_FILE="${VLESS_STORE_ROOT}/registry.json"
	export VLESS_CONNECTIONS_DIR="${VLESS_STORE_ROOT}/connections"
	export VLESS_STATE_ROOT="${BATS_TEST_TMPDIR}/state"
	export VLESS_RUNTIME_ROOT="${BATS_TEST_TMPDIR}/run"
	export VLESS_STATE_FILE="${VLESS_STATE_ROOT}/state.json"
	export VLESS_ACTIVE_FILE="${VLESS_STATE_ROOT}/active"
	export VLESS_EVENTS_FILE="${VLESS_STATE_ROOT}/events.jsonl"
	export VLESS_SUPERVISOR_LIBRARY_ONLY=true
	export VLESS_CONFIRM_DELAY=0
	source "${REPO_ROOT}/opt/bin/main/vless-supervisor"

	vless_store__ensure
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a

	vless_supervisor__xray_ready() { return 0; }
	vless_runtime__override() { OVERRIDDEN_TAG="${1}"; return 0; }
}

@test "confirmed active failure switches to a healthy standby" {
	vless_runtime__probe_connection() {
		if [ "${1}" -eq 11971 ]; then
			VLESS_PROBE_ERROR=timeout
			VLESS_PROBE_LATENCY_MS=null
			return 1
		fi
		VLESS_PROBE_ERROR=''
		VLESS_PROBE_LATENCY_MS=40
		return 0
	}
	vless_supervisor__confirm_active_failure() { return 1; }
	vless_runtime__probe() { VLESS_PROBE_LATENCY_MS=10; VLESS_PROBE_ERROR=''; return 0; }

	run vless_supervisor__once
	[ "$(vless_runtime__active_id)" = vless-b ]
	[ "$(jq -r '.last_switch.reason' "${VLESS_STATE_FILE}")" = health_failure ]
	[ "$(jq -r '.connections["vless-b"].status' "${VLESS_STATE_FILE}")" = active ]
}

@test "a recovered old connection does not trigger automatic failback" {
	vless_runtime__set_active_id vless-b
	vless_runtime__probe_connection() {
		VLESS_PROBE_ERROR=''
		if [ "${1}" -eq 11971 ]; then VLESS_PROBE_LATENCY_MS=20; else VLESS_PROBE_LATENCY_MS=50; fi
		return 0
	}

	run vless_supervisor__once
	[ "$(vless_runtime__active_id)" = vless-b ]
	[ "$(jq -r '.connections["vless-a"].status' "${VLESS_STATE_FILE}")" = standby ]
	[ "$(jq -r '.connections["vless-b"].status' "${VLESS_STATE_FILE}")" = active ]
}

@test "upstream failure does not rotate VLESS connections" {
	vless_runtime__probe_connection() {
		VLESS_PROBE_ERROR=timeout
		VLESS_PROBE_LATENCY_MS=null
		return 1
	}
	vless_supervisor__confirm_active_failure() { return 1; }
	vless_runtime__probe() { VLESS_PROBE_ERROR=upstream; VLESS_PROBE_LATENCY_MS=null; return 1; }

	run vless_supervisor__once
	[ "$(vless_runtime__active_id)" = vless-a ]
	[ "$(jq -r '.upstream_state' "${VLESS_STATE_FILE}")" = down ]
	[ "$(jq -r '.last_switch' "${VLESS_STATE_FILE}")" = null ]
}

@test "direct fallback keeps the recovery choice but clears the current VLESS selection" {
	vless_store__set_direct_fallback true
	vless_runtime__probe_connection() {
		VLESS_PROBE_ERROR=timeout
		VLESS_PROBE_LATENCY_MS=null
		return 1
	}
	vless_supervisor__confirm_active_failure() { return 1; }
	vless_runtime__probe() { VLESS_PROBE_LATENCY_MS=10; VLESS_PROBE_ERROR=''; return 0; }

	run vless_supervisor__once
	[ "${status}" -ne 0 ]
	[ "$(tail -n 1 "${VLESS_EVENTS_FILE}" | jq -r '.to_id')" = mors-direct ]
	[ "$(tail -n 1 "${VLESS_EVENTS_FILE}" | jq -r '.reason')" = direct_fallback ]
	[ "$(jq -r '.overall_state' "${VLESS_STATE_FILE}")" = direct_fallback ]
	[ "$(jq -r '.active_id' "${VLESS_STATE_FILE}")" = null ]
	[ "$(vless_runtime__active_id)" = vless-a ]
}

@test "global pause skips probes and preserves last active connection" {
	vless_store__set_paused true
	vless_runtime__probe_connection() { return 99; }

	run vless_supervisor__once
	[ "${status}" -eq 0 ]
	[ "$(vless_runtime__active_id)" = vless-a ]
	[ "$(jq -r '.overall_state' "${VLESS_STATE_FILE}")" = paused ]
}

@test "completed supervisor cycles have a monotonic sequence" {
	[ "$(jq -r '.cycle' "${VLESS_STATE_FILE}")" -eq 0 ]
	vless_runtime__mark_cycle
	vless_runtime__mark_cycle
	[ "$(jq -r '.cycle' "${VLESS_STATE_FILE}")" -eq 2 ]
	[ "$(jq -r '.last_cycle_at' "${VLESS_STATE_FILE}")" != null ]
}

@test "stale supervisor lock is recovered" {
	mkdir -p "${VLESS_SUPERVISOR_LOCK_DIR}"
	printf '%s\n' 999999 >"${VLESS_SUPERVISOR_PID_FILE}"

	run vless_supervisor__acquire_lock
	[ "${status}" -eq 0 ]
}

@test "live unrelated PID does not block stale supervisor lock recovery" {
	sleep 30 &
	unrelated_pid=$!
	mkdir -p "${VLESS_SUPERVISOR_LOCK_DIR}"
	printf '%s\n' "${unrelated_pid}" >"${VLESS_SUPERVISOR_PID_FILE}"

	run vless_supervisor__acquire_lock
	result=${status}
	kill -0 "${unrelated_pid}"
	kill "${unrelated_pid}"
	wait "${unrelated_pid}" 2>/dev/null || true
	[ "${result}" -eq 0 ]
}

@test "wake never signals a live unrelated PID from a stale file" {
	sleep 30 &
	unrelated_pid=$!
	printf '%s\n' "${unrelated_pid}" >"${VLESS_SUPERVISOR_PID_FILE}"

	run vless_runtime__wake_supervisor
	result=${status}
	kill -0 "${unrelated_pid}"
	kill "${unrelated_pid}"
	wait "${unrelated_pid}" 2>/dev/null || true
	[ "${result}" -ne 0 ]
}

@test "health endpoint must return exactly HTTP 204" {
	fake_curl() { printf '%s\n' '200|0.010'; }
	VLESS_CURL=fake_curl
	run vless_runtime__probe https://health.invalid ''
	[ "${status}" -ne 0 ]

	fake_curl() { printf '%s\n' '204|0.010'; }
	run vless_runtime__probe https://health.invalid ''
	[ "${status}" -eq 0 ]
}

@test "empty registry is unconfigured rather than paused" {
	jq '.connections = []' "${VLESS_REGISTRY_FILE}" >"${VLESS_REGISTRY_FILE}.next"
	mv "${VLESS_REGISTRY_FILE}.next" "${VLESS_REGISTRY_FILE}"
	vless_runtime__reconcile

	run vless_supervisor__once
	[ "${status}" -eq 0 ]
	[ "$(jq -r '.overall_state' "${VLESS_STATE_FILE}")" = unconfigured ]
}

@test "sticky active override happens before connection probes" {
	order_file="${BATS_TEST_TMPDIR}/order"
	vless_runtime__override() { printf 'override:%s\n' "${1}" >>"${order_file}"; return 0; }
	vless_runtime__probe_connection() { printf 'probe:%s\n' "${1}" >>"${order_file}"; VLESS_PROBE_LATENCY_MS=10; VLESS_PROBE_ERROR=''; return 0; }

	vless_supervisor__once
	[ "$(head -n 1 "${order_file}")" = override:mors-vless-vless-a ]
}

@test "failed fail-closed override is reported as an error" {
	vless_runtime__probe_connection() { VLESS_PROBE_ERROR=timeout; VLESS_PROBE_LATENCY_MS=null; return 1; }
	vless_supervisor__confirm_active_failure() { return 1; }
	vless_runtime__probe() { VLESS_PROBE_LATENCY_MS=10; VLESS_PROBE_ERROR=''; return 0; }
	vless_runtime__override() { [ "${1}" != mors-block ]; }

	run vless_supervisor__once
	[ "${status}" -ne 0 ]
	[ "$(jq -r '.overall_state' "${VLESS_STATE_FILE}")" = unavailable ]
	[ "$(jq -r '.active_id' "${VLESS_STATE_FILE}")" = vless-a ]
	[ "$(tail -n 1 "${VLESS_EVENTS_FILE}" | jq -r '.result')" = error ]
}

@test "USR1 wakes and TERM promptly stops supervisor during interval sleep" {
	local cycles="${BATS_TEST_TMPDIR}/cycles" stopped=false
	vless_supervisor__once() { printf '%s\n' cycle >>"${cycles}"; }
	cycle_count() {
		[ -f "${cycles}" ] && wc -l <"${cycles}" || printf '%s\n' 0
	}
	VLESS_SUPERVISOR_INTERVAL=30
	vless_supervisor__run &
	process_id=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cycle_count)" -ge 1 ] && break; sleep 0.1; done
	kill -USR1 "${process_id}"
	for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(cycle_count)" -ge 2 ] && break; sleep 0.1; done
	[ "$(cycle_count)" -ge 2 ]
	kill -TERM "${process_id}"
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		if ! kill -0 "${process_id}" 2>/dev/null; then stopped=true; break; fi
		sleep 0.1
	done
	if [ "${stopped}" != true ]; then
		kill -KILL "${process_id}" 2>/dev/null || true
		wait "${process_id}" 2>/dev/null || true
		false
	fi
	wait "${process_id}"
	[ ! -e "${VLESS_SUPERVISOR_PID_FILE}" ]
	[ ! -d "${VLESS_SUPERVISOR_LOCK_DIR}" ]
}

@test "ownerless decision lock is not removed immediately" {
	mkdir -p "${VLESS_DECISION_LOCK_DIR}"
	( sleep 0.2; printf '%s\n' "$$" >"${VLESS_DECISION_PID_FILE}" ) &
	VLESS_DECISION_LOCK_WAIT=0

	run vless_runtime__acquire_decision_lock
	[ "${status}" -ne 0 ]
	[ -d "${VLESS_DECISION_LOCK_DIR}" ]
}
