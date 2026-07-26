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

@test "prerelease package declares E2E runtime dependencies" {
	local dependencies=${REPO_ROOT}/builder/entware/runtime-dependencies.mk

	grep -q 'PKG_VERSION:=1.3.0~rc1' "${REPO_ROOT}/Makefile"
	grep -q 'DEPENDS:=$(MORS_RUNTIME_DEPENDS)' "${REPO_ROOT}/Makefile"
	grep -q '+conntrack' "${dependencies}"
	grep -q '+coreutils-cksum' "${dependencies}"
	grep -q '+coreutils-timeout' "${dependencies}"
	grep -q '+shadowsocks-libev-ss-local' "${dependencies}"
}

@test "package QA builds host opkg before the version gate" {
	grep -q 'package/opkg/host/compile' "${REPO_ROOT}/scripts/qa/entware-build.sh"
	grep -q 'Entware host opkg was not built' "${REPO_ROOT}/scripts/qa/entware-build.sh"
	grep -q -- '--conf /dev/null compare-versions' "${REPO_ROOT}/scripts/qa/opkg-version-order.sh"
}

@test "package QA pins and validates the complete Entware source set" {
	local lock=${REPO_ROOT}/scripts/qa/entware.lock
	local expected_names='entware packages routing telephony oldports rtndev golang rustlang'

	[ -f "${lock}" ]
	[ "$(awk '!/^($|#)/ { count++ } END { print count + 0 }' "${lock}")" -eq 8 ]
	[ "$(awk '!/^($|#)/ { print $1 }' "${lock}" | xargs)" = "${expected_names}" ]
	! awk '!/^($|#)/ && ($3 !~ /^[0-9a-f]{40}$/ || NF != 3) { invalid=1 } END { exit invalid ? 0 : 1 }' "${lock}"
	grep -q 'checkout --detach "${entware_revision}"' "${REPO_ROOT}/scripts/qa/entware-build.sh"
	grep -q "printf 'src-git %s %s\^%s" "${REPO_ROOT}/scripts/qa/entware-build.sh"
}
