#!/usr/bin/env bats

setup() {
	REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	FIXTURE_ROOT="${BATS_TEST_TMPDIR}/repo"
	mkdir -p \
		"${FIXTURE_ROOT}/builder/entware" \
		"${FIXTURE_ROOT}/scripts/qa"
	cp "${REPO_ROOT}/rust-toolchain.toml" "${FIXTURE_ROOT}/"
	cp "${REPO_ROOT}/builder/entware/rust-toolchain.json" "${FIXTURE_ROOT}/builder/entware/"
	cp "${REPO_ROOT}/scripts/qa/entware-rust.py" "${FIXTURE_ROOT}/scripts/qa/"
	cp "${REPO_ROOT}/builder/entware/Dockerfile" \
		"${REPO_ROOT}/builder/entware/Dockerfile.dockerignore" \
		"${REPO_ROOT}/builder/entware/runtime-dependencies.mk" \
		"${FIXTURE_ROOT}/builder/entware/"
	cp "${REPO_ROOT}/scripts/qa/entware.lock" \
		"${REPO_ROOT}/scripts/qa/entware-build.sh" \
		"${REPO_ROOT}/scripts/qa/entware-builder-id.sh" \
		"${REPO_ROOT}/scripts/qa/entware-feed-lock.sh" \
		"${REPO_ROOT}/scripts/qa/opkg-version-order.sh" \
		"${REPO_ROOT}/scripts/qa/verify-entware-builder.sh" \
		"${FIXTURE_ROOT}/scripts/qa/"
}

@test "builder ID is deterministic and manifest records locked inputs" {
	local first_id second_id

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	[[ "${output}" =~ ^[0-9a-f]{64}$ ]]
	first_id="${output}"

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	second_id="${output}"
	[ "${second_id}" = "${first_id}" ]

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"schema=entware-builder-v1"* ]]
	[[ "${output}" == *"builder_id=${first_id}"* ]]
	[[ "${output}" == *"target_config=configs/aarch64-3.10.config"* ]]
	[[ "${output}" =~ entware_revision=[0-9a-f]{40} ]]
}

@test "runtime dependency changes create a new builder ID" {
	local original_id changed_id

	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	original_id="${output}"

	printf '\nMORS_RUNTIME_DEPENDS+=+new-runtime\n' \
		>>"${FIXTURE_ROOT}/builder/entware/runtime-dependencies.mk"
	run env ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -eq 0 ]
	changed_id="${output}"

	[ "${changed_id}" != "${original_id}" ]
}

@test "builder verifier requires every canonical runtime dependency" {
	local entware_dir="${BATS_TEST_TMPDIR}/entware"
	local fake_bin="${BATS_TEST_TMPDIR}/bin"
	local manifest="${BATS_TEST_TMPDIR}/manifest.env"
	local builder_id locked_revision target_dir root_stamp_dir

	builder_id="$(
		ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
			bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	)"
	locked_revision="$(
		awk '$1 == "entware" { print $3; exit }' \
			"${FIXTURE_ROOT}/scripts/qa/entware.lock"
	)"
	ENTWARE_BUILDER_REPO_ROOT="${FIXTURE_ROOT}" \
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest \
		>"${manifest}"

	target_dir="${entware_dir}/staging_dir/target-aarch64_fixture"
	root_stamp_dir="${target_dir}/root-aarch64/stamp"
	mkdir -p \
		"${fake_bin}" \
		"${entware_dir}/.git" \
		"${entware_dir}/bin/targets" \
		"${entware_dir}/staging_dir/host/bin" \
		"${entware_dir}/staging_dir/toolchain-aarch64_fixture" \
		"${root_stamp_dir}"
	for host_tool in opkg bash fakeroot patchelf; do
		printf '#!/bin/sh\nexit 0\n' \
			>"${entware_dir}/staging_dir/host/bin/${host_tool}"
		chmod +x "${entware_dir}/staging_dir/host/bin/${host_tool}"
	done
	for dependency_token in $(
		sed -n 's/^MORS_RUNTIME_DEPENDS:=//p' \
			"${FIXTURE_ROOT}/builder/entware/runtime-dependencies.mk"
	); do
		touch "${root_stamp_dir}/.${dependency_token#+}_installed"
	done
	cat >"${fake_bin}/git" <<EOF
#!/bin/sh
printf '%s\n' '${locked_revision}'
EOF
	chmod +x "${fake_bin}/git"
	prepare_rust_fixture

	run env \
		ENTWARE_DIR="${entware_dir}" \
		MORS_ENTWARE_BUILDER_ID="${builder_id}" \
		MORS_ENTWARE_BUILDER_MANIFEST="${manifest}" \
		PATH="${fake_bin}:${PATH}" \
		bash "${FIXTURE_ROOT}/scripts/qa/verify-entware-builder.sh"
	[ "${status}" -eq 0 ]
	[[ "${output}" == *"Entware builder verified: ${builder_id}"* ]]

	rm "${root_stamp_dir}/.xray_installed"
	run env \
		ENTWARE_DIR="${entware_dir}" \
		MORS_ENTWARE_BUILDER_ID="${builder_id}" \
		MORS_ENTWARE_BUILDER_MANIFEST="${manifest}" \
		PATH="${fake_bin}:${PATH}" \
		bash "${FIXTURE_ROOT}/scripts/qa/verify-entware-builder.sh"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *"Entware builder dependency is not installed: xray"* ]]
}

prepare_rust_fixture() {
	local rust_home="${target_dir}/host" tool recipe_dir
	recipe_dir="${entware_dir}/feeds/rustlang/rustc-dev"
	mkdir -p "${rust_home}/bin" "${recipe_dir}" \
		"${entware_dir}/staging_dir/toolchain-aarch64_fixture/bin"
	cat >"${recipe_dir}/Makefile" <<'EOF'
PKG_VERSION:=1.94.0
PKG_HASH:=b83f921cd3f321ff614f9c06a8b870d89299fc02888b48a5549683a36823474c
PRE_COMMIT_HASH:=4a4ef493e3a1488c6e321570238084b38948f6db
EOF
	cat >"${fake_bin}/git" <<EOF
#!/bin/sh
case "\$*" in
  *status*) exit 0 ;;
  *feeds/rustlang*) echo 379fa6ff578506a50e3158b92ac2c09bc22cb450 ;;
  *) echo '${locked_revision}' ;;
esac
EOF
	cat >"${rust_home}/bin/rustc" <<EOF
#!/bin/sh
case "\$*" in
  '-vV') printf '%s\n' 'release: 1.94.0-nightly' 'commit-hash: 4a4ef493e3a1488c6e321570238084b38948f6db' 'host: x86_64-unknown-linux-gnu' 'LLVM version: 21.1.8' ;;
  '--print target-list') echo aarch64-openwrt-linux-gnu ;;
  '--print sysroot') echo '${rust_home}' ;;
  *) exit 1 ;;
esac
EOF
	printf '#!/bin/sh\necho "cargo 1.94.0-nightly (4a4ef493e 2026-03-02)"\n' >"${rust_home}/bin/cargo"
	chmod +x "${rust_home}/bin/"*
	for triple in x86_64-unknown-linux-gnu aarch64-openwrt-linux-gnu; do
		mkdir -p "${rust_home}/lib/rustlib/${triple}/lib"
		printf 'fixture\n' >"${rust_home}/lib/rustlib/${triple}/lib/libstd-fixture.rlib"
		printf 'fixture\n' >"${rust_home}/lib/rustlib/${triple}/lib/libcore-fixture.rlib"
	done
	for tool in gcc g++ ld ar ranlib readelf; do
		cat >"${entware_dir}/staging_dir/toolchain-aarch64_fixture/bin/aarch64-openwrt-linux-gnu-${tool}" <<'EOF'
#!/bin/sh
case "$1" in
  -dumpfullversion) echo 8.4.0 ;;
  -dumpmachine) echo aarch64-openwrt-linux-gnu ;;
  --version) echo fixture ;;
  *) exit 1 ;;
esac
EOF
	done
	chmod +x "${entware_dir}/staging_dir/toolchain-aarch64_fixture/bin/"*
}

@test "Rust toolchain inputs invalidate builder ID but Mors source and version do not" {
	local original input
	original="$(bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh")"
	mkdir -p "${FIXTURE_ROOT}/crates/core/src" "${FIXTURE_ROOT}/opt/bin"
	printf 'changed\n' >"${FIXTURE_ROOT}/crates/core/src/main.rs"
	printf 'changed\n' >"${FIXTURE_ROOT}/opt/bin/mors"
	printf 'PKG_VERSION:=9.9.9\n' >"${FIXTURE_ROOT}/Makefile"
	[ "$(bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh")" = "${original}" ]
	for input in rust-toolchain.toml builder/entware/rust-toolchain.json scripts/qa/entware-rust.py \
		scripts/qa/verify-entware-builder.sh; do
		cp "${FIXTURE_ROOT}/${input}" "${BATS_TEST_TMPDIR}/saved"
		printf '\n' >>"${FIXTURE_ROOT}/${input}"
		[ "$(bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh")" != "${original}" ]
		cp "${BATS_TEST_TMPDIR}/saved" "${FIXTURE_ROOT}/${input}"
	done
}

@test "Rust verifier rejects missing and mismatched compiler target and feed fixtures" {
	local entware_dir="${BATS_TEST_TMPDIR}/entware" fake_bin="${BATS_TEST_TMPDIR}/bin"
	local target_dir="${entware_dir}/staging_dir/target-aarch64_fixture" locked_revision=unused
	local rust_home="${target_dir}/host" mutation
	mkdir -p "${fake_bin}"
	for mutation in valid compiler cargo target_std empty_std target_tool target_version feed recipe dirty_feed wrong_sysroot missing_target; do
		prepare_rust_fixture
		chmod +x "${fake_bin}/git"
		case "${mutation}" in
			compiler) sed -i 's/1.94.0-nightly/1.93.0-nightly/' "${rust_home}/bin/rustc" ;;
			cargo) rm "${rust_home}/bin/cargo" ;;
			target_std) rm "${rust_home}/lib/rustlib/aarch64-openwrt-linux-gnu/lib/libstd-fixture.rlib" ;;
			empty_std) : >"${rust_home}/lib/rustlib/aarch64-openwrt-linux-gnu/lib/libstd-fixture.rlib" ;;
			target_tool) rm "${entware_dir}/staging_dir/toolchain-aarch64_fixture/bin/aarch64-openwrt-linux-gnu-ar" ;;
			target_version) sed -i 's/8.4.0/9.0.0/' "${entware_dir}/staging_dir/toolchain-aarch64_fixture/bin/aarch64-openwrt-linux-gnu-gcc" ;;
			feed) sed -i 's/379fa6ff578506a50e3158b92ac2c09bc22cb450/stale/' "${fake_bin}/git" ;;
			recipe) printf 'PKG_VERSION:=latest\n' >"${entware_dir}/feeds/rustlang/rustc-dev/Makefile" ;;
			dirty_feed) sed -i 's/exit 0/echo modified; exit 0/' "${fake_bin}/git" ;;
			wrong_sysroot) sed -i "s|echo '${rust_home}'|echo /unattested|" "${rust_home}/bin/rustc" ;;
			missing_target) sed -i 's/echo aarch64-openwrt-linux-gnu/echo aarch64-unknown-linux-gnu/' "${rust_home}/bin/rustc" ;;
		esac
		run env ENTWARE_DIR="${entware_dir}" PATH="${fake_bin}:${PATH}" \
			python3 "${FIXTURE_ROOT}/scripts/qa/entware-rust.py" verify
		if [ "${mutation}" = valid ]; then
			[ "${status}" -eq 0 ]
		else
			[ "${status}" -ne 0 ]
			[[ "${output}" == *"Entware Rust:"* ]]
		fi
	done
}

@test "Rust builder invokes only pinned feed host and target builds then attests tools" {
	local entware_dir="${BATS_TEST_TMPDIR}/entware" fake_bin="${BATS_TEST_TMPDIR}/bin"
	local target_dir="${entware_dir}/staging_dir/target-aarch64_fixture" locked_revision=unused
	mkdir -p "${fake_bin}"
	prepare_rust_fixture
	cat >"${fake_bin}/make" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'${BATS_TEST_TMPDIR}/make.log'
EOF
	chmod +x "${fake_bin}/make" "${fake_bin}/git"
	run env ENTWARE_DIR="${entware_dir}" PATH="${fake_bin}:${PATH}" JOBS=2 \
		python3 "${FIXTURE_ROOT}/scripts/qa/entware-rust.py" build
	[ "${status}" -eq 0 ]
	[ "$(cat "${BATS_TEST_TMPDIR}/make.log")" = "$(printf '%s\n' \
		'-j2 package/feeds/rustlang/rustc-dev/host/compile V=s' \
		'-j2 package/feeds/rustlang/rustc-dev/compile V=s')" ]
}

@test "builder refuses missing Rust inputs and host toolchain drift" {
	sed -i 's/1.94.0/1.93.0/' "${FIXTURE_ROOT}/rust-toolchain.toml"
	run bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest
	[ "${status}" -ne 0 ]
	[[ "${output}" == *'Host and Entware Rust source versions differ'* ]]
	rm "${FIXTURE_ROOT}/builder/entware/rust-toolchain.json"
	run bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh"
	[ "${status}" -ne 0 ]
	[[ "${output}" == *'input is not readable'* ]]
}

@test "builder rejects missing duplicate and stale Rust manifest inputs before inspecting tools" {
	local manifest="${BATS_TEST_TMPDIR}/manifest.env" mutation
	for mutation in missing duplicate stale; do
		bash "${FIXTURE_ROOT}/scripts/qa/entware-builder-id.sh" --manifest >"${manifest}"
		case "${mutation}" in
			missing) sed -i '/^rust_target=/d' "${manifest}" ;;
			duplicate) printf 'rust_target=aarch64-openwrt-linux-gnu\n' >>"${manifest}" ;;
			stale) sed -i 's/^rust_release=.*/rust_release=1.93.0-nightly/' "${manifest}" ;;
		esac
		run env MORS_ENTWARE_BUILDER_MANIFEST="${manifest}" \
			bash "${FIXTURE_ROOT}/scripts/qa/verify-entware-builder.sh"
		[ "${status}" -ne 0 ]
		[[ "${output}" == *'manifest does not match'* ]]
	done
}
