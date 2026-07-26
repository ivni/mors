#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	export MORS_OWNERSHIP_ROOT=${BATS_TEST_TMPDIR}/etc/.mors/ownership
	. "${REPO_ROOT}/opt/bin/libs/ownership"
}

@test "claimed generic file is removed only with its exact ownership record" {
	local file=${BATS_TEST_TMPDIR}/shared/sources.list marker
	mkdir -p "$(dirname "${file}")"
	printf '%s\n' mors >"${file}"

	ownership__claim_file "${file}" adblock-sources-list
	marker=$(ownership__marker_path adblock-sources-list)
	[ "$(cat "${marker}")" = "${file}" ]
	[ "$(stat -c '%a' "${MORS_OWNERSHIP_ROOT}")" = 700 ]
	[ "$(stat -c '%a' "${marker}")" = 600 ]

	ownership__remove_claimed_file "${file}" adblock-sources-list
	[ ! -e "${file}" ]
	[ ! -e "${marker}" ]
}

@test "missing ownership record preserves a foreign generic file" {
	local file=${BATS_TEST_TMPDIR}/shared/sources.list
	mkdir -p "$(dirname "${file}")"
	printf '%s\n' foreign >"${file}"

	run ownership__remove_claimed_file "${file}" adblock-sources-list
	[ "${status}" -eq 2 ]
	[ "$(cat "${file}")" = foreign ]
}

@test "replacement symlink is preserved and makes owned-file cleanup fail" {
	local file=${BATS_TEST_TMPDIR}/shared/exception.list outside=${BATS_TEST_TMPDIR}/outside
	mkdir -p "$(dirname "${file}")"
	printf '%s\n' mors >"${file}"
	ownership__claim_file "${file}" adblock-exception-list
	rm -f "${file}"
	printf '%s\n' foreign >"${outside}"
	ln -s "${outside}" "${file}"

	run ownership__remove_claimed_file "${file}" adblock-exception-list
	[ "${status}" -ne 0 ]
	[ -L "${file}" ]
	[ "$(cat "${outside}")" = foreign ]
}

@test "package checksum record contains only checksum and byte count" {
	local file=${BATS_TEST_TMPDIR}/ndm marker
	printf '%s\n' payload >"${file}"
	ownership__record_checksum "${file}" package-ndm.cksum
	marker=$(ownership__marker_path package-ndm.cksum)
	grep -Eq '^[0-9]+ [0-9]+$' "${marker}"
}

@test "production ownership path cannot be redirected by inherited environment" {
	MORS_OWNERSHIP_ROOT=${BATS_TEST_TMPDIR}/redirected
	ownership__pin_production
	[ "${MORS_OWNERSHIP_ROOT}" = /opt/etc/.mors/ownership ]
}
