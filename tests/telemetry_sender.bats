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
	export TELEMETRY_PID_FILE="${TELEMETRY_STATE_ROOT}/sender.pid"
	export TELEMETRY_PROCESS_LOCK_DIR="${TELEMETRY_STATE_ROOT}/sender.lock"
	export TELEMETRY_SENDER_PROGRAM="${REPO_ROOT}/opt/bin/main/telemetry-sender"
	export MORS_LIFECYCLE_STATE_FILE="${BATS_TEST_TMPDIR}/lifecycle.json"
	export MORS_CONF_FILE="${BATS_TEST_TMPDIR}/mors.conf"
	export VLESS_STATE_FILE="${BATS_TEST_TMPDIR}/vless.json"
	export VLESS_EVENTS_FILE="${BATS_TEST_TMPDIR}/events.jsonl"
	export TELEMETRY_VLESS_INIT="${BATS_TEST_TMPDIR}/missing-vless"
	export TELEMETRY_XRAY_INIT="${BATS_TEST_TMPDIR}/missing-xray"
	export TELEMETRY_SYS_CLASS_NET="${BATS_TEST_TMPDIR}/sys"
	export TELEMETRY_IPTABLES_SAVE="${BATS_TEST_TMPDIR}/missing-iptables-save"
	. "${MORS_LIB_DIR}/telemetry_store"
	telemetry_store__write_config folder__test home mors true aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_key "${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_curl_config
	printf '%s\n' '{"schema_version":1,"state":"ready"}' >"${MORS_LIFECYCLE_STATE_FILE}"
	printf '%s\n' 'APP_VERSION=1.3.0~beta6' 'APP_RELEASE=1' 'INFACE_ENT=t2s21' >"${MORS_CONF_FILE}"
	printf '%s\n' '{"schema_version":1,"cycle":1,"overall_state":"healthy","upstream_state":"up","active_id":"vless-a","last_cycle_at":null,"connections":{"vless-a":{"enabled":true,"status":"active","latency_ms":50,"consecutive_failures":0,"recent_failures":0}}}' >"${VLESS_STATE_FILE}"
	: >"${VLESS_EVENTS_FILE}"
	telemetry_otlp_cursor=''
}

make_curl() {
	local mode=$1
	cat >"${BATS_TEST_TMPDIR}/curl" <<EOF
#!/bin/sh
output=''
while [ \$# -gt 0 ]; do
	case "\$1" in
		-q) shift ;;
		--output) output=\$2; shift 2 ;;
		--config|--write-out|--data-binary|--max-filesize) shift 2 ;;
		*) shift ;;
	esac
done
case '${mode}' in
	success) printf '{}\n' >"\${output}"; printf '200'; exit 0 ;;
	dns) exit 6 ;;
esac
EOF
	chmod +x "${BATS_TEST_TMPDIR}/curl"
	export TELEMETRY_CURL="${BATS_TEST_TMPDIR}/curl"
}

run_sender_once() {
	run sh "${REPO_ROOT}/opt/bin/main/telemetry-sender" once
}

@test "successful direct delivery does not write the offline queue" {
	make_curl success
	run_sender_once
	[ "${status}" -eq 0 ]
	[ "$(telemetry_store__queue_depth)" -eq 0 ]
	[ "$(jq -r '.last_http_code' "${TELEMETRY_STATE_FILE}")" = 200 ]
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = null ]
}

@test "transport failure is classified and queued without raw curl output" {
	make_curl dns
	run_sender_once
	[ "${status}" -ne 0 ]
	[ "$(telemetry_store__queue_depth)" -eq 1 ]
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = dns ]
	! grep -R -q 'Could not resolve\|AQVN' "${TELEMETRY_STATE_ROOT}"
}

@test "recovered receiver drains queued and current samples in order" {
	make_curl dns
	run_sender_once
	[ "$(telemetry_store__queue_depth)" -eq 1 ]
	make_curl success
	run_sender_once
	[ "${status}" -eq 0 ]
	[ "$(telemetry_store__queue_depth)" -eq 0 ]
	[ ! -e "${TELEMETRY_QUEUE_FILE}" ]
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = null ]
}

@test "queue overflow remains visible during a continuing transport outage" {
	export TELEMETRY_QUEUE_LIMIT=1
	make_curl dns
	run_sender_once
	[ "$(telemetry_store__queue_depth)" -eq 1 ]
	run_sender_once
	[ "${status}" -ne 0 ]
	[ "$(telemetry_store__queue_depth)" -eq 1 ]
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = dns ]
	[ "$(jq -r '.queue_overflow' "${TELEMETRY_STATE_FILE}")" = true ]
	[ "$(jq -r '.dropped_samples' "${TELEMETRY_STATE_FILE}")" -eq 1 ]
}

@test "disabled config never attempts delivery" {
	telemetry_store__set_enabled false
	make_curl success
	run_sender_once
	[ "${status}" -eq 3 ]
	[ ! -e "${TELEMETRY_QUEUE_FILE}" ]
}
