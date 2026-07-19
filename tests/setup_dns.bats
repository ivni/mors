#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
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
	export MORS_SETUP_DNSCRYPT_BIN MORS_SETUP_DNSCRYPT_CONFIG
	export MORS_SETUP_DNSCRYPT_INIT MORS_SETUP_DNSMASQ_INIT MORS_SETUP_DNS_TIMEOUT_CMD
	export MORS_SETUP_DNS_LOG MORS_SETUP_DNS_READY_TIMEOUT MORS_SETUP_DNS_RETRY_INTERVAL
	printf 'listen_addresses = ["127.0.0.1:9153"]\n' >"${MORS_SETUP_DNSCRYPT_CONFIG}"
	get_config_value() {
		case "$1" in DNS_CRYPT_PORT) printf '%s\n' 9153 ;; DNSMASQ_PORT) printf '%s\n' 9753 ;; esac
	}
	. "${REPO_ROOT}/opt/bin/libs/setup_dns"
}

@test "cold DNS commit validates then starts each dependency exactly once" {
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
	bind_line=$(grep -n 'setup__bind_transaction_dns_log' <<<"${wrapper}" | cut -d: -f1)
	apply_line=$(grep -n 'setup__cmd_install_unlocked' <<<"${wrapper}" | cut -d: -f1)
	verify_line=$(grep -n 'setup__verify_committed' <<<"${wrapper}" | cut -d: -f1)
	[ "${bind_line}" -lt "${apply_line}" ]
	[ "${apply_line}" -lt "${verify_line}" ]
}
