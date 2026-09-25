# Закреплённый Rust в immutable builder (#67)

Builder сохраняет единственный release target `configs/aarch64-3.10.config`
и прежний выбор `mors_*_all.ipk`. Rust-каркас не включается в пакет.
Поставка ELF, production linkage и допуск остальных платформ остаются отдельными
задачами; наличие компилятора не доказывает запуск ядра на роутере.

## Входы и границы

[`rust-toolchain.json`](../builder/entware/rust-toolchain.json) закрепляет
patched Entware Rust 1.94.0-nightly, compiler commit, LLVM, SHA-256 исходного
архива, host/target ABI, GCC и обязательные target tools. Рецепт и все patches
закреплены revision `rustlang` в [`entware.lock`](../scripts/qa/entware.lock).
Host pin [`rust-toolchain.toml`](../rust-toolchain.toml) обязан иметь ту же
версию исходников, но не подменяет patched compiler обычным rustup target.

Эти файлы, build/verify helper и verifier входят в builder ID. Manifest содержит
Rust digest и явные значения версий/ABI/feed revision. Изменение исходников
Mors, Cargo.lock, package version или документации не меняет ID. Изменение
toolchain inputs требует нового образа. Существующий namespace `v1-<ID>` и
OCI digest resolution не меняются; прежний manifest без Rust полей отклоняется.

Runtime dependencies остаются в отдельном
[`runtime-dependencies.mk`](../builder/entware/runtime-dependencies.mk).
NaiveProxy — внешний runtime по #61/#62, не часть Rust toolchain; эта задача
его не скачивает и не добавляет. Его будущая упаковка должна иметь отдельный
pin/provenance, без `latest` и без загрузки на роутере.

## Сборка и проверка

[`entware-rust.py`](../scripts/qa/entware-rust.py) — host build helper
(Python 3.11+, уже доступен в Ubuntu 24.04 builder), а не логика Rust-ядра.

- `manifest` проверяет lock и печатает Rust-поля attestation.
- `build` проверяет чистоту и revision rustlang feed, версию/hash рецепта;
  вызывает закреплённые `rustc-dev/host/compile` и `rustc-dev/compile`, затем
  проверяет установленный toolchain. По умолчанию используется `-j2`; `JOBS`
  может задать другой положительный предел параллелизма.
- `verify` ничего не скачивает: сверяет `rustc -vV`, Cargo, patched target,
  sysroot, host/target `std` и `core`, наличие и запуск GCC/G++/ld/ar/ranlib/readelf,
  GCC version и target triple. Отсутствие любого обязательного элемента — ошибка.

Bootstrap/download/checksum policy принадлежит закреплённому Entware recipe,
включая фиксированный LLVM artifact. Toolchain строится только при создании
образа. Компиляция Mors package проходит через прежний verifier и прямой
package submake; автоматической установки Rust/rustup в этом пути нет.

[`Dockerfile`](../builder/entware/Dockerfile) получает только явно разрешённые
в [`Dockerfile.dockerignore`](../builder/entware/Dockerfile.dockerignore) входы.
Rust workspace, `.git`, локальная инфраструктура и credentials не добавляются
в context. В финальных слоях по-прежнему нет Mors source/IPK. В конце build
выполняется общий verifier. Package workflow запускает образ по OCI digest.

Общий verifier сравнивает manifest целиком с вычисленным из checkout:
устаревшие, отсутствующие, дублированные и неизвестные поля запрещены;
manifest не исполняется как shell-код. Fixture-проверки не являются проверкой
реального compiler/ELF и отмечаются отдельно от полной сборки образа.

## Локальная проверка

```sh
bats tests/entware_builder.bats
bash scripts/qa/static.sh
bats tests
```

Проверка 25.09.2026, база `origin/main` `921c76f`:

- Linux Ubuntu 24.04 в отдельном Docker-контейнере: полный `bats tests` —
  **498/498**, exit 0. После последнего усиления проверки библиотек повторно
  пройдены все **8/8** builder fixtures, включая пустую target `std`.
- `static.sh` — exit 0, включая ShellCheck 0.9.0 и actionlint 1.7.12;
  actionlint проверен по SHA-256 из QA workflow. Проверки выполнялись на LF
  снимке Git, без Windows CRLF-конверсии.
- `docker build --check --file builder/entware/Dockerfile .` — exit 0,
  предупреждений нет. Это проверка Dockerfile, не построенный образ.
- Отдельный пробный запуск `entware-rust.py build` поверх существующего OCI
  digest `sha256:5eb5bd38560cd981d4396a1b6f6f9988b0a0ee74620647bbfff23f3439c72b4e`
  прошёл проверку реального feed/recipe и начал загрузку закреплённых архивов.
  Дополнительный длительный прогон остановлен на загрузке исходников;
  полная компиляция Rust, установленный toolchain и новый OCI image **не проверены**.
  Это не отказ компилятора и не успешная image attestation. Для такого evidence
  требуется полный cold build Dockerfile с последующим verifier.
- Журналы хранятся локально в игнорируемом `.qa/`: `builder.log`, `bats.log`,
  `static.log`, `rust-build.log`. Router runtime, выпуск IPK и remote CI в этом
  прогоне не выполнялись. Существующие source/IPK и OCI-digest gates сохранены.
