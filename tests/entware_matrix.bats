#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
}

@test "core ELF gate rejects wrong class endian machine MIPS ABI and interpreter" {
	run python3 "${REPO_ROOT}/tests/entware_core_test.py"
	[ "${status}" -eq 0 ]
}

@test "platform candidate gate rejects wrong metadata unsafe archives residue and active hooks" {
	run python3 "${REPO_ROOT}/tests/platform_package_test.py"
	[ "${status}" -eq 0 ]
}

@test "NaiveProxy supply gates require pinned CA static ABI and matching complete notices" {
	run python3 "${REPO_ROOT}/tests/naiveproxy_packaging_test.py"
	[ "${status}" -eq 0 ]
}

@test "package rejects an unknown mode before touching the builder" {
	run env MORS_PACKAGE_MODE=unknown bash "${REPO_ROOT}/scripts/qa/entware-builder-package.sh"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Unsupported Mors package mode"* ]]
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
	git -C "${fixture}" init -q
	git -C "${fixture}" add .
	env GIT_AUTHOR_DATE=2000-01-01T00:00:00Z GIT_COMMITTER_DATE=2000-01-01T00:00:00Z \
		git -C "${fixture}" -c user.name='Mors QA' -c user.email=qa@example.invalid \
		-c commit.gpgsign=false commit -q -m fixture
	for abi in aarch64-3.10 mips-3.4 mipsel-3.4; do
		run env MORS_ENTWARE_TARGET="${abi}" ENTWARE_DIR="${entware_dir}" \
			SOURCE_DATE_EPOCH=1700000000 \
			MAKE_LOG="${BATS_TEST_TMPDIR}/${abi}.log" PATH="${fake_bin}:${PATH}" \
			bash "${fixture}/scripts/qa/entware-builder-package.sh"
		[ "${status}" -eq 0 ]
		[ "$(head -1 "${BATS_TEST_TMPDIR}/${abi}.log")" = verified ]
		[ "$(wc -l <"${BATS_TEST_TMPDIR}/${abi}.log")" -eq 4 ]
		[ "$(grep -c -- '-C package/mors' "${BATS_TEST_TMPDIR}/${abi}.log")" -eq 3 ]
		[ "$(grep -c 'SOURCE=package/mors' "${BATS_TEST_TMPDIR}/${abi}.log")" -eq 3 ]
		[ "$(grep -c 'PKG_SOURCE_DATE_EPOCH=1700000000 SOURCE_DATE_EPOCH=1700000000' "${BATS_TEST_TMPDIR}/${abi}.log")" -eq 3 ]
		[ -f "${fixture}/packages/mors_1.0.0-1_all.ipk" ]
		[ ! -L "${entware_dir}/package/mors" ]
		[ -z "$(find "${entware_dir}" -maxdepth 1 -name '.mors-package-source.*' -print)" ]
	done
	# Git models the runner/container ownership mismatch without requiring root.
	run env -u SOURCE_DATE_EPOCH GIT_TEST_ASSUME_DIFFERENT_OWNER=1 \
		MORS_ENTWARE_TARGET=aarch64-3.10 ENTWARE_DIR="${entware_dir}" \
		MAKE_LOG="${BATS_TEST_TMPDIR}/git-epoch.log" PATH="${fake_bin}:${PATH}" \
		bash "${fixture}/scripts/qa/entware-builder-package.sh"
	[ "${status}" -eq 0 ]
	[ "$(grep -c 'PKG_SOURCE_DATE_EPOCH=946684800 SOURCE_DATE_EPOCH=946684800' "${BATS_TEST_TMPDIR}/git-epoch.log")" -eq 3 ]
}

@test "package rejects an invalid source epoch before touching the builder" {
	run env SOURCE_DATE_EPOCH=invalid bash "${REPO_ROOT}/scripts/qa/entware-builder-package.sh"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *"numeric SOURCE_DATE_EPOCH"* ]]
}

@test "platform submake stages only the verified core and isolates candidate outputs" {
	local fixture="${BATS_TEST_TMPDIR}/repo" fake_bin="${BATS_TEST_TMPDIR}/bin"
	local entware_dir="${BATS_TEST_TMPDIR}/entware"
	mkdir -p "${fixture}/scripts/qa" "${fixture}/builder/entware" "${fixture}/opt" \
		"${entware_dir}/package" "${entware_dir}/bin/targets" "${fake_bin}"
	cp "${REPO_ROOT}/scripts/qa/entware-builder-package.sh" "${fixture}/scripts/qa/"
	cp "${REPO_ROOT}/scripts/qa/entware-target.py" "${fixture}/scripts/qa/"
	cp "${REPO_ROOT}/builder/entware/targets.json" "${fixture}/builder/entware/"
	cp "${REPO_ROOT}/builder/entware/runtime-dependencies.mk" "${fixture}/builder/entware/"
	printf 'PKG_VERSION:=1.0.0\nPKG_RELEASE:=1\n' >"${fixture}/Makefile"
	printf '#!/bin/sh\necho builder >>"$MAKE_LOG"\n' >"${fixture}/scripts/qa/verify-entware-builder.sh"
	cat >"${fixture}/scripts/qa/entware-core-build.py" <<'EOF'
import os
from pathlib import Path
root = Path(__file__).resolve().parents[2]
output = root / "packages/core" / os.environ["MORS_ENTWARE_TARGET"]
output.mkdir(parents=True)
(output / "mors-core").write_text("verified fixture ELF")
with open(os.environ["MAKE_LOG"], "a") as log:
    log.write("core\n")
EOF
	cat >"${fixture}/scripts/qa/entware-platform-package.py" <<'EOF'
import os
import sys
from pathlib import Path
if sys.argv[1] == "verify":
    assert Path(sys.argv[2]).is_file()
with open(os.environ["MAKE_LOG"], "a") as log:
    log.write(sys.argv[1] + "\n")
EOF
	cat >"${fake_bin}/make" <<'EOF'
#!/bin/sh
case "$*" in
  *MORS_CORE_PACKAGE=1*) ;;
  *) exit 98 ;;
esac
test "$(cat package/mors/core/mors-core)" = 'verified fixture ELF' || exit 97
test ! -e package/mors/Cargo.toml || exit 96
printf 'make\n' >>"$MAKE_LOG"
case "$*" in
  *compile*) touch "bin/targets/mors_1.0.0-1_${MORS_ENTWARE_TARGET}.ipk" ;;
esac
EOF
	chmod +x "${fake_bin}/make"
	run env MORS_PACKAGE_MODE=platform MORS_ENTWARE_TARGET=mipsel-3.4 \
		ENTWARE_DIR="${entware_dir}" SOURCE_DATE_EPOCH=1700000000 \
		MAKE_LOG="${BATS_TEST_TMPDIR}/platform.log" PATH="${fake_bin}:${PATH}" \
		bash "${fixture}/scripts/qa/entware-builder-package.sh"
	[ "${status}" -eq 0 ]
	[ "$(cat "${BATS_TEST_TMPDIR}/platform.log")" = $'builder\ncore\ninputs\nmake\nmake\nmake\nverify' ]
	[ -f "${fixture}/packages/platform/mipsel-3.4/mors_1.0.0-1_mipsel-3.4.ipk" ]
	[ ! -e "${fixture}/packages/mors_1.0.0-1_all.ipk" ]
	[ ! -L "${entware_dir}/package/mors" ]
}
