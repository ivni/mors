#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "release metadata matches Makefile and the first history entry" {
	local version release expected
	version="$(sed -n 's/^PKG_VERSION:=//p; /^PKG_VERSION:=/q' "${REPO_ROOT}/Makefile")"
	release="$(sed -n 's/^PKG_RELEASE:=//p; /^PKG_RELEASE:=/q' "${REPO_ROOT}/Makefile")"
	expected="${version}-${release}"

	run bash "${REPO_ROOT}/scripts/qa/release-metadata.sh" "v${version//\~/-}"
	[ "${status}" -eq 0 ]
	[ "${output}" = "${expected}" ]

	run bash "${REPO_ROOT}/scripts/qa/release-metadata.sh" v9.9.9-beta1
	[ "${status}" -ne 0 ]
}

@test "release artifact verifier validates metadata and normalizes the upload name" {
	local fixture=${BATS_TEST_TMPDIR}/fixture
	local artifact_dir=${fixture}/artifact
	local control_dir=${fixture}/control
	local data_dir=${fixture}/data
	local outer_dir=${fixture}/outer
	local output_dir=${fixture}/release
	local output_file=${fixture}/github-output
	local version='9.9.9~beta1-4'

	mkdir -p "${artifact_dir}" "${control_dir}" \
		"${data_dir}/opt/apps/mors/bin/libs" \
		"${data_dir}/opt/apps/mors/bin/main" \
		"${data_dir}/opt/apps/mors/etc/init.d" "${outer_dir}"
	printf '%s\n' \
		'Package: mors' \
		"Version: ${version}" \
		'Architecture: all' >"${control_dir}/control"
	: >"${data_dir}/opt/apps/mors/bin/mors"
	: >"${data_dir}/opt/apps/mors/bin/libs/main"
	: >"${data_dir}/opt/apps/mors/bin/libs/test"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry_runtime"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry_store"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry_otlp"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry_process"
	: >"${data_dir}/opt/apps/mors/bin/libs/telemetry_upgrade"
	: >"${data_dir}/opt/apps/mors/bin/libs/upgrade_artifact"
	: >"${data_dir}/opt/apps/mors/bin/main/telemetry-sender"
	: >"${data_dir}/opt/apps/mors/etc/init.d/S98mors-telemetry"
	printf '2.0\n' >"${outer_dir}/debian-binary"
	tar -czf "${outer_dir}/control.tar.gz" -C "${control_dir}" ./control
	tar -czf "${outer_dir}/data.tar.gz" -C "${data_dir}" ./opt
	(
		cd "${outer_dir}"
		tar -czf "${artifact_dir}/mors_${version}_all.ipk" \
			./debian-binary ./control.tar.gz ./data.tar.gz
	)

	run bash "${REPO_ROOT}/scripts/qa/verify-release-artifact.sh" \
		"${artifact_dir}" "${version}" "${output_dir}" "${output_file}"
	[ "${status}" -eq 0 ]
	[ -f "${output_dir}/mors_9.9.9.beta1-4_all.ipk" ]
	grep -q '^control_version=9.9.9~beta1-4$' "${output_file}"
	grep -q '^asset_name=mors_9.9.9.beta1-4_all.ipk$' "${output_file}"
	grep -Eq '^sha256=[0-9A-F]{64}$' "${output_file}"
}

@test "tag pushes no longer build packages after the fact" {
	grep -q '^  workflow_call:$' "${REPO_ROOT}/.github/workflows/package.yml"
	! grep -q '^[[:space:]]*tags:' "${REPO_ROOT}/.github/workflows/package.yml"
	grep -q '^  workflow_call:$' "${REPO_ROOT}/.github/workflows/qa.yml"
	grep -q 'Install pinned actionlint' "${REPO_ROOT}/.github/workflows/qa.yml"
	grep -q 'bash scripts/qa/actionlint.sh' "${REPO_ROOT}/scripts/qa/static.sh"
	grep -q 'expected_package="mors_${package_version}-${package_release}_all.ipk"' \
		"${REPO_ROOT}/scripts/qa/entware-build.sh"
	! grep -Eq "mors_[0-9]+\\.[0-9]+\\.[0-9]+.*_all\\.ipk" \
		"${REPO_ROOT}/scripts/qa/entware-build.sh"
}

@test "package workflow resolves and verifies an immutable Entware builder" {
	local workflow=${REPO_ROOT}/.github/workflows/package.yml
	local dockerfile=${REPO_ROOT}/builder/entware/Dockerfile

	grep -q 'runs-on: ubuntu-24.04' "${workflow}"
	grep -q 'docker buildx imagetools inspect' "${workflow}"
	grep -q 'docker buildx build' "${workflow}"
	grep -q -- '--platform linux/amd64' "${workflow}"
	grep -q 'image: ${{ needs.builder.outputs.image }}' "${workflow}"
	grep -q 'bash scripts/qa/verify-entware-builder.sh' "${workflow}"
	grep -q 'builder_image:' "${workflow}"
	! grep -q 'actions/cache@' "${workflow}"
	grep -Eq '^FROM ubuntu:24\.04@sha256:[0-9a-f]{64} AS runtime-base$' \
		"${dockerfile}"
	grep -q '^\*\*$' "${dockerfile}.dockerignore"
	! grep -q 'TEST_INFRASTRUCTURE' "${dockerfile}.dockerignore"
	[ "$(grep -c '^ENV FORCE_UNSAFE_CONFIGURE=1$' "${dockerfile}")" -eq 2 ]
	grep -q 'COPY --from=prepare /opt/entware /opt/entware' "${dockerfile}"
	! grep -q 'COPY --from=prepare /src' "${dockerfile}"
	grep -q 'runtime-dependencies.mk' "${REPO_ROOT}/Makefile"
	grep -q 'make package/mors/clean' "${REPO_ROOT}/scripts/qa/entware-build.sh"
	grep -q 'rm -f package/mors' "${REPO_ROOT}/scripts/qa/entware-build.sh"
}

@test "release publication depends on QA package and artifact gates" {
	local workflow=${REPO_ROOT}/.github/workflows/release.yml
	local artifact_line tag_line

	grep -q 'needs: \[validate, qa, package\]' "${workflow}"
	grep -q 'uses: ./\.github/workflows/qa.yml' "${workflow}"
	grep -q 'uses: ./\.github/workflows/package.yml' "${workflow}"
	grep -q 'verify-release-artifact.sh' "${workflow}"
	grep -q 'needs.package.outputs.builder_image' "${workflow}"
	grep -q 'git tag -a' "${workflow}"
	grep -q -- '--verify-tag' "${workflow}"

	artifact_line="$(grep -n -m1 'Verify release artifact' "${workflow}" | cut -d: -f1)"
	tag_line="$(grep -n -m1 'Create annotated tag' "${workflow}" | cut -d: -f1)"
	[ "${artifact_line}" -lt "${tag_line}" ]
}
