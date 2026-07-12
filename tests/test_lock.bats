#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	. "${REPO_ROOT}/opt/bin/libs/runtime_lock"
	MORS_LOCK_ROOT=${BATS_TEST_TMPDIR}/locks
	MORS_TEST_LOCK_DIR=${MORS_LOCK_ROOT}/test.lock
	MORS_RUNTIME_LOCK_DIR=${MORS_LOCK_ROOT}/runtime.lock
	MORS_COLD_JOURNAL_DIR=${BATS_TEST_TMPDIR}/journal
}

teardown() {
	test_lock__release >/dev/null 2>&1 || true
	runtime_mutation_lock__release >/dev/null 2>&1 || true
}

@test "test lock is fail-fast and stale lock is recovered" {
	test_lock__acquire 'first test'
	run env -u MORS_TEST_LOCK_TOKEN -u MORS_TEST_LOCK_DEPTH \
		MORS_LOCK_ROOT="${MORS_LOCK_ROOT}" MORS_TEST_LOCK_DIR="${MORS_TEST_LOCK_DIR}" \
		sh -c '. "'"${REPO_ROOT}"'/opt/bin/libs/runtime_lock"; test_lock__acquire second'
	[ "${status}" -ne 0 ]
	test_lock__release
	mkdir -p "${MORS_TEST_LOCK_DIR}"
	printf '%s\n' 999999 >"${MORS_TEST_LOCK_DIR}/pid"
	test_lock__acquire recovered
}

@test "runtime lock is reentrant and recovery journal blocks mutations" {
	runtime_mutation_lock__acquire outer
	runtime_mutation_lock__acquire inner
	[ "${MORS_RUNTIME_LOCK_DEPTH}" -eq 2 ]
	runtime_mutation_lock__release
	[ -d "${MORS_RUNTIME_LOCK_DIR}" ]
	runtime_mutation_lock__release
	mkdir -p "${MORS_COLD_JOURNAL_DIR}"
	run runtime_mutation_lock__acquire blocked
	[ "${status}" -eq 2 ]
}

@test "lock acquisition does not change the caller umask" {
	local before after
	before=$(umask)
	test_lock__acquire umask
	after=$(umask)
	[ "${after}" = "${before}" ]
}

@test "an inherited transaction can reenter while its cold journal exists" {
	runtime_mutation_lock__acquire parent
	mkdir -p "${MORS_COLD_JOURNAL_DIR}"
	runtime_mutation_lock__acquire child
	[ "${MORS_RUNTIME_LOCK_DEPTH}" -eq 2 ]
	runtime_mutation_lock__release
}

@test "an inherited child token cannot release the parent lock" {
	runtime_mutation_lock__acquire parent
	env MORS_LOCK_ROOT="${MORS_LOCK_ROOT}" \
		MORS_RUNTIME_LOCK_DIR="${MORS_RUNTIME_LOCK_DIR}" \
		MORS_RUNTIME_LOCK_TOKEN="${MORS_RUNTIME_LOCK_TOKEN}" \
		MORS_RUNTIME_LOCK_DEPTH=1 \
		sh -c '. "'"${REPO_ROOT}"'/opt/bin/libs/runtime_lock"; runtime_mutation_lock__release'
	[ -d "${MORS_RUNTIME_LOCK_DIR}" ]
	runtime_mutation_lock__release
}

@test "mutating NDM hooks participate in runtime serialization" {
	local hook
	for hook in \
		opt/etc/ndm/ifcreated.d/mors-iface-add \
		opt/etc/ndm/ifdestroyed.d/mors-iface-del \
		opt/etc/ndm/iflayerchanged.d/100-mors-vpn \
		opt/etc/ndm/netfilter.d/100-dns-local \
		opt/etc/ndm/netfilter.d/100-proxy-redirect \
		opt/etc/ndm/netfilter.d/100-vpn-mark; do
		grep -q 'ndm_runtime__begin' "${REPO_ROOT}/${hook}"
	done
	grep -q 'runtime_lock__request_cold_cancel' "${REPO_ROOT}/opt/etc/ndm/ndm"
}

@test "startup paths attempt cold recovery before normal initialization" {
	grep -q 'test_cold__recover' "${REPO_ROOT}/opt/etc/ndm/fs.d/15-mors-start.sh"
	grep -q 'test_cold__recover' "${REPO_ROOT}/opt/etc/init.d/S96mors"
}

@test "lifecycle and VLESS decision paths nest the runtime lock" {
	grep -q 'lifecycle__run_locked setup__cmd_install_with_runtime' \
		"${REPO_ROOT}/opt/bin/main/setup"
	grep -q "runtime_mutation_lock__acquire 'vless decision'" \
		"${REPO_ROOT}/opt/bin/libs/vless_runtime"
}
