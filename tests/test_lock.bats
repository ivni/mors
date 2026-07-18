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

@test "metadata-free runtime lock is reclaimed only after its grace period" {
	mkdir -p "${MORS_RUNTIME_LOCK_DIR}"
	for file in pid owner_start token command started_at; do
		: >"${MORS_RUNTIME_LOCK_DIR}/${file}"
	done

	MORS_LOCK_EMPTY_STALE_MINUTES=1
	run runtime_mutation_lock__acquire fresh
	[ "${status}" -ne 0 ]
	[ -d "${MORS_RUNTIME_LOCK_DIR}" ]

	touch -d '2 minutes ago' "${MORS_RUNTIME_LOCK_DIR}"
	runtime_mutation_lock__acquire recovered
	[ -s "${MORS_RUNTIME_LOCK_DIR}/pid" ]
	[ "$(cat "${MORS_RUNTIME_LOCK_DIR}/command")" = recovered ]
}

@test "reported runtime lock acquisition explains a live owner" {
	runtime_mutation_lock__acquire owner
	run env -u MORS_RUNTIME_LOCK_TOKEN -u MORS_RUNTIME_LOCK_DEPTH \
		MORS_LOCK_ROOT="${MORS_LOCK_ROOT}" MORS_RUNTIME_LOCK_DIR="${MORS_RUNTIME_LOCK_DIR}" \
		MORS_COLD_JOURNAL_DIR="${MORS_COLD_JOURNAL_DIR}" \
		sh -c '. "$1"; runtime_mutation_lock__acquire_or_explain contender' \
		sh "${REPO_ROOT}/opt/bin/libs/runtime_lock"
	[ "${status}" -eq 1 ]
	[[ "${output}" == *'Другая операция изменения runtime Mors уже выполняется.'* ]]
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

@test "bounded runtime wait acquires after a live owner releases" {
	local ready=${BATS_TEST_TMPDIR}/holder-ready holder
	env MORS_LOCK_ROOT="${MORS_LOCK_ROOT}" \
		MORS_RUNTIME_LOCK_DIR="${MORS_RUNTIME_LOCK_DIR}" \
		MORS_COLD_JOURNAL_DIR="${MORS_COLD_JOURNAL_DIR}" \
		READY_FILE="${ready}" sh -c '
			. "$1"
			runtime_mutation_lock__acquire holder || exit 1
			: >"${READY_FILE}"
			sleep 1
			runtime_mutation_lock__release
		' sh "${REPO_ROOT}/opt/bin/libs/runtime_lock" &
	holder=$!
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		[ -e "${ready}" ] && break
		sleep 0.1
	done
	[ -e "${ready}" ]

	runtime_mutation_lock__acquire_wait waiter 5
	wait "${holder}"
	[ "${MORS_RUNTIME_LOCK_DEPTH}" -eq 1 ]
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
	grep -q 'runtime_mutation_lock__acquire_wait' "${REPO_ROOT}/opt/etc/init.d/S96mors"
}

@test "lifecycle and VLESS decision paths nest the runtime lock" {
	grep -q 'lifecycle__run_locked setup__cmd_install_with_runtime' \
		"${REPO_ROOT}/opt/bin/main/setup"
	grep -q "runtime_mutation_lock__acquire_or_explain 'mors setup'" \
		"${REPO_ROOT}/opt/bin/main/setup"
	grep -q "runtime_mutation_lock__acquire 'vless decision'" \
		"${REPO_ROOT}/opt/bin/libs/vless_runtime"
}
