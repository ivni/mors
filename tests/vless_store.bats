#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export VLESS_STORE_ROOT="${BATS_TEST_TMPDIR}/store"
	export VLESS_REGISTRY_FILE="${VLESS_STORE_ROOT}/registry.json"
	export VLESS_CONNECTIONS_DIR="${VLESS_STORE_ROOT}/connections"
	export VLESS_STATE_ROOT="${BATS_TEST_TMPDIR}/state"
	export VLESS_RUNTIME_ROOT="${BATS_TEST_TMPDIR}/run"
	export VLESS_STATE_FILE="${VLESS_STATE_ROOT}/state.json"
	export VLESS_ACTIVE_FILE="${VLESS_STATE_ROOT}/active"
	export VLESS_EVENTS_FILE="${VLESS_STATE_ROOT}/events.jsonl"
	source "${REPO_ROOT}/opt/bin/libs/vless_store"
}

@test "store initializes a versioned protected registry" {
	run vless_store__ensure
	[ "${status}" -eq 0 ]
	[ "$(jq -r '.schema_version' "${VLESS_REGISTRY_FILE}")" -eq 1 ]
	[ "$(jq -r '.connections | length' "${VLESS_REGISTRY_FILE}")" -eq 0 ]
	[ "$(jq -r '.policy.paused' "${VLESS_REGISTRY_FILE}")" = false ]
	[ "$(jq -r '.policy.direct_fallback' "${VLESS_REGISTRY_FILE}")" = false ]
}

@test "pause is independent from per-connection enabled state" {
	vless_store__ensure
	vless_store__add_metadata vless-a Finland true 11971
	vless_store__set_paused true

	[ "$(vless_store__is_paused)" = true ]
	[ "$(vless_store__get vless-a | jq -r '.enabled')" = true ]
}

@test "store assigns stable metadata and resolves name or id" {
	vless_store__ensure
	vless_store__add_metadata vless-a "Финляндия" true 11971

	[ "$(vless_store__resolve vless-a)" = vless-a ]
	[ "$(vless_store__resolve "Финляндия")" = vless-a ]
	[ "$(vless_store__enabled_count)" -eq 1 ]
	[ "$(vless_store__allocate_probe_port)" -eq 11972 ]
}

@test "latin names are unique without case sensitivity" {
	vless_store__ensure
	vless_store__add_metadata vless-a Finland true 11971

	run vless_store__name_available finland
	[ "${status}" -ne 0 ]
}

@test "registry validation rejects more than four connections" {
	vless_store__ensure
	for number in 1 2 3 4 5; do
		jq \
			--arg id "vless-${number}" \
			--arg name "Node ${number}" \
			--argjson port "$((11970 + number))" \
			'.connections += [{id: $id, name: $name, enabled: true, probe_port: $port}]' \
			"${VLESS_REGISTRY_FILE}" >"${VLESS_REGISTRY_FILE}.next"
		mv "${VLESS_REGISTRY_FILE}.next" "${VLESS_REGISTRY_FILE}"
	done

	run vless_store__validate_registry
	[ "${status}" -ne 0 ]
}

@test "store tree validation rejects missing connection secrets" {
	vless_store__ensure
	vless_store__add_metadata vless-a Finland true 11971

	run vless_store__validate_tree "${VLESS_STORE_ROOT}"
	[ "${status}" -ne 0 ]

	printf '%s\n' '{}' | vless_store__write_secret vless-a
	run vless_store__validate_tree "${VLESS_STORE_ROOT}"
	[ "${status}" -eq 0 ]
}

@test "store tree validation rejects nested lifecycle candidates" {
	vless_store__ensure
	mkdir -p "${VLESS_STORE_ROOT}/vless.restore-candidate"
	run vless_store__validate_tree "${VLESS_STORE_ROOT}"
	[ "${status}" -ne 0 ]
}
