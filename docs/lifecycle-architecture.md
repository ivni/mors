# Lifecycle-архитектура Mors

Этот документ задаёт границы транзакций установки, настройки, обновления,
отката и удаления Mors. Пользовательские термины и exit codes определены в
`docs/cli-design-system.md`.

## 1. Инварианты

1. Установка IPK пассивна: до подтверждённого setup пакет не меняет DNS,
   firewall, маршруты, ipset, сервисы и компоненты Keenetic.
2. Никакая lifecycle-операция не удаляет рабочую версию до подготовки rollback.
3. Изменение отмечается завершённым только после проверки наблюдаемого
   состояния.
4. Потеря питания между двумя фазами оставляет достаточно данных для
   идемпотентного продолжения или восстановления.
5. Снимок содержит только затрагиваемое состояние. Широкий reset не является
   механизмом rollback.
6. Секретные снимки имеют режим `0600`, каталоги — `0700`; их содержимое не
   выводится в журнал, CLI, syslog или JSON.
7. VLESS lifecycle вызывает только component prepare/apply/verify/restore и не
   создаёт второй Xray process, Proxy interface или health state machine.

## 2. Источник истины

```text
/opt/etc/.mors/lifecycle/state.json
/opt/etc/.mors/lifecycle/transactions/<id>/journal.json
/opt/etc/.mors/lifecycle/transactions/<id>/snapshot/
```

`state.json` хранит только подтверждённое стабильное состояние. `journal.json`
хранит одну активную операцию и её фазу. Новая операция запрещена, пока
предыдущая не завершена или не восстановлена.

Минимальная схема state:

```json
{
  "schema_version": 1,
  "state": "unconfigured",
  "updated_at": "2026-07-12T12:00:00Z",
  "source": "package_install"
}
```

Минимальная схема journal:

```json
{
  "schema_version": 1,
  "id": "setup-1720785600-1234",
  "operation": "setup",
  "phase": "prepared",
  "previous_state": "unconfigured",
  "target_state": "ready",
  "started_at": "2026-07-12T12:00:00Z",
  "updated_at": "2026-07-12T12:00:00Z",
  "reboot_marker": null,
  "last_error": null
}
```

Запись выполняется через файл в том же каталоге, `chmod`, `sync` и atomic
rename. Journal создаётся сначала во временном каталоге и публикуется rename.

## 3. Фазы и crash-consistency

Для каждого изменяющего шага используется протокол:

1. записать pending intent;
2. применить идемпотентное изменение;
3. проверить ожидаемое наблюдаемое состояние;
4. записать completed phase.

Если процесс прерван после intent, recovery проверяет наблюдаемое состояние и
либо завершает тот же шаг, либо восстанавливает snapshot. Он не предполагает,
что шаг не выполнялся.

`completed` journal является durable commit marker. Если питание пропало между
его записью, обновлением `state.json` и удалением active marker, boot повторно
выводит стабильное состояние из `outcome` и идемпотентно завершает commit.

Общие фазы: `planning`, `prepared`, `awaiting_reboot`, `applying`, `verifying`,
`rolling_back`, `cleanup`, `package_remove_ready`, `completed`.

## 4. Setup

Setup разделён на read-only plan и apply:

1. read-only RCI inventory и сбор всех решений пользователя;
2. проверка пакетов, места, интерфейсов и кандидатов конфигурации;
3. snapshot затрагиваемого состояния;
4. установка необходимых системных компонентов;
5. при необходимости `awaiting_reboot` и явный `mors setup resume`;
6. подготовка неактивных конфигов и hooks;
7. короткая commit-фаза DNS/firewall/routes/services;
8. end-to-end verify;
9. запись `ready` последним действием.

Plan фиксирует точные `interface_cli`, `interface_entware`, `dns_backend` и
режим provisioning в journal до snapshot/apply. Для уже существующего тоннеля
apply повторно проверяет соответствие выбранного интерфейса live RCI. Для
управляемого VLESS target `Proxy21 / Proxy21` допускается отсутствие интерфейса
в read-only inventory, если системные компоненты Keenetic уже установлены:
после snapshot setup записывает intent, создаёт интерфейс, проверяет его через
RCI и только затем продолжает apply. Rollback удаляет интерфейс только при
наличии соответствующего intent в journal. После начала транзакции setup не
читает пользовательский ввод.

Пустой реестр VLESS не блокирует lifecycle setup. Xray запускается с
fail-closed конфигурацией без внешних outbound, lifecycle может перейти в
`ready`, а VLESS сохраняет собственное состояние `unconfigured` до добавления
первого соединения. Установка отсутствующих системных компонентов Keenetic не
подменяется provisioning интерфейса и остаётся отдельной предварительной
операцией.

До commit hooks находятся только под `/opt/apps/mors`. Boot/init в
`unconfigured` выполняют no-op. Все NDM/init/cron entrypoints дополнительно
проверяют lifecycle gate; временный apply-доступ действует только в дочернем
процессе владельца транзакции и не наследуется асинхронными router events.

Verify подтверждает выбранный интерфейс и DNS backend, работающие DNS-сервисы,
активные Mors firewall/ipset-объекты, policy rule и таблицу маршрутизации, а
также опубликованные hooks. Одного наличия CLI или конфигурационного файла
недостаточно для перехода в `ready`.

## 5. Uninstall

Штатный порядок:

1. snapshot и quiesce;
2. остановка Mors-сервисов;
3. удаление Mors DNS/firewall/routes/ipset и активных hooks;
4. проверка отсутствия активного dataplane;
5. фаза `package_remove_ready`;
6. `opkg remove mors`;
7. пассивный postrm cleanup.

`prerm remove` является safety gate: при активном dataplane, неизвестной фазе
или неуспешной проверке он возвращает ошибку и сохраняет пакет. `postrm` не
зависит от jq, библиотек Mors или сети. Пользовательские данные сохраняются без
`--purge`.

Для `unconfigured` используется отдельный пассивный remove-path: он сначала
подтверждает отсутствие Mors dataplane и hooks, затем вызывает `opkg remove`,
не останавливая DNS/VPN-сервисы и не очищая firewall/ipset.

Опциональный пакет удаляется только если lifecycle ownership record доказывает,
что его установил Mors. Обязательные зависимости остаются ответственностью
opkg и не переустанавливаются setup.

## 6. Upgrade и rollback

Upgrade использует in-place установку IPK. До вызова opkg сохраняются:

- текущий IPK либо проверенный rollback artifact;
- конфигурация и schema version;
- список активированных hooks;
- затрагиваемое runtime-состояние.

Artifact проверяется по опубликованному digest до lifecycle mutation. После
upgrade выполняются migration и health verification. Ошибка запускает rollback
на подготовленный artifact и snapshot.

После `opkg install` updater повторно загружает библиотеки установленного IPK,
выполняет migrations, обновляет активные копии hooks, перезапускает runtime и
только после полной lifecycle verification записывает успешный commit.

Для стабильного состояния `unconfigured` update использует тот же проверенный
artifact и rollback, но сохраняет target `unconfigured`: hooks и сервисы не
активируются, а commit требует подтверждённого отсутствия Mors dataplane.
Rollback также ветвится по `previous_state` и не пытается запускать runtime,
которого до операции не было. Runtime-миграции VLESS откладываются до
подтверждённого `setup`: пассивное обновление не создаёт Xray-конфигурацию.
Явный rollback и аварийное восстановление используют проверенный rollback IPK с
`opkg --force-downgrade`, поскольку SemVer-цель штатно может быть старше
установленного пакета. При повторном recovery пассивный runtime проверяется до
commit journal без преждевременной смены `recovery_required`; stable-state
возвращается в `unconfigured` только через `rollback_finish`. Восстановление
service-state идемпотентно: уже остановленный Entware-сервис не получает
повторный `stop`, чей ненулевой код не означает ошибку snapshot.

Первое обновление с legacy-версии не имеет старого journal. Новый `preinst`
создаёт bootstrap snapshot до замены файлов. Если старый IPK недоступен,
гарантируется восстановление конфигурации и безопасного dataplane, но не
бинарный rollback.

## 7. Locks и boot recovery

Порядок блокировок:

1. lifecycle;
2. test;
3. runtime mutation;
4. VLESS decision.

Lifecycle mutator не получает test lock. Boot выполняет:

- `ready` без journal — обычный init;
- `unconfigured` без journal — no-op;
- незавершённый journal — recovery до запуска runtime;
- неуспешный recovery — `recovery_required`, DNS и tunnel mutation не
  активируются.

## 8. Release gates

- BATS state/journal unit tests;
- CLI no-mutation tests для пустого вызова, help, version и syntax error;
- fault injection после каждой mutation boundary;
- package-layout проверка отсутствия активных hooks в системных каталогах IPK;
- реальные install/setup/reboot/update/rollback/uninstall проверки на
  авторизованном Keenetic;
- сравнение DNS, firewall, ipset, services и package inventory с baseline.
