#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	EVENTS=${BATS_TEST_TMPDIR}/events
	LOOKUPS=${BATS_TEST_TMPDIR}/lookups
	JOURNAL=${BATS_TEST_TMPDIR}/journal.json
	: >"${EVENTS}"
	: >"${LOOKUPS}"
	telemetry_runtime__pin_production() { :; }
	source <(sed '/^\. \/opt\/apps\/mors\/bin\/libs\//d' "${REPO_ROOT}/opt/bin/main/setup")

	PROXY_VLESS_NAME=Proxy21
	PROXY_VLESS_ENTWARE=t2s21
	PROXY_VLESS_DESC=Mors-proxy-vless
	LEGACY_PROXY_VLESS_DESC=Kvas-proxy-vless
	PROXY_STATE=missing
	lifecycle_transaction__journal_file() { printf '%s\n' "${JOURNAL}"; }
	error() { :; }
	sleep() { :; }
	setup__proxy_vless_lookup() {
		printf '%s\n' lookup >>"${LOOKUPS}"
		case "${PROXY_STATE}" in
			missing)
				printf '%s\n' '{"presence":"missing","cli":"Proxy21","entware":"t2s21","type":"","interface_name":"","description":""}'
				;;
			pending)
				printf '%s\n' '{"presence":"present","cli":"Proxy21","entware":"t2s21","type":"Proxy","interface_name":"","description":"Mors-proxy-vless"}'
				;;
			mors)
				printf '%s\n' '{"presence":"present","cli":"Proxy21","entware":"t2s21","type":"Proxy","interface_name":"opkg21","description":"Mors-proxy-vless"}'
				;;
			legacy)
				printf '%s\n' '{"presence":"present","cli":"Proxy21","entware":"t2s21","type":"Proxy","interface_name":"opkg21","description":"Kvas-proxy-vless"}'
				;;
			foreign)
				printf '%s\n' '{"presence":"present","cli":"Proxy21","entware":"t2s21","type":"Proxy","interface_name":"opkg21","description":"Operator proxy"}'
				;;
		esac
	}
	delete_proxy_interface() {
		printf '%s\n' delete >>"${EVENTS}"
		PROXY_STATE=missing
	}
	rename_proxy_interface() {
		printf 'rename:%s\n' "$1" >>"${EVENTS}"
		case "$1" in
			"${PROXY_VLESS_DESC}") PROXY_STATE=mors ;;
			"${LEGACY_PROXY_VLESS_DESC}") PROXY_STATE=legacy ;;
			*) return 64 ;;
		esac
	}
}

write_journal() {
	jq -n \
		--arg provisioning "$1" \
		--arg provision_state "$2" \
		--arg original_description "${3:-}" \
		'{plan: {provisioning: $provisioning, provision_state: $provision_state, interface_original_description: $original_description}}' \
		>"${JOURNAL}"
}

@test "managed Proxy21 lookup accepts only the exact Mors description" {
	PROXY_STATE=foreign
	run setup__managed_vless_live
	[ "${status}" -ne 0 ]

	PROXY_STATE=mors
	run setup__managed_vless_live
	[ "${status}" -eq 0 ]
	[ "$(jq -r '.description' <<<"${output}")" = Mors-proxy-vless ]
}

@test "rollback accepts bounded stable absence after managed creation did not start" {
	write_journal managed_vless creating
	PROXY_STATE=missing

	run setup__rollback_provisioned_interface

	[ "${status}" -eq 0 ]
	[ "$(wc -l <"${LOOKUPS}")" -eq 4 ]
	[ ! -s "${EVENTS}" ]
}

@test "rollback does not guess ownership while managed Proxy21 is pending" {
	write_journal managed_vless creating
	PROXY_STATE=pending

	run setup__rollback_provisioned_interface

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "rollback fails closed when Proxy21 appears during missing confirmation" {
	write_journal managed_vless creating
	sequence_counter=${BATS_TEST_TMPDIR}/sequence-counter
	printf '%s\n' 0 >"${sequence_counter}"
	setup__proxy_vless_lookup() {
		calls=$(cat "${sequence_counter}")
		calls=$((calls + 1))
		printf '%s\n' "${calls}" >"${sequence_counter}"
		if [ "${calls}" -eq 1 ]; then
			printf '%s\n' '{"presence":"missing","cli":"Proxy21","entware":"t2s21","type":"","interface_name":"","description":""}'
		else
			printf '%s\n' '{"presence":"present","cli":"Proxy21","entware":"t2s21","type":"Proxy","interface_name":"","description":"Mors-proxy-vless"}'
		fi
	}

	run setup__rollback_provisioned_interface

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "rollback never deletes a foreign Proxy21" {
	write_journal managed_vless created
	PROXY_STATE=foreign

	run setup__rollback_provisioned_interface

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "rollback deletes only an exact published Mors Proxy21" {
	write_journal managed_vless created
	PROXY_STATE=mors

	run setup__rollback_provisioned_interface

	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = delete ]
}

@test "rollback accepts an already absent interface only after creation completed" {
	write_journal managed_vless created
	PROXY_STATE=missing

	run setup__rollback_provisioned_interface

	[ "${status}" -eq 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "legacy rollback never renames a foreign Proxy21" {
	write_journal legacy_vless adopted Kvas-proxy-vless
	PROXY_STATE=foreign

	run setup__rollback_provisioned_interface

	[ "${status}" -ne 0 ]
	[ ! -s "${EVENTS}" ]
}

@test "legacy rollback changes only the exact Mors description" {
	write_journal legacy_vless adopted Kvas-proxy-vless
	PROXY_STATE=mors

	run setup__rollback_provisioned_interface

	[ "${status}" -eq 0 ]
	[ "$(cat "${EVENTS}")" = 'rename:Kvas-proxy-vless' ]
}

@test "legacy rollback is idempotent when the original description is already present" {
	write_journal legacy_vless adopting Kvas-proxy-vless
	PROXY_STATE=legacy

	run setup__rollback_provisioned_interface

	[ "${status}" -eq 0 ]
	[ ! -s "${EVENTS}" ]
}
