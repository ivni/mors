#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	source <(sed -n '/^cmd_dnsmasq_listen_show()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/vpn")
	source <(sed -n '/^cmd_vpn_status()/,/^}/p' "${REPO_ROOT}/opt/bin/libs/vpn")
}

@test "dnsmasq status reports the configured listener without AdGuard output" {
	exit_when_adguard_on() { eval "${1}=0"; }
	ready() { printf '%s: ' "${1}"; }
	when_alert() { printf '%s\n' "${1}"; }
	get_config_value() {
		case "${1}" in
			DNSMASQ_LISTEN_IP) printf '%s\n' 192.0.2.1 ;;
			DNSMASQ_PORT) printf '%s\n' 9753 ;;
		esac
	}
	cmd_adguardhome_status() { printf '%s\n' 'НЕ ДОЛЖНО ПОЯВИТЬСЯ'; }

	run cmd_dnsmasq_listen_show
	[ "${status}" -eq 0 ]
	[[ "${output}" == *'192.0.2.1:9753'* ]]
	[[ "${output}" != *'НЕ ДОЛЖНО ПОЯВИТЬСЯ'* ]]
}

@test "generic VPN status delegates managed VLESS to its canonical state" {
	is_vless_over_proxy_enabled() { return 0; }
	cmd_vless_status() { printf '%s\n' 'VLESS: НЕ НАСТРОЕНО'; }
	get_current_vpn_interface() { return 99; }

	run cmd_vpn_status
	[ "${status}" -eq 0 ]
	[ "${output}" = 'VLESS: НЕ НАСТРОЕНО' ]
}
