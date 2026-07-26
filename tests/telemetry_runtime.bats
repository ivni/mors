#!/usr/bin/env bats

setup() {
	REPO_ROOT=$(cd "${BATS_TEST_DIRNAME}/.." && pwd)
}

@test "production runtime pins paths without changing unrelated curl environment" {
	. "${REPO_ROOT}/opt/bin/libs/telemetry_runtime"
	MORS_LIB_DIR=/tmp/attacker
	TELEMETRY_ENDPOINT=https://attacker.invalid/collect
	TELEMETRY_CURL=/tmp/attacker-curl
	TELEMETRY_STAT=/tmp/attacker-stat
	TELEMETRY_SENDER_PROGRAM=/tmp/attacker-sender
	TELEMETRY_CONFIG_ROOT=/tmp/attacker-config
	MORS_TELEMETRY_INIT=/tmp/attacker-init
	MORS_TELEMETRY_INIT_SOURCE=/tmp/attacker-init-source
	PATH=/tmp/attacker-bin
	CURL_CA_BUNDLE=/tmp/attacker-ca
	SSL_CERT_FILE=/tmp/attacker-ca
	https_proxy=http://attacker.invalid:8080
	ALL_PROXY=socks5://attacker.invalid:1080
	telemetry_runtime__pin_production

	[ "${MORS_LIB_DIR}" = /opt/apps/mors/bin/libs ]
	[ "${TELEMETRY_ENDPOINT}" = https://ingest.monium.yandex.cloud/otlp/v1/logs ]
	[ "${TELEMETRY_CURL}" = /opt/bin/curl ]
	[ "${TELEMETRY_STAT}" = /opt/bin/stat ]
	[ "${TELEMETRY_SENDER_PROGRAM}" = /opt/apps/mors/bin/main/telemetry-sender ]
	[ "${TELEMETRY_CONFIG_ROOT}" = /opt/etc/mors/telemetry ]
	[ "${MORS_TELEMETRY_INIT}" = /opt/etc/init.d/S98mors-telemetry ]
	[ "${MORS_TELEMETRY_INIT_SOURCE}" = /opt/apps/mors/etc/init.d/S98mors-telemetry ]
	[ "${PATH}" = /opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ]
	[ "${CURL_CA_BUNDLE}" = /tmp/attacker-ca ]
	[ "${SSL_CERT_FILE}" = /tmp/attacker-ca ]
	[ "${https_proxy}" = http://attacker.invalid:8080 ]
	[ "${ALL_PROXY}" = socks5://attacker.invalid:1080 ]

	telemetry_runtime__pin_transport
	[ -z "${CURL_CA_BUNDLE+x}" ]
	[ -z "${SSL_CERT_FILE+x}" ]
	[ -z "${https_proxy+x}" ]
	[ -z "${ALL_PROXY+x}" ]
}

@test "every installed telemetry entrypoint pins production before loading runtime code" {
	cli=${REPO_ROOT}/opt/bin/mors
	sender=${REPO_ROOT}/opt/bin/main/telemetry-sender
	init=${REPO_ROOT}/opt/etc/init.d/S98mors-telemetry
	setup_script=${REPO_ROOT}/opt/bin/main/setup
	upgrade_script=${REPO_ROOT}/opt/bin/main/upgrade

	[ "$(grep -n 'telemetry_runtime__pin_production' "${cli}" | head -n 1 | cut -d: -f1)" -lt \
		"$(grep -n 'libs/telemetry$' "${cli}" | head -n 1 | cut -d: -f1)" ]
	grep -q '/opt/apps/mors/bin/main/telemetry-sender)' "${sender}"
	grep -q 'telemetry_runtime__pin_production' "${sender}"
	grep -q 'telemetry_runtime__pin_transport' "${sender}"
	grep -q '/opt/etc/init.d/S98mors-telemetry)' "${init}"
	grep -q 'telemetry_runtime__pin_production' "${init}"
	grep -q 'telemetry_runtime__pin_production' "${setup_script}"
	grep -q 'telemetry_runtime__pin_production' "${upgrade_script}"
}
