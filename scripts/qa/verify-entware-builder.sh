#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="${MORS_ENTWARE_BUILDER_MANIFEST:-/opt/mors-builder/manifest.env}"
entware_dir="${ENTWARE_DIR:-/opt/entware}"

if [ ! -r "${manifest}" ]; then
	echo "Entware builder manifest is not readable: ${manifest}" >&2
	exit 1
fi

# Compare the complete canonical manifest: missing, unknown, duplicate and stale
# fields all fail closed. Never source an image-provided manifest as shell code.
expected_manifest="$(bash "${repo_root}/scripts/qa/entware-builder-id.sh" --manifest)"
[ "$(cat "${manifest}")" = "${expected_manifest}" ] ||
	{ echo 'Entware builder manifest does not match the checked-out inputs.' >&2; exit 1; }
builder_id="$(sed -n 's/^builder_id=//p' "${manifest}")"
entware_revision="$(sed -n 's/^entware_revision=//p' "${manifest}")"

if [ -n "${MORS_ENTWARE_BUILDER_ID:-}" ] &&
	[ "${MORS_ENTWARE_BUILDER_ID}" != "${builder_id}" ]; then
	echo 'Entware builder environment ID does not match its manifest.' >&2
	exit 1
fi

[ -d "${entware_dir}/.git" ] ||
	{ echo "Entware buildroot is missing: ${entware_dir}" >&2; exit 1; }
actual_entware_revision="$(git -C "${entware_dir}" rev-parse HEAD)"
[ "${actual_entware_revision}" = "${entware_revision}" ] ||
	{ echo 'Entware buildroot HEAD does not match its manifest.' >&2; exit 1; }

host_opkg="$(
	find -L "${entware_dir}/staging_dir/host/bin" \
		-maxdepth 1 -type f -name opkg -print -quit
)"
[ -n "${host_opkg}" ] && [ -x "${host_opkg}" ] ||
	{ echo 'Entware builder has no executable host opkg.' >&2; exit 1; }
for host_tool in bash fakeroot patchelf; do
	[ -x "${entware_dir}/staging_dir/host/bin/${host_tool}" ] ||
		{
			echo "Entware builder has no executable host ${host_tool}." >&2
			exit 1
		}
done

python3 "${repo_root}/scripts/qa/entware-target.py" verify-active
toolchain_name="$(python3 "${repo_root}/scripts/qa/entware-target.py" toolchain)"
staging_name="$(python3 "${repo_root}/scripts/qa/entware-target.py" staging)"
root_name="$(python3 "${repo_root}/scripts/qa/entware-target.py" root)"
mapfile -t toolchain_dirs < <(
	find "${entware_dir}/staging_dir" -maxdepth 1 \( -type d -o -type l \) \
		-name 'toolchain-*' -print
)
[ "${#toolchain_dirs[@]}" -eq 1 ] &&
	[ "$(basename "${toolchain_dirs[0]}")" = "${toolchain_name}" ] ||
	{ echo 'Entware builder has no unique selected toolchain.' >&2; exit 1; }
mapfile -t target_dirs < <(
	find "${entware_dir}/staging_dir" -maxdepth 1 \( -type d -o -type l \) \
		-name 'target-*' -print
)
[ "${#target_dirs[@]}" -eq 1 ] &&
	[ "$(basename "${target_dirs[0]}")" = "${staging_name}" ] ||
	{ echo 'Entware builder has no unique selected target staging tree.' >&2; exit 1; }
mapfile -t root_stamp_dirs < <(
	find "${target_dirs[0]}" -mindepth 2 -maxdepth 2 -type d \
		-path '*/root-*/stamp' -print
)
[ "${#root_stamp_dirs[@]}" -eq 1 ] &&
	[ "${root_stamp_dirs[0]}" = "${target_dirs[0]}/${root_name}/stamp" ] ||
	{ echo 'Entware builder has no unique target root stamp directory.' >&2; exit 1; }

runtime_dependencies="$(
	sed -n 's/^MORS_RUNTIME_DEPENDS:=//p' \
		"${repo_root}/builder/entware/runtime-dependencies.mk"
)"
[ -n "${runtime_dependencies}" ] ||
	{ echo 'Mors runtime dependency set is empty.' >&2; exit 1; }
for dependency_token in ${runtime_dependencies}; do
	case "${dependency_token}" in
		+[a-zA-Z0-9._+-]*) dependency="${dependency_token#+}" ;;
		*)
			echo "Unsupported Mors runtime dependency token: ${dependency_token}" >&2
			exit 1
			;;
	esac
	dependency_stamp="${root_stamp_dirs[0]}/.${dependency}_installed"
	[ -f "${dependency_stamp}" ] && [ ! -L "${dependency_stamp}" ] ||
		{
			echo "Entware builder dependency is not installed: ${dependency}" >&2
			exit 1
		}
done

[ ! -e "${entware_dir}/package/mors" ] && [ ! -L "${entware_dir}/package/mors" ] ||
	{ echo 'Entware builder contains a stale package/mors source.' >&2; exit 1; }
if find "${entware_dir}/bin/targets" -type f \
	-name 'mors_*_all.ipk' -print -quit | grep -q .; then
	echo 'Entware builder contains a stale Mors package artifact.' >&2
	exit 1
fi

python3 "${repo_root}/scripts/qa/entware-rust.py" verify

printf 'Entware builder verified: %s\n' "${builder_id}"
