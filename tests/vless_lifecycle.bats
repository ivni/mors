#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "setup preserves the managed store and installs supervisor lifecycle hooks" {
	grep -q 'MORS_BACKUP_PATH}/vless-store' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'S25mors-vless' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'vless-watchdog' "${REPO_ROOT}/opt/bin/main/setup"
}

@test "install update and uninstall share one reentrant lifecycle lock" {
	grep -q 'libs/lifecycle' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'lifecycle__run_locked setup__cmd_install_with_runtime' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'lifecycle__run_locked setup__cmd_uninstall_with_runtime' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'lifecycle__guard_shell' "${REPO_ROOT}/opt/bin/main/upgrade"

	local lock_dir="${BATS_TEST_TMPDIR}/lifecycle.lock"
	run env REPO_ROOT="${REPO_ROOT}" LOCK_DIR="${lock_dir}" bash -c '
		. "${REPO_ROOT}/opt/bin/libs/lifecycle"
		MORS_LIFECYCLE_LOCK_DIR=${LOCK_DIR}
		export MORS_LIFECYCLE_LOCK_DIR
		lifecycle__acquire || exit 1
		[ "${MORS_LIFECYCLE_LOCK_OWNED}" = true ] || exit 2
		bash -c '\''
			. "${REPO_ROOT}/opt/bin/libs/lifecycle"
			lifecycle__acquire || exit 3
			[ "${MORS_LIFECYCLE_LOCK_OWNED}" = false ]
		'\'' || exit 4
		lifecycle__release
	'
	[ "${status}" -eq 0 ]
}

@test "parallel lifecycle operation is rejected and stale lock is recovered" {
	local lock_dir="${BATS_TEST_TMPDIR}/lifecycle.lock"
	run env REPO_ROOT="${REPO_ROOT}" LOCK_DIR="${lock_dir}" bash -c '
		. "${REPO_ROOT}/opt/bin/libs/lifecycle"
		MORS_LIFECYCLE_LOCK_DIR=${LOCK_DIR}
		export MORS_LIFECYCLE_LOCK_DIR
		lifecycle__acquire || exit 1
		env -u MORS_LIFECYCLE_LOCK_TOKEN bash -c '\''
			. "${REPO_ROOT}/opt/bin/libs/lifecycle"
			lifecycle__acquire
		'\'' && exit 2
		lifecycle__release || exit 3
		mkdir -p "${LOCK_DIR}"
		printf "%s\n" 99999999 >"${LOCK_DIR}/pid"
		printf "%s\n" stale >"${LOCK_DIR}/token"
		unset MORS_LIFECYCLE_LOCK_TOKEN
		lifecycle__acquire || exit 4
		lifecycle__release
	'
	[ "${status}" -eq 0 ]
}

@test "full uninstall cannot remove the active lifecycle lock" {
	grep -q '! -path "${MORS_LIFECYCLE_LOCK_DIR}"' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q '! -path "${MORS_LIFECYCLE_LOCK_DIR}/\*"' "${REPO_ROOT}/opt/bin/main/setup"
}

@test "watchdog only runs for active unpaused VLESS" {
	grep -q 'cli_interface.*PROXY_VLESS_NAME' "${REPO_ROOT}/opt/bin/main/vless-watchdog"
	grep -q 'vless_store__is_paused' "${REPO_ROOT}/opt/bin/main/vless-watchdog"
}

@test "boot restarts Xray and supervisor when VLESS is selected" {
	grep -q 'is_vless_over_proxy_enabled' "${REPO_ROOT}/opt/etc/init.d/S96mors"
	grep -q 'S25mors-vless restart' "${REPO_ROOT}/opt/etc/init.d/S96mors"
}

@test "legacy five minute VPN monitor exits for managed VLESS" {
	grep -q '\[ "${CLI_INTERFACE}" = "${PROXY_VLESS_NAME}" \] && exit 0' "${REPO_ROOT}/opt/bin/main/check_vpn"
}
