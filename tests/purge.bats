#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	ROOT=${BATS_TEST_TMPDIR}/root
	export MORS_OWNERSHIP_ROOT=${ROOT}/opt/etc/.mors/ownership
	export MORS_ETC_DATA_ROOT=${ROOT}/opt/etc/mors
	export MORS_VAR_DATA_ROOT=${ROOT}/opt/var/lib/mors
	export MORS_VAR_RUN_ROOT=${ROOT}/opt/var/run/mors
	export MORS_VLESS_STORE_ROOT=${MORS_ETC_DATA_ROOT}/vless
	export MORS_VLESS_STATE_ROOT=${MORS_VAR_DATA_ROOT}/vless
	export MORS_VLESS_RUNTIME_ROOT=${MORS_VAR_RUN_ROOT}/vless
	export MORS_TELEMETRY_CONFIG_ROOT=${MORS_ETC_DATA_ROOT}/telemetry
	export MORS_TELEMETRY_DATA_ROOT=${MORS_VAR_DATA_ROOT}/telemetry
	export MORS_TMP_DATA_ROOT=${ROOT}/tmp/mors
	export MORS_TELEMETRY_STATE_ROOT=${MORS_TMP_DATA_ROOT}/telemetry
	export MORS_TELEMETRY_RUNTIME_ROOT=${MORS_VAR_RUN_ROOT}/telemetry
	export MORS_XRAY_CONFIG_FILE=${ROOT}/opt/etc/xray/mors.json
	export MORS_XRAY_LEGACY_CONFIG_FILE=${MORS_XRAY_CONFIG_FILE}.legacy-1.1.9
	export MORS_ADBLOCK_HOSTS_FILE=${ROOT}/opt/etc/adblock/ads.mors.list
	export MORS_ADBLOCK_SOURCES_FILE=${ROOT}/opt/etc/adblock/sources.list
	export MORS_ADBLOCK_EXCEPTION_FILE=${ROOT}/opt/etc/adblock/exception.list
	. "${REPO_ROOT}/opt/bin/libs/ownership"
	. "${REPO_ROOT}/opt/bin/libs/mors_purge"
}

@test "full purge removes VLESS telemetry generated config and owned adblock data" {
	local path
	for path in \
		"${MORS_VLESS_STORE_ROOT}" \
		"${MORS_VLESS_STATE_ROOT}" \
		"${MORS_VLESS_RUNTIME_ROOT}" \
		"${MORS_TELEMETRY_STATE_ROOT}" \
		"${MORS_TELEMETRY_RUNTIME_ROOT}"; do
		mkdir -p "${path}"
		printf '%s\n' secret >"${path}/data"
	done
	mkdir -p "${MORS_XRAY_CONFIG_FILE%/*}" "${MORS_ADBLOCK_HOSTS_FILE%/*}"
	printf '%s\n' secret >"${MORS_XRAY_CONFIG_FILE}"
	printf '%s\n' secret >"${MORS_XRAY_LEGACY_CONFIG_FILE}"
	printf '%s\n' secret >"${MORS_XRAY_CONFIG_FILE}.candidate.123.json"
	printf '%s\n' secret >"${MORS_XRAY_CONFIG_FILE}.backup.123"
	printf '%s\n' secret >"${MORS_XRAY_CONFIG_FILE}.rollback.123.json"
	printf '%s\n' generated >"${MORS_ADBLOCK_HOSTS_FILE}"
	printf '%s\n' default >"${MORS_ADBLOCK_SOURCES_FILE}"
	printf '%s\n' exception >"${MORS_ADBLOCK_EXCEPTION_FILE}"
	ownership__claim_file "${MORS_ADBLOCK_SOURCES_FILE}" adblock-sources-list
	ownership__claim_file "${MORS_ADBLOCK_EXCEPTION_FILE}" adblock-exception-list

	mors_purge__user_data

	[ ! -e "${MORS_ETC_DATA_ROOT}" ]
	[ ! -e "${MORS_VAR_DATA_ROOT}" ]
	[ ! -e "${MORS_VAR_RUN_ROOT}" ]
	[ ! -e "${MORS_TMP_DATA_ROOT}" ]
	[ ! -e "${MORS_XRAY_CONFIG_FILE}" ]
	[ ! -e "${MORS_XRAY_LEGACY_CONFIG_FILE}" ]
	[ ! -e "${MORS_XRAY_CONFIG_FILE}.candidate.123.json" ]
	[ ! -e "${MORS_XRAY_CONFIG_FILE}.backup.123" ]
	[ ! -e "${MORS_XRAY_CONFIG_FILE}.rollback.123.json" ]
	[ ! -e "${MORS_ADBLOCK_HOSTS_FILE}" ]
	[ ! -e "${MORS_ADBLOCK_SOURCES_FILE}" ]
	[ ! -e "${MORS_ADBLOCK_EXCEPTION_FILE}" ]
}

@test "foreign generic adblock files without ownership records are preserved" {
	mkdir -p "${MORS_ADBLOCK_SOURCES_FILE%/*}"
	printf '%s\n' foreign >"${MORS_ADBLOCK_SOURCES_FILE}"
	printf '%s\n' foreign >"${MORS_ADBLOCK_EXCEPTION_FILE}"

	mors_purge__user_data

	[ "$(cat "${MORS_ADBLOCK_SOURCES_FILE}")" = foreign ]
	[ "$(cat "${MORS_ADBLOCK_EXCEPTION_FILE}")" = foreign ]
}

@test "unexpected data under a Mors root is preserved and blocks success" {
	mkdir -p "${MORS_ETC_DATA_ROOT}"
	printf '%s\n' unknown >"${MORS_ETC_DATA_ROOT}/unknown"

	run mors_purge__user_data

	[ "${status}" -ne 0 ]
	[ "$(cat "${MORS_ETC_DATA_ROOT}/unknown")" = unknown ]
}

@test "symlinked Mors root is preserved and blocks success" {
	local outside=${BATS_TEST_TMPDIR}/outside
	mkdir -p "${MORS_ETC_DATA_ROOT}" "${outside}"
	printf '%s\n' secret >"${outside}/registry.json"
	ln -s "${outside}" "${MORS_VLESS_STORE_ROOT}"

	run mors_purge__user_data

	[ "${status}" -ne 0 ]
	[ "$(cat "${outside}/registry.json")" = secret ]
}

@test "production purge paths cannot be redirected by inherited environment" {
	MORS_ETC_DATA_ROOT=${ROOT}
	MORS_XRAY_CONFIG_FILE=${ROOT}/foreign
	MORS_ADBLOCK_SOURCES_FILE=${ROOT}/foreign-sources

	mors_purge__pin_production

	[ "${MORS_ETC_DATA_ROOT}" = /opt/etc/mors ]
	[ "${MORS_XRAY_CONFIG_FILE}" = /opt/etc/xray/mors.json ]
	[ "${MORS_ADBLOCK_SOURCES_FILE}" = /opt/etc/adblock/sources.list ]
}

@test "symlinked Xray crash artifact is preserved and blocks purge" {
	local outside=${BATS_TEST_TMPDIR}/outside artifact=${MORS_XRAY_CONFIG_FILE}.candidate.42.json
	mkdir -p "${MORS_XRAY_CONFIG_FILE%/*}"
	printf '%s\n' foreign >"${outside}"
	ln -s "${outside}" "${artifact}"

	run mors_purge__user_data

	[ "${status}" -ne 0 ]
	[ -L "${artifact}" ]
	[ "$(cat "${outside}")" = foreign ]
}
