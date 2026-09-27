# Supervisor общего ядра — issue #74

Дата проверки: 2026-09-27. База: `3102f6e` (`origin/main` при создании worktree).

Реализован `crates/coordinator/src/supervisor.rs`: один владелец состояния вызывает
`StickyHealth` из #70, последовательно передаёт решения исполнителю и публикует
целый `Frame` в volatile API #72. Код не устанавливает новый daemon на роутер.

## Исполнение и ограничения

- `Supervisor` владеет runtime, единственным `Publisher` и входной очередью.
  У CLI и hooks остаются клонируемые `Handle`; они не получают selector или
  mutable состояние. До 64 событий в очереди, до 16 событий за один turn,
  до 128 подключений, одна операция применения/восстановления и до 4 TCP probes.
- `submit` возвращает отдельный bounded receipt: `Accepted`, `Busy`,
  `RevisionConflict`, `Ignored`, `Stopped`. `Accepted` подтверждает принятие
  проекции конфигурации владельцем, а не успешное применение маршрутов.
  Сохранение реестра и публичный mutation IPC в эту задачу не входят.
  Во время операции изменение конфигурации получает `Busy`; повтор требует
  актуального expected revision. Hooks и CLI используют одинаковые правила.
- Startup всегда начинает с `Recover`; восстановленные preference/intent
  не становятся подтверждением здоровья. После восстановления выполняется
  общий selector, а active появляется только после успешного `Apply`.
  Любая неизвестная ошибка операции или deadline переводит состояние в
  `recovery_required`, отменяет workers и запрещает дальнейшее применение
  до нового экземпляра с восстановлением.
- `Runtime` — контракт неблокирующего dispatch/poll, проверяемый fake runtime.
  Рабочий адаптер обязан владеть исключительной lease исполнителя #73,
  проверять fence непосредственно перед эффектом и отображать volatile tickets
  в уникальные durable operation IDs текущего epoch. Tickets нового экземпляра
  не являются durable IDs. Отмена должна отозвать полномочия и освободить worker
  до возврата; слот нельзя освобождать с продолжающим работать старым worker.
  Ошибка dispatch не должна оставлять worker. Это обязательства будущего
  runtime, а не доказательство поддержки такого исполнения реальным backend.
- Clock передаётся в `tick(now)`; deadline имеет приоритет над готовым поздним
  результатом. Уменьшение времени/переполнение приводят к ошибке и recovery.
  `run` использует monotonic clock Publisher и interruptible `recv_timeout`.
  По умолчанию: interval 30 s, probe deadline 5 s, operation deadline 30 s,
  poll 100 ms. Poll ограничен 1 s и не превышает deadlines.
- Stop находится вне очереди и пробуждает owner даже при её переполнении.
  Drop отменяет оставшиеся workers. Stop завершает планирование; реальное
  снятие маршрутов/остановка сервисов принадлежит lifecycle #95.
- Probes используют общий health-контракт: primary failure, затем отдельные
  confirmation tickets. Обход списка циклический. Deadlines probes проверяются
  и во время применения решения. Пауза/изменение конфигурации отменяет старые
  probes и сбрасывает health generation. NaiveProxy не имеет UDP probe API;
  UDP capability остаётся `Unsupported`, selector требует блокировку UDP.
  Успешный TCP probe не поднимает admission gate автоматически.
- Применение сравнивает active, TCP path, UDP path и preference; смена лишь
  причины selector или повторный успешный probe не создаёт транзакцию.
  `preference_changed` разрешает запись preference только при изменении,
  после успешной проверки эффекта. Snapshot и health остаются volatile.
  Подтверждённая блокировка UDP публикуется только после успешного общего Apply.
- Status имеет отдельный read handle. Ни probe, ни ожидающая операция не
  удерживают snapshot lock. Добавлен `Publisher::publish_at` для управляемых
  часов; публикации с уменьшением времени отклоняются атомарно.

## Доказательства

`crates/coordinator/tests/supervisor.rs` содержит 13 тестов:

- recovery до selection, отсутствие persistent writes в стабильном состоянии
  и на повторных циклах probes;
- bounded/fair TCP scheduling и confirmation endpoints;
- stop при полной очереди, отмена и drop, настоящий wake/stop event-loop;
- deadlines, late completion, clock regression и backend failure;
- последовательные mutations, revisions и явные receipts;
- доступность status во время задержанного backend;
- deadline probes при незавершённом Apply;
- отклонение некорректной конфигурации до постановки в очередь.

В `crates/coordinator/tests/transaction.rs` добавлены две проверки с настоящим
`Executor<Memory, FakeNaiveProxy>` из #73: active после verify/commit и crash
в середине записи intent с последующим rollback до нового выбора. Этот bridge
поддерживает только начальное заблокированное состояние и fake NaiveProxy
activation, а не все production routing paths. Остальные 14 тестов исполнителя
сохраняют покрытие fencing, rollback, конфликтов и durable journal.

Проверки выполнены в Linux Docker на снимке Git с Unix permissions и LF:

- `bash scripts/qa/rust.sh`: fmt, Clippy с `-D warnings`, workspace tests,
  doc tests и release build — PASS.
- `bash scripts/qa/static.sh`: layout, secrets, line endings, syntax,
  ShellCheck, actionlint — PASS.
- `bats tests` — 508/508 PASS.
- Дополнительные финальные coordinator tests и Clippy после уточнения
  bounded receipts/повторных probe cycles — PASS.

## Граница внедрения

Shell supervisor, его decision lock #57, NDM hooks и init-скрипты не изменены.
Подключение нового процесса, OS ownership handoff, реальные cancellable workers,
startup/shutdown и маршрутизация остаются #95 и задачами backend. Нельзя запускать
этот owner параллельно с legacy selector без такого handoff. Изменение не
заявляет router smoke, production admission NaiveProxy или готовый IPK.
`Makefile`/`PKG_RELEASE` не менялись: файлы этого host-only компонента сейчас
не входят в устанавливаемое дерево `opt`.

### Стабилизация journal lease tests при публикации

Первоначально повторные прогоны старых unit tests `transaction_journal` иногда
возвращали `Busy` при немедленном открытии lease после drop на Windows bind
mount. Сбой воспроизведён на неизменённом `3102f6e` (третий повтор baseline
binary на bind mount); на Linux filesystem тот же baseline прошёл 20 повторов.
После публикации сбой проявился и на GitHub runner в QA run `36320071255`.
Следовательно, ограничение не специфично для Windows filesystem.

Параллельный fork/exec другого теста может временно удерживать унаследованный
flock-дескриптор до закрытия CLOEXEC при exec. Добавлена тестовая mutex-изоляция
lease fixtures: независимые unit tests журнала не пересекают это окно.
Явные проверки исключения между процессами и освобождения lease после crash
сохранены; production-код журнала и его контракт не менялись.

После исправления полный `scripts/qa/rust.sh` прошёл и с `target` на bind mount.
Отдельно выполнены 50 повторов всех девяти journal unit tests на bind mount —
50/50 PASS. Изменение ограничено тестовой изоляцией и этим отчётом.
