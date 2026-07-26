#!/usr/bin/env bash
set -euo pipefail

repo_root="${ENTWARE_BUILDER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
schema='entware-builder-v1'
target_config='configs/aarch64-3.10.config'
input_files=(
	builder/entware/Dockerfile
	builder/entware/Dockerfile.dockerignore
	builder/entware/runtime-dependencies.mk
	scripts/qa/entware.lock
	scripts/qa/entware-build.sh
	scripts/qa/entware-feed-lock.sh
	scripts/qa/opkg-version-order.sh
)

cd "${repo_root}"
for input_file in "${input_files[@]}"; do
	if [ ! -r "${input_file}" ]; then
		echo "Entware builder input is not readable: ${input_file}" >&2
		exit 1
	fi
done

builder_id="$(
	{
		printf 'schema=%s\n' "${schema}"
		printf 'target_config=%s\n' "${target_config}"
		sha256sum "${input_files[@]}"
	} | sha256sum | awk '{ print $1 }'
)"

case "${1:-}" in
	'')
		printf '%s\n' "${builder_id}"
		;;
	--manifest)
		entware_revision="$(
			awk '$1 == "entware" { print $3; exit }' scripts/qa/entware.lock
		)"
		if [[ ! "${entware_revision}" =~ ^[0-9a-f]{40}$ ]]; then
			echo 'Entware builder lock has no valid buildroot revision.' >&2
			exit 1
		fi
		printf 'schema=%s\n' "${schema}"
		printf 'builder_id=%s\n' "${builder_id}"
		printf 'entware_lock_sha256=%s\n' "$(
			sha256sum scripts/qa/entware.lock | awk '{ print $1 }'
		)"
		printf 'runtime_dependencies_sha256=%s\n' "$(
			sha256sum builder/entware/runtime-dependencies.mk | awk '{ print $1 }'
		)"
		printf 'entware_revision=%s\n' "${entware_revision}"
		printf 'target_config=%s\n' "${target_config}"
		;;
	*)
		echo 'Usage: entware-builder-id.sh [--manifest]' >&2
		exit 2
		;;
esac
