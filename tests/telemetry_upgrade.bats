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
	export MORS_TELEMETRY_TIMEOUT_CMD
	MORS_TELEMETRY_TIMEOUT_CMD=$(PATH=/usr/bin:/bin command -v timeout)
	export TELEMETRY_PID_FILE="${BATS_TEST_TMPDIR}/pid/sender.pid"
	export TELEMETRY_PROCESS_LOCK_DIR="${BATS_TEST_TMPDIR}/pid/sender.lock"
	export TELEMETRY_PROCESS_ROOT="${BATS_TEST_TMPDIR}/proc"
	export SERVICE_STATE_FILE="${BATS_TEST_TMPDIR}/service-state"
	mkdir -p "$(dirname "${TELEMETRY_INIT}")"
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
	. "${MORS_LIB_DIR}/telemetry_upgrade"
}

prepare_enabled_config() {
	telemetry_store__write_config folder__test home mors true aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
}

build_target_ipk() {
	local artifact=${1} capability=${2} root outer member
	root="${BATS_TEST_TMPDIR}/ipk-${capability}-root"
	outer="${BATS_TEST_TMPDIR}/ipk-${capability}-outer"
	mkdir -p "${root}" "${outer}"
	if [ "${capability}" = supported ]; then
		for member in \
			opt/apps/mors/bin/libs/telemetry \
			opt/apps/mors/bin/libs/telemetry_runtime \
			opt/apps/mors/bin/libs/telemetry_store \
			opt/apps/mors/bin/libs/telemetry_otlp \
			opt/apps/mors/bin/libs/telemetry_process \
			opt/apps/mors/bin/libs/telemetry_upgrade \
			opt/apps/mors/bin/main/telemetry-sender \
			opt/apps/mors/etc/init.d/S98mors-telemetry; do
			mkdir -p "${root}/$(dirname "${member}")"
			: >"${root}/${member}"
		done
	else
		mkdir -p "${root}/opt/apps/mors/bin"
		: >"${root}/opt/apps/mors/bin/mors"
	fi
	tar -czf "${outer}/data.tar.gz" -C "${root}" .
	printf '%s\n' '2.0' >"${outer}/debian-binary"
	tar -czf "${artifact}" -C "${outer}" .
}

@test "artifact capability distinguishes telemetry and pre-telemetry targets" {
	build_target_ipk "${BATS_TEST_TMPDIR}/supported.ipk" supported
	build_target_ipk "${BATS_TEST_TMPDIR}/unsupported.ipk" unsupported
	[ "$(telemetry_upgrade__artifact_capability "${BATS_TEST_TMPDIR}/supported.ipk" "${BATS_TEST_TMPDIR}")" = supported ]
	[ "$(telemetry_upgrade__artifact_capability "${BATS_TEST_TMPDIR}/unsupported.ipk" "${BATS_TEST_TMPDIR}")" = unsupported ]
}

@test "supported target quiesces a managed sender without disabling it" {
	prepare_enabled_config
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	telemetry_upgrade__prepare_target supported
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = true ]
	[ -L "${TELEMETRY_INIT}" ]
}

@test "pre-telemetry target disables and detaches a managed sender" {
	prepare_enabled_config
	ln -s "${TELEMETRY_INIT_SOURCE}" "${TELEMETRY_INIT}"
	printf '%s\n' running >"${SERVICE_STATE_FILE}"
	telemetry_upgrade__prepare_target unsupported
	[ "$(cat "${SERVICE_STATE_FILE}")" = stopped ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
	[ ! -e "${TELEMETRY_INIT}" ]
	[ ! -L "${TELEMETRY_INIT}" ]
}

@test "pre-telemetry target preserves and never executes an external hook" {
	prepare_enabled_config
	cat >"${TELEMETRY_INIT}" <<EOF
#!/bin/sh
touch '${BATS_TEST_TMPDIR}/unexpected-executed'
EOF
	chmod +x "${TELEMETRY_INIT}"
	telemetry_upgrade__prepare_target unsupported
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = false ]
	[ -f "${TELEMETRY_INIT}" ]
	[ ! -e "${BATS_TEST_TMPDIR}/unexpected-executed" ]
}

@test "supported unconfigured update preserves an external hook and passes passive verification" {
	printf '%s\n' operator-owned >"${TELEMETRY_INIT}"
	telemetry_upgrade__prepare_target supported
	telemetry_lifecycle__passive_runtime_removed
	[ "$(cat "${TELEMETRY_INIT}")" = operator-owned ]
}

@test "upgrade aborts before mutation when a running sender has an external hook" {
	prepare_enabled_config
	printf '%s\n' operator-owned >"${TELEMETRY_INIT}"
	telemetry_process__running_pid() { printf '%s\n' 123; }
	run telemetry_upgrade__prepare_target unsupported
	[ "${status}" -eq 4 ]
	[ "$(jq -r '.enabled' "${TELEMETRY_CONFIG_FILE}")" = true ]
	[ "$(cat "${TELEMETRY_INIT}")" = operator-owned ]
}
