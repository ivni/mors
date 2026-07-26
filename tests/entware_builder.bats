#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	FIXTURE_ROOT="${BATS_TEST_TMPDIR}/repo"
	mkdir -p \
		"${FIXTURE_ROOT}/builder/entware" \
		"${FIXTURE_ROOT}/scripts/qa"
	cp "${REPO_ROOT}/builder/entware/Dockerfile" \
		"${REPO_ROOT}/builder/entware/Dockerfile.dockerignore" \
		"${REPO_ROOT}/builder/entware/runtime-dependencies.mk" \
		"${FIXTURE_ROOT}/builder/entware/"
	cp "${REPO_ROOT}/scripts/qa/entware.lock" \
		"${REPO_ROOT}/scripts/qa/entware-build.sh" \
		"${REPO_ROOT}/scripts/qa/entware-builder-id.sh" \
		"${REPO_ROOT}/scripts/qa/entware-feed-lock.sh" \
		"${REPO_ROOT}/scripts/qa/opkg-version-order.sh" \
		"${FIXTURE_ROOT}/scripts/qa/"
}

@test "builder ID is deterministic and manifest records locked inputs" {
	local first_id second_id

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	[[ "${output}" =~ ^[0-9a-f]{64}$ ]]
	first_id="${output}"

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	second_id="${output}"
	[ "${second_id}" = "${first_id}" ]

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"schema=entware-builder-v1"* ]]
	[[ "${output}" == *"builder_id=${first_id}"* ]]
	[[ "${output}" == *"target_config=configs/aarch64-3.10.config"* ]]
	[[ "${output}" =~ entware_revision=[0-9a-f]{40} ]]
}

@test "runtime dependency changes create a new builder ID" {
	local original_id changed_id

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	original_id="${output}"

	printf '\nMORS_RUNTIME_DEPENDS+=+new-runtime\n' \
		>>"${FIXTURE_ROOT}/builder/entware/runtime-dependencies.mk"
	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	changed_id="${output}"

	[ "${changed_id}" != "${original_id}" ]
}
