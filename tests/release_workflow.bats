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
		"${data_dir}/opt/apps/mors/bin/libs" "${outer_dir}"
	printf '%s\n' \
		'Package: mors' \
		"Version: ${version}" \
		'Architecture: all' >"${control_dir}/control"
	: >"${data_dir}/opt/apps/mors/bin/mors"
	: >"${data_dir}/opt/apps/mors/bin/libs/main"
	: >"${data_dir}/opt/apps/mors/bin/libs/test"
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

@test "package workflow reuses only locked Entware state" {
	local workflow=${REPO_ROOT}/.github/workflows/package.yml

	grep -q 'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0' "${workflow}"
	grep -q 'runs-on: ubuntu-24.04' "${workflow}"
	grep -q 'entware-v2-ubuntu-24.04-${{ runner.arch }}-aarch64-3.10-' "${workflow}"
	grep -q "hashFiles('scripts/qa/entware.lock')" "${workflow}"
	grep -q 'ENTWARE_CACHE_HIT:' "${workflow}"
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
	grep -q 'git tag -a' "${workflow}"
	grep -q -- '--verify-tag' "${workflow}"

	artifact_line="$(grep -n -m1 'Verify release artifact' "${workflow}" | cut -d: -f1)"
	tag_line="$(grep -n -m1 'Create annotated tag' "${workflow}" | cut -d: -f1)"
	[ "${artifact_line}" -lt "${tag_line}" ]
}
