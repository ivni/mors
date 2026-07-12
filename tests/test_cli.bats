#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	# shellcheck source=/dev/null
	. "${MORS_LIB_DIR}/test"
}

@test "test parser applies stable defaults" {
	test__parse
	[ "${MORS_TEST_MODE}" = default ]
	[ "${MORS_TEST_TIMEOUT}" -eq 30 ]
	[ "${MORS_TEST_RETRIES}" -eq 1 ]
}

@test "all mode has a 90 second default budget" {
	test__parse --all --json
	[ "${MORS_TEST_MODE}" = all ]
	[ "${MORS_TEST_TIMEOUT}" -eq 90 ]
	[ "${MORS_TEST_JSON}" = true ]
}

@test "parser accepts exact noninteractive client IPv4" {
	test__parse --client 192.0.2.10 --timeout 45 --retries 2
	[ "${MORS_TEST_MODE}" = client ]
	[ "${MORS_TEST_CLIENT}" = 192.0.2.10 ]
}

@test "parser rejects incompatible modes and invalid bounds" {
	run test__parse --all --client 192.0.2.10
	[ "${status}" -eq 64 ]
	run test__parse --timeout 9
	[ "${status}" -eq 64 ]
	run test__parse --retries 6
	[ "${status}" -eq 64 ]
}

@test "interactive cold JSON requires explicit yes" {
	run test__parse cold --json
	[ "${status}" -eq 64 ]
	test__parse cold --json --yes
	[ "${MORS_TEST_MODE}" = cold ]
}

@test "cold recovery rejects meaningless network retries" {
	test__parse cold recover --yes --timeout 20
	[ "${MORS_TEST_MODE}" = cold_recover ]
	[ "${MORS_TEST_RETRIES}" -eq 0 ]
	run test__parse cold recover --yes --retries 1
	[ "${status}" -eq 64 ]
}

@test "legacy top-level test aliases are absent" {
	! grep -Eq 'test_old|check_old|test[[:space:]]*\|[[:space:]]*check' "${REPO_ROOT}/opt/bin/mors"
}
