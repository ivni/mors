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
		"${REPO_ROOT}/scripts/qa/verify-entware-builder.sh" \
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

@test "builder verifier requires every canonical runtime dependency" {
	local entware_dir="${BATS_TEST_TMPDIR}/entware"
	local fake_bin="${BATS_TEST_TMPDIR}/bin"
	local manifest="${BATS_TEST_TMPDIR}/manifest.env"
	local builder_id locked_revision target_dir root_stamp_dir

	builder_id="$(
		ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
			bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	)"
	locked_revision="$(
		awk '$1 == "entware" { print $3; exit }' \
			"${FIXTURE_ROOT}/scripts/qa/entware.lock"
	)"
	ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest \
		>"${manifest}"

	target_dir="${entware_dir}/staging_dir/target-aarch64_fixture"
	root_stamp_dir="${target_dir}/root-aarch64/stamp"
	mkdir -p \
		"${fake_bin}" \
		"${entware_dir}/.git" \
		"${entware_dir}/bin/targets" \
		"${entware_dir}/staging_dir/host/bin" \
		"${entware_dir}/staging_dir/toolchain-aarch64_fixture" \
		"${root_stamp_dir}"
	for host_tool in opkg bash fakeroot patchelf; do
		printf '#!/bin/sh\nexit 0\n' \
			>"${entware_dir}/staging_dir/host/bin/${host_tool}"
		chmod +x "${entware_dir}/staging_dir/host/bin/${host_tool}"
	done
	for dependency_token in $(
		sed -n 's/^MORS_RUNTIME_DEPENDS:=//p' \
			"${FIXTURE_ROOT}/builder/entware/runtime-dependencies.mk"
	); do
		touch "${root_stamp_dir}/.${dependency_token#+}_installed"
	done
	cat >"${fake_bin}/git" <<EOF
#!/bin/sh
printf '%s\n' '${locked_revision}'
EOF
	chmod +x "${fake_bin}/git"

	run env \
		ENTWARE_DIR="${entware_dir}" \
		MORS_ENTWARE_BUILDER_ID="${builder_id}" \
		MORS_ENTWARE_BUILDER_MANIFEST="${manifest}" \
		PATH="${fake_bin}:${PATH}" \
		bash "${FIXTURE_ROOT}/scripts/qa/verify-entware-builder.sh"
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"Entware builder verified: ${builder_id}"* ]]

	rm "${root_stamp_dir}/.xray_installed"
	run env \
		ENTWARE_DIR="${entware_dir}" \
		MORS_ENTWARE_BUILDER_ID="${builder_id}" \
		MORS_ENTWARE_BUILDER_MANIFEST="${manifest}" \
		PATH="${fake_bin}:${PATH}" \
		bash "${FIXTURE_ROOT}/scripts/qa/verify-entware-builder.sh"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Entware builder dependency is not installed: xray"* ]]
}
