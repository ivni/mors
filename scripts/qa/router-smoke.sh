#!/usr/bin/env bash
set -euo pipefail

: "${ROUTER_HOST:?ROUTER_HOST is required}"
: "${IPK_PATH:?IPK_PATH is required}"
: "${LEGACY_IPK_PATH:?LEGACY_IPK_PATH is required}"

router_user="${ROUTER_USER:-root}"
router_port="${ROUTER_PORT:-22}"
confirm="${MORS_ROUTER_SMOKE_CONFIRM:-}"

if [ "${confirm}" != "install-mors-passive" ]; then
	echo "Set MORS_ROUTER_SMOKE_CONFIRM=install-mors-passive to allow passive package installation" >&2
	exit 2
fi

for package in "${IPK_PATH}" "${LEGACY_IPK_PATH}"; do
	if [ ! -f "${package}" ]; then
		echo "Package not found: ${package}" >&2
		exit 1
	fi
done

remote_dir="/opt/tmp/mors-qa"
current_name="$(basename "${IPK_PATH}")"
legacy_name="$(basename "${LEGACY_IPK_PATH}")"
ssh_target="${router_user}@${ROUTER_HOST}"
ssh_opts=(-p "${router_port}" -o StrictHostKeyChecking=accept-new)
staging_dir="$(mktemp -d)"
trap 'rm -rf -- "${staging_dir}"' EXIT

package_version() {
	local package_path=$1 extract_dir=$2 version
	mkdir -p "${extract_dir}"
	tar -xzf "${package_path}" -C "${extract_dir}" ./control.tar.gz
	tar -xzf "${extract_dir}/control.tar.gz" -C "${extract_dir}" ./control
	version="$(sed -n 's/^Version: //p; /^Version: /q' "${extract_dir}/control" | tr -d '\r')"
	case "${version}" in
		''|*[!0-9A-Za-z.+~:_-]*)
			echo "Invalid package version in ${package_path}" >&2
			return 1
			;;
	esac
	printf '%s\n' "${version}"
}

current_version="$(package_version "${IPK_PATH}" "${staging_dir}/current-control")"
legacy_version="$(package_version "${LEGACY_IPK_PATH}" "${staging_dir}/legacy-control")"
cp -f "${IPK_PATH}" "${staging_dir}/${current_name}"
cp -f "${LEGACY_IPK_PATH}" "${staging_dir}/${legacy_name}"
(
	cd "${staging_dir}"
	sha256sum "${current_name}" >"${current_name}.sha256"
	sha256sum "${legacy_name}" >"${legacy_name}.sha256"
)

ssh "${ssh_opts[@]}" "${ssh_target}" \
	"test '${remote_dir}' = /opt/tmp/mors-qa && rm -rf '${remote_dir}' && mkdir -p '${remote_dir}'"
# Entware Dropbear does not necessarily provide an SFTP subsystem.
scp -O -P "${router_port}" \
	"${staging_dir}/${current_name}" "${staging_dir}/${current_name}.sha256" \
	"${staging_dir}/${legacy_name}" "${staging_dir}/${legacy_name}.sha256" \
	"${ssh_target}:${remote_dir}/"

ssh "${ssh_opts[@]}" "${ssh_target}" \
	"CURRENT_PACKAGE='${remote_dir}/${current_name}' LEGACY_PACKAGE='${remote_dir}/${legacy_name}' CURRENT_VERSION='${current_version}' LEGACY_VERSION='${legacy_version}' sh -s" <<'REMOTE'
set -eu

fail() {
	echo "$*" >&2
	exit 1
}

missing() {
	[ ! -e "$1" ] && [ ! -L "$1" ]
}

snapshot() {
	prefix=$1
	opkg list-installed >"${prefix}.packages.raw" || return 1
	sort "${prefix}.packages.raw" >"${prefix}.packages"
	rm -f "${prefix}.packages.raw"

	iptables-save >"${prefix}.iptables.raw" || return 1
	grep -E '(^|[[:space:]:])MORS(_|[[:space:]])' \
		"${prefix}.iptables.raw" >"${prefix}.iptables" || true
	rm -f "${prefix}.iptables.raw"

	ipset list -n >"${prefix}.ipset.raw" || return 1
	grep -E '^MORS($|_)' "${prefix}.ipset.raw" >"${prefix}.ipset" || true
	rm -f "${prefix}.ipset.raw"

	/opt/sbin/ip -4 rule show >"${prefix}.rules.raw" || return 1
	grep -E '(^|[[:space:]])(fwmark 0xd1000/0xd1000|lookup 1001)([[:space:]]|$)' \
		"${prefix}.rules.raw" >"${prefix}.rules" || true
	rm -f "${prefix}.rules.raw"

	if /opt/sbin/ip -4 route show table 1001 >"${prefix}.routes" 2>"${prefix}.routes.error"; then
		:
	elif grep -q 'FIB table does not exist' "${prefix}.routes.error"; then
		: >"${prefix}.routes"
	else
		cat "${prefix}.routes.error" >&2
		return 1
	fi
	rm -f "${prefix}.routes.error"

	for path in \
		/opt/etc/init.d/S96mors \
		/opt/etc/init.d/S25mors-vless \
		/opt/etc/ndm/fs.d/15-mors-start.sh \
		/opt/etc/ndm/netfilter.d/100-dns-local \
		/opt/etc/ndm/netfilter.d/100-vpn-mark \
		/opt/etc/ndm/netfilter.d/100-proxy-redirect \
		/opt/etc/ndm/ifcreated.d/mors-iface-add \
		/opt/etc/ndm/ifdestroyed.d/mors-iface-del \
		/opt/etc/ndm/iflayerchanged.d/100-mors-vpn \
		/opt/etc/cron.5mins/vless-watchdog \
		/opt/etc/cron.5mins/check_vpn; do
		[ -e "${path}" ] || [ -L "${path}" ] || continue
		printf '%s\n' "${path}"
	done >"${prefix}.hooks"
	for managed_hook in \
		'/opt/etc/init.d/S97xray:/opt/apps/mors/etc/init.d/S97xray' \
		'/opt/etc/init.d/S98mors-telemetry:/opt/apps/mors/etc/init.d/S98mors-telemetry'; do
		path=${managed_hook%%:*}
		target=${managed_hook#*:}
		[ -L "${path}" ] && [ "$(readlink "${path}")" = "${target}" ] || continue
		printf '%s\n' "${path}" >>"${prefix}.hooks"
	done

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

require_passive_snapshot() {
	prefix=$1
	for suffix in iptables ipset rules routes hooks; do
		[ ! -s "${prefix}.${suffix}" ] || fail "Unexpected Mors ${suffix} in ${prefix}"
	done
}

prepare_shared_fixture() {
	path=$1
	name=$2
	parent=${path%/*}
	[ "${parent}" != "${path}" ] || return 1
	[ -d "${parent}" ] && [ ! -L "${parent}" ] && [ ! -L "${path}" ] || return 1
	if [ -e "${path}" ]; then
		[ -f "${path}" ] || return 1
		printf '%s\n' existing >"${remote_dir}/${name}.mode"
	else
		printf 'foreign-router-smoke-%s\n' "${name}" >"${path}" || return 1
		printf '%s\n' created >"${remote_dir}/${name}.mode"
	fi
	sha256sum "${path}" >"${remote_dir}/${name}.sha256"
}

prepare_shared_parent() {
	path=$1
	[ ! -L "${path}" ] || return 1
	if [ -e "${path}" ]; then
		[ -d "${path}" ] || return 1
		printf '%s\n' existing >"${remote_dir}/adblock-parent.mode"
	else
		mkdir -p "${path}" || return 1
		printf '%s\n' created >"${remote_dir}/adblock-parent.mode"
	fi
}

verify_shared_fixture() {
	sha256sum -c "${remote_dir}/$1.sha256"
}

cleanup_shared_fixture() {
	path=$1
	name=$2
	[ ! -r "${remote_dir}/${name}.mode" ] || \
		[ "$(cat "${remote_dir}/${name}.mode")" != created ] || \
		rm -f "${path}"
}

cleanup_fixtures() {
	cleanup_shared_fixture /opt/etc/adblock/sources.list adblock-sources
	cleanup_shared_fixture /opt/etc/adblock/exception.list adblock-exception
	[ ! -r "${remote_dir}/adblock-parent.mode" ] || \
		[ "$(cat "${remote_dir}/adblock-parent.mode")" != created ] || \
		rmdir /opt/etc/adblock 2>/dev/null || true
}
trap cleanup_fixtures EXIT HUP INT TERM

snapshot "${remote_dir}/before"
require_passive_snapshot "${remote_dir}/before"
if grep -q '^mors - ' "${remote_dir}/before.packages"; then
	fail 'The test router already has a Mors package installed.'
fi
for path in \
	/opt/bin/mors \
	/opt/apps/mors \
	/opt/etc/.mors \
	/opt/etc/mors.conf \
	/opt/etc/mors.list \
	/opt/etc/mors \
	/opt/var/lib/mors \
	/opt/var/run/mors \
	/tmp/mors \
	/opt/etc/xray/mors.json \
	/opt/etc/xray/mors.json.legacy-1.1.9; do
	missing "${path}" || fail "The test router contains stale Mors state: ${path}"
done

prepare_shared_parent /opt/etc/adblock
prepare_shared_fixture /opt/etc/adblock/sources.list adblock-sources
prepare_shared_fixture /opt/etc/adblock/exception.list adblock-exception

opkg install "${LEGACY_PACKAGE}"
[ "$(opkg status mors | awk -F': ' '/^Version:/{print $2; exit}')" = "${LEGACY_VERSION}" ]
[ -f /opt/apps/mors/bin/libs/ndm ]
[ -f /opt/apps/mors/etc/ndm/ndm ]
snapshot "${remote_dir}/legacy-installed"
require_passive_snapshot "${remote_dir}/legacy-installed"

mors update apply "${CURRENT_PACKAGE}" --rollback-ipk "${LEGACY_PACKAGE}" --yes
[ "$(opkg status mors | awk -F': ' '/^Version:/{print $2; exit}')" = "${CURRENT_VERSION}" ]
[ -f /opt/apps/mors/bin/libs/ndm ]
[ ! -e /opt/apps/mors/etc/ndm/ndm ]
[ -s /opt/etc/.mors/ownership/package-ndm.cksum ]

mors version
mors help >"${remote_dir}/mors.help.out"
mors >"${remote_dir}/mors.status.out"
if mors test; then
	fail 'Passive upgraded install unexpectedly reported a configured runtime.'
else
	[ "$?" -eq 3 ] || exit 1
fi

snapshot "${remote_dir}/installed"
require_passive_snapshot "${remote_dir}/installed"
cmp "${remote_dir}/before.iptables" "${remote_dir}/installed.iptables"
cmp "${remote_dir}/before.ipset" "${remote_dir}/installed.ipset"
cmp "${remote_dir}/before.rules" "${remote_dir}/installed.rules"
cmp "${remote_dir}/before.routes" "${remote_dir}/installed.routes"
cmp "${remote_dir}/before.hooks" "${remote_dir}/installed.hooks"
cmp "${remote_dir}/before.dns-services" "${remote_dir}/installed.dns-services"
cmp "${remote_dir}/before.dns-configs" "${remote_dir}/installed.dns-configs"

# Seed only Mors-specific and telemetry-known files. A successful full purge
# must remove them even when the installation was never configured.
[ ! -L /opt/etc/mors ] && [ ! -L /opt/var/lib/mors ] && [ ! -L /opt/etc/xray ]
[ ! -e /opt/etc/xray ] || [ -d /opt/etc/xray ]
mkdir -p \
	/opt/etc/mors/vless/connections \
	/opt/var/lib/mors/vless \
	/opt/etc/mors/telemetry \
	/opt/var/lib/mors/telemetry \
	/opt/etc/xray
printf '%s\n' secret > /opt/etc/mors/vless/connections/router-smoke.json
printf '%s\n' state > /opt/var/lib/mors/vless/state.json
printf '%s\n' '{}' > /opt/etc/mors/telemetry/config.json
printf '%s\n' secret > /opt/etc/mors/telemetry/monium.key
printf '%s\n' queued > /opt/var/lib/mors/telemetry/outbox.jsonl
printf '%s\n' '{}' > /opt/etc/xray/mors.json
printf '%s\n' '{}' > /opt/etc/xray/mors.json.legacy-1.1.9
printf '%s\n' '{}' > /opt/etc/xray/mors.json.candidate.4242.json
printf '%s\n' '{}' > /opt/etc/xray/mors.json.backup.4242
printf '%s\n' '{}' > /opt/etc/xray/mors.json.rollback.4242.json

mors uninstall --purge --yes
snapshot "${remote_dir}/removed"
require_passive_snapshot "${remote_dir}/removed"

cmp "${remote_dir}/before.iptables" "${remote_dir}/removed.iptables"
cmp "${remote_dir}/before.ipset" "${remote_dir}/removed.ipset"
cmp "${remote_dir}/before.rules" "${remote_dir}/removed.rules"
cmp "${remote_dir}/before.routes" "${remote_dir}/removed.routes"
cmp "${remote_dir}/before.hooks" "${remote_dir}/removed.hooks"
cmp "${remote_dir}/before.dns-services" "${remote_dir}/removed.dns-services"
cmp "${remote_dir}/before.dns-configs" "${remote_dir}/removed.dns-configs"

if grep -q '^mors - ' "${remote_dir}/removed.packages"; then
	fail 'opkg still reports Mors after purge.'
fi
for path in \
	/opt/bin/mors \
	/opt/apps/mors \
	/opt/etc/mors.conf \
	/opt/etc/mors.list \
	/opt/etc/.mors \
	/opt/etc/mors \
	/opt/var/lib/mors \
	/opt/var/run/mors \
	/tmp/mors \
	/opt/etc/xray/mors.json \
	/opt/etc/xray/mors.json.legacy-1.1.9 \
	/opt/etc/xray/mors.json.candidate.4242.json \
	/opt/etc/xray/mors.json.backup.4242 \
	/opt/etc/xray/mors.json.rollback.4242.json; do
	missing "${path}" || fail "Purge left Mors state: ${path}"
done
verify_shared_fixture adblock-sources
verify_shared_fixture adblock-exception

echo "Legacy upgrade and passive router purge smoke completed"
REMOTE
