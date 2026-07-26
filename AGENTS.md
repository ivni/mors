# AGENTS.md

## Project Overview

Mors is a direct rename and fork of the Kvas package. The active package and CLI name is now `mors`; the old `kvas` command, package name, runtime paths, and hooks are not kept as compatibility aliases. The package is an Entware package for Keenetic routers. It provides a Russian-language CLI for routing selected domains, IPs, and networks through VPN, Shadowsocks, or VLESS, while coordinating `ipset`, `iptables`, DNSMasq, DNSCrypt, AdGuard Home, ad blocking, and Keenetic NDM event hooks.

The active project repository is `ivni/mors`. This codebase began as a fork of Kvas, so historical changelog entries, license attribution, old release artifacts, and historical references may still mention the old upstream project. New runtime behavior, user-facing commands, install/setup instructions, release sources, and diagnostics should target Mors.

Primary project references:

- Repository: `https://github.com/ivni/mors`
- Local Git remote should normally point at `ivni/mors`.

Local test infrastructure:

- If present, read [`TEST_INFRASTRUCTURE.local.md`](TEST_INFRASTRUCTURE.local.md) before connecting to or mutating the disposable router. This machine-local file is intentionally ignored by Git and must not contain passwords or private keys.

Normative design and architecture references:

- `docs/cli-design-system.md` - required CLI terminology, state vocabulary, interaction, error, JSON, and safety contracts.
- `docs/vless-architecture.md` - source-of-truth boundaries, VLESS storage, health state machine, supervisor, failover, and release gates.

Historical upstream references:

- Original repository: `https://github.com/qzeleza/kvas`
- Original wiki: `https://github.com/qzeleza/kvas/wiki`

Use the original Kvas repository and wiki only as historical/reference material when changing install/setup flow, CLI semantics, diagnostics, or user documentation. They contain operational guidance that is not fully captured in the source tree, but new work should target Mors.

## Repository Layout

- `README.md`, `HISTORY.md`, `LICENCE.md` - user documentation, changelog, and license.
- `Makefile` - Entware/OpenWrt package recipe. It declares package metadata/dependencies, installs selected NDM/init hooks, and copies `opt/.` into `/opt/apps/mors`.
- `builder/entware/` - inputs for the canonical immutable Entware builder image:
  - `Dockerfile` builds the locked Entware buildroot, host tools, aarch64 toolchain, target staging tree, and all canonical Mors runtime dependencies.
  - `Dockerfile.dockerignore` is the allowlist-only BuildKit context contract; do not broaden it to include the repository, `.git`, test infrastructure, or package artifacts.
  - `runtime-dependencies.mk` is the single dependency list shared by the package recipe, builder, and verifier.
- `builder/Dockerfile`, `builder/builder`, and `builder/Jenkinsfile` are legacy Docker/Jenkins helpers; they are not the release build path.
- `opt/bin/mors` - main CLI entrypoint. It sources libraries from `/opt/apps/mors/bin/libs` and dispatches commands.
- `opt/bin/libs/` - shared shell libraries:
  - `main` contains global paths, config helpers, output/log helpers, router API helpers, and low-level utilities.
  - `vpn` contains most runtime orchestration: init/reset, VPN/SSR/VLESS switching, DNSMasq/DNSCrypt/AdGuard Home setup, host list operations, and route updates.
  - `xray` contains Xray version parsing and the supported/tested compatibility policy for VLESS Reality.
  - `ndm` contains NDM/netfilter and `iptables`/`ipset` helpers for Keenetic hooks.
  - `check`, `debug`, `route`, `tags`, `hosts`, `adblock`, `vless`, `keen_api`, `ndm_d`, `update` provide focused feature areas.
- `opt/bin/main/` - standalone helper scripts invoked by the CLI and services, such as `adblock`, `adguard`, `dnsmasq`, `ipset`, `setup`, `update`, and `upgrade`.
- `opt/etc/conf/` - default config/templates copied or referenced at install time (`mors.conf`, `mors.list`, `dnsmasq.conf`, `shadowsocks.json`, `mors.vless`, `tags.list`, etc.).
- `opt/etc/init.d/` - Entware init scripts for Mors and optional services.
- `opt/etc/ndm/` - Keenetic NDM hooks for filesystem startup, interface lifecycle, netfilter refreshes, and WAN events.
- `tests/` - router-independent BATS tests for CLI/help contracts and focused library behavior.
- `scripts/qa/` - local/CI validation helpers for static checks, package layout, Entware builds, Xray compatibility, and guarded router smoke tests.
- `.github/workflows/` - GitHub Actions workflows: `qa.yml` runs reusable static/BATS/Xray checks, `package.yml` builds reusable release-candidate artifacts, `release.yml` gates tag/release creation on both workflows for the same SHA, and `router-smoke.yml` is a manually confirmed test-router workflow.
- `ipk/` - prebuilt package artifacts. It may still contain historical `kvas_*` packages; do not treat them as current Mors releases and do not change them unless intentionally adding/replacing release artifacts.
- `logs/` - captured build logs. Update only when recording a real build.

## GitHub Workflow

- Use GitHub CLI (`gh`) for GitHub operations when it is available and authenticated. Prefer it for inspecting issues, pull requests, releases, forks, and repository metadata instead of hand-assembling API calls.
- Default to `ivni/mors` for active development, issues, PRs, releases, and repository metadata. Use `qzeleza/kvas` only when explicitly comparing against historical upstream behavior.
- Write Git and release-facing text in Russian: commit subjects and bodies, annotated tag messages, release titles, and release notes. Keep technical identifiers, commands, paths, and upstream names unchanged where translation would make them inaccurate.
- Write release notes for users and lead with impact: explain what became better, safer, or easier, what observable behavior changed, and whether the user must take any action. Do not turn release notes into a low-level implementation log; deep technical details belong in commits and technical documentation. Include commands, identifiers, digests, or other technical evidence only when users need them for a safe upgrade or verification, and keep that evidence separate from the user-facing narrative.
- Phrase commit subjects as completed results: use Russian forms such as `Добавлено ...`, `Исправлено ...`, `Обновлено ...`, or `Удалено ...`. Do not use imperative or infinitive subjects such as `Добавить ...`, `Исправить ...`, or `Игнорировать ...`.
- Useful commands:
  - `gh auth status`
  - `gh repo view ivni/mors --web`
  - `gh issue list --repo ivni/mors`
  - `gh issue view <number> --repo ivni/mors`
  - `gh pr list --repo ivni/mors`
  - `gh release list --repo ivni/mors`
  - `gh release view --repo ivni/mors`
  - `gh repo view qzeleza/kvas --web` when checking the old upstream
- GitHub wiki pages are backed by a Git repository. If Mors gets its own wiki, inspect `https://github.com/ivni/mors.wiki.git`; for historical Kvas documentation, inspect `https://github.com/qzeleza/kvas.wiki.git`.
- Do not create issues, comments, releases, tags, or PRs unless the user explicitly asks for that remote mutation.
- Publish releases only through `.github/workflows/release.yml` on the intended commit. Do not create or push a release tag before the reusable `qa.yml` and `package.yml` gates succeed for that exact SHA.
- Treat every pushed release tag as immutable. Never move, overwrite, or silently reuse a failed tag; prepare a new version candidate instead.
- Use `package.yml` with `workflow_dispatch` when only a candidate `.ipk` is needed. A pushed tag is not a package-build trigger and is not a substitute for the release workflow.
- Before reporting a release complete, verify the GitHub Release is not a draft, has the intended prerelease/latest state, points to the gated SHA, and exposes exactly one checked `.ipk` whose digest matches the workflow output.

### Versioning Contract

- Entware package versions and GitHub tags are different representations and must be mapped explicitly; never derive a release tag with a blind `~` to `-` substitution.
- Entware prerelease packages use opkg ordering, for example `PKG_VERSION:=1.4.0~beta1`, while the matching SemVer GitHub tag is `v1.4.0-beta.1`. The dot makes the prerelease counter a numeric SemVer identifier, so `beta.10` sorts after `beta.9`.
- Stable releases use the same core version in both places: package `1.4.0` and tag `v1.4.0`.
- `PKG_RELEASE` identifies a rebuild of the same `PKG_VERSION`; increment it for another package build of that version and reset it to `1` when `PKG_VERSION` changes.
- Existing `v1.3.0-beta4` through `v1.3.0-beta10` tags remain immutable historical tags. Do not rename, move, delete/recreate, or continue that line as `v1.3.0-beta.11`: changing prerelease identifier structure in the middle of the same core version gives misleading SemVer ordering relative to `beta9`.
- The beta line for `1.3.0` is closed. Prereleases continue as `v1.3.0-rc.N` / `1.3.0~rcN`, starting with `rc.1`, and may then advance to stable `v1.3.0`; do not return to beta identifiers for the same core version. Start every future beta line at `vX.Y.Z-beta.1` / `X.Y.Z~beta1`.
- `scripts/qa/release-metadata.sh`, its BATS coverage, workflow help, and release documentation must enforce the explicit package-to-tag mapping for stable, beta, and RC versions. Never restore a blind `~` to `-` substitution.

## Runtime Assumptions

- Installed files live under `/opt/apps/mors`; `/opt/bin/mors` is a symlink created during package installation. Do not add a `/opt/bin/kvas` wrapper unless the user explicitly asks for a compatibility migration.
- Runtime config lives mostly in `/opt/etc`, for example `/opt/etc/mors.conf`, `/opt/etc/mors.list`, `/opt/etc/dnsmasq.conf`, `/opt/etc/AdGuardHome/AdGuardHome.yaml`, and `/opt/etc/shadowsocks.json`.
- Target environment is KeeneticOS plus Entware, with tools such as `opkg`, `curl`, `jq`, `knot-dig`/`dig`, `dnsmasq`, `dnscrypt-proxy2`, `ipset`, `iptables`, `ndmc`, and init scripts under `/opt/etc/init.d`.
- Many scripts call `localhost:79/rci` to change router configuration. Do not expect them to run safely or meaningfully on a normal development host.
- Historical Kvas documentation says the package requires Entware/opkg and Keenetic APIs, and does not function on non-Keenetic devices.
- Installing Mors over an existing Kvas installation is not supported. Users should remove the old `kvas` package before installing `mors`; automatic migration of `/opt/etc/kvas.conf`, `/opt/etc/kvas.list`, `/opt/etc/.kvas`, or old hooks is not part of the current behavior.
- Treat current behavior as IPv4-only unless the task explicitly includes IPv6 design/testing.
- The CLI and user-facing diagnostics are Russian. Preserve Russian messages unless the task explicitly asks for localization.

## Shell Style

- Most runtime files use `#!/bin/sh`. Prefer POSIX/BusyBox-compatible shell unless you have tested the target shell behavior.
- The existing code already contains some shell-specific constructs such as `${var:0:1}`, `${var::1}`, `[[ ... ]]`, `local`, and function names with double underscores. Avoid adding new Bash-only constructs unless the target router environment supports them.
- Follow the existing naming style:
  - `cmd_*` for CLI-facing command handlers.
  - `get_*`, `has_*`, `is_*` for query helpers.
  - namespaced helpers such as `ip4__...`, `iptables__...`, `config__...`, `hint__...` in shared libraries.
- Prefer small functions and keep side effects explicit. Many helpers mutate router state, so make preconditions and backup/restore behavior obvious.
- Keep absolute runtime paths (`/opt/apps/mors`, `/opt/etc/...`) in installed scripts. Use repository-relative `opt/...` paths only in build/package instructions and source files.

## Change Guidelines

- Treat inherited Kvas code and design decisions as historical input, not as an architectural authority. Mors is a fork of a third-party project, so existing behavior may contain accidental complexity, defects, or compromises that should not be preserved merely because they already exist.
- When a task exposes a flawed architecture, unsafe coupling, duplicated responsibility, or another structural weakness, call it out explicitly, explain the practical consequences, and propose the most correct maintainable implementation. Do not silently reproduce or work around a known design defect.
- Prefer sound architecture, correctness, testability, and long-term quality over the fastest possible closure of the immediate task. If the proper solution materially expands the requested scope, present the recommended design and tradeoffs and obtain direction before making that broader change.
- Keep changes narrowly scoped. This package touches DNS, firewall, routing, and VPN state on user routers.
- When adding or changing a CLI command:
  - follow `docs/cli-design-system.md`; update the design-system document first when introducing a new interaction or status pattern;
  - update `opt/bin/mors` dispatch logic;
  - update `opt/etc/conf/mors.help`;
  - compare the change with Mors documentation first, then the historical Kvas wiki command taxonomy in `Описание команд` if Mors docs do not cover it;
  - consider README/wiki/changelog updates if behavior is user-visible;
  - add or adjust helper functions in the relevant `opt/bin/libs/*` file.
- When adding a new runtime dependency, update `Makefile` `DEPENDS` and document the reason.
- When preparing a commit that changes packaged files or runtime behavior, increment `PKG_RELEASE` once for that release batch. Change `PKG_VERSION` only as part of a deliberate version transition.
- When changing default configuration, update templates in `opt/etc/conf/` and verify the install/setup paths that copy or transform them.
- When changing VLESS/Xray behavior or `opt/etc/conf/mors.vless`, inspect `opt/bin/libs/xray` and keep the compatibility policy, README, CLI help, changelog, and CI matrix synchronized. Update `XRAY_TESTED_VERSION` only after the compatibility CI validates that version.
- Changes to managed VLESS connections must preserve the component boundaries and release gates in `docs/vless-architecture.md`. Do not add a separate Xray process or Keenetic Proxy interface per connection.
- When changing NDM hooks, inspect `opt/bin/libs/ndm`, `opt/bin/libs/ndm_d`, and all matching hook directories because similar logic is duplicated across interface and netfilter events.
- When editing install, uninstall, update, or rollback behavior, inspect `opt/bin/main/setup`, `opt/bin/main/upgrade`, and `Makefile` post-install logic together.
- Do not rewrite large legacy shell sections just for style. Prefer targeted fixes with clear behavior.
- Preserve executable intent. Most runtime scripts are installed with `chmod -R +x` during post-install, but new build helper scripts may need Git executable mode if they are run directly from the repo.

## Safety Rules

- Do not run router-mutating scripts on a normal development host, regardless of privileges. Run `opt/bin/main/setup`, `opt/bin/main/upgrade`, uninstall paths, NDM hooks, and scripts that call `opkg`, `iptables`, `ipset`, or Keenetic RCI only on an explicitly scoped real/disposable Keenetic test target.
- Treat `rm -rf`, `sed -i`, `opkg`, `iptables`, `ipset`, `ndmc`, and `curl localhost:79/rci` changes as high-risk. Prefer dry reasoning, targeted tests, or a disposable router/test VM.
- Do not commit secrets or real endpoint data. Keep Shadowsocks/VLESS credentials, Telegram tokens, router IPs, SSH keys, and GitHub tokens out of the repo. Templates should use placeholders.
- Do not modify `.ipk` files, `packages/`, `.molot/`, or build outputs unless the task is explicitly about packaging/release artifacts.
- Before touching files, check `git status` and preserve unrelated user changes.
- Be careful with documentation or code that tells users to enable/disable `opkg dns-override`: historical Kvas install docs warn that it can interrupt SSH sessions and temporarily break internet access until package DNS setup is restored.

## Build And Test

- Keep BATS tests under `tests/` and runnable without a real router where practical.
- Run the fast repository checks from the repository root on a POSIX/Bash-capable host:

```sh
bash scripts/qa/static.sh
bats tests
```

  `static.sh` checks package layout, secrets, line endings, shell syntax, ShellCheck, and actionlint when the optional local tools are installed. CI installs BATS/ShellCheck, verifies a pinned actionlint binary, and runs both commands.
- The canonical CI and release package path is `.github/workflows/package.yml`. It resolves or publishes `ghcr.io/ivni/mors-entware-builder:v1-<builder-id>`, resolves that tag to an OCI digest, and runs the package job only with `ghcr.io/...@sha256:<digest>`. The mutable lookup tag is never sufficient release evidence.
- `scripts/qa/entware-builder-id.sh` hashes the builder schema, target config, Dockerfile/context allowlist, Entware/feed lock, builder scripts, and canonical runtime dependency file. Changing any builder input creates a new ID; ordinary Mors source or version changes reuse the existing toolchain image.
- `scripts/qa/verify-entware-builder.sh` is a fail-closed attestation gate. It verifies the manifest and input digests, locked Entware HEAD, host tools, the unique aarch64 toolchain/target, every dependency stamp, and absence of stale `package/mors` source or Mors IPK.
- After verification, `scripts/qa/entware-builder-package.sh` copies only `Makefile`, `opt`, and `runtime-dependencies.mk` into a temporary source tree and invokes the direct Mors package submake. Do not replace this with top-level `make package/mors/compile` inside the immutable image: the top-level target refreshes shared `.prepared` gates and rebuilds tools/dependencies.
- Builder images must never contain Mors source or a ready Mors IPK. Every package is cleaned and compiled from the current checkout, and release notes must record both the exact builder image digest and IPK SHA-256.
- A cold or local diagnostic build still requires an Entware buildroot. Use:

```sh
bash scripts/qa/entware-build.sh
```

  Inside a conventionally prepared non-image Entware tree, the equivalent top-level package target is:

```sh
make package/feeds/packages/mors/compile V=sc
```

- A release request requires both fast QA and a complete immutable-builder package build for the same commit before any tag is created. Use the manually confirmed `.github/workflows/release.yml`; do not infer that a missing router test stand prevents these host-only gates.

- The legacy Docker/Jenkins path uses `builder/Dockerfile` and `builder/builder`, but review it before trusting it for releases.
- `.github/workflows/router-smoke.yml` performs remote installation and router mutations. Trigger it only when the user explicitly requests a smoke run, the required secrets target an authorized test router, and the workflow confirmation is intentionally supplied.
- On a real or disposable Keenetic router, useful smoke checks include:
  - install the built `.ipk` with `opkg install`;
  - run `mors setup`;
  - run `mors test` and selected `mors debug ...` commands;
  - when collecting diagnostics for humans, prefer `mors debug /full/path/to/file` over shell redirection because the CLI strips color/control sequences for file output;
  - verify `mors vpn status`, `mors dnsmasq status`, `mors ipset`, and service statuses;
  - verify generated DNSMasq/AdGuardHome and `ipset` data files;
  - inspect `iptables-save` output for the expected `MORS_*` chains/rules.
- Treat new ShellCheck errors as actionable. When triaging legacy findings, account for Entware/Keenetic globals, BusyBox behavior, and absolute runtime paths rather than suppressing warnings broadly.

## Historical Wiki Notes

- Historical Kvas guidance favors the default `dnsmasq + dnscrypt-proxy2` path for simplicity and reliability; `adblock` can be enabled on top of it when needed. Treat AdGuard Home integration as optional and more sensitive.
- Kvas supports wildcard-style domain handling through DNSMasq. Adding a root domain such as `domain.com` is intended to cover subdomains; preserve this behavior when changing host-list parsing or DNSMasq/AdGuard generation.
- "Закваски" are tagged domain groups stored in `opt/etc/conf/tags.list` and exposed through `mors tags`, `mors add tags`, and `mors del tags`. Keep tag behavior and help text synchronized.
- The wiki install flow highlights router prerequisites: Entware should be installed on USB storage, older firmware may need Netfilter/Xtables components, clients should use the router as DNS, browser/private DNS can bypass Kvas, and IPv6 can interfere with expected routing.
- Kvas only supports AdGuard Home installations managed through Entware/opkg; manually copied AdGuard Home binaries are documented as unsupported.
- Debug labels have specific meanings: `АДРЕСА НЕТ` means the domain could not be resolved by `kdig`/`dig`; `ОТСУТСТВУЕТ` means the domain resolved but its address was not found in the active `ipset` table.

## Known Project Notes

- `Makefile` currently declares `PKG_NAME:=mors` and version/release values for the package. Keep package naming stable unless doing a deliberate migration.
- `opt/bin/main/upgrade` uses GitHub release URLs from `ivni/mors` and expects release artifacts named like `mors_*_all.ipk`. Treat release-source changes as user-facing install/update behavior.
- `opt/bin/libs/main` is the central source of runtime path constants. Check it before introducing new paths.
- `opt/bin/libs/vpn` is the largest and most coupled library. Be extra careful with changes there and inspect callers from `opt/bin/mors`, `setup`, NDM hooks, and helper scripts.
- NDM hook behavior differs across KeeneticOS versions; `opt/bin/libs/ndm` contains compatibility helpers such as firmware-version checks and PPE handling.
