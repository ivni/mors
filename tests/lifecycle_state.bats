#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIFECYCLE_ROOT=${BATS_TEST_TMPDIR}/lifecycle
	MORS_LIFECYCLE_STATE_FILE=${MORS_LIFECYCLE_ROOT}/state.json
	MORS_LIFECYCLE_TRANSACTION_ROOT=${MORS_LIFECYCLE_ROOT}/transactions
	MORS_LIFECYCLE_ACTIVE_FILE=${MORS_LIFECYCLE_ROOT}/active
	MORS_LIFECYCLE_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_LIFECYCLE_LEGACY_START_FILE=${BATS_TEST_TMPDIR}/S96mors
	export MORS_LIFECYCLE_ROOT MORS_LIFECYCLE_STATE_FILE
	export MORS_LIFECYCLE_TRANSACTION_ROOT MORS_LIFECYCLE_ACTIVE_FILE
	export MORS_LIFECYCLE_CONF_FILE MORS_LIFECYCLE_LEGACY_START_FILE
	. "${REPO_ROOT}/opt/bin/libs/lifecycle_state"
	. "${REPO_ROOT}/opt/bin/libs/lifecycle_snapshot"
}

@test "fresh package migrates to unconfigured without changing legacy config" {
	printf '%s\n' 'INFACE_CLI=' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	original=$(cat "${MORS_LIFECYCLE_CONF_FILE}")

	run lifecycle_state__read

	[ "${status}" -eq 0 ]
	[ "${output}" = unconfigured ]
	[ "$(cat "${MORS_LIFECYCLE_CONF_FILE}")" = "${original}" ]
	[ "$(jq -r '.source' "${MORS_LIFECYCLE_STATE_FILE}")" = legacy_migration ]
}

@test "legacy ready is accepted only with runtime evidence" {
	printf '%s\n' 'INFACE_CLI=Wireguard0' 'SETUP_FINISHED=true' >"${MORS_LIFECYCLE_CONF_FILE}"

	run lifecycle_state__read
	[ "${status}" -eq 0 ]
	[ "${output}" = recovery_required ]

	rm -rf "${MORS_LIFECYCLE_ROOT}"
	: >"${MORS_LIFECYCLE_LEGACY_START_FILE}"
	run lifecycle_state__read
	[ "${status}" -eq 0 ]
	[ "${output}" = ready ]
}

@test "state rejects a damaged or unsupported document" {
	mkdir -p "${MORS_LIFECYCLE_ROOT}"
	printf '%s\n' '{"schema_version":2,"state":"ready"}' >"${MORS_LIFECYCLE_STATE_FILE}"

	run lifecycle_state__read

	[ "${status}" -ne 0 ]
}

@test "transaction publishes journal and state only after finish" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	[ "$(lifecycle_state__read)" = unconfigured ]

	id=$(lifecycle_transaction__begin setup unconfigured ready)
	[ -n "${id}" ]
	[ "$(cat "${MORS_LIFECYCLE_ACTIVE_FILE}")" = "${id}" ]
	[ "$(jq -r '.phase' "$(lifecycle_transaction__journal_file "${id}")")" = planning ]
	[ "$(lifecycle_state__read)" = unconfigured ]

	lifecycle_transaction__phase prepared
	[ "$(jq -r '.phase' "$(lifecycle_transaction__journal_file "${id}")")" = prepared ]
	lifecycle_transaction__finish

	[ "$(lifecycle_state__read)" = ready ]
	[ ! -e "${MORS_LIFECYCLE_ACTIVE_FILE}" ]
	[ "$(jq -r '.phase' "$(lifecycle_transaction__journal_file "${id}")")" = completed ]
}

@test "second transaction is rejected while one is active" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null

	run lifecycle_transaction__begin upgrade unconfigured ready

	[ "${status}" -eq 3 ]
}

@test "a damaged active marker blocks runtime and new transactions" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_state__write ready test
	printf '%s\n' '../invalid' >"${MORS_LIFECYCLE_ACTIVE_FILE}"

	run lifecycle_state__require_ready
	[ "${status}" -eq 3 ]
	run lifecycle_transaction__begin upgrade ready ready
	[ "${status}" -eq 3 ]
}

@test "boot gate blocks an unfinished transaction and marks recovery" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_transaction__phase applying

	run lifecycle_state__boot_gate

	[ "${status}" -eq 3 ]
	[ "$(lifecycle_state__read)" = recovery_required ]
	[ "$(jq -r '.last_error' "$(lifecycle_transaction__journal_file)")" = transaction_incomplete ]
}

@test "boot gate reconciles a completed journal after a crash before state write" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	journal=$(lifecycle_transaction__journal_file)
	jq '.phase = "completed" | .outcome = "success"' "${journal}" >"${journal}.tmp"
	mv "${journal}.tmp" "${journal}"

	run lifecycle_state__boot_gate

	[ "${status}" -eq 0 ]
	[ "$(lifecycle_state__read)" = ready ]
	[ ! -e "${MORS_LIFECYCLE_ACTIVE_FILE}" ]
}

@test "awaiting reboot remains resumable and is not marked as recovery failure" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_transaction__phase awaiting_reboot

	run lifecycle_state__boot_gate

	[ "${status}" -eq 3 ]
	[ "$(lifecycle_state__read)" = unconfigured ]
	[ "$(jq -r '.phase' "$(lifecycle_transaction__journal_file)")" = awaiting_reboot ]
	[ -e "${MORS_LIFECYCLE_ACTIVE_FILE}" ]
}

@test "snapshot and metadata permissions are private" {
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	id=$(lifecycle_transaction__begin setup unconfigured ready)

	[ "$(stat -c '%a' "${MORS_LIFECYCLE_ROOT}")" = 700 ]
	[ "$(stat -c '%a' "$(lifecycle_transaction__snapshot_directory "${id}")")" = 700 ]
	[ "$(stat -c '%a' "$(lifecycle_transaction__journal_file "${id}")")" = 600 ]
}

@test "snapshot restores exact files and original service state" {
	local original=${BATS_TEST_TMPDIR}/original.conf
	local created=${BATS_TEST_TMPDIR}/created.conf
	local service=${BATS_TEST_TMPDIR}/service
	local service_state=${BATS_TEST_TMPDIR}/service.state
	printf '%s\n' original >"${original}"
	printf '%s\n' running >"${service_state}"
	printf '%s\n' '#!/bin/sh' \
		'case "$1" in' \
		'status) [ "$(cat "${SERVICE_STATE}")" = running ] && echo alive || echo dead ;;' \
		'restart|start) printf "%s\n" running >"${SERVICE_STATE}" ;;' \
		'stop) printf "%s\n" stopped >"${SERVICE_STATE}" ;;' \
		'esac' >"${service}"
	chmod +x "${service}"
	export SERVICE_STATE=${service_state}
	lifecycle_snapshot__files() {
		printf '%s\n' "${original}" "${created}"
	}
	lifecycle_snapshot__services() {
		printf '%s\n' "${service}"
	}
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture

	printf '%s\n' changed >"${original}"
	printf '%s\n' unexpected >"${created}"
	printf '%s\n' stopped >"${service_state}"
	lifecycle_snapshot__restore

	[ "$(cat "${original}")" = original ]
	[ ! -e "${created}" ]
	[ "$(cat "${service_state}")" = running ]
}

@test "snapshot restore treats an already stopped service as restored" {
	local service=${BATS_TEST_TMPDIR}/service
	local stop_called=${BATS_TEST_TMPDIR}/stop.called
	printf '%s\n' '#!/bin/sh' \
		'case "$1" in' \
		'status) echo dead; exit 1 ;;' \
		'stop) : >"${STOP_CALLED}"; exit 1 ;;' \
		'esac' >"${service}"
	chmod +x "${service}"
	export STOP_CALLED=${stop_called}
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture

	lifecycle_snapshot__restore

	[ ! -e "${stop_called}" ]
}

@test "snapshot preserves symlinks and managed directories" {
	local target=${BATS_TEST_TMPDIR}/target
	local link=${BATS_TEST_TMPDIR}/link
	local managed=${BATS_TEST_TMPDIR}/managed
	printf '%s\n' original >"${target}"
	ln -s "${target}" "${link}"
	mkdir "${managed}"
	printf '%s\n' secret >"${managed}/secret"
	lifecycle_snapshot__files() { printf '%s\n' "${link}"; }
	lifecycle_snapshot__directories() { printf '%s\n' "${managed}"; }
	lifecycle_snapshot__services() { :; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture

	rm -f "${link}"
	printf '%s\n' replacement >"${link}"
	printf '%s\n' changed >"${managed}/secret"
	printf '%s\n' extra >"${managed}/extra"
	lifecycle_snapshot__restore

	[ -L "${link}" ]
	[ "$(readlink "${link}")" = "${target}" ]
	[ "$(cat "${managed}/secret")" = secret ]
	[ ! -e "${managed}/extra" ]
}
