# Платформенная упаковка ядра и NaiveProxy (#69)

База реализации: `main` `d1036e44dd0850059e71c428b6a395f364f64e4c`.
Контракт: [ADR-0001 §7](adr/0001-connection-core-boundaries.md),
[матрица сборки #68](entware-core-matrix.md).

## Пакеты и граница внедрения

Основной пакет сохраняет имя `mors`. В явном режиме `platform` он содержит
существующую shell-обвязку и **один** `/opt/apps/mors/bin/mors-core`.
Отдельного обязательного `mors-core` package нет. Версия CLI ядра пока `0.1.0`;
версия IPK берётся из `PKG_VERSION`/`PKG_RELEASE` основного Makefile.

| Target / control Architecture | Имя кандидата |
| --- | --- |
| `aarch64-3.10` | `mors_<version>-<release>_aarch64-3.10.ipk` |
| `mips-3.4` | `mors_<version>-<release>_mips-3.4.ipk` |
| `mipsel-3.4` | `mors_<version>-<release>_mipsel-3.4.ipk` |

Включать ELF в `Architecture: all` запрещено. Makefile отклоняет неизвестный
ABI при `MORS_CORE_PACKAGE=1`; builder выбирает target по закрытой матрице,
проверяет соответствующий toolchain и заново собирает ядро из текущих исходников.
Зависимости ядра: `libc`, `libgcc`, `libpthread`; проверяются installed stamps,
наличие библиотек в staging и точный `DT_NEEDED` извлечённого ELF. Это уже
транзитивно установленные зависимости immutable images #68; новый builder
и изменение общего shell dependency list для них не требуются.
Полный control также включает базовые зависимости Entware `libssp` и `librt`.
Повторный Entware strip отключён только для платформенного кандидата: Cargo
уже собирает stripped ELF, его байты и digest сохраняются при упаковке.

Установка сохраняет существующие пассивные lifecycle scripts без изменений.
Не добавляются init/NDM hooks, selector, symlink в `/opt/bin`, скачивание или
запуск ядра. DNS, firewall и рабочий runtime не переключаются. Каркас умеет
только version/help. Установочные скрипты проверяются по точному содержимому
Makefile, включая раскрытие package version/release и экранирование `$`.
Исполнение maintainer scripts на реальном роутере этой host-проверкой не заявляется.

До #116 режим по умолчанию остаётся `legacy`: прежний shell `all.ipk`.
Новый режим не подключён к release workflow или updater. Кандидаты лежат
отдельно в `packages/platform/<target>/`; `release_admitted=false` в evidence.
Правило одного проверенного `all.ipk` для действующих релизов не изменено.

## Сборка и проверка

В контейнере, запущенном из соответствующего immutable image #68:

```sh
export MORS_ENTWARE_TARGET=mipsel-3.4
export MORS_ENTWARE_BUILDER_IMAGE=ghcr.io/ivni/mors-entware-builder@sha256:d7e419c76984864bd241023a285345a54caf36b2eadc946f7150a867a95a9a15
MORS_PACKAGE_MODE=platform bash scripts/qa/entware-builder-package.sh
```

Для snapshot без `.git` требуется числовой `SOURCE_DATE_EPOCH`.
Сборка выполняется direct package submake после полного builder verifier.
Временный source содержит только Makefile, `opt`, dependency list и проверенный
ELF. Rust toolchain, Cargo/source trees и build evidence не попадают в IPK.
Архив проверяется до успешного завершения команды:

- имя, Package, Version, Architecture, полный набор dependencies;
- запрет ссылок, traversal, дубликатов и специальных файлов в архивах;
- точный набор и байты payload относительно текущего `opt` и собранного ELF;
- mode `0755`, class/endian/machine, MIPS O32/r2/soft-float, loader и `DT_NEEDED`;
- соответствие ELF digest, source digests и builder evidence текущему checkout.

Рядом с IPK сохраняется JSON, связывающий package digest/size, ABI, core digest,
исходники и immutable builder digest. Это candidate evidence, не будущий
release manifest #116. `execution=not-tested` означает, что сам verifier
не запускает ELF; отдельный QEMU smoke фиксируется в отчёте проверки.

При наличии `qemu-aarch64`, `qemu-mips` или `qemu-mipsel` для выбранного target:

```sh
python3 scripts/qa/entware-platform-smoke.py packages/platform/mipsel-3.4/mors_1.3.0~rc2-2_mipsel-3.4.ipk
```

Smoke повторяет проверку IPK, извлекает ELF во временный каталог и выполняет
version/help с sysroot этого builder. Host opkg проверяет свою и две чужие
ABI только с `--noaction`; fixture status с именами установленных зависимостей
изолирует architecture check от resolver ошибок пустого root. Это не установка
зависимостей: host opkg проверяет их наличие даже с `--nodeps`/`--force-depends`.
Их реальный состав и
staging отдельно проверены выше. Установка не выполняется, maintainer scripts
не запускаются. Результат сохраняется в `.smoke.json` рядом с IPK.

## Переход со старого all

Соответствие: `mors_*_all.ipk` → один `mors_*_<Entware ABI>.ipk` того же
package name. Оно **не** означает разрешённое обновление текущим updater.
Opkg должен иметь только ABI установленного Entware; чужая Architecture
отклоняется штатным architecture check. `--force-architecture` и добавление
чужой ABI в конфигурацию opkg не являются поддерживаемым обходом.
Одного `uname -m` недостаточно для выбора пакета.

#116 должен реализовать ABI inventory, выбор/digest release manifest,
all→target и target→all rollback, version/schema compatibility, проверку места
и точного dependency set до quiesce/opkg. Нельзя объявлять update безопасным
по одному успешному извлечению IPK. До этих gates платформенные пакеты
не публикуются пользователям как релиз; #69 не меняет прежний updater.

## NaiveProxy: незакрытая часть #69

Имя необязательного runtime package: `mors-naiveproxy`; Architecture совпадает
с Entware target. Основной `mors` от него не зависит. Поддержка ядра MIPS BE
сохраняется; NaiveProxy BE не получает LE asset или фиктивный пустой package.

[Закреплённые кандидаты](../builder/entware/naiveproxy-candidates.json) теперь
описывают собственные сборки из pinned source с исправлением idle-cleanup #63.
MIPSel и AArch64 поставляются отдельным необязательным `mors-naiveproxy` IPK.
MIPS BE runtime отсутствует: новый порт не входит в #69 и не блокирует ядро BE.
Latest download не используется. `distribution_admitted=false` сохраняется
до отдельных activation/release gates, а не из-за отсутствия SBOM или CA.

Пакет содержит один статический ELF в `/opt/apps/mors-naiveproxy/bin/naive`,
CA bundle, отдельный пустой CA directory, CycloneDX SBOM, component inventory,
36 файлов notices и manifest с digests. Динамических зависимостей runtime нет.
Нет init/NDM hooks, preinst/postinst/prerm, скачивания, запуска selector или
изменений глобального trust store. Единственный postrm выполняет `rmdir`
точного списка принадлежащих пакету каталогов только при `remove`: чужие
файлы и непустые каталоги сохраняются, upgrade пропускается. Реальный opkg
оставлял пустые каталоги без этого script; повторная установка/удаление на
NC-1913 подтвердила полную очистку и неизменность сети/работающих служб.

CA: certifi `2026.7.22`, 121 корень, SHA-256 закреплён в manifest; поставлены
NOTICE и полный MPL-2.0. Встроенные Chrome roots остаются включены, bundle
не объявляется единственным trust source. #81 передаёт `SSL_CERT_FILE` и
`SSL_CERT_DIR` только дочернему процессу. Production compatibility/rollback
allowlist принадлежит coordinator и #116, не установочному script.

Подробные inputs, команды и доказательства:
[NaiveProxy packaging](naiveproxy-packaging.md).

## Фактическая проверка 26–27.09.2026

Сборки выполнены локально в отдельных контейнерах без сети из трёх immutable
OCI images #68. В исходном snapshot использованы LF и `SOURCE_DATE_EPOCH=1790358348`
(timestamp базового main). Перед коммитом `PKG_RELEASE` увеличен до `2`;
три платформенных пакета пересобраны дважды, legacy `all.ipk` также пересобран.
Ниже и в JSON evidence приведены результаты окончательной ревизии `rc2-2`.

| Target | IPK bytes | Build / verifier | Повтор IPK | QEMU version/help | Opkg ABI |
| --- | ---: | --- | --- | --- | --- |
| AArch64 | 371661 | PASS | одинаковый SHA-256 | PASS, cortex-a53 | свой PASS, два чужих отказа |
| MIPS BE | 396017 | PASS | одинаковый SHA-256 | PASS, 24Kc | свой PASS, два чужих отказа |
| MIPSel | 395929 | PASS | одинаковый SHA-256 | PASS, 24Kc | свой PASS, два чужих отказа |

Все `--version` вернули `mors-core 0.1.0`. Во время повторных сборок неизменны
размеры/mtime всех файлов `staging_dir/**/stamp/*`, кроме собственных Mors stamps.
Direct package compile занимал 0–1 секунду по секундному таймеру;
это не включает загрузку image и отдельную компиляцию Rust.

Машиночитаемые evidence с полными IPK/core digests, builder manifests,
исходными Rust inputs и результатами smoke:
[AArch64](research/platform-packaging-69/aarch64-3.10.json),
[MIPS BE](research/platform-packaging-69/mips-3.4.json),
[MIPSel](research/platform-packaging-69/mipsel-3.4.json).
Сами IPK находятся в игнорируемом `packages/platform/<target>/`.

Дополнительно:

- `bash scripts/qa/static.sh`: PASS, включая ShellCheck и actionlint.
- `bats tests`: **508/508 PASS** на snapshot, подготовленном к коммиту.
- `bash scripts/qa/rust.sh`: PASS, fmt/clippy/tests/release.
- `tests/platform_package_test.py`: PASS, включая три ABI, unsafe archives,
  подмену metadata/ELF/hooks, build residue, stale source/provenance и зависимости.
- Реальная legacy `all.ipk` сборка и прежний `verify-release-artifact.sh`: PASS;
  `mors-core` отсутствует в её payload. Release/updater не переключены.
- `git diff --check`: PASS. Runtime-файлы и decision lock #57 не изменены.

Первый реальный проход выявил и устранил неверное предположение о пути libc
(нужен `staging/root-<target>/opt/lib`), неучтённые базовые Entware dependencies,
GNU make continuation folding и повторный strip ELF. Для opkg dry-run
потребовалась fixture status: `--nodeps` и `--force-depends` не обходят
ранний unresolved-dependency check в закреплённой версии host opkg.

Параллельная подготовка больших OCI images достигла лимита памяти WSL 8 ГБ
без swap; диагностическое подключение WSL получило timeout. Два собственных
pull-процесса остановлены, образы успешно подготовлены последовательно из
уже скачанных слоёв. Настройки WSL и существующие образы не изменялись.

**Итог #69, дополнен 27.09.2026: ядро для трёх ABI и NaiveProxy для двух ABI
собраны и проверены.** NaiveProxy TLS/CA проверены локальным QEMU fixture;
пассивная установка/удаление MIPSel проверена на NC-1913, AArch64 version/help
на Pi 3 B+ без AES/SHA extensions. Это не полный production dataplane admission.
All→ABI updater/release integration остаётся #116, activation/DNS/routing
остаются за пределами упаковки. Релиз не выпускался, issue не закрывалась.
