# Матрица сборки каркаса Entware (#68)

База: `origin/main` `926fe9f`, результаты #59/#60/#61/#66/#67.
Изменение касается host build infrastructure. Runtime-команды Mors и decision
lock #57 не меняются. Полная приёмка требует реальных сборок каждой строки;
fixture-проверки ниже не заменяют compiler/ELF evidence.
Полный OCI/CI-прогон трёх ABI завершён; итоговые manifests и результаты
приёмки находятся в конце документа.

## Выбор ABI и attestation

[`targets.json`](../builder/entware/targets.json) — закрытый список:

| `MORS_ENTWARE_TARGET` | Rust target | Toolchain / target staging |
| --- | --- | --- |
| `aarch64-3.10` (default) | `aarch64-openwrt-linux-gnu` | `aarch64_cortex-a53_gcc-8.4.0_glibc-2.27` / `aarch64_cortex-a53_glibc-2.27` |
| `mips-3.4` | `mips-openwrt-linux-gnu` | `mips_mips32r2_gcc-8.4.0_glibc-2.27` / `mips_mips32r2_glibc-2.27` |
| `mipsel-3.4` | `mipsel-openwrt-linux-gnu` | `mipsel_mips32r2_gcc-8.4.0_glibc-2.27` / `mipsel_mips32r2_glibc-2.27` |

Префиксы каталогов — `toolchain-` и `target-`. В каждом образе разрешены ровно
один toolchain и один target staging; чужой, второй или символьная ссылка
не проходят проверку. `mips` не сопоставляется с `mipsel` через общий glob.
Неизвестное имя target отклоняется до сборки, без fallback на AArch64.

Для каждой строки закреплён SHA-256 исходной конфигурации
`configs/<target>.config` из Entware revision
`2d92d7c0b4055cb27901025f8a08d2e6344e849e` (#60). Digests сверены с содержимым
этих файлов через GitHub API. Cold build проверяет digest перед `defconfig`;
verifier также сверяет architecture, CPU, board и package ABI действующего
`.config`. Имена feeds не задают минимальное ядро Mors: минимум продукта —
KeeneticOS 5+, как в [матрице #59](research/connection-platform-matrix.md).

Target, config digest и точные имена каталогов включены в manifest. Таблица,
helper выбора ABI, Rust lock и verifier входят в builder ID. Разные ABI дают
разные ID и отдельные OCI images. Полный manifest сверяется с checkout, поэтому
manifest MIPS BE нельзя использовать для MIPSel. Rust verifier проверяет
именно выбранную target `std`/`core`, compiler sysroot, GCC ABI и версии.

## Сборка и артефакты

[`core-matrix.yml`](../.github/workflows/core-matrix.yml) запускается вручную и
вызывает reusable [`package.yml`](../.github/workflows/package.yml) для всех
трёх target. У каждого вызова свой resolver: образ строится с
`--build-arg ENTWARE_TARGET=<target>`, затем запускается только по OCI digest.
Обычный release продолжает вызывать тот же workflow с default AArch64 и
`core=false`, получает прежний artifact `mors-ipk` и единственный `all.ipk`.

Для проверки новой ветки до появления `core-matrix.yml` в default branch
тот же путь доступен через уже зарегистрированный `package.yml`:

```sh
gh workflow run package.yml --repo ivni/mors --ref codex/issue-68 \
  -f target=aarch64-3.10 -f core=true
```

Для двух остальных строк передаются `target=mips-3.4` и `target=mipsel-3.4`.
Это три отдельных запуска тех же builder/package/core jobs. Ручной запуск
без параметров сохраняет прежний AArch64 package-only путь. GitHub требует
наличия workflow в default branch для первого `workflow_dispatch`; одного
нового файла в feature branch недостаточно.

Matrix сначала проверяет обычный direct package submake; его команды остаются
`make -w -r -C package/mors ... clean/compile`, без top-level пересборки
tools/dependencies. Проверочные shell IPK получают имена CI artifacts
`mors-ipk-check-<target>` и не становятся релизными ABI-пакетами.
При `core=true` package submake выполняется повторно, и CI требует совпадения
SHA-256 обоих IPK. `PKG_SOURCE_DATE_EPOCH` и `SOURCE_DATE_EPOCH` передаются
явно из timestamp текущего Git-коммита; для дерева без Git требуется явный
числовой `SOURCE_DATE_EPOCH`. Это исключает fallback Entware на время создания
файла внутри builder. Исходные права файлов остаются частью package inputs.

[`entware-core-build.py`](../scripts/qa/entware-core-build.py) сначала вызывает
общий verifier, затем копирует только `Cargo.toml`, `Cargo.lock` и `crates/`
во временный каталог. Cargo работает с отдельным `CARGO_HOME`, с явными
attested rustc/linker и `--frozen`. Toolchain не загружается при сборке ядра;
пользовательские Cargo/Rust overrides и `.cargo/config.toml` не наследуются.

Выход: `packages/core/<target>/mors-core`, `elf.txt`, `builder.env`, `build.json`.
Manifest содержит digests исходников, ELF, builder inputs и OCI image из CI.
ELF gate проверяет class/endian/machine, Entware interpreter; для MIPS также
MIPS32r2, O32 и soft-float. Dynamic glibc в этом пути — проверка каркаса, а не
окончательный контракт production linkage/поставки #69. Artifact помечен
`execution=not-tested`: статическая инспекция не выдаётся за запуск.
`relocation-model=static` повторяет проверенный путь #60 и pinned Rust feed;
это не `crt-static` и не статическая линковка glibc. Аргументы передаются
через `CARGO_ENCODED_RUSTFLAGS`, чтобы пробелы в путях не разбивали linker flags.

Локальные команды для уже собранного **соответствующего** immutable image:

```sh
export MORS_ENTWARE_TARGET=mipsel-3.4
bash scripts/qa/verify-entware-builder.sh
bash scripts/qa/entware-builder-package.sh
python3 scripts/qa/entware-core-build.py
```

Для cold build ID вычисляется с тем же `MORS_ENTWARE_TARGET`, затем передаётся
в Dockerfile как `BUILDER_ID`, а target — как `ENTWARE_TARGET`. Нельзя изменить
target переменной окружения внутри готового образа другой ABI и считать его
подходящим: manifest/staging verification обязана завершиться ошибкой.

## Внешний NaiveProxy runtime проверяется отдельно

Способы получения сверены с [#61](research/naiveproxy-runtime.md) и
[финальным результатом #63](research/naiveproxy-runtime-spike.md):

25.09.2026 `gh release view v150.0.7871.63-1 --repo klzgrad/naiveproxy`
повторно подтвердил наличие выбранных MIPSel/AArch64 static assets и совпадение
archive digests с #61 (`741b26a2…` / `f5ae78dd…`). MIPS BE asset в этом
закреплённом release отсутствует. Это проверка доступности/provenance, без
повторного запуска runtime и без переоценки gates #63.

| ABI | Способ получения | Независимый gate |
| --- | --- | --- |
| MIPSel | Pinned static OpenWrt asset `openwrt-mipsel_24kc-static`; для production нужен исправленный build #63 или проверенный эквивалент upstream fix | Stock `v150.0.7871.63-1` не содержит исправление idle-cleanup. Проверенный patched ELF и provenance закреплены в [manifest #63](research/naiveproxy-63/build-20260924-manifest.json); SBOM/package/rollback остаются #69 |
| AArch64 | Pinned static asset `openwrt-aarch64_cortex-a53-static` из #61 | Зафиксирован SIGILL на `sha1h` у Pi 3 без SHA1 extension. До отдельного ISA/fallback gate этот asset нельзя объявлять совместимым со всеми AArch64; исправление #63 также нужно переносить и проверять отдельно |
| MIPS BE | Готового upstream asset нет; отдельный Chromium/NaiveProxy port/research | NaiveProxy capability BLOCKED. Rust core и поддержка платформы Mors сохраняются; чужой little-endian ELF не подставляется |

Ни один путь не скачивает `latest` и не объединяет runtime pin с Rust lock.
Новый target вне таблицы требует отдельного ограниченного toolchain spike с
config/compiler/std/ELF evidence до расширения матрицы; отсутствие такого
доказательства не означает прекращение поддержки роутеров.

## Проверки текущего изменения

25.09.2026, отдельный Linux QA-контейнер и LF-снимок рабочей копии:

- Полный `bats tests`: **503/503**, exit 0. После усиления проверки root staging
  и dangling source symlink повторно пройдены все **13/13** builder/matrix tests.
  Они включают dispatch прямого package submake для трёх ABI; это fixture,
  а не измерение фактической пересборки tools в полном образе.
- `bash scripts/qa/static.sh`: exit 0, включая ShellCheck и закреплённый
  actionlint 1.7.12 с проверкой SHA-256 из QA workflow.
- `bash scripts/qa/rust.sh`: pinned host Rust 1.94.0, fmt/clippy, четыре
  поведенческих теста, workspace/doc tests и release build — exit 0.
  Первоначально в QA-контейнере отсутствовал `cc`; после установки
  `build-essential` весь Rust gate повторён успешно.
- Python negative tests проверили class/endian/machine/interpreter, MIPS
  O32/soft-float, подмену `.config`, изоляцию Cargo и сохранение provenance.
- `docker build --check --file builder/entware/Dockerfile .`: exit 0,
  без предупреждений. Это Dockerfile check, не готовый OCI image.
- Новый config gate прошёл на реальном закреплённом AArch64 buildroot
  (`entware-target.py verify-active`), без fixture подмены.

Журналы host QA сохранены локально в игнорируемом `.qa/`: `bats.log`,
`matrix.log`, `static.log`, `rust-host.log`. Проверки не меняли роутеры,
runtime-файлы Mors, release workflow или текущий выбор релизного пакета.

### Реальный AArch64 прогон

Диагностический контейнер создан из прежнего image по digest
`ghcr.io/ivni/mors-entware-builder@sha256:5eb5bd38560cd981d4396a1b6f6f9988b0a0ee74620647bbfff23f3439c72b4e`.
В его writable layer построен полный pinned Rust toolchain: host recipe
завершился за 39m59s; target recipe построил AArch64 `std` и установил её.
Это не новый immutable image: для проверки изменённого buildroot использован
отдельный диагностический manifest, в ELF evidence `builder_image=null`.

Реальная сборка выявила два дефекта, исправленных в этом изменении:

- Cargo из pinned source tarball добавляет `(built from a source tarball)`
  к `--version`. Старый verifier #67 ошибочно отклонял корректную версию.
  Разрешён только этот точный дополнительный суффикс; неверная версия и
  произвольный суффикс по-прежнему отклоняются. Исходный build log с отказом
  сохранён; после исправления real verifier прошёл.
- Entware записывал случайный физический temporary path в IPK `Source`.
  Payload двух пакетов совпадал, но `control.tar.gz` и IPK SHA-256 различались.
  Direct submake теперь явно задаёт `SOURCE=package/mors`; это логический
  путь того же package submake, временный каталог и cleanup сохранены.

После исправлений:

| Проверка | Фактический результат |
| --- | --- |
| Полный verifier: config, toolchain/staging/root, dependencies, Rust/Cargo/std/C tools | PASS в диагностическом buildroot |
| Workspace `--frozen --release --target aarch64-openwrt-linux-gnu` | PASS, ELF 271360 bytes |
| Повторная сборка ELF в новом temporary source | SHA-256 совпал: `eadaa5baa6db12adcb6ed3d1c0a4874b372af98b59ad6bea0d05c8ca26bf3d4d` |
| Direct package submake | PASS; host/toolchain/runtime dependency stamp snapshots до/после совпали |
| Две повторные сборки IPK после исправления `Source` | SHA-256 совпал: `8ef3a0e004e5df6d2892e2f8dba27372702a3116fd8796995a9b5c8ec0ed70a5` |
| QEMU 8.2.2, `-cpu cortex-a53`, Entware root prefix | `mors-core --version` → `mors-core 0.1.0`, exit 0; `--help` → exit 0 |

[Build evidence](research/entware-core-68/aarch64-3.10/build.json),
[ELF inspection](research/entware-core-68/aarch64-3.10/elf.txt),
[input manifest](research/entware-core-68/aarch64-3.10/builder.env).
Бинарник и подробные журналы находятся локально в `.qa/aarch64/`, без включения
ELF в Git/IPK. QEMU проверяет запуск version/help на host kernel; это не
проверка физического роутера, минимального ядра Keenetic или NaiveProxy.

### Итог по всем трём ABI

В двух дополнительных контейнерах того же исходного OCI digest полностью
собраны MIPS/MIPSel C toolchain, target Rust `std` и canonical runtime
dependencies. Для host Rust повторно использован настоящий завершённый build
cache, включая source/install/stamps; SHA-256 `rustc` и Cargo до/после переноса
совпали. Старые AArch64 staging trees удалены только в этих диагностических
контейнерах перед проверкой уникальности выбранной ABI.

Первый MIPS проход остановился при одновременной распаковке двух Rust source
archives: cgroup зарегистрировал `oom_kill=1`. Архив сохранил правильный
SHA-256; его распакованный размер — 3867133440 bytes. После завершения второй
распаковки повтор MIPS build завершился успешно. Этот отказ не признан
несовместимостью ABI и не скрыт: исходный log и retry log сохранены отдельно.
В CI строки матрицы выполняются в отдельных jobs/runners.

| ABI | Размер ELF, bytes | Full verifier / core build | Повторяемость ELF и IPK | QEMU version/help |
| --- | ---: | --- | --- | --- |
| AArch64 | 271360 | PASS / PASS | PASS | Cortex-A53: оба exit 0 |
| MIPS BE | 357560 | PASS / PASS | PASS | 24Kc: оба exit 0 |
| MIPSel | 357720 | PASS / PASS | PASS | 24Kc: оба exit 0 |

ELF SHA-256:

```text
aarch64 eadaa5baa6db12adcb6ed3d1c0a4874b372af98b59ad6bea0d05c8ca26bf3d4d
mips    157181e400294ffef6189ded01624be87ef392ff1ba84ee9cfd94842b485c0d3
mipsel  38a072268229aae2a0af966123036af8d698631fc9c1cdf002f0b2277e089b22
```

Дополнительные evidence: [MIPS build](research/entware-core-68/mips-3.4/build.json),
[MIPS ELF](research/entware-core-68/mips-3.4/elf.txt),
[MIPS manifest](research/entware-core-68/mips-3.4/builder.env),
[MIPSel build](research/entware-core-68/mipsel-3.4/build.json),
[MIPSel ELF](research/entware-core-68/mipsel-3.4/elf.txt),
[MIPSel manifest](research/entware-core-68/mipsel-3.4/builder.env).

На каждой ABI direct package submake выполнен дважды; совпали IPK digests.
У всех трёх получился один и тот же shell `all.ipk` digest `8ef3a0e0…`,
полное значение приведено выше. Stamps host tools, C toolchain и runtime
dependencies до/после direct submake не изменились; на MIPS/MIPSel дополнительно
сверены target staging stamps, включая установленный Rust. Все три результата
`--version` — `mors-core 0.1.0`. Это реальные ELF проверки текущего каркаса #66,
а не повторное использование бинарников исторического spike #60.

**Граница локального результата:** на описанном выше локальном этапе новые
полные OCI images через канонический Dockerfile ещё не создавались.
Реально построен `runtime-base`, а core/package paths проверены в подготовленных
диагностических writable layers. Их input manifests и ELF digests нельзя
выдавать за digests новых immutable images: поле `builder_image` намеренно
равно `null`. Поэтому требовался отдельный полный OCI build/resolution/
verification gate для каждой ABI; его результат приведён ниже. Router runtime,
NaiveProxy admission и выпуск релиза этими проверками не подтверждаются.

Контейнеры `mors-68-build`, `mors-68-mips`, `mors-68-mipsel` сохраняются как
локальный диагностический cache на Docker pause, чтобы повторная проверка не
требовала заново собирать toolchain. Для доступа сначала нужен `docker unpause`
нужного контейнера. Исходники проверяемого snapshot находятся внутри в `/work`,
диагностический manifest — `/tmp/issue68-diagnostic.env`. Это не release images.

## Полный OCI/CI-прогон 25.09.2026

Все три образа реально собраны каноническим Dockerfile из коммита `cc52236`,
прошли встроенный полный verifier и опубликованы в GHCR. Отдельные package jobs
загрузили образы по OCI digest, повторно проверили их и собрали IPK и Rust ELF:

| ABI | Полный первый прогон | OCI manifest digest |
| --- | --- | --- |
| AArch64 | [36150670698](https://github.com/ivni/mors/actions/runs/36150670698), PASS | `sha256:67157b952aa44e33ee84a6034643738faa5754f6f04e867cef39f96d665ecc8b` |
| MIPS BE | [36150674736](https://github.com/ivni/mors/actions/runs/36150674736), PASS | `sha256:8c16bd214d22a3a41e10d016f6fa1e4d37317947dc10cfa9a95cda8dde43721b` |
| MIPSel | [36150679287](https://github.com/ivni/mors/actions/runs/36150679287), PASS | `sha256:d7e419c76984864bd241023a285345a54caf36b2eadc946f7150a867a95a9a15` |

Имена images: `ghcr.io/ivni/mors-entware-builder@<digest>`. Manifest digests
дополнительно разрешены через `docker buildx imagetools inspect`; это не
локальные Docker config/image IDs. Builder input IDs остались теми же, что
в диагностических manifests. После этого cold build не повторялся: дальнейшие
package/core проверки использовали уже опубликованные неизменяемые образы.

Сравнение первого CI IPK с диагностическим выявило дополнительный источник
невоспроизводимости: Entware вычислял `PKG_SOURCE_DATE_EPOCH` для временного
source tree через fallback на mtime своего `get_source_date_epoch.sh`.
Timestamp зависел от момента создания builder. Исправление явно передаёт
timestamp текущего Git-коммита в оба make-параметра, как описано выше.
Содержимое payload первого MIPSel CI IPK совпало с диагностическим; кроме
timestamp, отличались права части файлов/каталогов Windows-снимка.
Диагностический IPK SHA не выдаётся за канонический CI IPK SHA.

Первый повтор на `8e3a99c` остановился на новом timestamp gate: Git в package
контейнере отвергал checkout с другим владельцем. В `575d676` чтение timestamp
использует command-scoped `safe.directory` ровно для выбранного source root,
без глобального разрешения произвольных репозиториев. BATS воспроизводит
ownership mismatch через `GIT_TEST_ASSUME_DIFFERENT_OWNER=1`; старая команда
падает на этом тесте, исправленная получает timestamp fixture-коммита.

### Приёмка окончательной реализации

Проверенный code SHA: `575d6762c495aa4881d92647c6751be2252987e3`.
[QA 36167434858](https://github.com/ivni/mors/actions/runs/36167434858) — PASS:
**504/504 BATS**, static/ShellCheck/actionlint, Rust fmt/clippy/tests/release,
обе Xray compatibility jobs.

| ABI | Окончательный CI | Verifier / IPK / повтор IPK / core ELF | Evidence |
| --- | --- | --- | --- |
| AArch64 | [36167425441](https://github.com/ivni/mors/actions/runs/36167425441) | PASS / PASS / PASS / PASS | [build.json](research/entware-core-68/ci/aarch64-3.10/build.json) |
| MIPS BE | [36167428697](https://github.com/ivni/mors/actions/runs/36167428697) | PASS / PASS / PASS / PASS | [build.json](research/entware-core-68/ci/mips-3.4/build.json) |
| MIPSel | [36167431767](https://github.com/ivni/mors/actions/runs/36167431767) | PASS / PASS / PASS / PASS | [build.json](research/entware-core-68/ci/mipsel-3.4/build.json) |

[Сводный машиночитаемый результат](research/entware-core-68/ci/results.json)
фиксирует source SHA, run URLs, OCI digests, ELF/IPK hashes, archive metadata
и успех отдельных CI steps. Рядом с каждым `build.json` сохранены исходный
`builder.env` и вывод `readelf` (`elf.txt`, удалены только конечные пробелы).
Бинарные ELF/IPK остаются в GitHub Actions artifacts и не включены в Git.

Скачанные артефакты независимо проверены: class/endian/machine ELF, SHA-256
самого ELF, каждого перечисленного Git source input и core build helper,
равенство manifest ожидаемым builder inputs, совпадение OCI digest с GHCR.
Все три ELF побайтово совпали с соответствующими диагностическими ELF,
проверенными ранее под QEMU. Повторный запуск CI ELF на физическом роутере
этим не заявляется; `execution=not-tested` в manifests сохраняется.

Каждый direct package compile занял **0–1 секунду** по секундному таймеру.
В каждом CI job две сборки совпали побайтово; дополнительно одинаковый IPK
получен из всех трёх разных ABI images:

```text
mors_1.3.0~rc2-1_all.ipk
SHA-256: 1019b28523a386582ec089a16cb2867f280cedc28ae1db595c6b578b95647254
SourceDateEpoch: 1790357353
```

Timestamp совпадает с committer timestamp проверенного code SHA. Это
проверочный shell IPK, не релиз и не ABI-пакет с установленным Rust-ядром.
Использование других source timestamps или прав файлов не обязано давать
тот же digest. Критерии сборочной инфраструктуры #68 выполнены; NaiveProxy
ISA/port/admission, физический router runtime и production packaging #69
остаются самостоятельными задачами.
