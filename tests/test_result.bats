#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	# shellcheck source=/dev/null
	. "${REPO_ROOT}/opt/bin/libs/test_result"
	MORS_TEST_TMP_ROOT=${BATS_TEST_TMPDIR}
	MORS_TEST_MODE=default
	MORS_TEST_JSON=true
	MORS_TEST_TIMEOUT=30
	MORS_TEST_RETRIES=1
	test_result__init
}

teardown() {
	test_result__cleanup
}

@test "aggregation follows error degraded not_checked working priority" {
	test_result__add config working ok ok true true 0 1 '{}'
	[ "$(test_result__aggregate)" = working ]
	test_result__add optional not_checked missing missing false false 0 1 '{}'
	[ "$(test_result__aggregate)" = degraded ]
	test_result__add risk degraded risk risk false false 0 1 '{}'
	[ "$(test_result__aggregate)" = degraded ]
	test_result__add required error failed failed true true 0 1 '{}'
	[ "$(test_result__aggregate)" = error ]
}

@test "a required not-checked stage keeps the overall result inconclusive" {
	test_result__add required not_checked dependency_failed blocked true true 0 0 '{}'
	[ "$(test_result__aggregate)" = not_checked ]
}

@test "JSON v1 is one object with ordered stages" {
	test_result__add configuration working configuration_valid ok true true 1 1 '{"safe":true}'
	run test_result__json working 0 10
	[ "${status}" -eq 0 ]
	[ "$(printf '%s' "${output}" | jq -r '.schema_version')" -eq 1 ]
	[ "$(printf '%s' "${output}" | jq -r '.stages[0].id')" = configuration ]
	[ "$(printf '%s' "${output}" | jq -r '.exit_code')" -eq 0 ]
}

@test "exit codes implement the public state contract" {
	run test_result__exit_code working; [ "${status}" -eq 0 ]
	run test_result__exit_code degraded; [ "${status}" -eq 1 ]
	run test_result__exit_code error; [ "${status}" -eq 2 ]
	run test_result__exit_code not_checked; [ "${status}" -eq 3 ]
	run test_result__exit_code unconfigured; [ "${status}" -eq 3 ]
}
