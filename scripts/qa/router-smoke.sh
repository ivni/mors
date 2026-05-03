#!/usr/bin/env bash
set -euo pipefail

: "${ROUTER_HOST:?ROUTER_HOST is required}"
: "${IPK_PATH:?IPK_PATH is required}"

router_user="${ROUTER_USER:-root}"
router_port="${ROUTER_PORT:-22}"
confirm="${MORS_ROUTER_SMOKE_CONFIRM:-}"

if [ "${confirm}" != "install-mors" ]; then
	echo "Set MORS_ROUTER_SMOKE_CONFIRM=install-mors to allow router package installation" >&2
	exit 2
fi

if [ ! -f "${IPK_PATH}" ]; then
	echo "Package not found: ${IPK_PATH}" >&2
	exit 1
fi

remote_dir="/opt/tmp/mors-qa"
package_name="$(basename "${IPK_PATH}")"
ssh_target="${router_user}@${ROUTER_HOST}"
ssh_opts=(-p "${router_port}" -o StrictHostKeyChecking=accept-new)

ssh "${ssh_opts[@]}" "${ssh_target}" "mkdir -p '${remote_dir}'"
scp -P "${router_port}" "${IPK_PATH}" "${ssh_target}:${remote_dir}/${package_name}"

ssh "${ssh_opts[@]}" "${ssh_target}" "PACKAGE='${remote_dir}/${package_name}' sh -s" <<'REMOTE'
set -eu

opkg install "${PACKAGE}"

mors version
mors help >/opt/tmp/mors-qa/mors.help.out
mors test

if command -v iptables-save >/dev/null 2>&1; then
	iptables-save | grep -q 'MORS_' || true
fi

echo "Router smoke completed"
REMOTE
