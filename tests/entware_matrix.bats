#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "core ELF gate rejects wrong class endian machine MIPS ABI and interpreter" {
	run python3 "${REPO_ROOT}/tests/entware_core_test.py"
	[ "${status}" -eq 0 ]
}

@test "direct package submake stays package-only for every ABI" {
	local fixture="${BATS_TEST_TMPDIR}/repo" fake_bin="${BATS_TEST_TMPDIR}/bin"
	local entware_dir="${BATS_TEST_TMPDIR}/entware" abi
	mkdir -p "${fixture}/scripts/qa" "${fixture}/builder/entware" "${fixture}/opt" \
		"${entware_dir}/package" "${entware_dir}/bin/targets" "${fake_bin}"
	cp "${REPO_ROOT}/scripts/qa/entware-builder-package.sh" "${fixture}/scripts/qa/"
	cp "${REPO_ROOT}/builder/entware/runtime-dependencies.mk" "${fixture}/builder/entware/"
	printf 'PKG_VERSION:=1.0.0\nPKG_RELEASE:=1\n' >"${fixture}/Makefile"
	# This test observes dispatch, source cleanup and artifact cardinality only.
	printf '#!/bin/sh\necho verified >>"$MAKE_LOG"\n' >"${fixture}/scripts/qa/verify-entware-builder.sh"
	cat >"${fake_bin}/make" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MAKE_LOG"
case "$*" in
  '-w -r -C package/mors '*compile*) touch bin/targets/mors_1.0.0-1_all.ipk ;;
  '-w -r -C package/mors '*clean*) ;;
  *) exit 99 ;;
esac
EOF
	chmod +x "${fake_bin}/make"
	for abi in aarch64-3.10 mips-3.4 mipsel-3.4; do
		run env MORS_ENTWARE_TARGET="${abi}" ENTWARE_DIR="${entware_dir}" \
			MAKE_LOG="${BATS_TEST_TMPDIR}/${abi}.log" PATH="${fake_bin}:${PATH}" \
			bash "${fixture}/scripts/qa/entware-builder-package.sh"
		[ "${status}" -eq 0 ]
		[ "$(head -1 "${BATS_TEST_TMPDIR}/${abi}.log")" = verified ]
		[ "$(wc -l <"${BATS_TEST_TMPDIR}/${abi}.log")" -eq 4 ]
		[ "$(grep -c -- '-C package/mors' "${BATS_TEST_TMPDIR}/${abi}.log")" -eq 3 ]
		[ "$(grep -c 'SOURCE=package/mors' "${BATS_TEST_TMPDIR}/${abi}.log")" -eq 3 ]
		[ -f "${fixture}/packages/mors_1.0.0-1_all.ipk" ]
		[ ! -L "${entware_dir}/package/mors" ]
		[ -z "$(find "${entware_dir}" -maxdepth 1 -name '.mors-package-source.*' -print)" ]
	done
}
