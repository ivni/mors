#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	TEST_ROOT="$(mktemp -d)"
	TAGS_FIXTURE="${TEST_ROOT}/tags.list"
	cat >"${TAGS_FIXTURE}" <<'EOF'
# comments are ignored by get_tags_list
[media]
youtube.com
netflix.com

[ai]
openai.com
chatgpt.com
[empty]
EOF

	source "${REPO_ROOT}/opt/bin/libs/tags"
	TAGS_FILE="${TAGS_FIXTURE}"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "get_tags_list returns section names without brackets" {
	run get_tags_list

	[ "${status}" -eq 0 ]
	[ "${lines[0]}" = "media" ]
	[ "${lines[1]}" = "ai" ]
	[ "${lines[2]}" = "empty" ]
}

@test "get_tag_domain_list returns only domains from the requested section" {
	run get_tag_domain_list ai

	[ "${status}" -eq 0 ]
	[ "${lines[0]}" = "openai.com" ]
	[ "${lines[1]}" = "chatgpt.com" ]
	[ "${#lines[@]}" -eq 2 ]
}

@test "get_first_domain_from_section returns the first domain in a tag" {
	run get_first_domain_from_section media

	[ "${status}" -eq 0 ]
	[ "${output}" = "youtube.com" ]
}

@test "_check_domain_zone accepts normal domains and rejects hostnames without a zone" {
	run _check_domain_zone example.com
	[ "${status}" -eq 0 ]

	run _check_domain_zone localhost
	[ "${status}" -ne 0 ]
}
