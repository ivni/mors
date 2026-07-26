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
	export TELEMETRY_QUEUE_LIMIT=3
	export TELEMETRY_INSTANCE_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	. "${MORS_LIB_DIR}/telemetry_store"
	mkdir -p "${BATS_TEST_TMPDIR}/input"
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/input/key"
	telemetry_store__write_config folder__test home mors false "${TELEMETRY_INSTANCE_ID}"
}

make_payload() {
	local destination=$1 seconds=${2:-$(date -u '+%s')} cycle=${3:-1}
	jq -n --arg nanos "${seconds}000000000" --arg instance "${TELEMETRY_INSTANCE_ID}" --arg cycle "${cycle}" '{
		resourceLogs: [{
			resource: {attributes: [
				{key: "service.name", value: {stringValue: "mors"}},
				{key: "service.version", value: {stringValue: "1.3.0~beta7-1"}},
				{key: "service.instance.id", value: {stringValue: $instance}},
				{key: "telemetry.sdk.name", value: {stringValue: "mors"}}
			]},
			scopeLogs: [{scope: {name: "mors.telemetry", version: "1"}, logRecords: [{
				timeUnixNano: $nanos,
				observedTimeUnixNano: $nanos,
				severityNumber: 9,
				severityText: "INFO",
				body: {stringValue: "Состояние Mors"},
				attributes: [
					{key: "mors.event.id", value: {stringValue: ($instance + ":" + $nanos + ":snapshot:summary")}},
					{key: "mors.event", value: {stringValue: "health_snapshot"}},
					{key: "mors.vless.cycle", value: {intValue: $cycle}}
				]
			}]}]
		}]
	}' >"${destination}"
}

write_jq_without_oniguruma() {
	local wrapper="${BATS_TEST_TMPDIR}/jq-no-oniguruma"
	cat >"${wrapper}" <<'SH'
#!/bin/sh
case "$*" in
	*'test('*|*'match('*|*'sub('*|*'gsub('*|*'scan('*|*'splits('*|*'capture('*) exit 5 ;;
esac
exec "${REAL_JQ}" "$@"
SH
	chmod +x "${wrapper}"
	printf '%s\n' "${wrapper}"
}

@test "config and Monium credentials are stored with protected modes" {
	telemetry_store__write_config folder__test home mors false "${TELEMETRY_INSTANCE_ID}"
	telemetry_store__write_key "${BATS_TEST_TMPDIR}/input/key"
	telemetry_store__write_curl_config

	telemetry_store__credentials_valid
	[ "$(stat -c '%a' "${TELEMETRY_CONFIG_ROOT}")" = 700 ]
	[ "$(stat -c '%a' "${TELEMETRY_CONFIG_FILE}")" = 600 ]
	[ "$(stat -c '%a' "${TELEMETRY_KEY_FILE}")" = 600 ]
	[ "$(jq -r '.project' "${TELEMETRY_CONFIG_FILE}")" = folder__test ]
	! grep -q 'AQVN' "${TELEMETRY_CONFIG_FILE}"
	grep -q 'Authorization: Api-Key AQVN' "${TELEMETRY_CURL_CONFIG}"
	printf '%s\n' 'url = "https://attacker.invalid"' >"${TELEMETRY_CURL_CONFIG}"
	chmod 600 "${TELEMETRY_CURL_CONFIG}"
	run telemetry_store__credentials_valid
	[ "${status}" -ne 0 ]
}

@test "payload and state schemas work with jq compiled without Oniguruma" {
	REAL_JQ=$(command -v jq)
	export REAL_JQ
	TELEMETRY_JQ=$(write_jq_without_oniguruma)
	export TELEMETRY_JQ

	telemetry_store__capability_reason
	schema=$(telemetry_store__payload_schema)
	"${TELEMETRY_JQ}" -n -e "${schema} true" >/dev/null
	telemetry_store__ensure_directories
	: >"${TELEMETRY_QUEUE_FILE}"
	telemetry_store__state_write false timeout null
	telemetry_store__state_valid
}

@test "header injection and malformed keys are rejected" {
	run telemetry_store__write_config $'folder__test\nInjected' home mors false fixed
	[ "${status}" -ne 0 ]
	printf '%s\n' 'short' >"${BATS_TEST_TMPDIR}/input/bad-key"
	run telemetry_store__key_valid "${BATS_TEST_TMPDIR}/input/bad-key"
	[ "${status}" -ne 0 ]
	printf '%s\n' 'AQVN0123456789 bad' >"${BATS_TEST_TMPDIR}/input/bad-key"
	run telemetry_store__key_valid "${BATS_TEST_TMPDIR}/input/bad-key"
	[ "${status}" -ne 0 ]
}

@test "offline queue is bounded and preserves valid payload order" {
	for id in 1 2 3 4; do
		make_payload "${BATS_TEST_TMPDIR}/payload-${id}" "$(( $(date -u '+%s') + id ))" "${id}"
		telemetry_store__queue_enqueue "${BATS_TEST_TMPDIR}/payload-${id}"
	done

	[ "$(telemetry_store__queue_depth)" -eq 3 ]
	[ "$(head -n 1 "${TELEMETRY_QUEUE_FILE}" | jq -r '.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] | select(.key == "mors.vless.cycle").value.intValue')" = 1 ]
	[ "${TELEMETRY_QUEUE_DROPPED}" = true ]
}

@test "offline queue and delivery batch are bounded by bytes" {
	TELEMETRY_QUEUE_LIMIT=20
	TELEMETRY_QUEUE_BYTE_LIMIT=2400
	TELEMETRY_QUEUE_BATCH_LIMIT=20
	TELEMETRY_BATCH_BYTE_LIMIT=1500
	for id in 1 2 3 4 5 6; do
		make_payload "${BATS_TEST_TMPDIR}/payload-${id}" "$(( $(date -u '+%s') + id ))" "${id}"
		telemetry_store__queue_enqueue "${BATS_TEST_TMPDIR}/payload-${id}"
	done

	[ "$(wc -c <"${TELEMETRY_QUEUE_FILE}")" -le "${TELEMETRY_QUEUE_BYTE_LIMIT}" ]
	[ "${TELEMETRY_QUEUE_DROPPED}" = true ]
	telemetry_store__queue_batch "${BATS_TEST_TMPDIR}/batch"
	[ "$(wc -c <"${BATS_TEST_TMPDIR}/batch")" -le "${TELEMETRY_BATCH_BYTE_LIMIT}" ]
	[ "${TELEMETRY_QUEUE_BATCH_COUNT}" -gt 0 ]
}

@test "unchanged queue sanitization never replaces the persistent file" {
	make_payload "${BATS_TEST_TMPDIR}/payload"
	telemetry_store__queue_enqueue "${BATS_TEST_TMPDIR}/payload"
	telemetry_store__queue_sanitize
	before=$(stat -c '%i:%Y:%s' "${TELEMETRY_QUEUE_FILE}")
	telemetry_store__queue_sanitize
	after=$(stat -c '%i:%Y:%s' "${TELEMETRY_QUEUE_FILE}")
	[ "${after}" = "${before}" ]
}

@test "full queue drops a new sample without rewriting persistent data" {
	TELEMETRY_QUEUE_LIMIT=1
	make_payload "${BATS_TEST_TMPDIR}/payload-1"
	make_payload "${BATS_TEST_TMPDIR}/payload-2" "$(( $(date -u '+%s') + 1 ))" 2
	telemetry_store__queue_enqueue "${BATS_TEST_TMPDIR}/payload-1"
	before=$(stat -c '%i:%Y:%s' "${TELEMETRY_QUEUE_FILE}")
	telemetry_store__queue_enqueue "${BATS_TEST_TMPDIR}/payload-2"
	after=$(stat -c '%i:%Y:%s' "${TELEMETRY_QUEUE_FILE}")
	[ "${TELEMETRY_QUEUE_DROPPED}" = true ]
	[ "${after}" = "${before}" ]
}

@test "closed payload schema rejects foreign attributes and secret bodies" {
	make_payload "${BATS_TEST_TMPDIR}/payload"
	jq '.resourceLogs[0].scopeLogs[0].logRecords[0].attributes +=
		[{key: "server.address", value: {stringValue: "198.51.100.9"}}]' \
		"${BATS_TEST_TMPDIR}/payload" >"${BATS_TEST_TMPDIR}/foreign"
	run telemetry_store__payload_valid "${BATS_TEST_TMPDIR}/foreign"
	[ "${status}" -ne 0 ]
	telemetry_store__ensure_directories
	jq -c . "${BATS_TEST_TMPDIR}/foreign" >"${TELEMETRY_QUEUE_FILE}"
	telemetry_store__queue_sanitize
	[ ! -e "${TELEMETRY_QUEUE_FILE}" ]
	jq '.resourceLogs[0].scopeLogs[0].logRecords[0].body.stringValue = "AQVN_SECRET"' \
		"${BATS_TEST_TMPDIR}/payload" >"${BATS_TEST_TMPDIR}/secret"
	run telemetry_store__payload_valid "${BATS_TEST_TMPDIR}/secret"
	[ "${status}" -ne 0 ]
	jq '(.resourceLogs[0].scopeLogs[0].logRecords[0].attributes[] |
		select(.key == "mors.event.id").value.stringValue) = "AQVN0123456789_example_key"' \
		"${BATS_TEST_TMPDIR}/payload" >"${BATS_TEST_TMPDIR}/secret-attribute"
	run telemetry_store__payload_valid "${BATS_TEST_TMPDIR}/secret-attribute"
	[ "${status}" -ne 0 ]
	jq '(.resourceLogs[0].resource.attributes[] |
		select(.key == "service.version").value.stringValue) = "1.3.0~beta7-AQVN0123456789_example_key"' \
		"${BATS_TEST_TMPDIR}/payload" >"${BATS_TEST_TMPDIR}/secret-version"
	run telemetry_store__payload_valid "${BATS_TEST_TMPDIR}/secret-version"
	[ "${status}" -ne 0 ]
}

@test "queue sanitization drops malformed and expired records" {
	telemetry_store__ensure_directories
	make_payload "${BATS_TEST_TMPDIR}/valid"
	make_payload "${BATS_TEST_TMPDIR}/expired" "$(( $(date -u '+%s') - 80000 ))"
	jq -c . "${BATS_TEST_TMPDIR}/expired" >"${TELEMETRY_QUEUE_FILE}"
	printf '%s\n' 'not-json' >>"${TELEMETRY_QUEUE_FILE}"
	jq -c . "${BATS_TEST_TMPDIR}/valid" >>"${TELEMETRY_QUEUE_FILE}"

	telemetry_store__queue_sanitize
	[ "$(telemetry_store__queue_depth)" -eq 1 ]
	telemetry_store__payload_valid "${TELEMETRY_QUEUE_FILE}"
}

@test "derived state rejects corruption and preserves last success on failure" {
	telemetry_store__ensure_directories
	: >"${TELEMETRY_QUEUE_FILE}"
	telemetry_store__state_write true '' 200
	first=$(jq -r '.last_success_at' "${TELEMETRY_STATE_FILE}")
	telemetry_store__state_write false timeout null
	[ "$(jq -r '.last_success_at' "${TELEMETRY_STATE_FILE}")" = "${first}" ]
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = timeout ]
	[ "$(jq -r '.queue_overflow' "${TELEMETRY_STATE_FILE}")" = false ]
	[ "$(jq -r '.dropped_samples' "${TELEMETRY_STATE_FILE}")" -eq 0 ]
	telemetry_store__state_write false dns null true
	telemetry_store__state_write true '' 200
	[ "$(jq -r '.last_error' "${TELEMETRY_STATE_FILE}")" = null ]
	[ "$(jq -r '.queue_overflow' "${TELEMETRY_STATE_FILE}")" = true ]
	[ "$(jq -r '.dropped_samples' "${TELEMETRY_STATE_FILE}")" -eq 1 ]
	printf '%s\n' broken >"${TELEMETRY_STATE_FILE}"
	run telemetry_store__state_valid
	[ "${status}" -ne 0 ]
	printf '%s\n' '{"schema_version":1,"last_attempt_at":"2026-07-19T00:00:00Z","last_success_at":null,"last_error":"AQVN_SECRET","last_http_code":null,"queue_depth":0}' >"${TELEMETRY_STATE_FILE}"
	run telemetry_store__state_valid
	[ "${status}" -ne 0 ]
}
