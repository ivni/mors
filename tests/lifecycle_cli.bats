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

@test "ndm library is finalized in the package and never rewritten at runtime" {
	local install_body postinst vpn
	install_body=$(sed -n '/^define Package\/mors\/install/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	postinst=$(sed -n '/^define Package\/mors\/postinst/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	vpn=${REPO_ROOT}/opt/bin/libs/vpn

	[ -f "${REPO_ROOT}/opt/bin/libs/ndm" ]
	[ ! -e "${REPO_ROOT}/opt/etc/ndm/ndm" ]
	grep -Fq 'chmod -R 0755 $(1)/opt/apps/mors/bin/*' <<<"${install_body}"
	! grep -Fq 'cp -f /opt/apps/mors/etc/ndm/ndm /opt/apps/mors/bin/libs/ndm' <<<"${postinst}"
	grep -Fq 'ownership__record_checksum /opt/apps/mors/bin/libs/ndm package-ndm.cksum' <<<"${postinst}"
	! grep -Eq '^[[:space:]]*(cp|mv|chmod|sed -i).*bin/libs/ndm' "${vpn}"
}

@test "postrm removes only the known legacy ndm residue and empty package tree" {
	local cleanup fake_root marker outside checksum
	cleanup=$(sed -n '/^mors_postrm__cleanup_package_tree()/,/^}/p' \
		"${REPO_ROOT}/Makefile" | tr -d '\r' | sed 's/\$\$/\$/g')
	[ -n "${cleanup}" ]

	fake_root=${BATS_TEST_TMPDIR}/legacy
	marker=${BATS_TEST_TMPDIR}/legacy-marker
	mkdir -p "${fake_root}/opt/apps/mors/bin/libs"
	printf '%s\n' legacy >"${fake_root}/opt/apps/mors/bin/libs/ndm"
	checksum=$(cksum "${fake_root}/opt/apps/mors/bin/libs/ndm")
	set -- ${checksum}
	printf '%s %s\n' "${1}" "${2}" >"${marker}"
	run sh -c "${cleanup}
		mors_postrm__cleanup_package_tree \"\$1\" \"\$2\"" sh \
		"${fake_root}/opt/apps/mors" "${marker}"
	[ "${status}" -eq 0 ]
	[ ! -e "${fake_root}/opt/apps/mors" ]
	[ ! -e "${marker}" ]

	fake_root=${BATS_TEST_TMPDIR}/operator-file
	marker=${BATS_TEST_TMPDIR}/operator-marker
	mkdir -p "${fake_root}/opt/apps/mors/bin/libs"
	printf '%s\n' legacy >"${fake_root}/opt/apps/mors/bin/libs/ndm"
	printf '%s\n' operator >"${fake_root}/opt/apps/mors/bin/libs/custom"
	checksum=$(cksum "${fake_root}/opt/apps/mors/bin/libs/ndm")
	set -- ${checksum}
	printf '%s %s\n' "${1}" "${2}" >"${marker}"
	run sh -c "${cleanup}
		mors_postrm__cleanup_package_tree \"\$1\" \"\$2\"" sh \
		"${fake_root}/opt/apps/mors" "${marker}"
	[ "${status}" -ne 0 ]
	[ ! -e "${fake_root}/opt/apps/mors/bin/libs/ndm" ]
	[ -f "${fake_root}/opt/apps/mors/bin/libs/custom" ]

	fake_root=${BATS_TEST_TMPDIR}/symlink
	marker=${BATS_TEST_TMPDIR}/symlink-marker
	outside=${BATS_TEST_TMPDIR}/outside
	mkdir -p "${fake_root}/opt/apps/mors" "${outside}/libs"
	printf '%s\n' external >"${outside}/libs/ndm"
	ln -s "${outside}" "${fake_root}/opt/apps/mors/bin"
	run sh -c "${cleanup}
		mors_postrm__cleanup_package_tree \"\$1\" \"\$2\"" sh \
		"${fake_root}/opt/apps/mors" "${marker}"
	[ "${status}" -ne 0 ]
	[ -f "${outside}/libs/ndm" ]
}

@test "postrm preserves lifecycle evidence when package-tree cleanup fails" {
	local postrm cleanup_line lifecycle_line
	postrm=$(sed -n '/^define Package\/mors\/postrm/,/^endef/p' \
		"${REPO_ROOT}/Makefile" | tr -d '\r')
	cleanup_line=$(printf '%s\n' "${postrm}" | \
		grep -n '^mors_postrm__cleanup_package_tree \\$' | cut -d: -f1)
	lifecycle_line=$(printf '%s\n' "${postrm}" | \
		grep -n 'rm -rf /opt/etc/.mors' | cut -d: -f1)
	[ -n "${cleanup_line}" ]
	[ -n "${lifecycle_line}" ]
	[ "${cleanup_line}" -lt "${lifecycle_line}" ]
	printf '%s\n' "${postrm}" | \
		grep -A4 '^mors_postrm__cleanup_package_tree \\$' | grep -q 'exit 1'
}

@test "postinst preserves existing user configuration" {
	local postinst
	postinst=$(sed -n '/^define Package\/mors\/postinst/,/^endef/p' "${REPO_ROOT}/Makefile" | tr -d '\r')
	grep -Fq '[ -f /opt/etc/mors.conf ] || cp -f' <<<"${postinst}"
	! grep -q '^cp -f /opt/apps/mors/etc/conf/mors.conf /opt/etc/mors.conf' <<<"${postinst}"
}

@test "router smoke upgrades the legacy package and proves full purge" {
	local smoke=${REPO_ROOT}/scripts/qa/router-smoke.sh workflow=${REPO_ROOT}/.github/workflows/router-smoke.yml
	grep -Fq ': "${LEGACY_IPK_PATH:?LEGACY_IPK_PATH is required}"' "${smoke}"
	grep -Fq 'current_version="$(package_version "${IPK_PATH}"' "${smoke}"
	grep -Fq "CURRENT_VERSION='\${current_version}' LEGACY_VERSION='\${legacy_version}'" "${smoke}"
	grep -Fq 'mors update apply "${CURRENT_PACKAGE}" --rollback-ipk "${LEGACY_PACKAGE}" --yes' "${smoke}"
	grep -Fq '= "${CURRENT_VERSION}"' "${smoke}"
	grep -Fq '= "${LEGACY_VERSION}"' "${smoke}"
	! grep -Fq "1.3.0~rc1-" "${smoke}"
	grep -Fq "[ ! -e /opt/apps/mors/etc/ndm/ndm ]" "${smoke}"
	grep -Fq 'require_passive_snapshot "${remote_dir}/removed"' "${smoke}"
	grep -Fq 'verify_shared_fixture adblock-sources' "${smoke}"
	grep -Fq 'verify_shared_fixture adblock-exception' "${smoke}"
	grep -Fq 'gh release download v1.3.0-beta10' "${workflow}"
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
	grep -q 'upgrade__preflight_artifacts' "${updater}"
	grep -q 'upgrade_artifact__prepare_rollback_stub' "${updater}"
	grep -q 'upgrade__verify_installed_candidate() (' "${updater}"
	grep -q 'upgrade__restart_and_verify' "${updater}"
	grep -q 'setup__verify_committed' "${updater}"
	[ "$(grep -c 'runtime_mutation_lock__acquire_wait_or_explain' "${updater}")" -eq 2 ]
	grep -q 'MORS_UPDATE_RUNTIME_LOCK_WAIT=.*60' "${updater}"
}

@test "update preserves an unconfigured installation without starting runtime" {
	local upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	grep -q 'case "${state}" in ready|unconfigured)' "${upgrade}"
	grep -q 'lifecycle_transaction__begin "${operation}" "${state}" "${state}"' "${upgrade}"
	grep -q 'upgrade__verify_installed_candidate "${state}"' "${upgrade}"
	grep -q 'if \[ "${state}" = ready \]; then' "${upgrade}"
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
	grep -q 'opkg install --force-reinstall --force-downgrade' "${upgrade}"
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
	grep -A15 'MORS_UNINSTALL_PREVIOUS_STATE.*unconfigured' "${setup}" |
		grep -q 'setup__deactivate_telemetry_for_uninstall'
	grep -q 'setup__remove_package' "${setup}"
}

@test "full purge removes owned data before publishing package_remove_ready" {
	local body
	body=$(sed -n '/^setup__remove_package()/,/^}/p' \
		"${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	grep -q 'mors_purge__user_data' <<<"${body}"
	[ "$(grep -n 'mors_purge__user_data' <<<"${body}" | cut -d: -f1)" -lt \
		"$(grep -n 'lifecycle_transaction__phase package_remove_ready' <<<"${body}" | cut -d: -f1)" ]
	[ "$(grep -n 'lifecycle_transaction__phase package_remove_ready' <<<"${body}" | cut -d: -f1)" -lt \
		"$(grep -n 'opkg remove mors' <<<"${body}" | cut -d: -f1)" ]
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
