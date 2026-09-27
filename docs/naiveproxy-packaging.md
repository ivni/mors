# Поставка NaiveProxy (#69)

Связанный контракт: [платформенная упаковка](platform-packaging.md).
Это host build/package pipeline, не новая логика ядра и не activation runtime.

## Закреплённые входы

- NaiveProxy/Chromium `150.0.7871.63`, commit
  `3ba967e2d36cc133a896e81a36257ad4c6ea20f4`; patch idle-cleanup из #63
  и отдельный patch для link map. Другие изменения source запрещены.
- OpenWrt SDK `24.10.0`, GCC `13.3.0`, musl `1.2.5`, отдельный sysroot
  для каждой ABI. Все используемые файлы сверены с pinned SDK.
- LLVM `23.1.2` из apt.llvm.org, точные deb URL/SHA в
  [input lock](../builder/entware/naiveproxy-inputs.json).
  Штатные Google Storage downloads вернули HTTP 403 из-за географического
  ограничения, поэтому использован этот компилятор и GN из исходников.
  PGO выключен, Chromium-specific compiler plugins выключены; прочие
  build flags явно записаны в `naiveproxy-common.gn`.
- GN commit `3357c4f51b1a9e676378c695dd9c7e9911c35ee6`, version
  `2407 (3357c4f51b1a)`. Host tool строится GCC; его hash и host packages
  фиксируются в preparation receipt, а не выдаются за immutable toolchain.
- MIPSel: O32, MIPS32r2, soft-float, static. AArch64:
  `cortex-a53+nocrypto+nocrc`, static. Обязательных AES/SHA/CRC32 compiler
  macros нет. На физическом Pi без AES/SHA прошли version/help.
- CA certifi `2026.7.22`, 121 корень; wheel, bundle, NOTICE и MPL-2.0
  закреплены SHA-256. Встроенные Chrome roots остаются активными.

SBOM строится по target compilation graph и dependency headers, с требованием
готовых объектов, финального ELF и link map. Host generators исключены.
Каждая source/header группа классифицирована; неизвестная группа останавливает
сбор notices. Получено 33 компонента и 36 файлов лицензий, включая Chromium,
BoringSSL, zlib, libc++, musl, GCC runtime exception и CA.

Для pruned upstream tree восстановлены отсутствующие полные license texts
compiler-rt, Perfetto и Protobuf по pinned URL/digest из
[notice lock](../builder/entware/naiveproxy-notices.json). Для LSS/Googletest
извлечён полный license header. Protobuf C++ version `6.33.0` определена по
source macro; совпадение всего pruned source с release tag не утверждается.
Component inventory содержит source-file hashes и происхождение notices.

## Сборка

Нужен disposable Linux x86_64 с Python 3.11+, GCC/G++, make, git, curl,
ca-certificates, ninja-build, xz-utils, zstd, unzip, pkg-config, ccache,
libedit2, libz3-4, libxml2, binutils. Для smoke: qemu-user-static, Node.js,
python3-cryptography и host opkg из проверенного Entware builder.
Использованный base image:
`ubuntu@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90`.
Это не новый canonical Entware builder image; host package versions сохранены
в локальном preparation receipt. Сборка Chromium выполняется только на host.

В примере checkout Mors находится в `/work/mors`, отдельный build volume
в `/work`. Файлы checkout должны иметь LF. Подготовка требует сети; сами
обе компиляции, упаковка и smoke выполнены с отключённой сетью контейнера.

```sh
cd /work/mors
python3 scripts/qa/naiveproxy-prepare.py /work
# После подготовки отключить сеть build container.
export MORS_ENTWARE_TARGET=mipsel-3.4
python3 scripts/qa/naiveproxy-runtime-build.py "$MORS_ENTWARE_TARGET" /work/source /work/downloads
build="/work/source/src/out/mors-$MORS_ENTWARE_TARGET"
notices="/work/notices-$MORS_ENTWARE_TARGET"
output="/work/packages/$MORS_ENTWARE_TARGET"
python3 scripts/qa/naiveproxy-runtime-finalize.py "$build"
python3 scripts/qa/naiveproxy-notices.py /work/source/src "$build" /work/ca-materials "$notices"
python3 scripts/qa/naiveproxy-package.py "$build" /work/ca-materials "$notices" "$output"
ipk="$output/mors-naiveproxy_150.0.7871.63-1_$MORS_ENTWARE_TARGET.ipk"
python3 scripts/qa/naiveproxy-package-smoke.py "$ipk" --opkg /work/opkg
python3 scripts/qa/naiveproxy-tls-smoke.py "$ipk" "$output/tls-smoke.json"
```

Повторить для `aarch64-3.10`. Finalization и output-каталоги должны быть новыми.
TLS smoke двух ABI запускать последовательно: fixture использует фиксированные
loopback ports 18443-18449; между прогонами дождаться освобождения TCP ports.
При нехватке памяти ограничить build concurrency; проверка выполнена с 8 ГБ
WSL и двумя CPU. Полная сборка занимает существенно дольше упаковки.

Finalization удаляет debug/symbol build residue. У MIPSel LLD оставил 495
одинаковых GNU soft-float attribute records, которые GNU readelf отвергал.
Принимается только точная известная последовательность non-allocated records,
она сводится к одной записи. Program headers, runtime ELF header fields,
все allocated sections и их байты обязаны остаться неизменными; это проверяется
структурированным llvm-readobj JSON и hashes. Неизвестные attributes запрещены.
Исходный linked ELF и отдельный stripped ELF связаны receipt.

## Фактические проверки 27.09.2026

| ABI | IPK bytes | Package/QEMU/opkg | TLS fixture | Физический smoke |
| --- | ---: | --- | --- | --- |
| MIPSel | 4377242 | PASS | PASS | NC-1913 install/version/help/remove PASS |
| AArch64 | 4417747 | PASS | PASS | Pi 3 B+ version/help PASS |

Digests: [candidate lock](../builder/entware/naiveproxy-candidates.json).
Evidence: [MIPSel](research/platform-packaging-69/naiveproxy-mipsel-3.4.json),
[AArch64](research/platform-packaging-69/naiveproxy-aarch64-3.10.json).
Локальные IPK и полные manifests: `packages/naiveproxy/<ABI>/` (Git ignored).
Полные build logs, исходные linked ELF, link maps, preparation receipt и notices
сохранены в `packages/naiveproxy/issue69-runtime-evidence.tar.gz`, SHA-256
`e7fe69881b4781ff399a4edf79078c6fe36b1f935dd9ccfcc28c18898c290c3d`.

- Два независимых прохода упаковки одинаковых build inputs дали одинаковые
  IPK SHA-256. Это доказательство детерминированной упаковки, не двух cold builds.
- Payload/control/ABI/dependencies/modes/residue проверены после извлечения.
  Host opkg принимает свою architecture, отвергает обе чужие с `--noaction`.
- Оба SBOM прошли официальную CycloneDX 1.6 JSON Schema, specification commit
  `1ce97b2a7b8cf2429da248560d2aa671c6bce74a`.
- Loopback HTTP/2 CONNECT fixture проверил 7 TLS случаев: packaged CA отвергает
  private root; explicit custom CA и полная цепочка работают; неверное имя,
  expired, incomplete chain и неизвестный CA отвергаются. Nonce проходит только
  через CONNECT; UDP ASSOCIATE возвращает отказ. Временные ключи/процессы удалены.
- NC-1913: до/после установки и удаления совпали fingerprints firewall без
  counters, IPv4 rules/routes, конфигураций DNS и PID работающих runtime служб.
  После remove пакет, его файлы и пустые каталоги отсутствуют. Содержимое
  конфигов, адреса и fingerprints не публикуются. Домашний роутер не затронут.
- Static/ShellCheck/actionlint: PASS; BATS: 508/508 PASS; focused packaging
  Python tests: 9/9 PASS. Rust core не менялся; прежний fmt/clippy/tests/release
  PASS и три реальные core builds отражены в основном отчёте.

Установка пакета не активирует транспорт. QEMU fixture не доказывает production
padding, защищённый DNS, LAN egress, coordinator failover или upgrade/rollback.
Эти gates остаются отдельной работой (#81 и #116). AArch64 проверен физически
на Pi, не на AArch64 Keenetic. Новый MIPS BE NaiveProxy порт не реализован.
Никаких release/tag/push или закрытия issue не выполнялось.
