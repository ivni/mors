#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source <(sed -n '/^is_supported_keenetic_os()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/main")
}

@test "Mors supports KeeneticOS 5 and newer" {
	run is_supported_keenetic_os 4.2.4
	[ "${status}" -ne 0 ]

	run is_supported_keenetic_os 5.0.0
	[ "${status}" -eq 0 ]

	run is_supported_keenetic_os 6.1.2
	[ "${status}" -eq 0 ]
}

@test "package contains only the KeeneticOS 5 iflayerchanged hook" {
	[ -f "${REPO_ROOT}/opt/etc/ndm/iflayerchanged.d/100-mors-vpn" ]
	[ ! -e "${REPO_ROOT}/opt/etc/ndm/iflayerchanged.d/mors-ips-reset" ]
	[ ! -e "${REPO_ROOT}/opt/etc/ndm/ifstatechanged.d/100-mors-vpn" ]
	[ ! -e "${REPO_ROOT}/opt/etc/ndm/ifstatechanged.d/100-unblock-vpn" ]
	! grep -R -q 'get_hook_dir' "${REPO_ROOT}/opt"
}

@test "beta package declares E2E runtime dependencies" {
	grep -q 'PKG_VERSION:=1.3.0~beta1' "${REPO_ROOT}/Makefile"
	grep -q '+conntrack' "${REPO_ROOT}/Makefile"
	grep -q '+coreutils-timeout' "${REPO_ROOT}/Makefile"
	grep -q '+shadowsocks-libev-ss-local' "${REPO_ROOT}/Makefile"
}
