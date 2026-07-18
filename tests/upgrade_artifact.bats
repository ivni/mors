#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
	. "${REPO_ROOT}/opt/bin/libs/upgrade_artifact"
	CANDIDATE="${BATS_TEST_TMPDIR}/candidate-source.ipk"
	ROLLBACK="${BATS_TEST_TMPDIR}/rollback-source.ipk"
	SNAPSHOT="${BATS_TEST_TMPDIR}/snapshot"
	mkdir -p "${SNAPSHOT}"
	printf '%s\n' candidate-v1 >"${CANDIDATE}"
	printf '%s\n' rollback-v1 >"${ROLLBACK}"
	write_digest "${CANDIDATE}"
	write_digest "${ROLLBACK}"
}

write_digest() {
	local path=${1}
	printf '%s  %s\n' "$(sha256sum "${path}" | awk '{print $1}')" "$(basename "${path}")" >"${path}.sha256"
}

@test "staged artifacts remain immutable when original paths change after prepare" {
	candidate_fingerprint=$(upgrade_artifact__verified_digest "${CANDIDATE}")
	rollback_fingerprint=$(upgrade_artifact__verified_digest "${ROLLBACK}")
	upgrade_artifact__stage_pair "${CANDIDATE}" "${ROLLBACK}" "${SNAPSHOT}" \
		"${candidate_fingerprint}" "${rollback_fingerprint}"

	printf '%s\n' candidate-v2 >"${CANDIDATE}"
	printf '%s\n' rollback-v2 >"${ROLLBACK}"
	write_digest "${CANDIDATE}"
	write_digest "${ROLLBACK}"

	[ "$(cat "${SNAPSHOT}/candidate.ipk")" = candidate-v1 ]
	[ "$(cat "${SNAPSHOT}/rollback.ipk")" = rollback-v1 ]
	[ "$(upgrade_artifact__verified_digest "${SNAPSHOT}/candidate.ipk")" = "${candidate_fingerprint}" ]
	[ "$(upgrade_artifact__verified_digest "${SNAPSHOT}/rollback.ipk")" = "${rollback_fingerprint}" ]
}

@test "staging rejects a source pair replaced after fingerprint capture" {
	candidate_fingerprint=$(upgrade_artifact__verified_digest "${CANDIDATE}")
	rollback_fingerprint=$(upgrade_artifact__verified_digest "${ROLLBACK}")
	printf '%s\n' candidate-v2 >"${CANDIDATE}"
	printf '%s\n' rollback-v2 >"${ROLLBACK}"
	write_digest "${CANDIDATE}"
	write_digest "${ROLLBACK}"
	run upgrade_artifact__stage_pair "${CANDIDATE}" "${ROLLBACK}" "${SNAPSHOT}" \
		"${candidate_fingerprint}" "${rollback_fingerprint}"
	[ "${status}" -ne 0 ]
	[ ! -e "${SNAPSHOT}/candidate.ipk" ]
	[ ! -e "${SNAPSHOT}/rollback.ipk" ]
}

@test "upgrade installs and rolls back only from the protected snapshot" {
	upgrade=${REPO_ROOT}/opt/bin/main/upgrade
	grep -q 'MORS_UPDATE_ARTIFACT=${staged_candidate}' "${upgrade}"
	grep -q 'MORS_UPDATE_ROLLBACK=${staged_rollback}' "${upgrade}"
	grep -q 'upgrade__install_artifact "${operation}" "${MORS_UPDATE_ARTIFACT}"' "${upgrade}"
	grep -q 'opkg install --force-downgrade "${MORS_UPDATE_ROLLBACK}"' "${upgrade}"
}
