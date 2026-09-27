# Volatile snapshot и локальный API чтения (#72)

База: `main`, `ba01681` (#71). Реализация —
[`snapshot.rs`](../crates/coordinator/src/snapshot.rs) и
[`local_api.rs`](../crates/coordinator/src/local_api.rs), согласно
[ADR-0001 §3–4](adr/0001-connection-core-boundaries.md).

## Владение и согласованность

`channel(boot_id, preference)` возвращает единственный `Publisher` и клонируемый
`Reader`. Вызывающий coordinator обязан задавать новый непрогнозируемый ID
инкарнации при каждом старте, включая перезапуск в пределах одного boot ОС.
Сравнение sequence между разными boot_id запрещено. Источник монотонного времени
для worker observations и deadlines — `Publisher::now()`.

Writer публикует полный `Frame` завершённого цикла, а не результаты отдельных
workers. Config revision, observed generation, lifecycle, transaction, active,
preference, transport health, таймер следующего probe и наблюдаемая защита UDP
заменяются под одним write lock. Sequence увеличивается только при успешной
публикации. Ошибка валидации сохраняет предыдущий снимок. Дубли ID, будущие
observations, несовпадение health generation, регресс общей revision/generation
и неподдерживаемая комбинация Naive/UDP отклоняются. Отбрасывание устаревших
worker results перед публикацией остаётся обязанностью владельца и #71.

Reader удерживает read lock на время ограниченной сериализации: это одна
revision и один момент чтения. Чтение не обновляет timestamps, sequence,
таймеры, счётчики или event cursor. Возраст вычисляется по монотонным часам;
`observed_unix_ms` фиксируется writer только для отображения и не участвует
в freshness. Невозможное wall time представляется null.

После старта preference не становится active: lifecycle `starting`, пустые
наблюдения, current_active=null. В paused/unconfigured/changing/recovery_required,
при active transaction и после TTL снимка выводятся not_ready, null active,
неподтверждённый TCP и unknown applied UDP protection. Старая preference остаётся
отдельным полем. Устаревшее транспортное наблюдение получает `stale`, пока сам
снимок ещё свеж; неизвестное/unsupported capability не становится healthy.

`tcp_ready` означает свежий успешный TCP probe, а не полный routing admission.
`admitted` приходит от coordinator. Для Naive UDP capability всегда unsupported;
`protected_udp=blocked` приходит только из наблюдённого результата routing,
не выводится из успешного TCP или наличия типа NaiveProxy.

## Транспорт и схема v1

Linux `Server::bind` принимает готовый абсолютный путь отдельного root-owned
каталога 0700 на **tmpfs**, отклоняет symlink/другую файловую систему и создаёт
`read.sock` 0600. Каталог не создаётся автоматически. `/opt/var/run` не считается
RAM по имени. Bind/chmod/cleanup используют удерживаемый directory FD;
существующий socket не удаляется и не заменяется. При аварии cleanup оставшегося
socket принадлежит будущему lifecycle, с проверкой ownership.

Обе стороны проверяют Linux `SO_PEERCRED`, UID=0. Права файловой системы —
дополнительный барьер. TCP listener, shell, запуск core и fallback отсутствуют.
`serve_one()` обслуживает максимум один клиент; WouldBlock означает отсутствие
клиента, его обработка принадлежит event loop будущего coordinator.

Один запрос — одна ASCII-строка, один JSON-ответ, затем закрытие соединения:

```text
MORS/1 handshake\n
MORS/1 status\n
MORS/1 list\n
MORS/1 events\n
```

Handshake перечисляет protocol_version и операции. Иная версия/грамматика,
mutation или произвольные данные возвращают закрытый `invalid_request` без
отражения ввода. Status и list возвращают один полный snapshot, включая
connections; разделение пользовательских представлений выполняет будущий CLI.
Events возвращает ту же snapshot metadata и последние классифицированные события.

Metadata: boot_id, sequence, config_revision, observed_generation,
observed_at_ms, observed_unix_ms, read_at_ms, age_ms, stale, lifecycle,
not_ready, active_transaction, current_active, preference.
Connection: opaque numeric ID, generation, backend enum, intent/admission/drain,
TCP/UDP capabilities и health, timestamps, latency/counter, next_probe_at_ms,
tcp_ready и protected_udp. Схема не имеет произвольных строк для имени,
endpoint, config, credentials или stderr. Это внутренний IPC, не замена JSON
envelope продуктового CLI из [#65](connection-pool-ux.md).

`query()` возвращает CoreUnavailable при отсутствующем/неотвечающем core,
AccessDenied при запрещённом доступе, InvalidResponse при нарушении рамки ответа.
Ни один исход не читает durable health и не запускает старый supervisor.

## Лимиты и I/O

| Ресурс | Ограничение компонента |
| --- | --- |
| Connections | 128; лишние отклоняются целиком, retained Vec capacity сжимается |
| Events | 256; старые вытесняются, dropped_events явно сообщает потерю |
| Snapshot TTL | 90 000 ms; transport freshness дополнительно задаёт HealthPolicy |
| Request | 32 bytes; неизвестные строки не сохраняются |
| Response | 128 KiB, поля и число строк ограничены схемой |
| Clients | Последовательное обслуживание, listen backlog 8; без worker threads |
| I/O deadline | 250 ms на запрос/ответ; пересчитывается перед каждой операцией |

Это защитные host-лимиты компонента, **не измеренный product budget роутера**
(#117). Client connect неблокирующий: заполненный backlog не создаёт бессрочного
ожидания. Events — локальное volatile окно наблюдений, не durable причинный
журнал и не обещание сохранности событий #110/#111. Чтение окна недеструктивно.
Probe cycle не требует записи snapshot на флешку. Значимый commit/preference
сохраняется отдельным будущим durable writer; этот компонент не выдаёт за него
запись события в RAM.

## Проверка и границы

В изолированном Linux x86_64 контейнере, Rust 1.94.0:

- `scripts/qa/rust.sh`: fmt, clippy `-D warnings`, 35 unit/integration tests,
  doc tests и release build.
- `scripts/qa/static.sh`: package layout, secret scan, LF, shell syntax,
  ShellCheck и actionlint; полный `bats tests`: **508/508, exit 0**.
- Новые 13 tests: согласованность 8 concurrent readers с 500 публикациями,
  reboot/preference, lifecycle/staleness, TCP/UDP distinction, лимиты, overflow,
  read-only socket, malformed input, deadline и отказ UID 65534 даже после
  намеренного ослабления прав socket до 0666.
- `scripts/qa/read-api-io.sh` запускает Linux socket tests как root, затем
  проверяет strace участка 100 запросов: 200 socket sends, **нет filesystem
  access, durable writes и сетевых probes**. Setup/cleanup сокета вне участка.
  Gate добавлен в host CI; обычный непривилегированный test run не заменяет его.

Компонент пока не подключён к `mors-core` help/version binary или shell CLI.
Daemon, lifecycle/ownership handoff и продуктовые команды — #73/#95/#99/#101;
выпуск/Entware linkage/проверки router ABI и resource admission — отдельные gates.
Новые зависимости: безопасные Linux wrappers `rustix`; `serde_json` только для
tests. Их версии/checksums закреплены Cargo.lock; host CI делает отдельный
`cargo fetch --locked`, затем frozen checks. Проверка компонента не доказывает
готовность Entware image или runtime на роутере. `opt/`, Makefile и legacy
decision lock #57 не изменены.
