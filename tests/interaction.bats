#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	INTERACTION_LIB="${REPO_ROOT}/opt/bin/libs/interaction"
	SETUP_SCRIPT="${REPO_ROOT}/opt/bin/main/setup"
}

run_confirm() {
	local input
	input=$1
	run bash -c '. "$1"; cli_confirm__ask "Продолжить?"' \
		bash "${INTERACTION_LIB}" <<<"${input}"
}

run_setup_apply() {
	local input marker
	input=$1
	marker=$2
	run bash -c '
		. "$1"
		eval "$(sed -n "/^setup__interactive_apply()/,/^}/p" "$2")"
		marker=$3
		setup_plan__interactive() { return 0; }
		setup_plan__print() { :; }
		error() { printf "%s\n" "$*" >&2; }
		cmd_install() { printf "%s\n" install >>"${marker}"; }
		setup__interactive_apply
	' bash "${INTERACTION_LIB}" "${SETUP_SCRIPT}" "${marker}" <<<"${input}"
}

run_setup_apply_eof() {
	local marker
	marker=$1
	run bash -c '
		. "$1"
		eval "$(sed -n "/^setup__interactive_apply()/,/^}/p" "$2")"
		marker=$3
		setup_plan__interactive() { return 0; }
		setup_plan__print() { :; }
		error() { printf "%s\n" "$*" >&2; }
		cmd_install() { printf "%s\n" install >>"${marker}"; }
		setup__interactive_apply
	' bash "${INTERACTION_LIB}" "${SETUP_SCRIPT}" "${marker}" </dev/null
}

run_uninstall() {
	local input marker purge result
	input=$1
	marker=$2
	purge=${3:-false}
	result=${4:-0}
	run bash -c '
		. "$1"
		eval "$(sed -n \
			-e "/^setup__confirm_uninstall()/,/^}/p" \
			-e "/^setup__run_uninstall()/,/^}/p" \
			-e "/^setup__interactive_uninstall()/,/^}/p" "$2")"
		marker=$3
		result=$5
		cmd_uninstall() {
			printf "%s\n" "$*" >>"${marker}"
			return "${result}"
		}
		setup__interactive_uninstall "$4"
	' bash "${INTERACTION_LIB}" "${SETUP_SCRIPT}" "${marker}" "${purge}" "${result}" <<<"${input}"
}

run_confirmed_uninstall() {
	local marker purge result
	marker=$1
	purge=${2:-false}
	result=${3:-0}
	run bash -c '
		eval "$(sed -n \
			-e "/^setup__run_uninstall()/,/^}/p" \
			-e "/^cmd_uninstall_cli()/,/^setup__cmd_install_with_runtime()/p" \
			"$1" | sed "\$d")"
		marker=$2
		result=$4
		cmd_uninstall() {
			printf "%s\n" "$*" >>"${marker}"
			return "${result}"
		}
		if [ "$3" = true ]; then
			cmd_uninstall_cli --purge --yes
		else
			cmd_uninstall_cli --yes
		fi
	' bash "${SETUP_SCRIPT}" "${marker}" "${purge}" "${result}"
}

@test "confirmation accepts documented affirmative answers" {
	local answer
	for answer in y Y yes YES Yes да Да ДА; do
		run_confirm "${answer}"
		[ "${status}" -eq 0 ]
		[[ "${output}" == *'Продолжить? [y/N]:'* ]]
	done
}

@test "confirmation normalizes CR ASCII spaces and bracketed paste" {
	local answer
	for answer in $'y\r' ' y ' $'\e[200~y\e[201~'; do
		run_confirm "${answer}"
		[ "${status}" -eq 0 ]
	done
}

@test "confirmation treats default No and exact negative answers as cancellation" {
	local answer
	for answer in '' n N no NO No нет Нет НЕТ; do
		run_confirm "${answer}"
		[ "${status}" -eq 1 ]
		[[ "${output}" != *'Ответ не распознан.'* ]]
	done
}

@test "unrecognized answer is retried and then can be confirmed" {
	run_confirm $'maybe\ny'

	[ "${status}" -eq 0 ]
	[[ "${output}" == *'Ответ не распознан. Введите y для продолжения или n для отмены.'* ]]
	[ "$(grep -o 'Продолжить? \[y/N\]:' <<<"${output}" | wc -l)" -eq 2 ]
}

@test "three unrecognized answers fail with input status" {
	run_confirm $'maybe\nlater\nagain'

	[ "${status}" -eq 64 ]
	[ "$(grep -o 'Ответ не распознан\.' <<<"${output}" | wc -l)" -eq 3 ]
	[[ "${output}" == *'Допустимое число попыток исчерпано. Изменения не выполнены.'* ]]
}

@test "EOF is an input error and is not reported as cancellation" {
	run bash -c '. "$1"; cli_confirm__ask "Продолжить?"' \
		bash "${INTERACTION_LIB}" </dev/null

	[ "${status}" -eq 64 ]
	[[ "${output}" == *'Не удалось прочитать ответ. Изменения не выполнены.'* ]]
	[[ "${output}" != *'отменена'* ]]
}

@test "unknown controls are not reflected and cannot confirm" {
	run_confirm $'\e[31my\nn'

	[ "${status}" -eq 1 ]
	[[ "${output}" == *'Ответ не распознан.'* ]]
	[[ "${output}" != *$'\e'* ]]
}

@test "overlong input cannot confirm and exhausts the bounded retries" {
	local long input
	long=$(printf 'x%.0s' {1..65})
	input=$(printf '%s\n%s\n%s' "${long}" "${long}" "${long}")

	run_confirm "${input}"

	[ "${status}" -eq 64 ]
	[[ "${output}" == *'Допустимое число попыток исчерпано. Изменения не выполнены.'* ]]
}

@test "interactive setup retries invalid input and starts installation exactly once" {
	local marker=${BATS_TEST_TMPDIR}/setup-called

	run_setup_apply $'maybe\ny\r' "${marker}"

	[ "${status}" -eq 0 ]
	[ "$(cat "${marker}")" = install ]
	[ "$(wc -l <"${marker}")" -eq 1 ]
	[[ "${output}" == *'Ответ не распознан.'* ]]
}

@test "interactive setup cancellation and EOF never start installation" {
	local cancel_marker=${BATS_TEST_TMPDIR}/setup-cancelled
	local eof_marker=${BATS_TEST_TMPDIR}/setup-eof

	run_setup_apply n "${cancel_marker}"
	[ "${status}" -eq 0 ]
	[ ! -e "${cancel_marker}" ]
	[[ "${output}" == *'Настройка отменена. Изменения не выполнены.'* ]]

	run_setup_apply_eof "${eof_marker}"
	[ "${status}" -eq 64 ]
	[ ! -e "${eof_marker}" ]
	[[ "${output}" == *'Не удалось прочитать ответ. Изменения не выполнены.'* ]]
	[[ "${output}" != *'Настройка отменена.'* ]]
}

@test "interactive uninstall uses the shared helper and mutates exactly once" {
	local marker=${BATS_TEST_TMPDIR}/uninstall-called

	run_uninstall $'\e[200~ y \e[201~' "${marker}" true

	[ "${status}" -eq 0 ]
	[ "$(cat "${marker}")" = 'full yes' ]
	[ "$(wc -l <"${marker}")" -eq 1 ]
	[[ "${output}" == *'Удалить Mors вместе с пользовательскими данными? [y/N]:'* ]]
}

@test "interactive uninstall cancellation never calls domain operation" {
	local marker=${BATS_TEST_TMPDIR}/uninstall-cancelled

	run_uninstall нет "${marker}" false

	[ "${status}" -eq 0 ]
	[ ! -e "${marker}" ]
	[[ "${output}" == *'Удаление отменено. Изменения не выполнены.'* ]]
}

@test "interactive purge failure is returned without a second uninstall" {
	local marker=${BATS_TEST_TMPDIR}/uninstall-failed

	run_uninstall y "${marker}" true 37

	[ "${status}" -eq 37 ]
	[ "$(cat "${marker}")" = 'full yes' ]
	[ "$(wc -l <"${marker}")" -eq 1 ]
}

@test "confirmed purge failure is returned without a non-purge fallback" {
	local marker=${BATS_TEST_TMPDIR}/uninstall-confirmed-failed

	run_confirmed_uninstall "${marker}" true 41

	[ "${status}" -eq 41 ]
	[ "$(cat "${marker}")" = 'full yes' ]
	[ "$(wc -l <"${marker}")" -eq 1 ]
}

@test "setup and uninstall contain no private confirmation case tables" {
	local setup_body uninstall_body
	setup_body=$(sed -n '/^setup__interactive_apply()/,/^}/p' "${SETUP_SCRIPT}")
	uninstall_body=$(sed -n '/^setup__confirm_uninstall()/,/^}/p' "${SETUP_SCRIPT}")

	grep -q "cli_confirm__ask 'Продолжить настройку?'" <<<"${setup_body}"
	grep -q 'cli_confirm__ask "Удалить Mors' <<<"${uninstall_body}"
	! grep -Eq 'y\|Y\|yes|да\|Да\|ДА' <<<"${setup_body}${uninstall_body}"
}
