#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR="${REPO_ROOT}/opt/bin/libs"
	. "${MORS_LIB_DIR}/test"
}

@test "client parser requires canonical IPv4" {
	test__parse --client 192.0.2.25 --json
	[ "${MORS_TEST_CLIENT}" = 192.0.2.25 ]
	run test__parse --client workstation --json
	[ "${status}" -eq 64 ]
	run test__parse --client 192.0.2.025 --json
	[ "${status}" -eq 64 ]
}

@test "JSON client mode has a stable missing-report reason" {
	grep -q 'client_exit_ip_not_reported' "${REPO_ROOT}/opt/bin/libs/test"
}

@test "client route evidence correlates target and mark on one conntrack row" {
	local observations=${BATS_TEST_TMPDIR}/conntrack
	MORS_TEST_DNS_FILE=${BATS_TEST_TMPDIR}/dns-a
	printf '%s\n' 203.0.113.10 >"${MORS_TEST_DNS_FILE}"
	printf '%s\n' \
		'tcp src=192.0.2.2 dst=203.0.113.10 sport=40000 dport=443 mark=0' \
		'tcp src=192.0.2.2 dst=198.51.100.4 sport=40001 dport=443 mark=0xd1000' \
		>"${observations}"
	! test__client_route_observed "$(cat "${observations}")"
	printf '%s\n' \
		'tcp src=192.0.2.2 dst=203.0.113.10 sport=40000 dport=443 mark=0xd1000' \
		>"${observations}"
	test__client_route_observed "$(cat "${observations}")"
}

@test "any observed external DNS flow is reported even with router DNS" {
	local observations=${BATS_TEST_TMPDIR}/conntrack
	printf '%s\n' \
		'udp src=192.0.2.2 dst=192.0.2.1 sport=50000 dport=53' \
		'udp src=192.0.2.2 dst=9.9.9.9 sport=50001 dport=53' >"${observations}"
	MORS_TEST_CLIENT_DNS_ROUTER=false
	MORS_TEST_CLIENT_DNS_EXTERNAL=false
	test__client_classify_dns "$(cat "${observations}")" 192.0.2.1
	[ "${MORS_TEST_CLIENT_DNS_ROUTER}" = true ]
	[ "${MORS_TEST_CLIENT_DNS_EXTERNAL}" = true ]
}
