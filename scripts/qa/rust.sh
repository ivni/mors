#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"
# Explicit selection wins over environment and local rustup directory overrides.
toolchain="$(sed -n 's/^channel = "\([^"]*\)"$/\1/p' rust-toolchain.toml)"
if [ -z "${toolchain}" ]; then
	echo "Missing pinned host toolchain in rust-toolchain.toml" >&2
	exit 1
fi
cargo "+${toolchain}" fmt --all -- --check
cargo "+${toolchain}" clippy --workspace --all-targets --frozen -- -D warnings
cargo "+${toolchain}" test --workspace --all-targets --frozen
cargo "+${toolchain}" test --workspace --doc --frozen
cargo "+${toolchain}" build --workspace --release --frozen
