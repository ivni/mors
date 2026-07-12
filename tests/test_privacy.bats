#!/usr/bin/env bats

@test "public result schema has no raw external or client IP field" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -E 'external_ip[" ]*:|client_ip[" ]*:' "${REPO_ROOT}/opt/bin/libs/test_result"
}

@test "Shadowsocks secrets are passed by protected config file not argv" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	grep -q 'ss-local.*SHADOWSOCKS_CONF\|MORS_TEST_SS_LOCAL.*-c' "${REPO_ROOT}/opt/bin/libs/test_tunnel"
	! grep -E -- '--password|-[kp][[:space:]]+.*password' "${REPO_ROOT}/opt/bin/libs/test_tunnel"
}

@test "normal test does not call repair or service restart helpers" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -E 'cmd_mors_init|cmd_state_checker|all_services_restart' "${REPO_ROOT}/opt/bin/libs/test"
}

@test "client observation never persists raw conntrack output" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	! grep -q 'client-conntrack\|>>.*conntrack' "${REPO_ROOT}/opt/bin/libs/test"
}
