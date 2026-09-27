# Versioned реестр и secret store (#71)

`crates/storage` реализует `mors-storage` отдельно от domain, runtime и движков.
База реализации — `main` на `ba01681`. Контракт продолжает
[ADR-0001 §3–6](adr/0001-connection-core-boundaries.md).
Store не вызывает RCI, не генерирует конфиг движка, не выбирает active и не
публикует events. Shell, decision lock #57, `/opt` и пакет не изменены.

## Данные и границы

- Registry schema 1: общая revision и список подключений. ID — 128 случайных
  бит из Linux getrandom, представленных 32 hex-символами; имя отдельно от ID.
- Подключение: ID, тип, имя, enabled, confirmed, revision, optional profile.
  Черновик можно сохранить без profile; даже enabled-черновик не проходит
  `selection_candidate()`. Это только фильтр membership: подтверждённому
  профилю всё равно нужны capability/preflight/health gates перед выбором.
- NaiveProxy payload v1: host/port, auth reference, TLS server name, trust
  System либо custom CA reference/revision, TLS revision. URI, произвольные
  engine options и отключение TLS verification не поддерживаются.
  Auth bytes и CA bytes хранятся отдельно. Проверка содержимого auth/CA,
  совместимости и принятие TCP-only предупреждения принадлежат адаптеру/UX.
- VLESS и Shadowsocks payload v1 пока ссылаются на защищённый протокольный
  input; native VPN — на внутренний opaque ID observed object. Их полноценные
  протокольные модели/валидация остаются задачами адаптеров. Store не импортирует
  legacy VLESS registry и не превращает raw URI в подтверждённый профиль.
- Capabilities не записываются в durable registry: они выводятся из контракта
  backend и scoped evidence. Наличие NaiveProxy profile не доказывает TCP
  admission; пользовательский UDP остаётся unsupported по ADR.
- `Registry::snapshot()` возвращает только ID, kind, enabled, confirmed и
  revision. Имя, endpoint, auth/CA references и TLS данные туда не входят.
  Debug конфигурационных типов редактирован; ошибки — закрытый enum без путей,
  JSON-фрагментов и исходных значений. Прямая serde-сериализация Registry —
  приватный формат хранения, её нельзя использовать для CLI/events/telemetry.
  `read_secret()` — явный привилегированный доступ адаптера к bytes.

## Файловая безопасность и durability

Файловый backend доступен только на Linux. Caller заранее создаёт выделенный
owned каталог с mode 0700 и сохраняет его parent entry durable. Store::open
не создаёт/не исправляет каталог. Абсолютный путь обходится через openat по
компонентам с O_NOFOLLOW; final root проверяется на uid/mode, далее операции
привязаны к открытому directory fd. Каталог должен оставаться закреплённым за
координатором; замена/удаление самого root извне не является поддержанным API.

Файлы — regular, owned текущим effective uid, mode 0600, nlink=1;
symlink/hardlink/FIFO/directory targets отклоняются. Размер ограничен 4 MiB,
число записей — 4096 (защитные пределы формата, не runtime admission budget).
`unsafe` в crate запрещён; Linux syscalls выполняются через rustix.
Доступ другого root-процесса и злонамеренные записи того же uid не являются
изоляционной границей Unix permissions.

Store открывает отдельный fd на каталог для каждого flock: shared для чтения,
exclusive для записи. Отдельные Store и вызовы одного Store сериализуются.
Это не замена decision lock/transaction fencing координатора.

1. `put_secret` создаёт новый случайный `secret-ID` через O_EXCL/0600,
   пишет bytes, делает fsync файла и каталога. Существующие secrets неизменяемы.
2. `commit(expected_revision, desired)` перечитывает current под lock,
   проверяет CAS, схему, типы и доступность всех secret/CA references.
   Store назначает revision новым/изменённым записям и registry; смена kind
   существующего ID запрещена. Caller передаёт ненулевую revision записи,
   но конкретный следующий номер назначает только store.
3. Равное содержимое после нормализации порядка ID/revisions возвращается
   без записи. Чтение не создаёт registry/lock-файлы, не делает chmod/migration.
   ОС может обновлять atime; для запрета таких записей нужна mount policy.
4. Предыдущее полное содержимое сохраняется как `registry.previous.json`:
   случайный pending-файл → fsync файла → rename → fsync каталога.
5. `registry.json` заменяется тем же протоколом. Успех возвращается после
   fsync каталога. Ошибка после rename — `DurabilityUncertain`: перечитать
   current/revision перед решением о повторе, не считать операцию отменённой.

При сбое current остаётся целиком старым либо целиком новым; backup durable
до замены current. Незавершённый pending/secret-файл может остаться без ссылки,
но не включается в реестр автоматически. Схемы, отличные от 1, неизвестные поля,
дубли полей/ID и неизвестные payload versions отклоняются; current и новая
схема backup не перезаписываются. Автомиграции и schema downgrade отсутствуют.

## Backup и rollback

`registry.previous.json` — предыдущая принятая конфигурация, а не снимок
здоровья/active/RCI. `rollback(expected_revision)` читает backup и применяет его
как новую CAS-запись, с новой registry revision. Изменённые сохранившиеся записи
получают новую revision; возвращённые после удаления записи начинают с 1,
поэтому consumers обязаны использовать также registry revision для fencing.
Rollback не переписывает внешние объекты Keenetic и не восстанавливает runtime.

Все immutable secret/CA файлы сохраняются, в том числе после удаления профиля
или смены auth. Для автономного backup нужны согласованный registry и все
referenced secret/CA bytes с исходными ID/правами; export/import не входят в API
этой задачи. Протокол lifecycle backup/export и безопасный GC с учётом всех
rollback references остаются отдельной интеграционной работой. До неё
автоматическое удаление невостребованных secrets запрещено. Заполнение диска
возвращает ошибку и не выдаётся за успешный commit.

## Проверка

Проверки выполняются на Linux x86_64 в локальном Docker QA-образе с Rust 1.94.0:
fmt, clippy `-D warnings`, workspace tests, doc tests, release build.
Storage tests проверяют no-write reads/no-op, CAS/concurrent writers,
права и link hazards, схемы, missing references, redaction, rollback и
fault injection после file fsync, rename и directory fsync для backup/current.
Fault injection проверяет шесть границ, включая повтор после reopen.
Это проверка протокола и Linux filesystem API, не физическое отключение питания
USB-накопителя Keenetic. Router/Entware ABI, реальное power-loss испытание,
CLI/координаторная интеграция и удалённый CI не заявляются.

### Фактический результат 27.09.2026

- `bash scripts/qa/rust.sh`: exit 0, Rust 1.94.0, fmt, clippy без warnings,
  **34 теста workspace**, в том числе **12 storage tests** (11 integration и
  один fault-injection test с шестью точками), doc tests и release build.
- `bash scripts/qa/static.sh`: exit 0, включая ShellCheck и actionlint 1.7.12.
- `bats tests`: **508/508**, exit 0, BATS 1.10.0.
- Linux snapshot получен через `git -c core.autocrlf=false archive` и наложение
  файлов задачи. Форматированные Rust sources возвращены в worktree.
- Локальные журналы: `.qa/issue71-rust.log`, `.qa/issue71-static.log`,
  `.qa/issue71-bats.log`. `git diff --check` прошёл.
- Новые зависимости закреплены Cargo.lock; host QA сначала fetch --locked,
  затем frozen gates. ABI/toolchain/package admission этими тестами не доказан.
