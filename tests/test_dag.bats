#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	. "${MORS_LIB_DIR}/test"
	MORS_TEST_TMP_ROOT=${BATS_TEST_TMPDIR}
	MORS_TEST_MODE=default MORS_TEST_JSON=true MORS_TEST_TIMEOUT=30 MORS_TEST_RETRIES=1
	test_result__init
}

teardown() { test_result__cleanup; }

@test "blocked stage is explicit and keeps dependency evidence" {
	test__blocked dns_a true true
	[ "$(jq -r '.status' "${MORS_TEST_STAGES_FILE}")" = not_checked ]
	[ "$(jq -r '.reason_code' "${MORS_TEST_STAGES_FILE}")" = dependency_failed ]
	[ "$(jq -r '.evidence.blocked' "${MORS_TEST_STAGES_FILE}")" = true ]
}

@test "absolute deadline returns zero after budget exhaustion" {
	MORS_TEST_DEADLINE=$(( $(test_probe__now_seconds) - 1 ))
	[ "$(test_probe__remaining)" -eq 0 ]
}

@test "ordinary Mors request is blocked by failed ipset while forced evidence continues" {
	local calls=${BATS_TEST_TMPDIR}/calls
	: >"${calls}"
	test__stage() {
		local id=${1}
		case "${id}" in
			dns_backend|target|active_tunnel|dns_a|firewall_route)
				MORS_PROBE_STATUS=working ;;
			ipset_population) MORS_PROBE_STATUS=error ;;
			*) MORS_PROBE_STATUS=working; printf '%s\n' "${id}" >>"${calls}" ;;
		esac
		[ "${MORS_PROBE_STATUS}" = working ]
	}
	test__blocked() { printf 'blocked:%s\n' "${1}" >>"${calls}"; }
	MORS_TEST_MODE=default
	test__network_group
	grep -qx 'blocked:mors_request' "${calls}"
	grep -qx 'forced_tunnel_request' "${calls}"
	! grep -qx 'mors_request' "${calls}"
}
