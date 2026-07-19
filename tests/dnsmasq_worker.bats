#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	SOURCE=${BATS_TEST_TMPDIR}/mors.list
	DESTINATION=${BATS_TEST_TMPDIR}/mors.dnsmasq
	IPSET_TABLE_NAME=MORS_LIST
	source <(sed -n '/^dnsmasq__render_list()/,/^}/p' "${REPO_ROOT}/opt/bin/main/dnsmasq")
}

@test "empty and comment-only lists produce a valid empty dnsmasq fragment" {
	printf '%s\n' '# comment' '' >"${SOURCE}"

	dnsmasq__render_list "${SOURCE}" "${DESTINATION}"

	[ ! -s "${DESTINATION}" ]
}

@test "one domain produces exactly one dnsmasq record" {
	printf '%s\n' 'example.com' >"${SOURCE}"

	dnsmasq__render_list "${SOURCE}" "${DESTINATION}"

	[ "$(cat "${DESTINATION}")" = 'ipset=/example.com/MORS_LIST' ]
}

@test "IP-only lists produce a valid empty dnsmasq fragment" {
	printf '%s\n' '192.0.2.1' '198.51.100.0/24' >"${SOURCE}"

	dnsmasq__render_list "${SOURCE}" "${DESTINATION}"

	[ ! -s "${DESTINATION}" ]
}
