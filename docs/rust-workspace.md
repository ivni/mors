# Rust workspace: безопасный каркас (#66)

База: `main`, `1893eb7`. Границы соответствуют
[ADR-0001](adr/0001-connection-core-boundaries.md). Это исходники будущего
управляющего ядра, пока без daemon, IPC, сети, файлов состояния и router API.
Первый бинарник `mors-core` печатает только справку/версию; неизвестные и лишние
аргументы отклоняются с кодом 2 без отражения входных значений в stderr.
Без аргументов показывается справка. Версия `0.1.0` относится к каркасу,
а не к Entware-пакету или версии adapter contract.

## Границы crate

| Crate | Ответственность | Зависимости workspace |
| --- | --- | --- |
| `mors-domain` | Чистые типы capability, operation, transport и версия контракта | Нет |
| `mors-adapters` | Типизированный интерфейс engine adapter и каркас NaiveProxy | domain |
| `mors-platform` | Отдельная граница допуска platform routing | domain |
| `mors-coordinator` | Место будущего единственного владельца orchestration; пока только граница crate | domain, adapters, platform |
| `mors-core` | Безопасный бинарник help/version, пока без подключения coordinator | Нет |

Реестр/secret store, чистые health/selection, observability, typed lifecycle
prepare/apply/verify/restore/probe/drain и протокол команд реализуются в своих
последующих задачах. Пустая граница координатора намеренно не имитирует рабочие
транзакции. Адаптеры и platform не зависят от coordinator и не выбирают active.
Новые зависимости не должны превращать domain в слой I/O.

`NaiveProxy` сообщает TCP-only контракт; TCP admission и все операции остаются
`Unknown`, UDP — `Unsupported`. Это не доказательство готовности listener,
здоровья, допустимости платформы или graceful drain. В каркасе нет credentials,
генерации конфигурации, HTTP/2, TLS/Chromium, запуска процессов или direct fallback.
Будущему `Supported` потребуется evidence для конкретных OS/ABI/engine/operation
и успешный preflight по ADR; статического имени backend недостаточно.

## Toolchain и воспроизводимость

Для разработки и host CI закреплён upstream Rust **1.94.0** в
[`rust-toolchain.toml`](../rust-toolchain.toml), edition 2021; обязательны
rustfmt и clippy. Это версия исходников из [#60](research/rust-entware-spike.md),
но **не** patched Entware compiler и не доказательство router ABI.

Контракт будущей сборки Entware сохраняет lock #60:

- Entware `2d92d7c0b4055cb27901025f8a08d2e6344e849e` и rustlang feed
  `379fa6ff578506a50e3158b92ac2c09bc22cb450` из
  [`entware.lock`](../scripts/qa/entware.lock).
- Rust source 1.94.0, SHA-256
  `b83f921cd3f321ff614f9c06a8b870d89299fc02888b48a5549683a36823474c`.
- Patched stage1 #60: `1.94.0-nightly`, commit
  `4a4ef493e3a1488c6e321570238084b38948f6db`, LLVM 21.1.8.
- Отдельные Entware std/GCC 8.4.0/sysroot, glibc 2.27 для трёх ABI;
  плавающий `nightly` и stock rustup MIPS target не заменяют этот lock.

Постоянный cross-builder и окончательный dynamic/static linkage — #67;
до получения ELF/dependency/loader evidence production linkage не выбран.
Host release binary не включается в нынешний `all.ipk`. Rust нужен только
на машине сборки; установка toolchain на роутер не добавляется.

Внешних crate нет. Все workspace dependencies локальные; `Cargo.lock`
хранится в Git. Проверки используют `--frozen` (locked + offline), поэтому
не могут скрыто обновить lockfile или скачать dependency. Это воспроизводимость
dependency resolution, не обещание побитового совпадения ELF между разными host.

## Проверка

На host с rustup, Bash и установленным toolchain:

```sh
rustup show active-toolchain
bash scripts/qa/rust.sh
bash scripts/qa/static.sh
bats tests
```

`rust.sh` — единый вход fmt, clippy с запретом warnings, unit/integration/doc
tests и release build. CI запускает его отдельным обязательным job в reusable
`qa.yml`; существующий release gate получает этот job через workflow_call.
Static/BATS не исполняют router scripts на host. Сам static.sh не требует Rust,
поэтому существующие shell-only проверки остаются доступны отдельно.

Makefile, `/opt`, shell dispatch, NDM hooks, decision lock #57 и пакетная версия
не меняются. Подключение ядра к lifecycle и поставка ELF — отдельные gates.

## Фактическая проверка 25.09.2026

- Windows x86_64/MSVC, upstream rustc 1.94.0 (`4a4ef493e`): единый `rust.sh`
  прошёл fmt, clippy `-D warnings`, 1 adapter unit test, 2 CLI integration tests,
  doc tests (примеров пока нет) и release build. Повтор с намеренно неверным
  `RUSTUP_TOOLCHAIN` также прошёл: скрипт выбирает pin явно.
- После запуска Docker выполнен полный Linux-прогон в отдельном контейнере
  Ubuntu 24.04 (Docker 29.8.0), на снимке текущих изменений в Linux filesystem.
  Для `git archive` явно задан `core.autocrlf=false`, чтобы Windows-конверсия
  не добавляла CRLF в shell scripts при переносе снимка.
- Linux x86_64/GNU, upstream rustc 1.94.0 (`4a4ef493e`): `rust.sh` прошёл
  fmt, clippy `-D warnings`, 1 adapter unit test, **3 CLI integration tests**,
  включая non-UTF8 argv, doc tests и release build с `--frozen`.
- Linux `static.sh` прошёл полностью: ShellCheck 0.9.0, actionlint 1.7.12
  (архив проверен по SHA-256 из workflow). Windows static также прошёл
  с ShellCheck 0.11.0 и actionlint 1.7.12.
- Полный Linux `bats tests`: **493/493, exit 0**, BATS 1.10.0, jq 1.7.
  Отказы Unix permissions/symlink из предыдущего Windows-прогона не повторились;
  runtime-файлы и существующие тесты для этого не изменялись.
- Журналы сохранены локально в игнорируемых `.qa/linux-rust.log`,
  `.qa/linux-static.log`, `.qa/linux-bats.log`; временный контейнер удалён.
  Удалённый GitHub Actions проверяется отдельно для опубликованного commit SHA;
  результат публикации фиксируется в issue #66. Локальный Linux-прогон
  не выдаётся за удалённый CI.
- `git diff --check`, LF новых файлов, ссылки документа и отсутствие изменений
  в Makefile/opt проверены. Router/Entware ELF и runtime acceptance не измерялись.

Локальные проверки каркаса завершены. Выпуск пакета и включение нового runtime
в эту задачу не входят.
