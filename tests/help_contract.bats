#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	HELP_FILE="${REPO_ROOT}/opt/etc/conf/mors.help"
}

@test "help file documents the main user command groups" {
	grep -q 'Работа со списком' "${HELP_FILE}"
	grep -q 'Расширенные настройки' "${HELP_FILE}"
	grep -q 'Поиск и устранение неисправностей' "${HELP_FILE}"
	grep -q 'Управление пакетом' "${HELP_FILE}"
}

@test "help file documents critical smoke commands" {
	grep -q '^show|list' "${HELP_FILE}"
	grep -q '^add|new' "${HELP_FILE}"
	grep -q '^vpn ' "${HELP_FILE}"
	grep -q '^dnsmasq ' "${HELP_FILE}"
	grep -q '^debug ' "${HELP_FILE}"
	grep -q '^test ' "${HELP_FILE}"
	grep -q '^test --all' "${HELP_FILE}"
	grep -q '^test cold recover' "${HELP_FILE}"
	grep -q '^ver|version' "${HELP_FILE}"
	grep -q '^vless version|ver' "${HELP_FILE}"
	grep -q '^vless add' "${HELP_FILE}"
	grep -q '^vless status' "${HELP_FILE}"
	grep -q '^vless check' "${HELP_FILE}"
	grep -q '^vless events' "${HELP_FILE}"
}
