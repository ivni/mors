#!/bin/sh

if [ "${1}" = 'start' ] ; then
	. /opt/apps/mors/bin/libs/ndm
	. /opt/apps/mors/bin/libs/test_cold
	MORS_TEST_IPSET=/opt/sbin/ipset

	if [ -d "${MORS_COLD_JOURNAL_DIR}" ]; then
		MORS_ALLOW_COLD_RECOVERY=true; export MORS_ALLOW_COLD_RECOVERY
		runtime_mutation_lock__acquire 'boot cold recovery prepare' || exit $?
		# Набор нужен для восстановления snapshot до старта DNS.
		ip4__ipset__create_list
		runtime_mutation_lock__release >/dev/null 2>&1 || exit 1
		unset MORS_ALLOW_COLD_RECOVERY
		MORS_COLD_BOOT_RECOVERY=true
		export MORS_COLD_BOOT_RECOVERY MORS_TEST_IPSET
		test_cold__recover || exit 1
	else
		ndm_runtime__begin filesystem_start || exit $?
		# стартуем ipset'ы, используемые DNS-серверами
		# до старта самих DNS-серверов
		ip4__ipset__create_list
		ndm_runtime__end
	fi
fi
