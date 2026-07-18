#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "CLI never launches setup from the global pre-dispatch guard" {
	! grep -q 'Настройка пакета не завершена, запускаем настройку пакета' \
		"${REPO_ROOT}/opt/bin/mors"
	! sed -n '1,/^case "${1}" in/p' "${REPO_ROOT}/opt/bin/mors" | \
		grep -q 'cmd_install'
}

@test "empty CLI is lifecycle status and setup has explicit dispatcher" {
	grep -q 'mors_cli__print_lifecycle_status' "${REPO_ROOT}/opt/bin/mors"
	grep -A4 '^[[:space:]]*setup)' "${REPO_ROOT}/opt/bin/mors" | grep -q 'cmd_setup_cli'
}

@test "VLESS dispatcher preserves health exit codes and keeps JSON undecorated" {
	local cli=${REPO_ROOT}/opt/bin/mors body
	body=$(sed -n '/^[[:space:]]*vless)/,/^[[:space:]]*;;/p' "${cli}" | tr -d '\r')
	grep -q 'vless_status=\$?' <<<"${body}"
	grep -q 'exit "\${vless_status}"' <<<"${body}"
	grep -q '\[ "\${MORS_CLI_JSON_OUTPUT}" = true \] || print_line' <<<"${body}"
	grep -q '^mors_cli__has_json_flag()' "${cli}"
	grep -q '\[ "\${1}" = test \] || \[ "\${MORS_CLI_JSON_OUTPUT}" = true \] || print_line' "${cli}"
}

@test "IPK install payload contains no active system hooks" {
	local install_body
	install_body=$(sed -n '/^define Package\/mors\/install/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	! printf '%s\n' "${install_body}" | grep -q '/opt/etc/init.d'
	! printf '%s\n' "${install_body}" | grep -q '/opt/etc/ndm'
	printf '%s\n' "${install_body}" | grep -q '/opt/apps/mors'
}

@test "postinst preserves existing user configuration" {
	local postinst
	postinst=$(sed -n '/^define Package\/mors\/postinst/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	grep -Fq '[ -f /opt/etc/mors.conf ] || cp -f' <<<"${postinst}"
	! grep -q '^cp -f /opt/apps/mors/etc/conf/mors.conf /opt/etc/mors.conf' <<<"${postinst}"
}

@test "all active hooks enforce lifecycle readiness" {
	grep -q 'lifecycle_state__boot_gate' "${REPO_ROOT}/opt/etc/init.d/S96mors"
	grep -q 'lifecycle_state__boot_gate' "${REPO_ROOT}/opt/etc/ndm/fs.d/15-mors-start.sh"
	for hook in \
		opt/etc/ndm/ifcreated.d/mors-iface-add \
		opt/etc/ndm/ifdestroyed.d/mors-iface-del \
		opt/etc/ndm/iflayerchanged.d/100-mors-vpn \
		opt/etc/ndm/netfilter.d/100-dns-local \
		opt/etc/ndm/netfilter.d/100-vpn-mark \
		opt/etc/ndm/netfilter.d/100-proxy-redirect \
		opt/bin/main/vless-watchdog \
		opt/bin/main/check_vpn \
		opt/etc/init.d/S25mors-vless \
		opt/etc/init.d/S97xray; do
		grep -q 'lifecycle_state__runtime_allowed' "${REPO_ROOT}/${hook}"
	done
}

@test "boot attempts lifecycle recovery before normal initialization" {
	local init=${REPO_ROOT}/opt/etc/init.d/S96mors
	grep -q 'cmd_setup_recover' "${init}"
	grep -q 'main/upgrade recover --yes' "${init}"
	grep -q 'setup:awaiting_reboot' "${init}"
	grep -q '\*:completed' "${init}"
	[ "$(grep -n 'cmd_setup_recover' "${init}" | cut -d: -f1)" -lt \
		"$(grep -n 'cmd_mors_init no' "${init}" | head -n 1 | cut -d: -f1)" ]
}

@test "setup publishes active hooks only inside its transaction" {
	grep -q '^setup__activate_core_hooks()' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'lifecycle_transaction__finish' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'MORS_DEFER_SYSTEM_HOOKS=true' "${REPO_ROOT}/opt/bin/main/setup"
	grep -q 'MORS_DEFER_SYSTEM_HOOKS' "${REPO_ROOT}/opt/bin/libs/vpn"
}

@test "update is in-place verified and has a prepared rollback artifact" {
	local updater=${REPO_ROOT}/opt/bin/main/upgrade
	! grep -q 'mors uninstall' "${updater}"
	grep -q 'upgrade__verify_artifact' "${updater}"
	grep -q -- '--rollback-ipk' "${updater}"
	grep -q 'upgrade__install_artifact "${operation}" "${MORS_UPDATE_ARTIFACT}"' "${updater}"
	grep -q 'upgrade__rollback_failed_apply' "${updater}"
	grep -q 'upgrade__recover_locked' "${updater}"
	grep -q 'upgrade__run_migrations' "${updater}"
	grep -q 'upgrade__reload_installed_runtime' "${updater}"
	grep -q 'upgrade__restart_and_verify' "${updater}"
	grep -q 'setup__verify_committed' "${updater}"
}

@test "update preserves an unconfigured installation without starting runtime" {
	local upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	grep -q 'case "${state}" in ready|unconfigured)' "${upgrade}"
	grep -q 'lifecycle_transaction__begin "${operation}" "${state}" "${state}"' "${upgrade}"
	grep -q '\[ "${result:-0}" -eq 0 \] && \[ "${state}" = ready \]' "${upgrade}"
	grep -q 'upgrade__verify_unconfigured' "${upgrade}"
	grep -q 'upgrade__verify_passive_runtime' "${upgrade}"
	grep -q 'setup__verify_runtime_removed' "${upgrade}"
	grep -q 'telemetry_lifecycle__passive_runtime_removed' "${REPO_ROOT}/opt/bin/main/setup"
}

@test "passive recovery verifies runtime before restoring the stable state" {
	local upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	[ "$(grep -c 'upgrade__verify_passive_runtime' "${upgrade}")" -ge 4 ]
	grep -q 'lifecycle_transaction__rollback_finish' "${upgrade}"
}

@test "rollback explicitly allows opkg to install an older package" {
	local upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	grep -q 'rollback) opkg install --force-downgrade "${artifact}"' "${upgrade}"
	grep -q 'opkg install --force-downgrade "${MORS_UPDATE_ROLLBACK}"' "${upgrade}"
}

@test "maintainer scripts read a missing active marker without shell redirection errors" {
	local makefile=${REPO_ROOT}/Makefile
	run grep -q 'lifecycle/active 2>/dev/null' "${makefile}"
	[ "${status}" -eq 1 ]
	grep -q '\[ ! -r /opt/etc/.mors/lifecycle/active \]' "${makefile}"
}

@test "package maintainer scripts gate remove and upgrade transactions" {
	local prerm postrm
	prerm=$(sed -n '/^define Package\/mors\/prerm/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	postrm=$(sed -n '/^define Package\/mors\/postrm/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	grep -q 'package_remove_ready' <<<"${prerm}"
	grep -q 'transaction_operation' <<<"${prerm}"
	grep -q 'mors uninstall --yes' <<<"${prerm}"
	grep -q 'outcome.*success' <<<"${postrm}"
	! grep -qw jq <<<"${postrm}"
	[ "$(grep -n 'outcome.*success' <<<"${postrm}" | cut -d: -f1)" -lt \
		"$(grep -n 'state.*unconfigured' <<<"${postrm}" | cut -d: -f1)" ]
}

@test "uninstall verifies cleanup and restores DNS before package removal" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	! grep -q 'opkg remove mors --autoremove' "${setup}"
	grep -q 'setup__verify_runtime_removed' "${setup}"
	grep -q 'штатный DNS после очистки Mors' "${setup}"
	[ "$(grep -n 'setup__verify_runtime_removed &&' "${setup}" | head -n 1 | cut -d: -f1)" -lt \
		"$(grep -n 'opkg remove mors' "${setup}" | head -n 1 | cut -d: -f1)" ]
}

@test "unconfigured uninstall uses a passive package removal branch" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	grep -q 'MORS_UNINSTALL_PREVIOUS_STATE.*unconfigured' "${setup}"
	grep -q 'Проверяем пассивное состояние Mors' "${setup}"
	grep -q 'setup__remove_package' "${setup}"
}

@test "legacy setup and uninstall bodies cannot exit past rollback wrappers" {
	local setup=${REPO_ROOT}/opt/bin/main/setup
	grep -B4 'setup__cmd_install_unlocked "\$@"' "${setup}" | grep -q '^[[:space:]]*($'
	grep -B4 'setup__cmd_uninstall_unlocked "\$@"' "${setup}" | grep -q '^[[:space:]]*($'
}

@test "runtime mutators require ready state without an active transaction" {
	grep -A12 'if mors_cli__requires_runtime_lock "\$@"' "${REPO_ROOT}/opt/bin/mors" | \
		grep -q 'lifecycle_state__require_ready'
}
