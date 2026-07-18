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
	export MORS_LIFECYCLE_STATE_FILE="${BATS_TEST_TMPDIR}/lifecycle.json"
	export MORS_CONF_FILE="${BATS_TEST_TMPDIR}/mors.conf"
	export VLESS_STATE_FILE="${BATS_TEST_TMPDIR}/vless-state.json"
	export VLESS_EVENTS_FILE="${BATS_TEST_TMPDIR}/events.jsonl"
	export TELEMETRY_SYS_CLASS_NET="${BATS_TEST_TMPDIR}/sys/class/net"
	export TELEMETRY_IPTABLES_SAVE="${BATS_TEST_TMPDIR}/iptables-save"
	export TELEMETRY_VLESS_INIT="${BATS_TEST_TMPDIR}/vless-init"
	export TELEMETRY_XRAY_INIT="${BATS_TEST_TMPDIR}/xray-init"
	export TELEMETRY_VLESS_PID_FILE="${BATS_TEST_TMPDIR}/supervisor.pid"
	. "${MORS_LIB_DIR}/telemetry_otlp"
	telemetry_store__write_config folder__test home mors-router false aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	printf '%s\n' 'AQVN0123456789_example_key' >"${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_key "${BATS_TEST_TMPDIR}/key"
	telemetry_store__write_curl_config
	printf '%s\n' '{"schema_version":1,"state":"ready"}' >"${MORS_LIFECYCLE_STATE_FILE}"
	printf '%s\n' 'APP_VERSION=1.3.0~beta6' 'APP_RELEASE=1' 'INFACE_ENT=t2s21' >"${MORS_CONF_FILE}"
	cat >"${VLESS_STATE_FILE}" <<'JSON'
{"schema_version":1,"cycle":42,"overall_state":"healthy","upstream_state":"up","active_id":"vless-a","last_cycle_at":"2026-07-18T18:00:00Z","connections":{"vless-a":{"name":"SECRET Germany","server":"198.51.100.9","enabled":true,"status":"active","latency_ms":73,"consecutive_failures":0,"recent_failures":1},"vless-b":{"name":"SECRET Reserve","enabled":true,"status":"standby","latency_ms":91,"consecutive_failures":0,"recent_failures":0}}}
JSON
	printf '%s\n' '#!/bin/sh' "touch '${BATS_TEST_TMPDIR}/vless-status-called'" 'echo alive' >"${TELEMETRY_VLESS_INIT}"
	printf '%s\n' '#!/bin/sh' 'echo alive' >"${TELEMETRY_XRAY_INIT}"
	chmod +x "${TELEMETRY_VLESS_INIT}" "${TELEMETRY_XRAY_INIT}"
	mkdir -p "${TELEMETRY_SYS_CLASS_NET}/t2s21/statistics"
	printf '%s\n' 1234 >"${TELEMETRY_SYS_CLASS_NET}/t2s21/statistics/rx_bytes"
	printf '%s\n' 5678 >"${TELEMETRY_SYS_CLASS_NET}/t2s21/statistics/tx_bytes"
	printf '%s\n' '#!/bin/sh' 'printf "%s\n" "[10:2000] -A PREROUTING -m set --match-set MORS_LIST dst -j MORS_MARK"' >"${TELEMETRY_IPTABLES_SAVE}"
	chmod +x "${TELEMETRY_IPTABLES_SAVE}"
}

@test "OTLP payload contains operational fields and excludes secrets and raw addresses" {
	printf '%s\n' '[]' >"${BATS_TEST_TMPDIR}/events.json"
	telemetry_otlp__build_payload "${BATS_TEST_TMPDIR}/payload" snapshot "${BATS_TEST_TMPDIR}/events.json"

	jq -e '.resourceLogs[0].scopeLogs[0].logRecords | length == 3' "${BATS_TEST_TMPDIR}/payload"
	jq -e '[.resourceLogs[].scopeLogs[].logRecords[].attributes[] | select(.key == "mors.connection.latency_ms")][0].value.intValue == "73"' "${BATS_TEST_TMPDIR}/payload"
	jq -e '.resourceLogs[0].resource.attributes[] | select(.key == "service.name") | .value.stringValue == "mors-router"' "${BATS_TEST_TMPDIR}/payload"
	jq -e '[.resourceLogs[].scopeLogs[].logRecords[].attributes[] | select(.key == "mors.firewall.rule_match_bytes")][0].value.intValue == "2000"' "${BATS_TEST_TMPDIR}/payload"
	[ ! -e "${BATS_TEST_TMPDIR}/vless-status-called" ]
	! grep -qE 'SECRET|198\.51\.100\.9|AQVN|server|public.key|user.id' "${BATS_TEST_TMPDIR}/payload"
}

@test "event cursor forwards only new whitelisted VLESS events" {
	printf '%s\n' '{"at":"2026-07-18T18:00:00Z","type":"switch","from_id":"vless-a","to_id":"vless-b","reason":"health_failure","result":"ok"}' >"${VLESS_EVENTS_FILE}"
	telemetry_otlp__cursor_initialize
	printf '%s\n' '{"at":"2026-07-18T18:01:00Z","type":"all_unavailable","from_id":"vless-b","to_id":"mors-block","reason":"fail_closed","result":"ok"}' >>"${VLESS_EVENTS_FILE}"
	printf '%s\n' '{"at":"2026-07-18T18:02:00Z","type":"unknown","from_id":null,"to_id":null,"reason":"SECRET","result":"ok"}' >>"${VLESS_EVENTS_FILE}"

	telemetry_otlp__collect_events "${BATS_TEST_TMPDIR}/pending" "${BATS_TEST_TMPDIR}/next"
	[ "$(jq 'length' "${BATS_TEST_TMPDIR}/pending")" -eq 1 ]
	[ "$(jq -r '.[0].reason' "${BATS_TEST_TMPDIR}/pending")" = fail_closed ]
	! grep -q SECRET "${BATS_TEST_TMPDIR}/pending"
}

@test "unchanged event cursor is not rewritten on every sample" {
	printf '%s\n' '{"at":"2026-07-18T18:00:00Z","type":"switch","from_id":"vless-a","to_id":"vless-b","reason":"health_failure","result":"ok"}' >"${VLESS_EVENTS_FILE}"
	telemetry_otlp__cursor_initialize
	cp "${TELEMETRY_CURSOR_FILE}" "${BATS_TEST_TMPDIR}/next"
	before=$(stat -c '%i' "${TELEMETRY_CURSOR_FILE}")
	telemetry_otlp__cursor_commit "${BATS_TEST_TMPDIR}/next"
	after=$(stat -c '%i' "${TELEMETRY_CURSOR_FILE}")
	[ "${after}" = "${before}" ]
}

@test "stable event ids stay within the Monium label value limit" {
	long_id="vless-$(printf '%048d' 0 | tr 0 a)"
	jq --arg id "${long_id}" '
		.active_id = $id |
		.connections = {($id): {enabled: true, status: "active", latency_ms: 1,
			consecutive_failures: 0, recent_failures: 0}}
	' "${VLESS_STATE_FILE}" >"${BATS_TEST_TMPDIR}/long-state"
	mv "${BATS_TEST_TMPDIR}/long-state" "${VLESS_STATE_FILE}"
	raw=$(jq -nc --arg id "${long_id}" '{at:"2026-07-18T18:00:00Z",type:"switch",
		from_id:$id,to_id:$id,reason:"manual",result:"ok"}')
	normalized=$(telemetry_otlp__normalize_event "${raw}")
	printf '[%s]\n' "${normalized}" >"${BATS_TEST_TMPDIR}/events.json"

	telemetry_otlp__build_payload "${BATS_TEST_TMPDIR}/payload" snapshot "${BATS_TEST_TMPDIR}/events.json"
	jq -e 'all(.resourceLogs[].scopeLogs[].logRecords[].attributes[] |
		select(.key == "mors.event.id"); (.value.stringValue | length) <= 256)' \
		"${BATS_TEST_TMPDIR}/payload"
}

make_fake_curl() {
	local response=${1}
	cat >"${BATS_TEST_TMPDIR}/curl" <<EOF
#!/bin/sh
output=''
printf '%s\n' "\$@" >'${BATS_TEST_TMPDIR}/curl-args'
while [ \$# -gt 0 ]; do
	case "\$1" in
		-q) shift ;;
		--output) output=\$2; shift 2 ;;
		--config|--write-out|--data-binary|--max-filesize) shift 2 ;;
		*) shift ;;
	esac
done
printf '%s\n' '${response}' >"\${output}"
printf '200'
EOF
	chmod +x "${BATS_TEST_TMPDIR}/curl"
	export TELEMETRY_CURL="${BATS_TEST_TMPDIR}/curl"
}

@test "delivery accepts an empty OTLP success response" {
	printf '%s\n' '[]' >"${BATS_TEST_TMPDIR}/events.json"
	telemetry_otlp__build_payload "${BATS_TEST_TMPDIR}/payload" test "${BATS_TEST_TMPDIR}/events.json"
	make_fake_curl '{}'
	run telemetry_otlp__send "${BATS_TEST_TMPDIR}/payload"
	[ "${status}" -eq 0 ]
	[ "$(head -n 1 "${BATS_TEST_TMPDIR}/curl-args")" = -q ]
}

@test "delivery rejects OTLP partial success" {
	printf '%s\n' '[]' >"${BATS_TEST_TMPDIR}/events.json"
	telemetry_otlp__build_payload "${BATS_TEST_TMPDIR}/payload" test "${BATS_TEST_TMPDIR}/events.json"
	make_fake_curl '{"partialSuccess":{"rejectedLogRecords":"1","errorMessage":"bad"}}'
	run telemetry_otlp__send "${BATS_TEST_TMPDIR}/payload"
	[ "${status}" -ne 0 ]
}
