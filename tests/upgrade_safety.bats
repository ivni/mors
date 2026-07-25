#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	. "${REPO_ROOT}/opt/bin/libs/upgrade_artifact"
	WORK="${BATS_TEST_TMPDIR}/work"
	mkdir -p "${WORK}"
}

write_digest() {
	local path=${1}
	printf '%s  %s\n' "$(sha256sum "${path}" | awk '{print $1}')" \
		"$(basename "${path}")" >"${path}.sha256"
}

build_test_ipk() {
	local artifact=${1} runtime_mode=${2:-valid} control_mode=${3:-valid}
	local name root control outer duplicate duplicate_outer=false
	name=$(basename "${artifact}" .ipk)
	root="${BATS_TEST_TMPDIR}/${name}-root"
	control="${BATS_TEST_TMPDIR}/${name}-control"
	outer="${BATS_TEST_TMPDIR}/${name}-outer"
	duplicate="${BATS_TEST_TMPDIR}/${name}-duplicate"
	mkdir -p \
		"${root}/opt/apps/mors/bin/libs" \
		"${root}/opt/apps/mors/bin/main" \
		"${root}/opt/apps/mors/etc/init.d" \
		"${root}/opt/apps/mors/etc/ndm/fs.d" \
		"${control}" "${outer}"
	cat >"${root}/opt/apps/mors/bin/mors" <<'SH'
#!/bin/sh
touch "${PREFLIGHT_EXECUTION_MARKER}"
exit 0
SH
	cat >"${root}/opt/apps/mors/bin/libs/main" <<'SH'
#!/bin/sh
main__valid() {
	printf '%s\n' valid
}
SH
	cat >"${root}/opt/apps/mors/bin/main/upgrade" <<'SH'
#!/bin/sh
exit 0
SH
	cat >"${root}/opt/apps/mors/etc/init.d/S96mors" <<'SH'
#!/bin/sh
exit 0
SH
	cat >"${root}/opt/apps/mors/etc/ndm/fs.d/15-mors-start.sh" <<'SH'
#!/bin/sh
exit 0
SH
	cat >"${control}/postinst" <<'SH'
#!/bin/sh
exit 0
SH
	cat >"${control}/prerm" <<'SH'
#!/bin/sh
exit 0
SH
	cat >"${control}/control" <<'EOF'
Package: mors
Version: 1.0.0-1
Architecture: all
EOF
	case "${runtime_mode}" in
		valid) ;;
		syntax_error)
			cat >"${root}/opt/apps/mors/bin/libs/main" <<'SH'
#!/bin/sh
if true; then
SH
			;;
		missing_shebang)
			printf '%s\n' 'exit 0' >"${root}/opt/apps/mors/bin/libs/main"
			;;
		lifecycle_collision)
			mkdir -p "${root}/opt/etc/.mors/lifecycle"
			printf '%s\n' '#!/bin/sh' >"${root}/opt/etc/.mors/lifecycle/rollback-active.sh"
			;;
		symlink_escape)
			ln -s /opt/etc/.mors/lifecycle \
				"${root}/opt/apps/mors/bin/lifecycle-link"
			;;
		duplicate_outer)
			duplicate_outer=true
			;;
		*) return 64 ;;
	esac
	case "${control_mode}" in
		valid) ;;
		syntax_error)
			cat >"${control}/postinst" <<'SH'
#!/bin/sh
case broken in
SH
			;;
		duplicate_metadata) ;;
		duplicate_field)
			printf '%s\n' 'Package: other' >>"${control}/control"
			;;
		*) return 64 ;;
	esac
	tar -czf "${outer}/data.tar.gz" -C "${root}" .
	if [ "${control_mode}" = duplicate_metadata ]; then
		mkdir -p "${duplicate}"
		cp "${control}/control" "${duplicate}/control"
		tar --no-recursion -czf "${outer}/control.tar.gz" -C "${control}" \
			./ ./control -C "${duplicate}" ./control \
			-C "${control}" ./postinst ./prerm
	else
		tar -czf "${outer}/control.tar.gz" -C "${control}" .
	fi
	printf '%s\n' '2.0' >"${outer}/debian-binary"
	if [ "${duplicate_outer}" = true ]; then
		mkdir -p "${duplicate}"
		cp "${outer}/data.tar.gz" "${duplicate}/data.tar.gz"
		tar -czf "${artifact}" -C "${outer}" \
			./debian-binary ./data.tar.gz \
			-C "${duplicate}" ./data.tar.gz \
			-C "${outer}" ./control.tar.gz
	else
		tar -czf "${artifact}" -C "${outer}" \
			./debian-binary ./data.tar.gz ./control.tar.gz
	fi
}

make_mock_opkg() {
	local path=${1}
	mkdir -p "$(dirname "${path}")"
	cat >"${path}" <<'SH'
#!/bin/sh
case "${1:-}" in
	install)
		printf '%s\n' "$*" >"${ROLLBACK_TEST_LOG}"
		;;
	status)
		printf '%s\n' \
			'Package: mors' \
			"Version: ${ROLLBACK_TEST_STATUS_VERSION:-1.0.0-1}" \
			'Status: install user installed'
		;;
	*) exit 64 ;;
esac
SH
	chmod +x "${path}"
}

load_candidate_verification_functions() {
	eval "$(
		awk '
			/^upgrade__verify_installed_candidate\(\) \(/ { capture = 1 }
			/^upgrade__parse_apply\(\)/ { capture = 0 }
			capture { print }
		' "${REPO_ROOT}/opt/bin/main/upgrade"
	)"
}

@test "shell preflight validates runtime and maintainer scripts without executing them" {
	artifact="${BATS_TEST_TMPDIR}/valid.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" valid valid

	upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ ! -e "${PREFLIGHT_EXECUTION_MARKER}" ]
	[ -z "$(find "${WORK}" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "shell preflight preserves the caller umask" {
	artifact="${BATS_TEST_TMPDIR}/valid-umask.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" valid valid
	umask 022

	upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "$(umask)" = 0022 ]
}

@test "shell preflight rejects a syntax error in packaged runtime" {
	artifact="${BATS_TEST_TMPDIR}/runtime-invalid.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" syntax_error valid

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Синтаксическая ошибка shell в IPK: ./opt/apps/mors/bin/libs/main"* ]]
	[ ! -e "${PREFLIGHT_EXECUTION_MARKER}" ]
}

@test "shell preflight rejects a syntax error in maintainer scripts" {
	artifact="${BATS_TEST_TMPDIR}/control-invalid.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" valid syntax_error

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Синтаксическая ошибка shell в IPK: ./postinst"* ]]
}

@test "shell preflight rejects a packaged shell file without the target shebang" {
	artifact="${BATS_TEST_TMPDIR}/shebang-invalid.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" missing_shebang valid

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Shell-файл IPK не использует /bin/sh"* ]]
}

@test "shell preflight rejects data payload outside canonical Mors root" {
	artifact="${BATS_TEST_TMPDIR}/collision.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" lifecycle_collision valid

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Data payload IPK выходит за /opt/apps/mors"* ]]
}

@test "shell preflight rejects a symlink that can escape the canonical data root" {
	artifact="${BATS_TEST_TMPDIR}/symlink-escape.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" symlink_escape valid

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"IPK содержит небезопасный тип объекта"* ]]
	[ ! -e "${PREFLIGHT_EXECUTION_MARKER}" ]
}

@test "shell preflight rejects duplicate outer data payload" {
	artifact="${BATS_TEST_TMPDIR}/duplicate-outer.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" duplicate_outer valid

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"IPK содержит дублирующийся объект: ./data.tar.gz"* ]]
}

@test "shell preflight rejects duplicate control metadata" {
	artifact="${BATS_TEST_TMPDIR}/duplicate-control.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" valid duplicate_metadata

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"IPK содержит дублирующийся объект: ./control"* ]]
}

@test "shell preflight rejects duplicate identity fields in control metadata" {
	artifact="${BATS_TEST_TMPDIR}/duplicate-control-field.ipk"
	export PREFLIGHT_EXECUTION_MARKER="${BATS_TEST_TMPDIR}/preflight-executed"
	build_test_ipk "${artifact}" valid duplicate_field

	run upgrade_artifact__preflight "${artifact}" "${WORK}" candidate

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Control metadata IPK содержит неуникальное поле: Package"* ]]
}

@test "prepared rollback stub restores the staged package without Mors runtime" {
	lifecycle_root="${BATS_TEST_TMPDIR}/lifecycle"
	active_id=upgrade-123-456
	snapshot="${lifecycle_root}/transactions/${active_id}/snapshot"
	stub="${lifecycle_root}/rollback-active.sh"
	rollback="${snapshot}/rollback.ipk"
	mock_opkg="${BATS_TEST_TMPDIR}/mock-bin/opkg"
	export ROLLBACK_TEST_LOG="${BATS_TEST_TMPDIR}/opkg.log"
	mkdir -p "${snapshot}"
	printf '%s\n' "${active_id}" >"${lifecycle_root}/active"
	build_test_ipk "${rollback}" valid valid
	write_digest "${rollback}"
	fingerprint=$(upgrade_artifact__verified_digest "${rollback}")
	make_mock_opkg "${mock_opkg}"

	upgrade_artifact__prepare_rollback_stub "${snapshot}" "${fingerprint}" \
		"${stub}" "${mock_opkg}"

	[ "$(stat -c '%a' "${stub}")" = 700 ]
	run grep -q '/opt/apps/mors' "${stub}"
	[ "${status}" -ne 0 ]
	/bin/sh -n "${stub}"
	run /bin/sh "${stub}"
	[ "${status}" -eq 0 ]
	grep -Fq "install --force-reinstall --force-downgrade ${rollback}" "${ROLLBACK_TEST_LOG}"
}

@test "rollback stub preparation rejects duplicate identity fields" {
	lifecycle_root="${BATS_TEST_TMPDIR}/lifecycle"
	active_id=upgrade-123-duplicate
	snapshot="${lifecycle_root}/transactions/${active_id}/snapshot"
	stub="${lifecycle_root}/rollback-active.sh"
	rollback="${snapshot}/rollback.ipk"
	mock_opkg="${BATS_TEST_TMPDIR}/mock-bin/opkg"
	mkdir -p "${snapshot}"
	printf '%s\n' "${active_id}" >"${lifecycle_root}/active"
	build_test_ipk "${rollback}" valid duplicate_field
	write_digest "${rollback}"
	fingerprint=$(upgrade_artifact__verified_digest "${rollback}")
	make_mock_opkg "${mock_opkg}"

	run upgrade_artifact__prepare_rollback_stub "${snapshot}" "${fingerprint}" \
		"${stub}" "${mock_opkg}"

	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Control metadata IPK содержит неуникальное поле: Package"* ]]
	[ ! -e "${stub}" ]
}

@test "rollback stub rejects a staged package changed after preparation" {
	lifecycle_root="${BATS_TEST_TMPDIR}/lifecycle"
	active_id=rollback-123-456
	snapshot="${lifecycle_root}/transactions/${active_id}/snapshot"
	stub="${lifecycle_root}/rollback-active.sh"
	rollback="${snapshot}/rollback.ipk"
	mock_opkg="${BATS_TEST_TMPDIR}/mock-bin/opkg"
	export ROLLBACK_TEST_LOG="${BATS_TEST_TMPDIR}/opkg.log"
	mkdir -p "${snapshot}"
	printf '%s\n' "${active_id}" >"${lifecycle_root}/active"
	build_test_ipk "${rollback}" valid valid
	write_digest "${rollback}"
	fingerprint=$(upgrade_artifact__verified_digest "${rollback}")
	make_mock_opkg "${mock_opkg}"
	upgrade_artifact__prepare_rollback_stub "${snapshot}" "${fingerprint}" \
		"${stub}" "${mock_opkg}"
	printf '%s\n' tampered >"${rollback}"

	run /bin/sh "${stub}"

	[ "${status}" -eq 72 ]
	[ ! -e "${ROLLBACK_TEST_LOG}" ]
}

@test "rollback stub rejects an installed version different from staged rollback" {
	lifecycle_root="${BATS_TEST_TMPDIR}/lifecycle"
	active_id=upgrade-123-789
	snapshot="${lifecycle_root}/transactions/${active_id}/snapshot"
	stub="${lifecycle_root}/rollback-active.sh"
	rollback="${snapshot}/rollback.ipk"
	mock_opkg="${BATS_TEST_TMPDIR}/mock-bin/opkg"
	export ROLLBACK_TEST_LOG="${BATS_TEST_TMPDIR}/opkg.log"
	export ROLLBACK_TEST_STATUS_VERSION=9.9.9-9
	mkdir -p "${snapshot}"
	printf '%s\n' "${active_id}" >"${lifecycle_root}/active"
	build_test_ipk "${rollback}" valid valid
	write_digest "${rollback}"
	fingerprint=$(upgrade_artifact__verified_digest "${rollback}")
	make_mock_opkg "${mock_opkg}"
	upgrade_artifact__prepare_rollback_stub "${snapshot}" "${fingerprint}" \
		"${stub}" "${mock_opkg}"

	run /bin/sh "${stub}"

	[ "${status}" -eq 74 ]
	[[ "${output}" == *"точную rollback-версию"* ]]
}

@test "rollback stub preparation preserves the caller umask" {
	lifecycle_root="${BATS_TEST_TMPDIR}/lifecycle"
	active_id=upgrade-123-790
	snapshot="${lifecycle_root}/transactions/${active_id}/snapshot"
	stub="${lifecycle_root}/rollback-active.sh"
	rollback="${snapshot}/rollback.ipk"
	mock_opkg="${BATS_TEST_TMPDIR}/mock-bin/opkg"
	mkdir -p "${snapshot}"
	printf '%s\n' "${active_id}" >"${lifecycle_root}/active"
	build_test_ipk "${rollback}" valid valid
	write_digest "${rollback}"
	fingerprint=$(upgrade_artifact__verified_digest "${rollback}")
	make_mock_opkg "${mock_opkg}"
	umask 022

	upgrade_artifact__prepare_rollback_stub "${snapshot}" "${fingerprint}" \
		"${stub}" "${mock_opkg}"

	[ "$(umask)" = 0022 ]
}

@test "candidate top-level exit zero cannot attest success or commit" {
	snapshot="${BATS_TEST_TMPDIR}/snapshot"
	finish_marker="${BATS_TEST_TMPDIR}/finished"
	mkdir -p "${snapshot}"
	load_candidate_verification_functions
	lifecycle_transaction__snapshot_directory() { printf '%s\n' "${snapshot}"; }
	upgrade__reload_installed_runtime() { exit 0; }
	lifecycle_transaction__finish() { touch "${finish_marker}"; }

	run upgrade__commit_installed_candidate ready

	[ "${status}" -ne 0 ]
	[ ! -e "${snapshot}/candidate-verified" ]
	[ ! -e "${finish_marker}" ]
}

@test "upgrade preflights before transaction and isolates candidate runtime loading" {
	upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	preflight_line=$(grep -n $'^\tupgrade__preflight_artifacts || return 64$' "${upgrade}" | cut -d: -f1)
	lock_line=$(grep -n $'^\truntime_mutation_lock__acquire_wait_or_explain "mors ${operation}"' "${upgrade}" | cut -d: -f1)

	[ "${preflight_line}" -lt "${lock_line}" ]
	grep -Fq 'upgrade__verify_installed_candidate() (' "${upgrade}"
	grep -Fq 'upgrade__commit_installed_candidate "${state}" || result=1' "${upgrade}"
	grep -Fq 'upgrade_artifact__prepare_rollback_stub "${snapshot}" "${rollback_fingerprint}"' "${upgrade}"
}
