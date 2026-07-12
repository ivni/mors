#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	. "${REPO_ROOT}/opt/bin/libs/runtime_lock"
	. "${REPO_ROOT}/opt/bin/libs/test_cold"
	MORS_LOCK_ROOT=${BATS_TEST_TMPDIR}/locks
	MORS_RUNTIME_LOCK_DIR=${MORS_LOCK_ROOT}/runtime.lock
	MORS_RUNTIME_CANCEL_FILE=${BATS_TEST_TMPDIR}/run/cancel-cold
	MORS_COLD_JOURNAL_DIR=${BATS_TEST_TMPDIR}/recovery/test-cold
	MORS_TEST_WORK_DIR=${BATS_TEST_TMPDIR}/work
	mkdir -p "${MORS_TEST_WORK_DIR}"
	MORS_TEST_DNS_FILE=${MORS_TEST_WORK_DIR}/dns-a
	printf '%s\n' 192.0.2.10 >"${MORS_TEST_DNS_FILE}"
	IPSET_TABLE_NAME=MORS_LIST
	MORS_TEST_DNS_BACKEND=dnsmasq
	DNSMASQ_DEMON=${BATS_TEST_TMPDIR}/dnsmasq
	ADGUARDHOME_DEMON=${BATS_TEST_TMPDIR}/adguard
	printf '%s\n' '#!/bin/sh' 'case "$1" in status) echo running;; *) exit 0;; esac' >"${DNSMASQ_DEMON}"
	chmod +x "${DNSMASQ_DEMON}"
	MORS_TEST_IPSET=${BATS_TEST_TMPDIR}/ipset
	printf '%s\n' '#!/bin/sh' \
		'case "$1" in' \
		' save) echo "add MORS_LIST 192.0.2.10 timeout 100";;' \
		' restore) cat >/dev/null;;' \
		' *) exit 0;;' \
		'esac' >"${MORS_TEST_IPSET}"
	chmod +x "${MORS_TEST_IPSET}"
}

@test "cold journal is atomic and records exact affected entries" {
	test_cold__create_journal
	[ -d "${MORS_COLD_JOURNAL_DIR}" ]
	[ "$(cat "${MORS_COLD_JOURNAL_DIR}/affected")" = 192.0.2.10 ]
	grep -q '^add MORS_LIST 192.0.2.10 ' "${MORS_COLD_JOURNAL_DIR}/entries.restore"
}

@test "restore scope includes new addresses returned by the cold DNS query" {
	test_cold__create_journal
	printf '%s\n' 198.51.100.20 >"${MORS_TEST_DNS_FILE}"
	test_cold__record_generated
	grep -qx 198.51.100.20 "${MORS_COLD_JOURNAL_DIR}/generated"
	[ "$(test_cold__affected_addresses | wc -l | tr -d ' ')" -eq 2 ]
}

@test "successful recovery removes journal only after restore" {
	test_cold__create_journal
	MORS_ALLOW_COLD_RECOVERY=true
	runtime_mutation_lock__acquire recover
	test_cold__restore
	[ ! -e "${MORS_COLD_JOURNAL_DIR}" ]
}

@test "fault before restore keeps a journal that blocks mutations" {
	test_cold__create_journal
	run runtime_mutation_lock__acquire mutation
	[ "${status}" -eq 2 ]
	[ -d "${MORS_COLD_JOURNAL_DIR}" ]
}

@test "every mutating crash phase remains recoverable from the journal" {
	local phase
	for phase in snapshotted mutating entries_removed dns_restarted refill_confirmed e2e_confirmed restoring; do
		rm -rf "${MORS_COLD_JOURNAL_DIR}"
		test_cold__create_journal
		test_cold__write_phase "${phase}"
		[ "$(cat "${MORS_COLD_JOURNAL_DIR}/phase")" = "${phase}" ]
		test_cold__journal_valid
	done
}

@test "malformed recovery journal is never silently removed" {
	mkdir -p "${MORS_COLD_JOURNAL_DIR}"
	printf '%s\n' broken >"${MORS_COLD_JOURNAL_DIR}/phase"
	run test_cold__restore
	[ "${status}" -ne 0 ]
	[ -d "${MORS_COLD_JOURNAL_DIR}" ]
}

@test "runtime cancellation remains distinguishable from a cold failure" {
	test_cold__remove_affected() {
		runtime_lock__request_cold_cancel ndm_event
	}
	run test_cold__run
	[ "${status}" -eq 3 ]
	[ ! -d "${MORS_COLD_JOURNAL_DIR}" ]
}
