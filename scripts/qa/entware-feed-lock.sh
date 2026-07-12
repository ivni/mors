#!/usr/bin/env bash
set -euo pipefail

mode=${1:-}
lock_file=${2:-}
entware_dir=${3:-}

if [ "${mode}" != sync-existing ] && [ "${mode}" != verify ]; then
	echo 'Usage: entware-feed-lock.sh sync-existing|verify LOCK_FILE ENTWARE_DIR' >&2
	exit 2
fi
if [ ! -r "${lock_file}" ] || [ ! -d "${entware_dir}" ]; then
	echo 'Entware feed lock requires a readable lock and an existing buildroot.' >&2
	exit 2
fi

while read -r feed_name feed_repo feed_revision feed_extra; do
	case "${feed_name}" in
		''|'#'*|entware) continue ;;
	esac
	if [ -n "${feed_extra}" ] ||
		[[ ! "${feed_name}" =~ ^[a-z][a-z0-9_-]*$ ]] ||
		[[ ! "${feed_revision}" =~ ^[0-9a-f]{40}$ ]]; then
		echo "Invalid Entware feed lock entry: ${feed_name}" >&2
		exit 1
	fi

	feed_dir="${entware_dir}/feeds/${feed_name}"
	if [ "${mode}" = sync-existing ] && [ ! -d "${feed_dir}/.git" ]; then
		continue
	fi
	if [ ! -d "${feed_dir}/.git" ]; then
		echo "Locked Entware feed is missing: ${feed_name}" >&2
		exit 1
	fi
	if [ -n "$(git -C "${feed_dir}" status --porcelain --untracked-files=all)" ]; then
		echo "Locked Entware feed has local changes: ${feed_name}" >&2
		exit 1
	fi

	actual_revision="$(git -C "${feed_dir}" rev-parse HEAD)"
	if [ "${mode}" = sync-existing ] && [ "${actual_revision}" != "${feed_revision}" ]; then
		git -C "${feed_dir}" remote set-url origin "${feed_repo}"
		git -C "${feed_dir}" fetch --depth=1 origin "${feed_revision}"
		git -C "${feed_dir}" -c advice.detachedHead=false checkout --detach "${feed_revision}"
		actual_revision="$(git -C "${feed_dir}" rev-parse HEAD)"
	fi
	if [ "${actual_revision}" != "${feed_revision}" ]; then
		echo "Entware feed revision mismatch: ${feed_name}: ${actual_revision}, expected ${feed_revision}" >&2
		exit 1
	fi
	printf 'Entware feed %s: %s\n' "${feed_name}" "${actual_revision}"
done <"${lock_file}"
