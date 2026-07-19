#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	MORS_LIB_DIR=${REPO_ROOT}/opt/bin/libs
	MOCK_BIN=${BATS_TEST_TMPDIR}/bin
	EVENTS=${BATS_TEST_TMPDIR}/events
	DNSCRYPT_STATE=${BATS_TEST_TMPDIR}/dnscrypt.state
	DNSMASQ_STATE=${BATS_TEST_TMPDIR}/dnsmasq.state
	mkdir -p "${MOCK_BIN}"
	: >"${EVENTS}"
	printf 'stopped\n' >"${DNSCRYPT_STATE}"
	printf 'stopped\n' >"${DNSMASQ_STATE}"

cat >"${MOCK_BIN}/timeout" <<'EOF'
#!/bin/sh
[ "$1" = -k ] && shift 2
shift
exec "$@"
EOF
	cat >"${MOCK_BIN}/dnscrypt-proxy" <<'EOF'
#!/bin/sh
printf '%s\n' validate >>"${EVENTS}"
printf '%s\n' 'Configuration successfully checked'
EOF
	cat >"${MOCK_BIN}/dnscrypt-init" <<'EOF'
#!/bin/sh
case "$1" in
	restart) printf '%s\n' dnscrypt-restart >>"${EVENTS}"; printf 'alive\n' >"${DNSCRYPT_STATE}" ;;
	status) cat "${DNSCRYPT_STATE}" ;;
esac
EOF
	cat >"${MOCK_BIN}/dnsmasq-init" <<'EOF'
#!/bin/sh
case "$1" in
	restart) printf '%s\n' dnsmasq-restart >>"${EVENTS}"; printf 'alive\n' >"${DNSMASQ_STATE}" ;;
	status) cat "${DNSMASQ_STATE}" ;;
esac
EOF
	cat >"${MOCK_BIN}/kdig" <<'EOF'
#!/bin/sh
port=''
while [ "$#" -gt 0 ]; do
	[ "$1" = -p ] && { port=$2; shift 2; continue; }
	shift
done
printf 'query-%s\n' "${port}" >>"${EVENTS}"
[ "${MORS_SETUP_DNS_QUERY_FAIL:-false}" = true ] && exit 1
printf '%s\n' 192.0.2.1
EOF
	chmod +x "${MOCK_BIN}"/*
	export PATH="${MOCK_BIN}:${PATH}" EVENTS DNSCRYPT_STATE DNSMASQ_STATE

	MORS_SETUP_DNSCRYPT_BIN=${MOCK_BIN}/dnscrypt-proxy
	MORS_SETUP_DNSCRYPT_CONFIG=${BATS_TEST_TMPDIR}/dnscrypt-proxy.toml
	MORS_SETUP_DNSCRYPT_INIT=${MOCK_BIN}/dnscrypt-init
	MORS_SETUP_DNSMASQ_INIT=${MOCK_BIN}/dnsmasq-init
	MORS_SETUP_DNS_TIMEOUT_CMD=${MOCK_BIN}/timeout
	MORS_SETUP_DNS_LOG=${BATS_TEST_TMPDIR}/dns-startup.log
	MORS_SETUP_DNS_READY_TIMEOUT=2
	MORS_SETUP_DNS_RETRY_INTERVAL=1
	MORS_SETUP_DNS_SERVICE_ACTION_TIMEOUT=2
	MORS_SETUP_DNS_SERVICE_KILL_AFTER=1
	export MORS_SETUP_DNSCRYPT_BIN MORS_SETUP_DNSCRYPT_CONFIG
	export MORS_SETUP_DNSCRYPT_INIT MORS_SETUP_DNSMASQ_INIT MORS_SETUP_DNS_TIMEOUT_CMD
	export MORS_SETUP_DNS_LOG MORS_SETUP_DNS_READY_TIMEOUT MORS_SETUP_DNS_RETRY_INTERVAL
	export MORS_SETUP_DNS_SERVICE_ACTION_TIMEOUT
	export MORS_SETUP_DNS_SERVICE_KILL_AFTER MORS_LIB_DIR
	printf 'listen_addresses = ["127.0.0.1:9153"]\n' >"${MORS_SETUP_DNSCRYPT_CONFIG}"
	get_config_value() {
		case "$1" in DNS_CRYPT_PORT) printf '%s\n' 9153 ;; DNSMASQ_PORT) printf '%s\n' 9753 ;; esac
	}
	. "${REPO_ROOT}/opt/bin/libs/setup_dns"
}

@test "cold DNS commit validates then starts each dependency exactly once" {
	# Ordering is the subject of this test. Hard wall-clock exhaustion has
	# dedicated coverage below and must not make this happy path runner-speed dependent.
	setup_dns__now() { printf '%s\n' 100; }
	setup_dns__validate_dnscrypt
	setup_dns__activate_dnscrypt_stack

	[ "$(grep -c '^validate$' "${EVENTS}")" -eq 1 ]
	[ "$(grep -c '^dnscrypt-restart$' "${EVENTS}")" -eq 1 ]
	[ "$(grep -c '^dnsmasq-restart$' "${EVENTS}")" -eq 1 ]
	[ "$(grep -n '^validate$' "${EVENTS}" | cut -d: -f1)" -lt "$(grep -n '^dnscrypt-restart$' "${EVENTS}" | cut -d: -f1)" ]
	[ "$(grep -n '^dnscrypt-restart$' "${EVENTS}" | cut -d: -f1)" -lt "$(grep -n '^query-9153$' "${EVENTS}" | cut -d: -f1)" ]
	[ "$(grep -n '^query-9153$' "${EVENTS}" | cut -d: -f1)" -lt "$(grep -n '^dnsmasq-restart$' "${EVENTS}" | cut -d: -f1)" ]
	[ "$(grep -n '^dnsmasq-restart$' "${EVENTS}" | cut -d: -f1)" -lt "$(grep -n '^query-9753$' "${EVENTS}" | cut -d: -f1)" ]
	case "$(uname -s)" in MINGW*|MSYS*) ;; *) [ "$(stat -c '%a' "${MORS_SETUP_DNS_LOG}")" = 600 ] ;; esac
}

@test "readiness failure is bounded and prevents dependent dnsmasq start" {
	MORS_SETUP_DNS_QUERY_FAIL=true
	MORS_SETUP_DNS_READY_TIMEOUT=0
	export MORS_SETUP_DNS_QUERY_FAIL MORS_SETUP_DNS_READY_TIMEOUT

	run setup_dns__activate_dnscrypt_stack

	[ "${status}" -ne 0 ]
	[ "$(grep -c '^dnscrypt-restart$' "${EVENTS}")" -eq 1 ]
	! grep -q '^dnsmasq-restart$' "${EVENTS}"
	grep -q 'timeout service=.*dnscrypt-init address=127.0.0.1:9153' "${MORS_SETUP_DNS_LOG}"
}

@test "service stop waits for process quiescence" {
	local service=${BATS_TEST_TMPDIR}/slow-stop calls=${BATS_TEST_TMPDIR}/status-calls
	printf '%s\n' '#!/bin/sh' 'exit 0' >"${service}"
	printf '%s\n' 0 >"${calls}"
	chmod +x "${service}"
	setup_dns__service_state() {
		local count
		count=$(cat "${calls}")
		count=$((count + 1))
		printf '%s\n' "${count}" >"${calls}"
		[ "${count}" -gt 2 ] && printf '%s\n' stopped || printf '%s\n' running
	}
	sleep() { :; }
	MORS_SETUP_DNS_STOP_TIMEOUT=4

	setup_dns__stop_service "${service}" dnsmasq

	grep -q "stopped service=${service} elapsed=2" "${MORS_SETUP_DNS_LOG}"
}

@test "service restart propagates nonzero even when old process remains running" {
	local service=${BATS_TEST_TMPDIR}/failed-init attempts=${BATS_TEST_TMPDIR}/restart-attempts
	printf '%s\n' 0 >"${attempts}"
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	restart)
		count=$(cat "${MORS_MOCK_ATTEMPTS}")
		printf '%s\n' $((count + 1)) >"${MORS_MOCK_ATTEMPTS}"
		exit 7
		;;
	status) printf '%s\n' alive ;;
esac
EOF
	chmod +x "${service}"
	MORS_MOCK_ATTEMPTS=${attempts}; export MORS_MOCK_ATTEMPTS

	run setup_dns__restart_service "${service}" dnsmasq

	[ "${status}" -eq 7 ]
	[ "$(cat "${attempts}")" -eq 1 ]
	grep -q 'restart-failed .*exit=7' "${MORS_SETUP_DNS_LOG}"
}

@test "service stop propagates nonzero even when status reports stopped" {
	local service=${BATS_TEST_TMPDIR}/failed-stop
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	stop) exit 6 ;;
	status) printf '%s\n' stopped ;;
esac
EOF
	chmod +x "${service}"

	run setup_dns__stop_service "${service}" dnsmasq

	[ "${status}" -eq 6 ]
	grep -q 'stop-failed .*exit=6' "${MORS_SETUP_DNS_LOG}"
}

@test "hanging service stop is terminated before polling" {
	local service=${BATS_TEST_TMPDIR}/hanging-stop real_timeout
	real_timeout=$(PATH=/usr/bin:/bin command -v timeout) || skip 'coreutils timeout is unavailable'
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	stop) trap '' TERM; sleep 10 ;;
	status) printf '%s\n' alive ;;
esac
EOF
	chmod +x "${service}"
	MORS_SETUP_DNS_TIMEOUT_CMD=${real_timeout}
	MORS_SETUP_DNS_SERVICE_ACTION_TIMEOUT=1
	MORS_SETUP_DNS_SERVICE_KILL_AFTER=1
	MORS_SETUP_DNS_STOP_TIMEOUT=0

	run setup_dns__stop_service "${service}" dnsmasq

	[ "${status}" -ne 0 ]
	grep -q 'service-action-timeout .*action=stop timeout=1 kill-after=1' "${MORS_SETUP_DNS_LOG}"
	grep -Eq 'stop-failed .*exit=(124|137)' "${MORS_SETUP_DNS_LOG}"
}

@test "hanging service restart is terminated before readiness polling" {
	local service=${BATS_TEST_TMPDIR}/hanging-restart real_timeout
	real_timeout=$(PATH=/usr/bin:/bin command -v timeout) || skip 'coreutils timeout is unavailable'
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	restart) sleep 10 ;;
	status) printf '%s\n' stopped ;;
esac
EOF
	chmod +x "${service}"
	MORS_SETUP_DNS_TIMEOUT_CMD=${real_timeout}
	MORS_SETUP_DNS_SERVICE_ACTION_TIMEOUT=1
	MORS_SETUP_DNS_SERVICE_READY_TIMEOUT=0

	run setup_dns__restart_service "${service}" dnsmasq

	[ "${status}" -ne 0 ]
	grep -q 'service-action-timeout .*action=restart timeout=1' "${MORS_SETUP_DNS_LOG}"
	grep -Eq 'restart-failed .*exit=(124|137)' "${MORS_SETUP_DNS_LOG}"
}

@test "hanging service status is terminated inside bounded polling" {
	local service=${BATS_TEST_TMPDIR}/hanging-status real_timeout
	real_timeout=$(PATH=/usr/bin:/bin command -v timeout) || skip 'coreutils timeout is unavailable'
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	stop) exit 0 ;;
	status) printf '%s\n' alive; sleep 10 ;;
esac
EOF
	chmod +x "${service}"
	MORS_SETUP_DNS_TIMEOUT_CMD=${real_timeout}
	MORS_SETUP_DNS_SERVICE_ACTION_TIMEOUT=1
	MORS_SETUP_DNS_STOP_TIMEOUT=3

	run setup_dns__stop_service "${service}" dnsmasq

	[ "${status}" -ne 0 ]
	grep -q 'service-action-timeout .*action=status timeout=1' "${MORS_SETUP_DNS_LOG}"
	grep -q 'stop-failed' "${MORS_SETUP_DNS_LOG}"
}

@test "exhausted stop budget does not invoke another status action" {
	local service=${BATS_TEST_TMPDIR}/no-extra-status calls=${BATS_TEST_TMPDIR}/status-calls
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	stop) exit 0 ;;
	status) printf 'called\n' >>"${STATUS_CALLS}"; printf 'dead\n' ;;
esac
EOF
	chmod +x "${service}"
	export STATUS_CALLS=${calls}
	MORS_SETUP_DNS_STOP_TIMEOUT=0

	run setup_dns__stop_service "${service}" dnsmasq

	[ "${status}" -ne 0 ]
	[ ! -e "${calls}" ]
	grep -q 'stop-timeout .*elapsed=0' "${MORS_SETUP_DNS_LOG}"
}

@test "unknown service status aborts polling immediately" {
	local service=${BATS_TEST_TMPDIR}/unknown-status calls=${BATS_TEST_TMPDIR}/status-calls
	printf '%s\n' 0 >"${calls}"
	cat >"${service}" <<'EOF'
#!/bin/sh
case "$1" in
	stop) exit 0 ;;
	status)
		count=$(cat "${MORS_MOCK_STATUS_CALLS}")
		printf '%s\n' $((count + 1)) >"${MORS_MOCK_STATUS_CALLS}"
		printf '%s\n' ambiguous
		exit 7
		;;
esac
EOF
	chmod +x "${service}"
	MORS_MOCK_STATUS_CALLS=${calls}; export MORS_MOCK_STATUS_CALLS
	MORS_SETUP_DNS_STOP_TIMEOUT=30

	run setup_dns__stop_service "${service}" dnsmasq

	[ "${status}" -ne 0 ]
	[ "$(cat "${calls}")" -eq 1 ]
	grep -q 'stop-status-error' "${MORS_SETUP_DNS_LOG}"
}

@test "committed DNS verification tolerates a bounded slow start" {
	local attempts=${BATS_TEST_TMPDIR}/query-attempts
	printf '%s\n' 0 >"${attempts}"
	printf '%s\n' alive >"${DNSCRYPT_STATE}"
	printf '%s\n' alive >"${DNSMASQ_STATE}"
	setup_dns__query() {
		local count
		count=$(cat "${attempts}")
		count=$((count + 1))
		printf '%s\n' "${count}" >"${attempts}"
		[ "${count}" -ge 3 ]
	}
	sleep() { :; }
	MORS_SETUP_DNS_READY_TIMEOUT=4

	setup_dns__verify_stack

	[ "$(cat "${attempts}")" -eq 4 ]
	grep -q 'ready service=.*dnscrypt-init address=127.0.0.1:9153 elapsed=2' "${MORS_SETUP_DNS_LOG}"
}

@test "committed DNS verification preserves a bounded persistent failure" {
	printf '%s\n' alive >"${DNSCRYPT_STATE}"
	printf '%s\n' alive >"${DNSMASQ_STATE}"
	setup_dns__query() { return 1; }
	sleep() { :; }
	MORS_SETUP_DNS_READY_TIMEOUT=2

	run setup_dns__verify_stack

	[ "${status}" -ne 0 ]
	grep -q 'timeout service=.*dnscrypt-init address=127.0.0.1:9153 elapsed=1' "${MORS_SETUP_DNS_LOG}"
}

@test "hosts file is created readable and symlinks are rejected" {
	error() { printf '%s\n' "$*" >&2; }
	source <(sed -n '/^mors_hosts__ensure_readable()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/main")
	MORS_HOSTS_FILE=${BATS_TEST_TMPDIR}/hosts
	mors_hosts__ensure_readable
	case "$(uname -s)" in MINGW*|MSYS*) ;; *) [ "$(stat -c '%a' "${MORS_HOSTS_FILE}")" = 644 ] ;; esac

	rm "${MORS_HOSTS_FILE}"
	case "$(uname -s)" in MINGW*|MSYS*) return 0 ;; esac
	: >"${BATS_TEST_TMPDIR}/target"
	ln -s "${BATS_TEST_TMPDIR}/target" "${MORS_HOSTS_FILE}"
	run mors_hosts__ensure_readable
	[ "${status}" -ne 0 ]
}

@test "lifecycle snapshot owns the generated hosts file" {
	grep -q '^/opt/etc/hosts$' "${REPO_ROOT}/opt/bin/libs/lifecycle_snapshot"
}

@test "dataplane failure prevents DNS services from starting" {
	cmd_mors_init() { printf '%s\n' dataplane >>"${EVENTS}"; return 1; }
	setup_dns__activate_dnscrypt_stack() { printf '%s\n' dns-start >>"${EVENTS}"; }
	source <(sed -n '/^setup__activate_dnscrypt_runtime()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	run setup__activate_dnscrypt_runtime

	[ "${status}" -ne 0 ]
	[ "$(cat "${EVENTS}")" = dataplane ]
}

@test "transaction DNS log is exported before apply and retained for verification" {
	lifecycle_transaction__directory() { printf '%s\n' "${BATS_TEST_TMPDIR}/transaction"; }
	source <(sed -n '/^setup__bind_transaction_dns_log()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	setup__bind_transaction_dns_log

	[ "${MORS_SETUP_DNS_LOG}" = "${BATS_TEST_TMPDIR}/transaction/dns-startup.log" ]
	bash -c '[ "$MORS_SETUP_DNS_LOG" = "$1/dns-startup.log" ]' _ "${BATS_TEST_TMPDIR}/transaction"
	wrapper=$(sed -n '/^setup__cmd_install_with_runtime()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup" | tr -d '\r')
	bind_line=$(grep -n 'setup__bind_transaction_dns_log' <<<"${wrapper}" | head -n 1 | cut -d: -f1)
	snapshot_line=$(grep -n 'lifecycle_snapshot__capture' <<<"${wrapper}" | head -n 1 | cut -d: -f1)
	apply_line=$(grep -n 'setup__cmd_install_unlocked' <<<"${wrapper}" | cut -d: -f1)
	verify_line=$(grep -n 'setup__verify_committed' <<<"${wrapper}" | cut -d: -f1)
	[ "${bind_line}" -lt "${apply_line}" ]
	[ "${bind_line}" -lt "${snapshot_line}" ]
	[ "${apply_line}" -lt "${verify_line}" ]
}

@test "intentionally stopped baseline DNSCrypt is not restarted during uninstall" {
	lifecycle_snapshot__baseline_service_state() { printf '%s\n' stopped; }
	setup_dns__restart_service() { printf '%s\n' restarted >>"${EVENTS}"; }
	source <(sed -n '/^setup__restore_baseline_service_if_running()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	setup__restore_baseline_service_if_running "${MORS_SETUP_DNSCRYPT_INIT}" dnscrypt

	! grep -q '^restarted$' "${EVENTS}"
	grep -q 'restore-skip .*baseline=stopped' "${MORS_SETUP_DNS_LOG}"
}

@test "running baseline DNSCrypt remains mandatory during uninstall restore" {
	lifecycle_snapshot__baseline_service_state() { printf '%s\n' running; }
	setup_dns__restart_service() { printf '%s\n' restarted >>"${EVENTS}"; return 7; }
	source <(sed -n '/^setup__restore_baseline_service_if_running()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	run setup__restore_baseline_service_if_running "${MORS_SETUP_DNSCRYPT_INIT}" dnscrypt 192.0.2.1 53

	[ "${status}" -eq 7 ]
	grep -q '^restarted$' "${EVENTS}"
}

@test "unknown legacy baseline keeps DNSCrypt stopped when restored resolver is ready" {
	lifecycle_snapshot__baseline_service_state() { return 1; }
	setup_dns__wait_resolver() { return 0; }
	setup_dns__restart_service() { printf '%s\n' restarted >>"${EVENTS}"; }
	source <(sed -n '/^setup__restore_baseline_service_if_running()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	setup__restore_baseline_service_if_running "${MORS_SETUP_DNSCRYPT_INIT}" dnscrypt 192.0.2.1 53

	! grep -q '^restarted$' "${EVENTS}"
	grep -q 'baseline=unknown resolver=ready' "${MORS_SETUP_DNS_LOG}"
}

@test "unknown legacy baseline starts DNSCrypt when restored resolver still fails" {
	lifecycle_snapshot__baseline_service_state() { return 1; }
	setup_dns__wait_resolver() { return 1; }
	setup_dns__restart_service() { printf '%s\n' restarted >>"${EVENTS}"; }
	source <(sed -n '/^setup__restore_baseline_service_if_running()/,/^}/p' "${REPO_ROOT}/opt/bin/main/setup")

	setup__restore_baseline_service_if_running "${MORS_SETUP_DNSCRYPT_INIT}" dnscrypt 192.0.2.1 53

	grep -q '^restarted$' "${EVENTS}"
}
