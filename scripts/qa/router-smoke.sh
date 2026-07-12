#!/usr/bin/env bash
set -euo pipefail

: "${ROUTER_HOST:?ROUTER_HOST is required}"
: "${IPK_PATH:?IPK_PATH is required}"

router_user="${ROUTER_USER:-root}"
router_port="${ROUTER_PORT:-22}"
confirm="${MORS_ROUTER_SMOKE_CONFIRM:-}"

if [ "${confirm}" != "install-mors-passive" ]; then
	echo "Set MORS_ROUTER_SMOKE_CONFIRM=install-mors-passive to allow passive package installation" >&2
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
# Entware Dropbear does not necessarily provide an SFTP subsystem.
scp -O -P "${router_port}" "${IPK_PATH}" "${ssh_target}:${remote_dir}/${package_name}"

ssh "${ssh_opts[@]}" "${ssh_target}" "PACKAGE='${remote_dir}/${package_name}' sh -s" <<'REMOTE'
set -eu

snapshot() {
	prefix=$1
	(opkg list-installed 2>/dev/null || true) | sort >"${prefix}.packages"
	(iptables-save 2>/dev/null || true) | grep 'MORS_' >"${prefix}.iptables"
	(ipset list -n 2>/dev/null || true) | grep '^MORS' >"${prefix}.ipset"
	for path in \
		/opt/etc/init.d/S96mors \
		/opt/etc/ndm/fs.d/15-mors-start.sh \
		/opt/etc/ndm/netfilter.d/100-dns-local; do
		[ -e "${path}" ] && printf '%s\n' "${path}"
	done >"${prefix}.hooks"
	for service in S56dnsmasq S09dnscrypt-proxy2 S99adguardhome; do
		path=/opt/etc/init.d/${service}
		if [ -x "${path}" ]; then
			printf '%s\t' "${service}"
			"${path}" status 2>/dev/null || true
		else
			printf '%s\tmissing\n' "${service}"
		fi
	done >"${prefix}.dns-services"
	for path in \
		/opt/etc/dnsmasq.conf \
		/opt/etc/dnscrypt-proxy.toml \
		/opt/etc/AdGuardHome/AdGuardHome.yaml; do
		if [ -r "${path}" ]; then
			sha256sum "${path}"
		else
			printf '%s  %s\n' missing "${path}"
		fi
	done >"${prefix}.dns-configs"
}

snapshot /opt/tmp/mors-qa/before
opkg install "${PACKAGE}"

mors version
mors help >/opt/tmp/mors-qa/mors.help.out
mors >/opt/tmp/mors-qa/mors.status.out
if mors test; then
	echo 'Fresh passive install unexpectedly reported a configured runtime.' >&2
	exit 1
else
	[ "$?" -eq 3 ] || exit 1
fi

snapshot /opt/tmp/mors-qa/after

cmp /opt/tmp/mors-qa/before.iptables /opt/tmp/mors-qa/after.iptables
cmp /opt/tmp/mors-qa/before.ipset /opt/tmp/mors-qa/after.ipset
cmp /opt/tmp/mors-qa/before.hooks /opt/tmp/mors-qa/after.hooks

[ "$(( $(wc -l </opt/tmp/mors-qa/after.packages) - $(wc -l </opt/tmp/mors-qa/before.packages) ))" -ge 1 ]

snapshot /opt/tmp/mors-qa/installed
mors uninstall --yes
snapshot /opt/tmp/mors-qa/removed

cmp /opt/tmp/mors-qa/installed.iptables /opt/tmp/mors-qa/removed.iptables
cmp /opt/tmp/mors-qa/installed.ipset /opt/tmp/mors-qa/removed.ipset
cmp /opt/tmp/mors-qa/installed.hooks /opt/tmp/mors-qa/removed.hooks
cmp /opt/tmp/mors-qa/installed.dns-services /opt/tmp/mors-qa/removed.dns-services
cmp /opt/tmp/mors-qa/installed.dns-configs /opt/tmp/mors-qa/removed.dns-configs
[ ! -e /opt/bin/mors ]

echo "Passive router install/uninstall smoke completed"
REMOTE
