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
	export VLESS_SKIP_PLATFORM_CHECK=true
	source "${REPO_ROOT}/opt/bin/libs/vless_store"
	source "${REPO_ROOT}/opt/bin/libs/vless_config"
	source "${REPO_ROOT}/opt/bin/libs/vless_runtime"
	print_line() { :; }
	source <(sed '/^\. \/opt\/apps\/mors\/bin\/libs\//d' "${REPO_ROOT}/opt/bin/libs/vless")

	vless_store__ensure
}

@test "status JSON exposes health metadata but no VLESS secrets" {
	vless_store__add_metadata vless-a "Финляндия" true 11971
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__set_connection vless-a active 42 0 0 '' true
	vless_runtime__set_overall degraded up vless-a

	run cmd_vless_status --json
	[ "${status}" -eq 0 ]
	[ "$(printf '%s\n' "${output}" | jq -r '.schema_version')" -eq 1 ]
	[ "$(printf '%s\n' "${output}" | jq -r '.connections[0].name')" = "Финляндия" ]
	[ "$(printf '%s\n' "${output}" | jq -r '.connections[0].latency_ms')" -eq 42 ]
	[[ "${output}" != *"user_id"* ]]
	[[ "${output}" != *"public_key"* ]]
}

@test "removed vless new command does not mutate storage" {
	rm -rf "${VLESS_STORE_ROOT}"

	run cmd_vless_cli new
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"vless add"* ]]
	[ ! -e "${VLESS_STORE_ROOT}" ]
}

@test "smooth disable moves active traffic to standby without Xray restart" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__set_connection vless-a active 40 0 0 '' true
	vless_runtime__set_connection vless-b standby 50 0 0 '' true

	vless_runtime__override() { OVERRIDE_TARGET="${1}"; return 0; }
	vless_domain__apply_generated() { APPLY_RESTART="${2:-true}"; return 0; }

	vless_domain__set_enabled vless-a false false

	[ "$(vless_runtime__active_id)" = vless-b ]
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = false ]
	[ "${OVERRIDE_TARGET}" = mors-vless-vless-b ]
	[ "${APPLY_RESTART}" = false ]
}

@test "forced disable requests an immediate runtime restart" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__set_connection vless-a active 40 0 0 '' true
	vless_runtime__set_connection vless-b standby 50 0 0 '' true

	vless_runtime__override() { return 0; }
	vless_domain__apply_generated() { APPLY_RESTART="${2:-true}"; return 0; }

	vless_domain__set_enabled vless-a false true
	[ "${APPLY_RESTART}" = true ]
}

@test "noninteractive removal requires explicit confirmation" {
	vless_store__add_metadata vless-a Finland false 11971

	run cmd_vless_remove vless-a
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"--yes"* ]]
	[ "$(vless_store__connection_count)" -eq 1 ]
}

@test "enabling direct fallback requires explicit confirmation" {
	run cmd_vless_policy on false
	[ "${status}" -eq 64 ]
	[ "$(vless_store__policy | jq -r '.direct_fallback')" = false ]
}

@test "pause requires confirmation and preserves enabled choices" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__override() { return 0; }
	vless_domain__apply_generated() { return 0; }

	run cmd_vless_pause
	[ "${status}" -eq 64 ]
	[ "$(vless_store__is_paused)" = false ]

	cmd_vless_pause --yes
	[ "$(vless_store__is_paused)" = true ]
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
}

@test "forced activation requires yes before changing runtime" {
	run cmd_vless_activate vless-a --force
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"--yes"* ]]
}

@test "failed smooth switch leaves active and registry unchanged" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__set_connection vless-a active 40 0 0 '' true
	vless_runtime__set_connection vless-b standby 50 0 0 '' true
	vless_runtime__override() { return 1; }

	run vless_domain__set_enabled vless-a false false
	[ "${status}" -ne 0 ]
	[ "$(vless_runtime__active_id)" = vless-a ]
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
}

@test "failed activation restores the previous active connection" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__override() { return 0; }
	vless_domain__apply_generated() { return 1; }

	run vless_domain__activate vless-b false
	[ "${status}" -ne 0 ]
	[ "$(vless_runtime__active_id)" = vless-a ]
}

@test "failed direct fallback shutdown restores previous policy" {
	vless_store__set_direct_fallback true
	vless_runtime__ensure
	vless_runtime__set_overall direct_fallback up ''
	vless_runtime__override() { return 1; }

	run cmd_vless_policy off false
	[ "${status}" -ne 0 ]
	[ "$(vless_store__policy | jq -r '.direct_fallback')" = true ]
}

@test "editing enabled state while paused does not restart Xray" {
	vless_store__add_metadata vless-a Finland false 11971
	vless_store__set_paused true
	vless_runtime__ensure
	vless_domain__apply_generated() { APPLY_RESTART="${2:-true}"; return 0; }

	vless_domain__set_enabled vless-a true false
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
	[ "${APPLY_RESTART}" = false ]
}

@test "noninteractive add never waits for missing parameters" {
	vless_cli__is_interactive() { return 1; }
	vless_cli__prompt() { return 99; }

	run cmd_vless_add
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"--name"* ]]
	[[ "${output}" == *"--link"* ]]
}

@test "read-only commands reject silently ignored arguments" {
	run cmd_vless_status unexpected
	[ "${status}" -eq 64 ]

	run cmd_vless_events --json unexpected
	[ "${status}" -eq 64 ]
}

@test "adding another enabled outbound requires restart confirmation" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_cli__is_interactive() { return 1; }
	vless_uri__parse() { return 0; }

	run cmd_vless_add --name Germany --link vless://placeholder
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"--yes"* ]]
	[ "$(vless_store__connection_count)" -eq 1 ]
}

@test "updating an enabled outbound requires restart confirmation" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_cli__is_interactive() { return 1; }
	vless_uri__parse() { return 0; }

	run cmd_vless_update vless-a --link vless://placeholder
	[ "${status}" -eq 64 ]
	[[ "${output}" == *"--yes"* ]]
}

@test "enabling a standby alongside active traffic requires confirmation" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany false 11972
	vless_cli__is_interactive() { return 1; }

	run cmd_vless_enable vless-b
	[ "${status}" -eq 64 ]
	[ "$(vless_store__get vless-b | jq -r '.enabled')" = false ]
}

@test "status does not rewrite runtime state" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_runtime__ensure
	before=$(sha256sum "${VLESS_STATE_FILE}" | awk '{print $1}')
	cmd_vless_status --json >/dev/null
	after=$(sha256sum "${VLESS_STATE_FILE}" | awk '{print $1}')
	[ "${before}" = "${after}" ]
}

@test "active disable aborts when no healthy standby exists" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany true 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_runtime__set_connection vless-a active 40 0 0 '' true
	vless_runtime__set_connection vless-b unavailable null 3 3 timeout false

	run vless_domain__set_enabled vless-a false false
	[ "${status}" -ne 0 ]
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
	[ "$(vless_runtime__active_id)" = vless-a ]
}

@test "failed probe rolls enable back to disabled" {
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__add_metadata vless-b Germany false 11972
	vless_runtime__ensure
	vless_runtime__set_active_id vless-a
	vless_domain__apply_generated() { return 0; }
	vless_domain__restore_declared_runtime() { return 0; }
	vless_runtime__override() { return 0; }
	vless_domain__probe_id() { return 1; }

	run vless_domain__set_enabled vless-b true false
	[ "${status}" -eq 2 ]
	[ "$(vless_store__get vless-b | jq -r '.enabled')" = false ]
	[ "$(vless_runtime__active_id)" = vless-a ]
}

@test "endpoint exclusion sync adds new and removes stale managed IPs" {
	VLESS_ENDPOINTS_FILE="${BATS_TEST_TMPDIR}/endpoints.list"
	VLESS_IPSET_COMMAND="${BATS_TEST_TMPDIR}/ipset"
	export VLESS_ENDPOINT_LOG="${BATS_TEST_TMPDIR}/ipset.log"
	printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >>"${VLESS_ENDPOINT_LOG}"' 'exit 0' >"${VLESS_IPSET_COMMAND}"
	chmod +x "${VLESS_IPSET_COMMAND}"
	printf '%s\n' '192.0.2.1' >"${VLESS_ENDPOINTS_FILE}"
	jq -n '{outbounds:[{protocol:"vless",settings:{vnext:[{address:"192.0.2.2"}]}}]}' >"${BATS_TEST_TMPDIR}/config.json"

	vless_domain__sync_endpoint_exclusions "${BATS_TEST_TMPDIR}/config.json"
	grep -q 'add MORS_DESTINATION_EXCLUDED 192.0.2.2' "${VLESS_ENDPOINT_LOG}"
	grep -q 'del MORS_DESTINATION_EXCLUDED 192.0.2.1' "${VLESS_ENDPOINT_LOG}"
	[ "$(cat "${VLESS_ENDPOINTS_FILE}")" = 192.0.2.2 ]
}

@test "smooth config apply keeps draining endpoint exclusions" {
	VLESS_ENDPOINTS_FILE="${BATS_TEST_TMPDIR}/endpoints.list"
	VLESS_IPSET_COMMAND="${BATS_TEST_TMPDIR}/ipset"
	export VLESS_ENDPOINT_LOG="${BATS_TEST_TMPDIR}/ipset.log"
	printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >>"${VLESS_ENDPOINT_LOG}"' 'exit 0' >"${VLESS_IPSET_COMMAND}"
	chmod +x "${VLESS_IPSET_COMMAND}"
	printf '%s\n' '192.0.2.1' >"${VLESS_ENDPOINTS_FILE}"
	jq -n '{outbounds:[{protocol:"blackhole"}]}' >"${BATS_TEST_TMPDIR}/config.json"

	vless_domain__sync_endpoint_exclusions "${BATS_TEST_TMPDIR}/config.json" false
	[ "$(cat "${VLESS_ENDPOINTS_FILE}")" = 192.0.2.1 ]
	! grep -q 'del MORS_DESTINATION_EXCLUDED 192.0.2.1' "${VLESS_ENDPOINT_LOG}"
}

@test "failed final override rolls first enable fully back" {
	vless_store__add_metadata vless-b Germany false 11972
	vless_runtime__ensure
	vless_domain__apply_generated() { return 0; }
	vless_domain__restore_declared_runtime() { return 0; }
	vless_domain__probe_id() { return 0; }
	vless_runtime__override() { [ "${1}" = mors-block ]; }

	run vless_domain__set_enabled vless-b true false
	[ "${status}" -ne 0 ]
	[ "$(vless_store__get vless-b | jq -r '.enabled')" = false ]
	[ -z "$(vless_runtime__active_id)" ]
}
