#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR=${REPO_ROOT}/opt/bin/libs
	MORS_LIFECYCLE_ROOT=${BATS_TEST_TMPDIR}/lifecycle
	MORS_LIFECYCLE_STATE_FILE=${MORS_LIFECYCLE_ROOT}/state.json
	MORS_LIFECYCLE_TRANSACTION_ROOT=${MORS_LIFECYCLE_ROOT}/transactions
	MORS_LIFECYCLE_ACTIVE_FILE=${MORS_LIFECYCLE_ROOT}/active
	MORS_LIFECYCLE_SERVICE_BASELINE_FILE=${MORS_LIFECYCLE_ROOT}/service-baseline.tsv
	MORS_LIFECYCLE_CONF_FILE=${BATS_TEST_TMPDIR}/mors.conf
	MORS_LIFECYCLE_LEGACY_START_FILE=${BATS_TEST_TMPDIR}/S96mors
	MORS_LIFECYCLE_TIMEOUT_CMD=$(PATH=/usr/bin:/bin command -v timeout)
	MORS_LIFECYCLE_SERVICE_ACTION_TIMEOUT=2
	MORS_LIFECYCLE_SERVICE_KILL_AFTER=1
	export MORS_LIFECYCLE_ROOT MORS_LIFECYCLE_STATE_FILE
	export MORS_LIFECYCLE_TRANSACTION_ROOT MORS_LIFECYCLE_ACTIVE_FILE
	export MORS_LIFECYCLE_SERVICE_BASELINE_FILE
	export MORS_LIFECYCLE_CONF_FILE MORS_LIFECYCLE_LEGACY_START_FILE
	export MORS_LIB_DIR MORS_LIFECYCLE_TIMEOUT_CMD
	export MORS_LIFECYCLE_SERVICE_ACTION_TIMEOUT MORS_LIFECYCLE_SERVICE_KILL_AFTER
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
	before_umask=$(umask)
	lifecycle_snapshot__capture
	[ "$(umask)" = "${before_umask}" ]

	printf '%s\n' changed >"${original}"
	printf '%s\n' unexpected >"${created}"
	printf '%s\n' stopped >"${service_state}"
	lifecycle_snapshot__restore

	[ "$(cat "${original}")" = original ]
	[ ! -e "${created}" ]
	[ "$(cat "${service_state}")" = running ]
}

@test "setup snapshot persists the pre-Mors service baseline" {
	local service=${BATS_TEST_TMPDIR}/dnscrypt-service
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" stopped' >"${service}"
	chmod +x "${service}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture

	lifecycle_snapshot__persist_service_baseline

	[ "$(lifecycle_snapshot__baseline_service_state "${service}")" = stopped ]
	case "$(uname -s)" in MINGW*|MSYS*) ;; *) [ "$(stat -c '%a' "${MORS_LIFECYCLE_SERVICE_BASELINE_FILE}")" = 600 ] ;; esac
}

@test "ready upgrade migrates a missing baseline from the completed setup snapshot" {
	local service=${BATS_TEST_TMPDIR}/dnscrypt-service
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" alive' >"${service}"
	chmod +x "${service}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture
	lifecycle_transaction__phase prepared
	lifecycle_transaction__finish
	[ ! -e "${MORS_LIFECYCLE_SERVICE_BASELINE_FILE}" ]

	[ "$(lifecycle_snapshot__baseline_service_state "${service}")" = running ]
	[ -r "${MORS_LIFECYCLE_SERVICE_BASELINE_FILE}" ]
}

@test "snapshot preserves unrecognized service status as unknown" {
	local service=${BATS_TEST_TMPDIR}/ambiguous-service
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" ambiguous; exit 7' >"${service}"
	chmod +x "${service}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	run lifecycle_snapshot__capture

	[ "${status}" -ne 0 ]
	[ "$(lifecycle_snapshot__captured_service_state "${service}")" = unknown ]
}

@test "snapshot hard-kills a TERM-ignoring service status" {
	local service=${BATS_TEST_TMPDIR}/hanging-service log
	cat >"${service}" <<'EOF'
#!/bin/sh
printf '%s\n' alive
trap '' TERM
sleep 10
EOF
	chmod +x "${service}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	MORS_LIFECYCLE_SERVICE_ACTION_TIMEOUT=1
	MORS_LIFECYCLE_SERVICE_KILL_AFTER=1

	run lifecycle_snapshot__capture

	[ "${status}" -ne 0 ]
	[ "$(lifecycle_snapshot__captured_service_state "${service}")" = unknown ]
	log=$(lifecycle_snapshot__service_log_path)
	grep -q 'service-action-timeout .*action=status timeout=1 kill-after=1' "${log}"
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

@test "snapshot restore rejects restart exit zero without running poststate" {
	local service=${BATS_TEST_TMPDIR}/lying-restart state=${BATS_TEST_TMPDIR}/service.state
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	status) [ "$(cat "${SERVICE_STATE}")" = running ] && echo alive || echo dead ;;
	restart) exit 0 ;;
esac
EOF
	chmod +x "${service}"
	export SERVICE_STATE=${state}
	printf '%s\n' running >"${state}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture
	printf '%s\n' stopped >"${state}"
	MORS_LIFECYCLE_SERVICE_STATE_TIMEOUT=0

	run lifecycle_snapshot__restore

	[ "${status}" -ne 0 ]
}

@test "snapshot restore rejects stop exit zero without stopped poststate" {
	local service=${BATS_TEST_TMPDIR}/lying-stop state=${BATS_TEST_TMPDIR}/service.state
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	status) [ "$(cat "${SERVICE_STATE}")" = running ] && echo alive || echo dead ;;
	stop) exit 0 ;;
esac
EOF
	chmod +x "${service}"
	export SERVICE_STATE=${state}
	printf '%s\n' stopped >"${state}"
	lifecycle_snapshot__files() { :; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture
	printf '%s\n' running >"${state}"
	MORS_LIFECYCLE_SERVICE_STATE_TIMEOUT=0

	run lifecycle_snapshot__restore

	[ "${status}" -ne 0 ]
}

@test "snapshot restore does not poll after service-state budget is exhausted" {
	local service=${BATS_TEST_TMPDIR}/no-extra-status calls=${BATS_TEST_TMPDIR}/status.calls
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	status) printf 'called\n' >>"${STATUS_CALLS}"; printf 'alive\n' ;;
esac
EOF
	chmod +x "${service}"
	export STATUS_CALLS=${calls}
	MORS_SETUP_DNS_LOG=${BATS_TEST_TMPDIR}/lifecycle-services.log
	export MORS_SETUP_DNS_LOG
	lifecycle_snapshot__prepare_service_log
	MORS_LIFECYCLE_SERVICE_STATE_TIMEOUT=0

	run lifecycle_snapshot__wait_service_state "${service}" running

	[ "${status}" -ne 0 ]
	[ ! -e "${calls}" ]
}

@test "service log path rejects a missing transaction instead of using filesystem root" {
	unset MORS_SETUP_DNS_LOG

	run lifecycle_snapshot__service_log_path

	[ "${status}" -ne 0 ]
	[ -z "${output}" ]
}

@test "snapshot quiesces a newly created service before removing its hook" {
	local service=${BATS_TEST_TMPDIR}/new-service state=${BATS_TEST_TMPDIR}/service.state
	export SERVICE_STATE=${state}
	lifecycle_snapshot__files() { printf '%s\n' "${service}"; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { printf '%s\n' "${service}"; }
	printf '%s\n' 'SETUP_FINISHED=' >"${MORS_LIFECYCLE_CONF_FILE}"
	lifecycle_state__read >/dev/null
	lifecycle_transaction__begin setup unconfigured ready >/dev/null
	lifecycle_snapshot__capture
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	status) [ "$(cat "${SERVICE_STATE}")" = running ] && echo alive || echo dead ;;
	stop) printf '%s\n' stopped >"${SERVICE_STATE}" ;;
esac
EOF
	chmod +x "${service}"
	printf '%s\n' running >"${state}"

	lifecycle_snapshot__restore

	[ "$(cat "${state}")" = stopped ]
	[ ! -e "${service}" ]
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

@test "snapshot classifies an external legacy Xray hook and never restores over it" {
	local legacy=${BATS_TEST_TMPDIR}/S97xray source=${BATS_TEST_TMPDIR}/packaged-S97xray
	local snapshot=${BATS_TEST_TMPDIR}/snapshot manifest
	TEST_SNAPSHOT=${snapshot}
	TEST_TRANSACTION=${BATS_TEST_TMPDIR}
	MORS_LEGACY_XRAY_INIT=${legacy}
	MORS_XRAY_INIT_SOURCE=${source}
	mkdir -p "${snapshot}"
	lifecycle_transaction__snapshot_directory() { printf '%s\n' "${TEST_SNAPSHOT}"; }
	lifecycle_transaction__directory() { printf '%s\n' "${TEST_TRANSACTION}"; }
	lifecycle_snapshot__files() { printf '%s\n' "${MORS_LEGACY_XRAY_INIT}"; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { :; }
	printf '%s\n' before >"${legacy}"

	lifecycle_snapshot__capture
	manifest="${snapshot}/files.tsv"
	grep -Fq $'\texternal\t' "${manifest}"
	printf '%s\n' after >"${legacy}"
	lifecycle_snapshot__restore_files

	[ "$(cat "${legacy}")" = after ]
}

@test "snapshot refuses to replace a new external Xray hook during managed rollback" {
	local legacy=${BATS_TEST_TMPDIR}/S97xray source=${BATS_TEST_TMPDIR}/packaged-S97xray
	local snapshot=${BATS_TEST_TMPDIR}/snapshot
	TEST_SNAPSHOT=${snapshot}
	TEST_TRANSACTION=${BATS_TEST_TMPDIR}
	MORS_LEGACY_XRAY_INIT=${legacy}
	MORS_XRAY_INIT_SOURCE=${source}
	mkdir -p "${snapshot}"
	lifecycle_transaction__snapshot_directory() { printf '%s\n' "${TEST_SNAPSHOT}"; }
	lifecycle_transaction__directory() { printf '%s\n' "${TEST_TRANSACTION}"; }
	lifecycle_snapshot__files() { printf '%s\n' "${MORS_LEGACY_XRAY_INIT}"; }
	lifecycle_snapshot__directories() { :; }
	lifecycle_snapshot__services() { :; }
	: >"${source}"
	ln -s "${source}" "${legacy}"
	lifecycle_snapshot__capture
	rm -f "${legacy}"
	printf '%s\n' external >"${legacy}"

	run lifecycle_snapshot__restore_files
	[ "${status}" -ne 0 ]
	[ "$(cat "${legacy}")" = external ]
}
