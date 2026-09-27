# Транзакционный исполнитель с фиктивными адаптерами

Реализация [#73](https://github.com/ivni/mors/issues/73):
[исполнитель](../crates/coordinator/src/transaction.rs),
[Linux-журнал](../crates/coordinator/src/transaction_journal.rs),
[fake NaiveProxy](../crates/coordinator/src/fake_transaction.rs).
Основание: [ADR-0001 §5–6](adr/0001-connection-core-boundaries.md),
[реестр #71](connection-registry.md), [lifecycle](lifecycle-architecture.md).

Это отдельная библиотека моделирования транзакций. Она не запускает NaiveProxy,
не вызывает RCI и не меняет firewall, shell lifecycle или decision lock #57.
Fake принимает валидированный typed профиль NaiveProxy из Registry #71.
Секреты и сетевые параметры не копируются в план или журнал; реальные чтение
secret store, генерация config и проверка CA остаются границей адаптера.
Флаги config/CA/start/TCP/policy моделируют результаты этих проверок.

## Контракт исполнения

Executor владеет journal и adapter, методы изменения требуют исключительного
доступа. FileJournal держит неблокирующий эксклюзивный Linux flock на открытом
дескрипторе выделенного каталога весь срок жизни исполнителя. Второй процесс
получает Busy. Состояние блокировки существует только в ядре ОС; PID/lock-файлов
нет, при завершении процесса блокировка освобождается. Все будущие writers одной
подсистемы обязаны использовать один закреплённый каталог, который нельзя
переименовывать/подменять во время работы. Это не реализует передачу legacy locks.

1. Чтение журнала: незавершённая операция запрещает новую. Неизвестная схема,
   повреждение или неоднозначный результат I/O запрещают мутации.
2. Prepare собирает точный write set и исходные значения. Validate проверяет
   ревизию, owner epoch, ownership, config/CA и TCP/UDP policy.
3. Prepared сохраняется до первого эффекта. Перед каждым apply сохраняются
   Applying и attempted, включающий потенциально выполненный текущий шаг.
4. Адаптер непосредственно перед эффектом проверяет ревизию/epoch и точное
   наблюдаемое состояние. Fake делает атомарный CAS в памяти; это не доказательство
   наличия CAS в Keenetic RCI.
5. Verifying сохраняется до проверки наблюдаемого результата. Только успешный
   verify и durable Committed означают успешное завершение.
6. Отмена между шагами, ошибка apply/verify запускают scoped restore. Отмена
   после verify, но до commit также не объявляется успехом.

Plan содержит operation ID, owner, revision/epoch и пять типизированных ресурсов
fake NaiveProxy: UDP guard, config generation, CA generation, process generation,
TCP route. Для каждого записаны before, after и отдельное restored-состояние.
Проверяются порядок, размер, допустимые значения, ownership и переполнение
ревизий. Новые типы ресурсов и протокольные планы требуют расширения versioned
контракта; произвольные argv, RCI snapshot и shell строки не принимаются.

Ошибки — закрытый Reason: в частности RevisionConflict, OwnershipConflict,
Config, Ca, Start, Tcp, Policy, Cancelled, Journal, Unknown, RestoreConflict.
Failure отдельно сообщает recovery_required. Пользовательское CLI-представление
будет подключено вместе с mutation API; существующий CLI не расширяется.

## Восстановление и защита внешних правок

Перед первым restore сохраняется Restoring с полным write set. Шаги выполняются
в обратном порядке только до attempted. Для каждого ресурса:

- before означает отсутствие эффекта; restored — уже выполненный откат;
- только точное совпадение after разрешает запись restored;
- чужой owner, новая ревизия или другое значение сохраняются, результат —
  RecoveryRequired. Изменение и возврат прежнего значения также обнаруживаются.

TCP route откатывается перед process/config/CA. Если маршрут изменён извне,
его возможные зависимости не удаляются. Независимые owned шаги могут быть
восстановлены; глобального reset/копирования конфигурации нет. UDP остаётся
заблокированным; модель вообще не предоставляет значения скрытого direct.
TCP включается только после старта процесса и проверки TCP. Подтверждение TCP
не даёт capability пользовательского UDP.

Recovery не продолжает старый apply и не превращает незавершённую транзакцию
в успех, даже если все эффекты успели произойти. Он повторяет идемпотентный
restore. Смена boot/owner epoch запрещает шаги старого worker; новый владелец
может восстановить старый план с явно переданной текущей authority. Это всё
ещё требует неизменного ownership конкретных ресурсов. Смена владельца ресурса
не даёт новому executor права перетирать его.

Committed/RolledBack сохраняются как последний terminal record. Повтор текущего
operation ID отклоняется; полная история request-id/deduplication и IPC timeout
семантика находятся за рамками этого компонента.

## Durable journal

Выделенный существующий каталог: текущий effective UID, 0700, не tmpfs/ramfs.
Каждый компонент абсолютного пути открывается descriptor-relative с NOFOLLOW.
Файлы — regular, 0600, текущего UID, одна hard link, максимум 64 KiB.
Symlink, небезопасные права, special files и неизвестные поля отклоняются.

Запись: private pending file → write → fsync(file) → atomic rename →
fsync(directory). Ошибка любого этапа отравляет текущий writer: продолжать
мутации нельзя, требуется переоткрытие и recovery. Полный неопубликованный
первый Prepared допускается только к recovery; повреждённый pending остаётся
fail-closed. Существующий опубликованный журнал имеет приоритет над pending.
Частично записанные/неизвестные данные не исправляются автоматическим reset.

Журнал содержит только типизированные generation/revision/ownership и
классифицированные причины. Файлы реестра и secret store не заменяются.
Отсутствие журнала допустимо только для нового выделенного каталога;
удалять каталог с незавершённой транзакцией нельзя.

## Проверка

Тесты исполнителя: [transaction.rs](../crates/coordinator/tests/transaction.rs).
Проверки реального файлового журнала размещены рядом с реализацией.

Покрыты ошибки config/CA/start/TCP/policy, cancellation на каждой границе,
частичный apply каждого ресурса, interruption до/после каждого forward
journal save и restore save, восстановление после каждого отдельного restore,
revision/epoch drift между шагами, foreign/ABA edits, повторное recovery,
неизвестная схема, private metadata, повторное открытие файлового журнала,
межпроцессная блокировка и аварийное завершение процесса.

Файловые fault points: после write, fsync(file), rename и fsync(directory),
включая самое первое Prepared. Это программная fault injection на Linux,
а не испытание физического отключения питания Entware-накопителя.

База worktree: main 45d3a2e плюс разрешённый локальный коммит #71
4e4f6dc (после разрешения конфликтов с #72 — 986955a).
Публикация этой зависимости в main остаётся отдельным действием.


## Фактическая проверка 27.09.2026

- Linux x86_64, rustc 1.94.0 (4a4ef493e): scripts/qa/rust.sh — PASS:
  rustfmt, Clippy -D warnings, 70 workspace tests (включая subprocess helpers),
  doc tests и release build.
- В #73 добавлены 14 integration tests исполнителя и 9 tests файлового журнала,
  из которых два — точки входа дочернего процесса.
- scripts/qa/static.sh — PASS, включая ShellCheck и actionlint 1.7.12.
- BATS 1.10.0: 508/508, exit 0.
- git diff --check — PASS. Makefile/opt/hooks не изменены.
- Linux-снимок получен через git archive с core.autocrlf=false; исходники,
  отформатированные и проверенные в контейнере, возвращены в worktree.
- Локальные полные логи: .qa/issue73/rust.log, static.log, bats.log.
  Удалённый CI, router runtime и физическое отключение питания не проверялись.
