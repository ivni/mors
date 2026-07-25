#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

function_body() {
	local file=${1} name=${2}
	sed -n "/^${name}()/,/^}/p" "${file}" | tr -d '\r'
}

assert_no_direct_init_action() {
	local body=${1} direct
	direct=$(printf '%s\n' "${body}" | \
		grep -E '(\$\{(XRAY_INIT|VLESS_SUPERVISOR_INIT|ADGUARDHOME_DEMON|TELEMETRY_INIT_SOURCE)\}|/opt/etc/init.d/S(09dnscrypt-proxy2|22shadowsocks|24xray|25mors-vless|56dnsmasq|98mors-telemetry|99adguardhome))[" ]*[[:space:]]+(status|stop|start|restart)' | \
		grep -Ev '(service_action|service_state|vless_runtime__supervisor_service)' || true)
	[ -z "${direct}" ]
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
	grep -q 'lifecycle__run_locked upgrade__apply_locked' "${REPO_ROOT}/opt/bin/main/upgrade"

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

@test "initial VLESS setup permits an empty fail-closed registry" {
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	grep -q 'empty_setup=true' "${vpn}"
	grep -q "VLESS ещё не настроен: трафик закрыт" "${vpn}"
	grep -q 'vless_domain__apply_generated.*false' "${vpn}"
}

@test "Xray candidate and rollback configs retain a JSON extension" {
	local vless=${REPO_ROOT}/opt/bin/libs/vless
	grep -Fq 'candidate="${VLESS_CONFIG_FILE}.candidate.$$.json"' "${vless}"
	grep -Fq 'rollback_config="${VLESS_CONFIG_FILE}.rollback.$$.json"' "${vless}"
}

@test "dnsmasq install stage returns success without starting runtime early" {
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	local body
	body=$(sed -n '/^dnsmasq_install(){/,/^}/p' "${vpn}" | tr -d '\r')
	grep -q 'if \[ -z "${is_install_stage}" \]; then' <<<"${body}"
	grep -q 'cmd_mors_init "no" || return 1' <<<"${body}"
	grep -q '^[[:space:]]*return 0$' <<<"${body}"
}

@test "dnscrypt activation errors fail setup instead of only printing a warning" {
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	local body
	body=$(sed -n '/^dns_crypt_install()/,/^}/p' "${vpn}" | tr -d '\r')
	grep -q 'activation_result=\$?' <<<"${body}"
	grep -q '\[ "${activation_result}" -ne 0 \].*\[ -s "${ERROR_LOG_FILE}" \]' <<<"${body}"
	grep -A2 'ready_status 1' <<<"${body}" | grep -q 'return 1'
}

@test "dnscrypt setup prepares config without restarting services before commit" {
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	local install_body activation_body init_body
	install_body=$(sed -n '/^dns_crypt_install()/,/^}/p' "${vpn}" | tr -d '\r')
	activation_body=$(sed -n '/^cmd_dns_crypt_on()/,/^}/p' "${vpn}" | tr -d '\r')
	init_body=$(sed -n '/^cmd_mors_init()/,/^}/p' "${vpn}" | tr -d '\r')
	grep -q 'cmd_dns_crypt_on "${activation_mode}"' <<<"${install_body}"
	grep -q 'dns_crypt_port_change "${dns_crypt_port}" norestart' <<<"${activation_body}"
	grep -q '\[ "${activation_mode}" = prepare \] || cmd_mors_init' <<<"${activation_body}"
	grep -q 'setup_commit) return 0' <<<"${init_body}"
}

@test "setup reports completion only after lifecycle verification is committed" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	local install_body wrapper finish_line completed_line
	install_body=$(sed -n '/^setup__cmd_install_unlocked()/,/^}/p' "${setup}" | tr -d '\r')
	wrapper=$(sed -n '/^setup__cmd_install_with_runtime()/,/^}/p' "${setup}" | tr -d '\r')
	! grep -q 'Установка пакета МОРС завершена' <<<"${install_body}"
	finish_line=$(grep -n 'lifecycle_transaction__finish' <<<"${wrapper}" | cut -d: -f1)
	completed_line=$(grep -n 'setup__print_install_completed' <<<"${wrapper}" | cut -d: -f1)
	[ "${finish_line}" -lt "${completed_line}" ]
}

@test "managed Proxy21 uses its Keenetic system interface for policy routing" {
	grep -q '^PROXY_VLESS_ENTWARE=t2s${PROXY_INFACE_NUMEBER}$' "${REPO_ROOT}/opt/bin/libs/main"
	grep -q 'managed_entware' "${REPO_ROOT}/opt/bin/libs/setup_plan"
	grep -q 'PROXY_VLESS_ENTWARE:-t2s21' "${REPO_ROOT}/opt/bin/main/setup"
}

@test "route creation failures propagate through VPN activation" {
	local ndm=${REPO_ROOT}/opt/etc/ndm/ndm
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	grep -Eq 'ip4__route__add_table \|\| (return|exit) 1' "${ndm}"
	grep -A2 'Ошибка при добавлении ${submessage}' "${ndm}" | grep -q 'return 1'
	grep -q 'net_interface.*PROXY_VLESS_ENTWARE:-t2s21' "${ndm}"
	grep -A5 'if ip4_firewall_set_all_rules' "${vpn}" | grep -q 'return 1'
	grep -A3 'operation_result=\$?' "${vpn}" | grep -q 'return 1'
}

@test "lifecycle verifier reports the exact failed invariant" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	grep -q '^setup__verify_failed()' "${setup}"
	grep -q 'в таблице ${table} нет единственного default route через ${expected_entware}' "${setup}"
}

@test "transactional setup call paths do not invoke init scripts directly" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	local vpn=${REPO_ROOT}/opt/bin/libs/vpn
	local vless=${REPO_ROOT}/opt/bin/libs/vless
	local telemetry=${REPO_ROOT}/opt/bin/libs/telemetry
	local name body

	for name in setup_adguard restore_adguard all_services_rm_develop_mode \
		setup__cmd_install_unlocked setup__cmd_uninstall_unlocked; do
		body=$(function_body "${setup}" "${name}")
		assert_no_direct_init_action "${body}"
	done
	for name in update_ipset reset_all_connection all_services_restart adguardhome_setup dnsmasq_install shadowsocks_backup \
		shadowsocks_off shadowsocks_on start_vless switch_vpn_on dns_crypt_install; do
		body=$(function_body "${vpn}" "${name}")
		assert_no_direct_init_action "${body}"
	done
	for name in telemetry_lifecycle__quiesce_for_upgrade telemetry_lifecycle__deactivate; do
		body=$(function_body "${telemetry}" "${name}")
		assert_no_direct_init_action "${body}"
	done
	for name in vless_runtime__supervisor_service vless_domain__apply_generated \
		vless_domain__restore_declared_runtime; do
		body=$(function_body "${vless}" "${name}")
		assert_no_direct_init_action "${body}"
	done

	grep -q 'setup_dns__service_action.*ADGUARDHOME_DEMON.*restart' \
		<<<"$(function_body "${setup}" setup_adguard)"
	grep -q 'vpn__service_action.*XRAY_INIT.*restart' \
		<<<"$(function_body "${vpn}" start_vless)"
	grep -q 'vpn__service_wait_running.*XRAY_INIT' \
		<<<"$(function_body "${vpn}" start_vless)"
	grep -q 'vpn__service_state.*S09dnscrypt-proxy2' \
		<<<"$(function_body "${vpn}" dns_crypt_install)"
	grep -q 'vless__service_action.*VLESS_SUPERVISOR_INIT' \
		<<<"$(function_body "${vless}" vless_runtime__supervisor_service)"
	grep -q 'start_vless.*|| {' <<<"$(function_body "${vpn}" switch_vpn_on)"
	grep -q 'vpn_on.*|| return 1' <<<"$(function_body "${vpn}" switch_vpn_on)"
	grep -q 'vpn__lifecycle_failure setup.switch.shadowsocks_off' \
		<<<"$(function_body "${vpn}" switch_vpn_on)"
	grep -q 'telemetry_lifecycle__stop_sender' \
		<<<"$(function_body "${telemetry}" telemetry_lifecycle__deactivate)"
}

@test "runtime Xray process uses external S24 while legacy managed S97 is snapshotted" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	local snapshot=${REPO_ROOT}/opt/bin/libs/lifecycle_snapshot
	local makefile=${REPO_ROOT}/Makefile
	grep -q 'S24xray принадлежит Entware-пакету xray' "${setup}"
	grep -q '\[ -x "${XRAY_INIT}" \]' "${setup}"
	! grep -q 'ln -sf .*S24xray' "${setup}"
	grep -q '/opt/etc/init.d/S24xray' "${snapshot}"
	grep -q '/opt/etc/init.d/S97xray' "${snapshot}"
	! sed -n '/^define Package\/mors\/postrm/,/^endef/p' "${makefile}" | grep -Eq 'S(24|97)xray'
	grep -q 'setup__quiesce_managed_vless_runtime' \
		<<<"$(function_body "${setup}" setup__rollback_transaction)"
	grep -q 'setup__managed_vless_processes_stopped' \
		<<<"$(function_body "${setup}" setup__verify_runtime_removed)"
}

@test "legacy Xray hook migration removes only the Mors-owned symlink" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	local legacy=${BATS_TEST_TMPDIR}/S97xray source=${BATS_TEST_TMPDIR}/source
	for name in setup__legacy_xray_hook_state setup__selected_interface_is_vless \
		setup__remove_managed_legacy_xray_hook setup__retire_legacy_xray_hook; do
		eval "$(function_body "${setup}" "${name}")"
	done
	PROXY_VLESS_NAME=Mors-proxy-vless
	MORS_SETUP_INTERFACE_CLI=${PROXY_VLESS_NAME}
	MORS_LEGACY_XRAY_INIT=${legacy}
	MORS_XRAY_INIT_SOURCE=${source}
	error() { :; }
	get_config_value() { :; }
	touch "${source}"

	[ "$(setup__legacy_xray_hook_state)" = missing ]
	ln -s "${source}" "${legacy}"
	[ "$(setup__legacy_xray_hook_state)" = managed ]
	setup__retire_legacy_xray_hook
	[ ! -e "${legacy}" ]

	printf '%s\n' external >"${legacy}"
	run setup__retire_legacy_xray_hook
	[ "${status}" -ne 0 ]
	[ -f "${legacy}" ]
}

@test "external legacy Xray conflict is rejected before setup can switch runtime" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	local legacy=${BATS_TEST_TMPDIR}/S97xray xray=${BATS_TEST_TMPDIR}/S24xray
	for name in setup__legacy_xray_hook_state setup__selected_interface_is_vless \
		setup__preflight_xray_hooks; do
		eval "$(function_body "${setup}" "${name}")"
	done
	PROXY_VLESS_NAME=Mors-proxy-vless
	MORS_SETUP_INTERFACE_CLI=${PROXY_VLESS_NAME}
	MORS_LEGACY_XRAY_INIT=${legacy}
	MORS_XRAY_INIT_SOURCE=${BATS_TEST_TMPDIR}/packaged-S97xray
	XRAY_INIT=${xray}
	error() { :; }
	get_config_value() { :; }
	printf '%s\n' external >"${legacy}"
	: >"${xray}"
	chmod +x "${xray}"

	run setup__preflight_xray_hooks
	[ "${status}" -ne 0 ]

	local preflight_line prepare_line switch_line
	preflight_line=$(grep -n 'setup__preflight_xray_hooks || return 1' "${setup}" | head -n 1 | cut -d: -f1)
	prepare_line=$(grep -n 'setup__prepare_selected_interface || return' "${setup}" | head -n 1 | cut -d: -f1)
	switch_line=$(grep -n 'switch_vpn_on "${MORS_SETUP_INTERFACE_ENTWARE}"' "${setup}" | head -n 1 | cut -d: -f1)
	[ "${preflight_line}" -lt "${prepare_line}" ]
	[ "${preflight_line}" -lt "${switch_line}" ]
}
