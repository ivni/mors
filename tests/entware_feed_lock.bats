#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	SOURCE_REPO=${BATS_TEST_TMPDIR}/source
	FEED_REPO=${BATS_TEST_TMPDIR}/buildroot/feeds/packages
	LOCK_FILE=${BATS_TEST_TMPDIR}/entware.lock

	mkdir -p "${SOURCE_REPO}" "$(dirname "${FEED_REPO}")"
	git -C "${SOURCE_REPO}" init -q
	git -C "${SOURCE_REPO}" config user.name 'Mors QA'
	git -C "${SOURCE_REPO}" config user.email 'qa@mors.invalid'
	printf '%s\n' first >"${SOURCE_REPO}/version"
	git -C "${SOURCE_REPO}" add version
	git -C "${SOURCE_REPO}" commit -q -m first
	FIRST_REVISION="$(git -C "${SOURCE_REPO}" rev-parse HEAD)"
	printf '%s\n' second >"${SOURCE_REPO}/version"
	git -C "${SOURCE_REPO}" commit -q -am second
	SECOND_REVISION="$(git -C "${SOURCE_REPO}" rev-parse HEAD)"
	git clone -q "${SOURCE_REPO}" "${FEED_REPO}"
	printf 'entware %s %s\npackages %s %s\n' \
		"${SOURCE_REPO}" "${FIRST_REVISION}" \
		"${SOURCE_REPO}" "${FIRST_REVISION}" >"${LOCK_FILE}"
}

@test "existing feed is switched to its locked revision" {
	[ "$(git -C "${FEED_REPO}" rev-parse HEAD)" = "${SECOND_REVISION}" ]

	run bash "${REPO_ROOT}/scripts/qa/entware-feed-lock.sh" \
		sync-existing "${LOCK_FILE}" "${BATS_TEST_TMPDIR}/buildroot"
	[ "${status}" -eq 0 ]
	[ "$(git -C "${FEED_REPO}" rev-parse HEAD)" = "${FIRST_REVISION}" ]

	run bash "${REPO_ROOT}/scripts/qa/entware-feed-lock.sh" \
		verify "${LOCK_FILE}" "${BATS_TEST_TMPDIR}/buildroot"
	[ "${status}" -eq 0 ]
}

@test "dirty locked feed is rejected" {
	printf '%s\n' changed >"${FEED_REPO}/version"

	run bash "${REPO_ROOT}/scripts/qa/entware-feed-lock.sh" \
		sync-existing "${LOCK_FILE}" "${BATS_TEST_TMPDIR}/buildroot"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *'has local changes: packages'* ]]
}
