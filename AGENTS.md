# AGENTS.md

## Project Overview

Mors is a direct rename and fork of the Kvas package. The active package and CLI name is now `mors`; the old `kvas` command, package name, runtime paths, and hooks are not kept as compatibility aliases. The package is an Entware package for Keenetic routers. It provides a Russian-language CLI for routing selected domains, IPs, and networks through VPN, Shadowsocks, or VLESS, while coordinating `ipset`, `iptables`, DNSMasq, DNSCrypt, AdGuard Home, ad blocking, and Keenetic NDM event hooks.

The active project repository is `ivni/mors`. This codebase began as a fork of Kvas, so historical changelog entries, license attribution, old release artifacts, and historical references may still mention the old upstream project. New runtime behavior, user-facing commands, install/setup instructions, release sources, and diagnostics should target Mors.

Primary project references:

- Repository: `https://github.com/ivni/mors`
- Local Git remote should normally point at `ivni/mors`.

Historical upstream references:

- Original repository: `https://github.com/qzeleza/kvas`
- Original wiki: `https://github.com/qzeleza/kvas/wiki`

Use the original Kvas repository and wiki only as historical/reference material when changing install/setup flow, CLI semantics, diagnostics, or user documentation. They contain operational guidance that is not fully captured in the source tree, but new work should target Mors.

## Repository Layout

- `README.md`, `HISTORY.md`, `LICENCE.md` - user documentation, changelog, and license.
- `Makefile` - Entware/OpenWrt package recipe. It declares package metadata/dependencies, installs selected NDM/init hooks, and copies `opt/.` into `/opt/apps/mors`.
- `builder/` - legacy CI/build helpers:
  - `Dockerfile` defines a Debian-based Entware build environment.
  - `builder` prepares Entware feeds/toolchain and compiles the package.
  - `Jenkinsfile` describes an older Jenkins pipeline; verify it before relying on it.
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
- `.github/workflows/` - GitHub Actions workflows: `qa.yml` runs static/BATS/Xray checks, `package.yml` builds release artifacts, and `router-smoke.yml` is a manually confirmed test-router workflow.
- `ipk/` - prebuilt package artifacts. It may still contain historical `kvas_*` packages; do not treat them as current Mors releases and do not change them unless intentionally adding/replacing release artifacts.
- `logs/` - captured build logs. Update only when recording a real build.

## GitHub Workflow

- Use GitHub CLI (`gh`) for GitHub operations when it is available and authenticated. Prefer it for inspecting issues, pull requests, releases, forks, and repository metadata instead of hand-assembling API calls.
- Default to `ivni/mors` for active development, issues, PRs, releases, and repository metadata. Use `qzeleza/kvas` only when explicitly comparing against historical upstream behavior.
- Write Git and release-facing text in Russian: commit subjects and bodies, annotated tag messages, release titles, and release notes. Keep technical identifiers, commands, paths, and upstream names unchanged where translation would make them inaccurate.
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

- Keep changes narrowly scoped. This package touches DNS, firewall, routing, and VPN state on user routers.
- When adding or changing a CLI command:
  - update `opt/bin/mors` dispatch logic;
  - update `opt/etc/conf/mors.help`;
  - compare the change with Mors documentation first, then the historical Kvas wiki command taxonomy in `Описание команд` if Mors docs do not cover it;
  - consider README/wiki/changelog updates if behavior is user-visible;
  - add or adjust helper functions in the relevant `opt/bin/libs/*` file.
- When adding a new runtime dependency, update `Makefile` `DEPENDS` and document the reason.
- When preparing a commit that changes packaged files or runtime behavior, increment `PKG_RELEASE` once for that release batch. Change `PKG_VERSION` only as part of a deliberate version transition.
- When changing default configuration, update templates in `opt/etc/conf/` and verify the install/setup paths that copy or transform them.
- When changing VLESS/Xray behavior or `opt/etc/conf/mors.vless`, inspect `opt/bin/libs/xray` and keep the compatibility policy, README, CLI help, changelog, and CI matrix synchronized. Update `XRAY_TESTED_VERSION` only after the compatibility CI validates that version.
- When changing NDM hooks, inspect `opt/etc/ndm/ndm`, `opt/bin/libs/ndm_d`, and all matching hook directories because similar logic is duplicated across interface and netfilter events.
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

  `static.sh` checks package layout, secrets, line endings, shell syntax, and ShellCheck when it is installed. CI installs BATS and ShellCheck and runs both commands.
- Full package compilation requires an Entware buildroot. The canonical build helper is:

```sh
bash scripts/qa/entware-build.sh
```

  Inside an already prepared Entware tree, the equivalent package target is:

```sh
make package/feeds/packages/mors/compile V=sc
```

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
- NDM hook behavior differs across KeeneticOS versions; `opt/etc/ndm/ndm` contains compatibility helpers such as firmware-version checks and PPE handling.
