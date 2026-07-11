#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source "${REPO_ROOT}/opt/bin/libs/xray"
}

@test "version comparison supports traditional and calendar Xray versions" {
	run version__at_least 1.8.24 1.8.24
	[ "${status}" -eq 0 ]

	run version__at_least 26.2.6 1.8.24
	[ "${status}" -eq 0 ]

	run version__at_least 1.8.23 1.8.24
	[ "${status}" -eq 1 ]

	run version__at_least 26.2 26.2.0
	[ "${status}" -eq 0 ]
}

@test "compatibility status rejects old versions and flags newer versions" {
	run xray__compatibility_status 1.8.23
	[ "${status}" -eq 1 ]
	[ "${output}" = "unsupported" ]

	run xray__compatibility_status 1.8.24
	[ "${status}" -eq 0 ]
	[ "${output}" = "supported" ]

	run xray__compatibility_status 26.2.6
	[ "${status}" -eq 0 ]
	[ "${output}" = "supported" ]

	run xray__compatibility_status 26.5.9
	[ "${status}" -eq 0 ]
	[ "${output}" = "newer" ]
}

@test "Xray version is extracted from binary output" {
	actual=$(printf '%s\n' 'Xray 26.2.6 (Xray, Penetrates Everything.) Custom' | xray__parse_version)
	[ "${actual}" = "26.2.6" ]
}

@test "invalid version output is reported explicitly" {
	run xray__compatibility_status unknown
	[ "${status}" -eq 2 ]
	[ "${output}" = "invalid" ]
}
