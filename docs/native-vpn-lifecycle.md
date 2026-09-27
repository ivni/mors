# Native lifecycle штатного VPN (#77)

Реализованы `mors_adapters::native` (start/stop/observe и alias-only RCI Source),
`mors_coordinator::native` (закрытые ошибки) и `native_transaction` (durable grant,
намерение пользователя и recovery). База изолированного worktree — main `a522e79`.
Компонент рассчитан на **уже подготовленный** клиентский VPN с назначенным alias.
Назначение alias/пользовательский adoption — #92; installed CLI, supervisor и init
здесь не включаются, протокольные параметры не настраиваются.

## Согласованный контракт идентичности

27.09.2026 пользователь выбрал управление через уникальный alias с ограничениями
после опытов, исключивших If-Match, RCI index и сохранённый CLI-контекст.

- Authority — durable grant и случайный alias `Mors` + 32 lowercase hex (128 bits).
  `fresh_alias` использует CSPRNG из storage. Alias не является секретом.
  `Owned` также фиксирует canonical ID, system name, тип, owner/epoch/incarnation.
  Последние три поля — **локальные** поколения, не аппаратный incarnation Keenetic.
- Подготовка должна подтвердить платформенный контракт, client role/egress,
  назначить alias с явным согласием и сохранить прежнее имя для будущего release.
  `LocalNative::new(binding, validated_client)` требует это подтверждение;
  discovery, имя, тип интерфейса или найденный listener его не заменяют.
  Сам lifecycle никогда не делает rename/create/system configuration save.
- Observe проверяет `/rci/interface/<canonical-id>/rename`, затем read-only
  inventory `/rci/show/interface`: alias, ID/type/system name должны совпасть.
  Перед каждой записью проверки повторяются, включая административное prestate.
  Запись — **только** POST `/rci/interface/<alias>` с `{"up":true}`/`{"down":true}`.
  Fallback на canonical ID, retry через другой endpoint и глобальный reset запрещены.
- Обычное удаление/пересоздание canonical ID теряет alias и не получает authority.
  Missing/mismatched alias или binding отзывает grant. Возвращение прежнего ID
  не снимает отзыв; новое принятие — отдельная явная операция.
- **Ограничение:** копирование/восстановление самого alias вместе с прежними
  ID/type/system name на новый объект надёжно не различается. Alias нельзя
  переносить извне; перед восстановлением конфигурации grant нужно отозвать,
  затем заново принять VPN. Тест явно фиксирует эту неразличимость.
- Mors сериализует собственные writes, но RCI не даёт CAS против веб-интерфейса.
  Известный до POST admin-state drift возвращает RevisionConflict, не отзывает
  ownership и не перетирается. Изменение после последней проверки может конкурировать
  с явной командой пользователя Mors; это не обещание атомарности GET+POST.

Исходные VPN-параметры, прочие интерфейсы, маршруты, firewall и процессы не меняются.
Native data path остаётся отдельным: участие рядом с NaiveProxy не включает SOCKS
и не даёт права управлять чужим процессом. Shell decision lock #57 сохранён.

## Состояния и транспорт

Ready требует state=up, link=up, connected=yes. Down — state=down. Неполные и
переходные данные — Unknown. Ready здесь означает состояние интерфейса; TCP/UDP
probe, protected DNS и допуск к маршрутизации остаются самостоятельными проверками.

Start/stop завершаются по observed poststate. Успешная команда без нужного состояния
даёт Timeout. Повтор на достигнутом состоянии не пишет. Уже административно поднятый
VPN только наблюдается, без reset. AutomaticStart не снимает admin-down и фактически
не посылает up: для выключенного интерфейса нужен явный UserStart.
ExcludeFromPool не вызывает Source и не останавливает VPN.

Единый deadline ограничен 60 секундами. Linux Source использует fixed loopback
`127.0.0.1:79`, отключает environment proxy/redirects, ограничивает каждый ответ
1 MiB и передаёт остаток времени curl. HTTP, malformed/semantic RCI и неизвестный
эффект не становятся успехом. Семантическая ошибка проверяется и при HTTP 200.
Пустой rename означает отсутствующий alias. Ошибки не несут тела ответа/секретов.

## Durable grant и recovery

`grant` сохраняет явное принятие после проверки подготовленной binding. Повторный
grant не заменяет имеющийся. Native schema **2** содержит binding, revision,
operation ID, exclusion, user-down, фазу и закрытую причину. Schema 1 из раннего
неопубликованного прототипа отклоняется: автоматического получения alias нет.
Журнал не содержит протокольного payload, endpoint, credentials или router config.

`execute` проверяет expected revision и возрастающий operation ID. Prepared и
Applying сохраняются до backend. Намерение StopVpn сохраняет user-down даже при
неопределённом эффекте и переживает restart. Committed записывается только после
poststate. Любой сбой save отравляет executor до переоткрытия и recovery.

Recovery **не пишет в роутер**, не повторяет interrupted operation и не делает
inverse up/down. Наблюдаемое Ready/Down с прежней binding даёт Reconciled, не
Committed: успех прерванной команды не утверждается. Down сохраняет запрет
автоматического подъёма; Unknown оставляет recovery pending. OwnershipConflict
постоянно отзывает grant. Повторное recovery не меняет интерфейс.

Файловая механика #73 переиспользована через `RecordJournal<R>`: directory flock,
private 0700 каталог, descriptor-relative NOFOLLOW, regular single-link 0600 файлы,
лимит 64 KiB, write/fsync/rename/fsync и poison. Native использует
`native.json`/`.native.pending`, прежняя proxy-схема —
`transaction.json`/`.transaction.pending`. Один каталог даёт общий flock,
разные файлы не перезаписывают друг друга при передаче lease.

Интеграционный gate: единый coordinator должен передавать общий lease и проверять
recovery **всех** журналов до новых межпротокольных операций. Нового supervisor нет;
этот модуль не объявляет всё runtime wiring выполненным.

## Проверка и границы доказательств

Подробности опытов, источники и очищенный live-result:
[исследование RCI/NDM](research/native-vpn-77.md),
[результат Rust → RCI](research/native-vpn-77-rust-live.json).

Contract tests покрывают Ready/Down/Unknown, повторы, deadline, user-down,
owner/epoch/alias drift, reuse ID, неизвестный эффект, exclusion, точные HTTP пути
и payload, semantic/HTTP/malformed errors, исчезновение alias между preflight/POST,
запрет canonical fallback и явную границу скопированного alias.
Durable tests покрывают каждую границу save, poison/reopen, stale revision/dedup,
external down, отзыв grant, unknown recovery, реальный Linux journal и общий flock.

На NC-1913 OS 5.0.12 production Rust backend и native executor работали из Linux
x86_64 контейнера через прозрачный loopback HTTP relay и SSH-туннель. Выполнены
реальные up/down временного PPTP77, повтор stop, timeout вместо ложного Ready,
recovery после внешнего down, запрет automatic start, reuse ID и отзыв grant.
После cleanup checksum всей конфигурации интерфейсов совпал с исходным.
Это live RCI integration, **не** запуск MIPSel ELF на роутере. Состояние Ready
проверено только fixtures; Internet egress native VPN не проверялся: тестовый PPTP
не содержал сервера или credentials.
Новые пакеты/компоненты на роутер не устанавливались; startup-config не сохранялся.

Финальная проверка 27.09.2026: `scripts/qa/rust.sh` PASS (fmt, Clippy -D warnings,
workspace/all-target/doc tests, release build), включая 34 новых native tests;
`scripts/qa/static.sh` PASS с ShellCheck/actionlint; BATS 508/508 PASS;
`git diff --check` PASS. После нормализации LF повторены static/fmt.
Полные локальные логи: `.qa/issue77/rust.log`, `static.log`, `bats.log`.
Временные PPTP77/PPTP78 и диагностический ELF удалены; SSH tunnel закрыт.
Entware IPK и Rust MIPSel ELF не собирались. Результаты выше относятся к локальной
проверке до публикации.
