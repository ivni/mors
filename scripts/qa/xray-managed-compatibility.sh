#!/usr/bin/env bash
set -euo pipefail

xray_binary="${1:?Usage: xray-managed-compatibility.sh /path/to/xray expected-version}"
expected_version="${2:?Usage: xray-managed-compatibility.sh /path/to/xray expected-version}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
temporary_root="$(mktemp -d)"
xray_pid=''

cleanup() {
	if [[ -n "${xray_pid}" ]]; then
		kill "${xray_pid}" 2>/dev/null || true
		wait "${xray_pid}" 2>/dev/null || true
	fi
	rm -rf "${temporary_root}"
}
trap cleanup EXIT

export MORS_LIB_DIR="${repo_root}/opt/bin/libs"
export VLESS_STORE_ROOT="${temporary_root}/store"
export VLESS_REGISTRY_FILE="${VLESS_STORE_ROOT}/registry.json"
export VLESS_CONNECTIONS_DIR="${VLESS_STORE_ROOT}/connections"
export VLESS_XRAY_CONFIG_FILE="${temporary_root}/mors.json"
export VLESS_API_PORT=10085
export VLESS_MAIN_PORT=1097
export VLESS_XRAY_ACCESS_LOG="${temporary_root}/xray-access.log"
export VLESS_XRAY_ERROR_LOG="${temporary_root}/xray-errors.log"

# shellcheck source=../../opt/bin/libs/vless_config
source "${repo_root}/opt/bin/libs/vless_config"

secret_json() {
	local address="${1}"
	jq -n --arg address "${address}" '{
		user_id: "00000000-0000-4000-8000-000000000000",
		address: $address,
		port: 443,
		network: "tcp",
		security: "reality",
		public_key: "ioE61VC3V30U7IdRmQ3bjhOq2ij9tPhVIgAD4JZ4YRY",
		fingerprint: "chrome",
		server_name: "example.com",
		short_id: "0123456789abcdef",
		flow: "xtls-rprx-vision",
		spider_x: "/",
		encryption: "none"
	}'
}

vless_store__ensure
for number in 1 2 3 4; do
	id="vless-${number}"
	secret_json "192.0.2.${number}" | vless_store__write_secret "${id}"
	vless_store__add_metadata "${id}" "Node ${number}" true "$((11970 + number))"
done

vless_config__generate "${VLESS_XRAY_CONFIG_FILE}" vless-1
"${xray_binary}" run -test -c "${VLESS_XRAY_CONFIG_FILE}"

"${xray_binary}" run -c "${VLESS_XRAY_CONFIG_FILE}" >"${temporary_root}/xray.log" 2>&1 &
xray_pid=$!

ready=false
for _ in {1..30}; do
	if "${xray_binary}" api bi --server=127.0.0.1:10085 mors-vless >/dev/null 2>&1; then
		ready=true
		break
	fi
	sleep 0.2
done

if [[ "${ready}" != true ]]; then
	cat "${temporary_root}/xray.log" >&2
	echo "Xray ${expected_version}: Routing API did not become ready" >&2
	exit 1
fi

for port in 1097 11971 11972 11973 11974; do
	if ! timeout 2 bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null; then
		echo "Xray ${expected_version}: expected localhost inbound ${port} is not listening" >&2
		exit 1
	fi
done

"${xray_binary}" api bo --server=127.0.0.1:10085 -b mors-vless mors-vless-vless-2
balancer_json=$("${xray_binary}" api bi --server=127.0.0.1:10085 -json mors-vless)
if [[ "$(jq -r '.balancer.override.target // empty' <<<"${balancer_json}")" != mors-vless-vless-2 ]]; then
	echo "Xray ${expected_version}: balancer override was not applied" >&2
	exit 1
fi
"${xray_binary}" api bo --server=127.0.0.1:10085 -b mors-vless mors-block
balancer_json=$("${xray_binary}" api bi --server=127.0.0.1:10085 -json mors-vless)
if [[ "$(jq -r '.balancer.override.target // empty' <<<"${balancer_json}")" != mors-block ]]; then
	echo "Xray ${expected_version}: fail-closed override was not applied" >&2
	exit 1
fi
"${xray_binary}" api bo --server=127.0.0.1:10085 -b mors-vless -r

echo "Xray ${expected_version}: managed VLESS config and Routing API are compatible"
