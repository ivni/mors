#!/usr/bin/env bash
set -euo pipefail

artifact_dir="${1:?Usage: verify-release-artifact.sh ARTIFACT_DIR VERSION OUTPUT_DIR [GITHUB_OUTPUT]}"
expected_version="${2:?Usage: verify-release-artifact.sh ARTIFACT_DIR VERSION OUTPUT_DIR [GITHUB_OUTPUT]}"
output_dir="${3:?Usage: verify-release-artifact.sh ARTIFACT_DIR VERSION OUTPUT_DIR [GITHUB_OUTPUT]}"
github_output="${4:-}"

case "${expected_version}" in
	*[!0-9A-Za-z.~+_-]*)
		echo "Unsafe package version: ${expected_version}" >&2
		exit 1
		;;
esac

mapfile -t packages < <(find "${artifact_dir}" -maxdepth 1 -type f -name 'mors_*_all.ipk' -print)
if [ "${#packages[@]}" -ne 1 ]; then
	echo "Expected exactly one Mors .ipk in ${artifact_dir}, found ${#packages[@]}." >&2
	exit 1
fi

package_path="${packages[0]}"
expected_name="mors_${expected_version}_all.ipk"
if [ "$(basename "${package_path}")" != "${expected_name}" ]; then
	echo "Unexpected package name: $(basename "${package_path}")" >&2
	echo "Expected: ${expected_name}" >&2
	exit 1
fi

tmp_dir="$(mktemp -d)"
cleanup() {
	[ ! -d "${tmp_dir}" ] || rm -r -- "${tmp_dir}"
}
trap cleanup EXIT

tar -xzf "${package_path}" -C "${tmp_dir}" \
	./debian-binary ./control.tar.gz ./data.tar.gz

if [ "$(tr -d '\r\n' <"${tmp_dir}/debian-binary")" != '2.0' ]; then
	echo 'Invalid debian-binary marker in release package.' >&2
	exit 1
fi

control="$(tar -xOf "${tmp_dir}/control.tar.gz" ./control)"
control_field() {
	printf '%s\n' "${control}" | sed -n "s/^${1}: //p; /^${1}: /q"
}

if [ "$(control_field Package)" != mors ]; then
	echo 'Release package control metadata has an unexpected Package field.' >&2
	exit 1
fi
if [ "$(control_field Version)" != "${expected_version}" ]; then
	echo 'Release package control metadata has an unexpected Version field.' >&2
	exit 1
fi
if [ "$(control_field Architecture)" != all ]; then
	echo 'Release package control metadata has an unexpected Architecture field.' >&2
	exit 1
fi

data_members="$(tar -tzf "${tmp_dir}/data.tar.gz")"
for required_member in \
	./opt/apps/mors/bin/mors \
	./opt/apps/mors/bin/libs/main \
	./opt/apps/mors/bin/libs/interaction \
	./opt/apps/mors/bin/libs/test \
	./opt/apps/mors/bin/libs/telemetry \
	./opt/apps/mors/bin/libs/telemetry_runtime \
	./opt/apps/mors/bin/libs/telemetry_store \
	./opt/apps/mors/bin/libs/telemetry_otlp \
	./opt/apps/mors/bin/libs/telemetry_process \
	./opt/apps/mors/bin/libs/telemetry_upgrade \
	./opt/apps/mors/bin/libs/upgrade_artifact \
	./opt/apps/mors/bin/main/telemetry-sender \
	./opt/apps/mors/etc/init.d/S98mors-telemetry; do
	if ! printf '%s\n' "${data_members}" | grep -Fxq "${required_member}"; then
		echo "Release package is missing ${required_member}." >&2
		exit 1
	fi
done

mkdir -p "${output_dir}"
asset_name="${expected_name//\~/.}"
asset_path="${output_dir}/${asset_name}"
cp -- "${package_path}" "${asset_path}"

sha256="$(sha256sum "${asset_path}" | awk '{ print toupper($1) }')"
size="$(stat -c '%s' "${asset_path}")"

printf 'Verified release package: %s\n' "${asset_name}"
printf 'Control version: %s\n' "${expected_version}"
printf 'SHA-256: %s\n' "${sha256}"

if [ -n "${github_output}" ]; then
	{
		printf 'asset_name=%s\n' "${asset_name}"
		printf 'asset_path=%s\n' "${asset_path}"
		printf 'control_version=%s\n' "${expected_version}"
		printf 'sha256=%s\n' "${sha256}"
		printf 'size=%s\n' "${size}"
	} >>"${github_output}"
fi
