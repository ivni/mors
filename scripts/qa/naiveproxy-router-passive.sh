#!/bin/sh
# Only a fresh optional package on the explicitly verified disposable router.
set -eu
[ "${MORS_TEST_ROUTER_CONFIRMED:-}" = NC-1913 ] || exit 2
command -v ndmc >/dev/null 2>&1 || exit 2
ndmc -c 'show version' | grep -F 'model: Viva (NC-1913)' >/dev/null || exit 2
opkg print-architecture | grep -F 'arch mipsel-3.4 ' >/dev/null || exit 2
package=${1:?package path required}
expected=${2:?package SHA-256 required}
version=${3:?control version required}
case "$package" in /opt/tmp/mors69-package.*/*.ipk) ;; *) exit 2 ;; esac
case "$expected" in ''|*[!0-9a-f]*) exit 2 ;; esac
[ "${#expected}" -eq 64 ] || exit 2
[ -f "$package" ] && [ ! -L "$package" ] || exit 2
[ "$(sha256sum "$package" | cut -d ' ' -f1)" = "$expected" ] || exit 2
name=mors-naiveproxy
prefix=/opt/apps/mors-naiveproxy
[ ! -e "$prefix" ] && [ ! -L "$prefix" ] || exit 2
[ ! -e "/opt/lib/opkg/info/$name.control" ] || exit 2
[ ! -e "/opt/lib/opkg/info/$name.list" ] || exit 2
[ -z "$(opkg list-installed "$name")" ] || exit 2
[ "$(df -Pk /opt | awk 'NR == 2 { print $4 }')" -ge 131072 ] || exit 2

snapshot() {
    firewall=$(iptables-save) || return 1
    rules=$(ip -4 rule show) || return 1
    routes=$(ip -4 route show table all) || return 1
    {
        printf '%s\n' "$firewall" | sed '/^#/d; s/\[[0-9][0-9]*:[0-9][0-9]*\]/[0:0]/g'
        printf '%s\n' "$rules" "$routes"
        for file in /opt/etc/mors.conf /opt/etc/dnsmasq.conf \
            /opt/etc/AdGuardHome/AdGuardHome.yaml /opt/etc/dnscrypt-proxy2/dnscrypt-proxy.toml; do
            [ ! -f "$file" ] || sha256sum "$file"
        done
        for service in dnsmasq dnscrypt-proxy xray AdGuardHome ss-redir ss-local naive; do
            printf '%s\n' "$service"
            pidof "$service" 2>/dev/null || true
        done
    } | sha256sum | cut -d ' ' -f1
}

owned=false
phase=preflight
cleanup() {
    result=$?
    if [ "$owned" = true ]; then
        opkg remove "$name" >/dev/null 2>&1 || true
    fi
    [ "$result" -eq 0 ] || printf 'FAIL: phase=%s exit=%s\n' "$phase" "$result" >&2
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
before=$(snapshot) || exit 1
owned=true
phase=install
opkg install "$package" >"${package%/*}/opkg-install.log" 2>&1
phase=version_help
[ "$(opkg status "$name" | sed -n 's/^Version: //p')" = "$version" ]
[ "$("$prefix/bin/naive" --version)" = "naive ${version%-*}" ]
"$prefix/bin/naive" --help >/dev/null 2>&1
phase=permissions
[ "$(stat -c '%a' "$prefix/bin/naive")" = 755 ]
[ "$(stat -c '%a' "$prefix/share/ca/ca-bundle.crt")" = 644 ]
[ -d "$prefix/share/ca/empty" ]
[ -z "$(ls -A "$prefix/share/ca/empty")" ]
after_install=$(snapshot) || exit 1
phase=compare_install
[ "$before" = "$after_install" ] || { echo 'FAIL: runtime snapshot changed after install' >&2; exit 1; }
phase=remove
opkg remove "$name" >"${package%/*}/opkg-remove.log" 2>&1
owned=false
phase=tree_cleanup
[ -z "$(opkg list-installed "$name")" ]
[ ! -e "$prefix" ]
after_remove=$(snapshot) || exit 1
phase=compare_remove
[ "$before" = "$after_remove" ] || { echo 'FAIL: runtime snapshot changed after remove' >&2; exit 1; }
printf '%s\n' '{"target":"NC-1913","architecture":"mipsel-3.4","install":"pass","version_help":"pass","runtime_unchanged":"pass","remove":"pass","package_tree_absent":true}'
