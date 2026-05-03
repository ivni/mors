#!/usr/bin/env bash
set -euo pipefail

git ls-files --cached --others --exclude-standard | while IFS= read -r file; do
	case "${file}" in
		builder/builder|\
		opt/bin/mors|\
		opt/bin/libs/*|\
		opt/bin/main/*|\
		opt/etc/init.d/*|\
		opt/etc/ndm/*|\
		opt/etc/ndm/*/*|\
		scripts/qa/*.sh)
			[ -f "${file}" ] && printf '%s\n' "${file}"
			;;
	esac
done
