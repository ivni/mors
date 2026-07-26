#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR=${REPO_ROOT}/opt/bin/libs
	. "${MORS_LIB_DIR}/test"
	MORS_TEST_TARGET=ifconfig.me
	MORS_TEST_DISABLE_FALLBACK=false
	attempts=0
	test_probe__target_in_list() { [ "${1}" = api.ipify.org ]; }
	test_probe__dns_a() { return 0; }
	test_probe__ipset_population() { return 0; }
}

@test "additional connection retries on the configured IPv4 fallback target" {
	test_tunnel__probe_inventory_item() {
		attempts=$((attempts + 1))
		[ "${MORS_TEST_TARGET}" = api.ipify.org ]
	}
	test__probe_inventory_item_with_fallback '{}'
	[ "${attempts}" -eq 2 ]
	[ "${MORS_TEST_TARGET}" = api.ipify.org ]
	[ "${MORS_TEST_CONNECTION_FALLBACK}" = true ]
}

@test "successful primary additional-connection probe does not activate fallback" {
	test_tunnel__probe_inventory_item() {
		attempts=$((attempts + 1))
		return 0
	}
	test__probe_inventory_item_with_fallback '{}'
	[ "${attempts}" -eq 1 ]
	[ "${MORS_TEST_TARGET}" = ifconfig.me ]
	[ "${MORS_TEST_CONNECTION_FALLBACK}" = false ]
}
