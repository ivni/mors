#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="${MORS_ENTWARE_BUILDER_MANIFEST:-/opt/mors-builder/manifest.env}"
entware_dir="${ENTWARE_DIR:-/opt/entware}"

if [ ! -r "${manifest}" ]; then
	echo "Entware builder manifest is not readable: ${manifest}" >&2
	exit 1
fi

schema=''
builder_id=''
entware_lock_sha256=''
runtime_dependencies_sha256=''
entware_revision=''
target_config=''
while IFS='=' read -r key value; do
	case "${key}" in
		schema) schema="${value}" ;;
		builder_id) builder_id="${value}" ;;
		entware_lock_sha256) entware_lock_sha256="${value}" ;;
		runtime_dependencies_sha256) runtime_dependencies_sha256="${value}" ;;
		entware_revision) entware_revision="${value}" ;;
		target_config) target_config="${value}" ;;
		*)
			echo "Unknown Entware builder manifest key: ${key}" >&2
			exit 1
			;;
	esac
done <"${manifest}"

expected_builder_id="$(bash "${repo_root}/scripts/qa/entware-builder-id.sh")"
expected_lock_sha256="$(
	sha256sum "${repo_root}/scripts/qa/entware.lock" | awk '{ print $1 }'
)"
expected_dependencies_sha256="$(
	sha256sum "${repo_root}/builder/entware/runtime-dependencies.mk" |
		awk '{ print $1 }'
)"
expected_entware_revision="$(
	awk '$1 == "entware" { print $3; exit }' \
		"${repo_root}/scripts/qa/entware.lock"
)"

[ "${schema}" = entware-builder-v1 ] ||
	{ echo "Unsupported Entware builder schema: ${schema}" >&2; exit 1; }
[ "${builder_id}" = "${expected_builder_id}" ] ||
	{ echo 'Entware builder ID does not match the checked-out inputs.' >&2; exit 1; }
[ "${entware_lock_sha256}" = "${expected_lock_sha256}" ] ||
	{ echo 'Entware builder lock digest does not match.' >&2; exit 1; }
[ "${runtime_dependencies_sha256}" = "${expected_dependencies_sha256}" ] ||
	{ echo 'Entware builder dependency digest does not match.' >&2; exit 1; }
[ "${entware_revision}" = "${expected_entware_revision}" ] ||
	{ echo 'Entware builder revision does not match the lock.' >&2; exit 1; }
[ "${target_config}" = configs/aarch64-3.10.config ] ||
	{ echo "Unexpected Entware builder target: ${target_config}" >&2; exit 1; }

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

mapfile -t toolchain_dirs < <(
	find "${entware_dir}/staging_dir" -maxdepth 1 -type d \
		-name 'toolchain-aarch64*' -print
)
[ "${#toolchain_dirs[@]}" -eq 1 ] ||
	{ echo 'Entware builder has no aarch64 toolchain.' >&2; exit 1; }
mapfile -t target_dirs < <(
	find "${entware_dir}/staging_dir" -maxdepth 1 -type d \
		-name 'target-aarch64*' -print
)
[ "${#target_dirs[@]}" -eq 1 ] ||
	{ echo 'Entware builder has no unique aarch64 target staging tree.' >&2; exit 1; }
mapfile -t root_stamp_dirs < <(
	find "${target_dirs[0]}" -mindepth 2 -maxdepth 2 -type d \
		-path '*/root-*/stamp' -print
)
[ "${#root_stamp_dirs[@]}" -eq 1 ] ||
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

[ ! -e "${entware_dir}/package/mors" ] ||
	{ echo 'Entware builder contains a stale package/mors source.' >&2; exit 1; }
if find "${entware_dir}/bin/targets" -type f \
	-name 'mors_*_all.ipk' -print -quit | grep -q .; then
	echo 'Entware builder contains a stale Mors package artifact.' >&2
	exit 1
fi

printf 'Entware builder verified: %s\n' "${builder_id}"
