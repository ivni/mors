#!/usr/bin/env bats

@test "inventory excludes disabled VLESS connections by contract" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	grep -q 'select(.enabled == true)' "${REPO_ROOT}/opt/bin/libs/test_tunnel"
}

@test "inventory excludes server VPN roles" {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	grep -q 'client.*server\|server.*client' "${REPO_ROOT}/opt/bin/libs/test_tunnel"
}
