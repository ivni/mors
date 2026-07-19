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
управляемого VLESS target `Proxy21 / t2s21` допускается отсутствие интерфейса
в read-only inventory, если системные компоненты Keenetic уже установлены:
после snapshot setup записывает intent, создаёт интерфейс, проверяет его через
RCI и только затем продолжает apply. Rollback удаляет интерфейс только при
наличии соответствующего intent в journal. Для intent `creating` отсутствие
`Proxy21` подтверждается несколькими ограниченными по времени чтениями RCI;
pending, foreign и изменившееся состояние остаются fail-closed в
`recovery_required` без автоматической мутации.

Точный legacy target `Kvas-proxy-vless` на `Proxy21` имеет отдельный intent
`legacy_vless`: setup меняет только его описание на `Mors-proxy-vless`, не
перезаписывая proxy protocol/upstream, системный ID и связанные политики, и
подтверждает новое описание через RCI. Rollback по intent также меняет только
описание обратно на `Kvas-proxy-vless`. Любой иной
`Proxy21` считается внешним конфликтом, не попадает в inventory и не может быть
автоматически заменён синтетическим target. После начала транзакции setup не
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

Dataplane считается готовым только по каноническим безусловным правилам:
home-interface PREROUTING jump не содержит дополнительных predicates или
инверсий, MARK устанавливает точную маску без фильтров, policy rule содержит
только ожидаемые `from all`, fwmark и table, а в policy table существует ровно
один IPv4 default route через выбранный интерфейс и сохранённый gateway. Он не
может быть `unreachable`, `blackhole`, `prohibit`, `throw` или `linkdown`.
Условное правило или соседний конфликтующий default не доказывают маршрутизацию
всей домашней сети.

Для DNSCrypt prepare меняет только файлы и выполняет bounded
`dnscrypt-proxy -check`. Commit сначала строит dataplane без рестарта DNS, затем один раз
запускает DNSCrypt и ждёт A-ответ на его локальном порту, после чего один раз
запускает dnsmasq и ждёт A-ответ через него. Повторная lifecycle verification
проверяет оба сервиса и оба DNS-пути. `/opt/etc/hosts` принадлежит snapshot,
должен быть обычным читаемым файлом `0644`; приватный журнал DNS cold-start
остаётся внутри каталога транзакции. Все lifecycle-вызовы Entware init-скриптов
проходят через общий wall-clock hard-bounded helper: deadline включает время
самих `status`, `stop`, `start` и readiness probes, а ограниченный KILL grace
резервируется внутри оставшегося бюджета. После исчерпания бюджета следующий
status/probe не запускается; timeout записывается в журнал транзакции.
Ненулевой результат действия всегда является ошибкой, даже если последующий
status совпал с целью. Неопознанный `status` немедленно сохраняется как `unknown`
и блокирует apply, потому что такой snapshot нельзя гарантированно восстановить.

При boot Entware может запустить первый health-cycle VLESS supervisor раньше
основного init Mors. `S96mors` ограниченно ждёт общий runtime-mutation lock,
после чего идемпотентно восстанавливает firewall и policy routes. Fail-fast
контракт интерактивных runtime-команд при этом не меняется.

Идемпотентный retry признаёт существующую цепочку готовой только при точном
совпадении полного упорядоченного semantic fingerprint: актуальных source и
destination exclusions, UDP/TCP и MARK-правил без затеняющих записей. Для MARK
он также повторно сверяет и восстанавливает policy table и `ip rule`, удаляя
конфликтующие defaults. Сообщение `iproute2`
`FIB table does not exist` означает штатное отсутствие ещё не созданной таблицы;
другой ненулевой результат чтения остаётся системной ошибкой. Ошибка snapshot
`iptables-save` никогда не интерпретируется как отсутствие jump-правила.

Пустой runtime lock не удаляется сразу, поскольку владелец мог ещё не успеть
опубликовать PID после атомарного `mkdir`. Если owner metadata не появляется
в течение минуты, lock считается следствием прерванного захвата и безопасно
пересоздаётся; lifecycle-команды явно сообщают о живом владельце или cold gate.

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

Develop-uninstall является таким же fail-closed: неизвестное состояние сервиса,
ошибка `stop`, удаления управляемого hook-файла или `opkg remove` прерывает
операцию и сохраняет ошибку вызывающей стороне.

Успешный setup сохраняет durable baseline исходного состояния сервисов.
Обновление существующей `ready`-установки при отсутствии baseline мигрирует его
из последнего успешного completed setup snapshot. Для более старого состояния,
где доказательный snapshot отсутствует, `unknown` не приравнивается к `stopped`:
uninstall сначала проверяет восстановленный resolver и запускает DNSCrypt только
если без него штатный DNS не отвечает.

Опциональный пакет удаляется только если lifecycle ownership record доказывает,
что его установил Mors. Обязательные зависимости остаются ответственностью
opkg и не переустанавливаются setup.

## 6. Upgrade и rollback

Upgrade использует in-place установку IPK. До вызова opkg сохраняются:

- текущий IPK либо проверенный rollback artifact;
- конфигурация и schema version;
- список активированных hooks;
- затрагиваемое runtime-состояние.

Candidate и rollback проверяются по опубликованным digest до lifecycle mutation.
Затем оба IPK вместе с sidecar копируются в защищённый transaction snapshot,
повторно проверяются против первоначальных fingerprint и классифицируются уже
из snapshot. `opkg` получает только эти immutable staged paths, поэтому подмена
исходного файла после prepare не меняет фактически установленный пакет. После
upgrade выполняются migration и health verification. Ошибка запускает rollback
только на staged artifact и snapshot.

После `opkg install` updater повторно загружает библиотеки установленного IPK,
выполняет migrations, обновляет активные копии hooks, перезапускает runtime и
только после полной lifecycle verification записывает успешный commit.

Для стабильного состояния `unconfigured` update использует тот же проверенный
artifact и rollback, но сохраняет target `unconfigured`: hooks и сервисы не
активируются, а commit требует подтверждённого отсутствия Mors dataplane.
Rollback также ветвится по `previous_state` и не пытается запускать runtime,
которого до операции не было. Runtime-миграции VLESS откладываются до
подтверждённого `setup`: пассивное обновление не создаёт Xray-конфигурацию.
Passive verifier запрещает managed telemetry hook и живой валидный sender, но
разрешает внешний operator-owned `S98mors-telemetry`, не исполняя и не изменяя
его.
Явный rollback и аварийное восстановление используют проверенный rollback IPK с
`opkg --force-downgrade`, поскольку SemVer-цель штатно может быть старше
установленного пакета. При повторном recovery пассивный runtime проверяется до
commit journal без преждевременной смены `recovery_required`; stable-state
возвращается в `unconfigured` только через `rollback_finish`. Восстановление
service-state идемпотентно: уже остановленный Entware-сервис не получает
повторный `stop`, чей ненулевой код не означает ошибку snapshot.

Перед восстановлением файлов snapshot rollback останавливает все сервисы,
которых не было в исходном снимке, пока их новые hook-файлы ещё доступны.
VLESS runtime использует принадлежащий Entware-пакету `xray` системный init
`S24xray`: Mors вызывает его bounded actions, но не создаёт, не заменяет и не
удаляет его файл. Legacy `S97xray` снимается только если exact symlink доказывает
ownership Mors; внешний одноимённый hook определяется до первой мутации setup,
классифицируется snapshot как `external`, не копируется и не изменяется rollback,
а для VLESS блокирует транзакцию. Snapshot хранит только managed legacy-файл для
rollback миграции. Xray и supervisor
дополнительно проверяются по процессам, поэтому удаление managed hook не может
оставить сиротский data-plane.
После каждого restore start/stop проверяется фактический poststate; ошибка
действия или несовпадение состояния оставляет lifecycle в recovery-required.

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
