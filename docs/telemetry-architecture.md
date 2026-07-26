# Архитектура телеметрии Mors

Документ задаёт границы opt-in доставки эксплуатационной телеметрии Mors в
Monium. Публичное поведение CLI определено в `docs/cli-design-system.md`.

## 1. Цель и границы

Телеметрия нужна для наблюдения за реальным состоянием Mors во времени:

- lifecycle и доступность runtime;
- активное и резервные VLESS-соединения;
- задержки, последовательные ошибки и автоматические переключения;
- состояние Xray и supervisor;
- агрегированные счётчики трафика без адресов клиентов и назначений;
- состояние самой доставки.

Телеметрия не является частью маршрутизации. Sender работает отдельным
процессом, использует только read-only snapshots и никогда не вызывает
`mors vless check`, не будит supervisor, не меняет Xray balancer и не держит
runtime mutation lock. Любая внутренняя ошибка telemetry завершается локально и
не меняет работу Mors.

## 2. Контракт Monium

Источник истины — официальная документация Monium:

- OTLP: <https://yandex.cloud/ru/docs/monium/collector/otlp-protocol>;
- логи приложений: <https://yandex.cloud/ru/docs/monium/logs/quickstart>;
- ограничения: <https://yandex.cloud/ru/docs/monium/logs/limits>;
- метрики по логам: <https://yandex.cloud/ru/docs/monium/logs/aggregates>.

Mors отправляет OTLP/HTTP JSON методом POST на фиксированный endpoint
`https://ingest.monium.yandex.cloud/otlp/v1/logs`. Запрос содержит:

- `Authorization: Api-Key ...`;
- `x-monium-project`;
- `x-monium-cluster`;
- `x-monium-service`;
- `Content-Type: application/json`.

TLS-сертификат всегда проверяется. Пользовательский endpoint, отключение TLS
verification и произвольные HTTP-заголовки не поддерживаются.
Публичные entrypoint Mors принудительно закрепляют endpoint и системные пути
sender/curl/jq/lifecycle: одноимённые environment variables игнорируются.
`curl` запускается с `-q`, поэтому пользовательский `.curlrc` также не может
добавить proxy, header, trace или перенаправить запрос. Proxy environment также
сбрасывается только внутри sender: он всегда использует обычную маршрутизацию
самого роутера, не изменяя proxy/custom-CA окружение команд update, VLESS и
других подсистем Mors.

На роутер не устанавливаются OTel Collector или Fluent Bit. JSON строится через
`jq`, а доставка выполняется существующим dependency `curl`. Payload следует
стабильной OTLP JSON-схеме `ExportLogsServiceRequest`:

```text
resourceLogs[] -> scopeLogs[] -> logRecords[]
```

Размер одного payload ограничен 512 KiB, отправляемого batch — 4 MiB, что
существенно ниже лимита Monium 8 MiB. Записи старше 20 часов удаляются из локальной очереди до отправки,
поскольку Monium не принимает логи старше 24 часов.

## 3. Данные и privacy

Payload создаётся только из белого списка полей. Постфактум-маскирование сырого
лога не считается защитой.

Разрешены:

- версия Mors и schema;
- случайный локальный `service.instance.id`;
- семантическое состояние lifecycle/VLESS;
- непривилегированный внутренний connection ID;
- роль active/standby, latency и числовые failure counters;
- тип и безопасная причина события VLESS;
- агрегированные packet/byte counters;
- булевы статусы Xray/supervisor;
- код HTTP и классифицированная причина ошибки sender.

Запрещены:

- VLESS URI, UUID, Reality public key/short ID и server address;
- API-ключ Monium и заголовок Authorization;
- внешний, клиентский и router management IP;
- домены, DNS-ответы, URL назначения и raw Xray access log;
- содержимое `/opt/etc/mors.list`, syslog и пользовательских конфигов;
- shell command line, stack trace и произвольный stderr сторонней команды.

Connection name не отправляется: для группировки используется внутренний ID.
Полный debug остаётся локальной диагностикой и не транслируется.

## 4. Хранилища

```text
/opt/etc/mors/telemetry/config.json       несекретная конфигурация, 0600
/opt/etc/mors/telemetry/monium.key        API-ключ, 0600
/opt/etc/mors/telemetry/curl.conf         защищённый curl config, 0600
/opt/var/lib/mors/telemetry/outbox.jsonl  bounded offline queue, 0600
/opt/etc/mors/telemetry/cursor            cursor VLESS events, 0600
/tmp/mors/telemetry/state.json            производное runtime state в RAM, 0600
/opt/var/run/mors/telemetry/sender.pid    защищённый PID, 0600
```

Каталоги имеют mode `0700`. Конфигурация и curl config публикуются атомарно.
API-ключ сначала проверяется как одна непустая строка без управляющих символов,
затем копируется из интерактивного ввода или `--key-file`; ключ никогда не
передаётся как аргумент процесса.

Очередь заполняется только после неуспешной доставки либо пока в ней уже есть
старые записи. Временные payload, проверка очереди и каждоминутное производное
состояние живут в `/tmp`. Неизменившаяся очередь не заменяется, новый payload
добавляется без полного rewrite, неизменившийся event cursor не переписывается,
а опустевшая очередь удаляется сразу после подтверждения. Поэтому длительная
ошибка Monium не превращается в ежеминутную перезапись всего файла на USB.

Queue ограничена одновременно 1000 payload и 16 MiB. Когда любой предел
достигнут, уже сохранённые записи остаются в порядке поступления, а новый sample
отбрасывается без записи на USB; sender до перезагрузки сохраняет в RAM липкие
`queue_overflow=true` и `dropped_samples`, отдельно оставляя в `last_error`
актуальный результат доставки, и продолжает пытаться освободить очередь. Повреждённые,
просроченные и выходящие за закрытую privacy-схему строки удаляются. Перед
enqueue и непосредственно перед delivery проверяются исчерпывающие наборы body,
resource/scope и attribute keys/types/lengths; произвольный структурно похожий
OTLP JSON не пересылается.

## 5. Доставка

Sender раз в 60 секунд:

1. валидирует config schema и защищённые права;
2. читает только подтверждённые snapshot-файлы и процессное состояние;
3. строит summary и по одной connection-health записи на соединение;
4. добавляет новые безопасные VLESS events после cursor;
5. если очередь пуста, сначала пытается доставить текущий batch без записи на
   flash;
6. при ошибке добавляет compact payload в очередь; незавершённая после power
   loss строка отбрасывается следующей проверкой;
7. если очередь непуста, отправляет bounded batch старых записей по порядку;
8. удаляет подтверждённые записи только после HTTP 2xx без OTLP partial reject.

Retry выполняется последующими циклами. Ошибки классифицируются (`dns`, `tls`,
`timeout`, `http_4xx`, `http_5xx`, `partial_reject`, `invalid_response`) без
сохранения необработанного ответа сервера. Доставка имеет семантику
at-least-once для принятого в очередь payload: после неопределённого сетевого
результата возможен повтор. При исчерпании явного queue limit новый sample может
быть отброшен, чтобы не повреждать USB. Каждая запись получает стабильный
`mors.event.id` для поиска дублей.

## 6. Жизненный цикл

IPK-установка пассивна и не включает telemetry. `enable` разрешён только при
lifecycle `ready`, атомарно готовит конфигурацию, создаёт init symlink и запускает
sender после успешного test delivery. Если test не прошёл, конфигурация может
быть сохранена, но сервис не объявляется включённым.

`disable` доступен даже при `recovery_required`, поскольку оператор всегда
должен иметь возможность остановить внешнюю передачу. Uninstall сначала
останавливает sender и удаляет только точную managed init symlink. Неожиданный
operator-owned path никогда не выполняется и не удаляется: valid Mors config
всё равно выключается, а команда возвращает recovery-ошибку. Full purge удаляет credentials,
cursor и queue; обычное удаление пакета сохраняет закрытую конфигурацию вместе
с остальными данными Mors, но не оставляет запущенного процесса или hook.

`enable`, `disable`, `test`, upgrade, rollback и uninstall используют общий
внешний lifecycle lock. `enable` повторно проверяет `ready` уже под lock, поэтому
snapshot и изменение telemetry config/hook не могут разойтись. Внутренний
telemetry admin lock берётся только после lifecycle lock.

Lifecycle snapshot распознаёт только точную managed symlink на packaged init.
Любой другой файл или symlink на пути `S98mors-telemetry` считается внешним: он
не исполняется, не копируется и не восстанавливается Mors. В пассивном
`unconfigured` состоянии такой path допускается verifier, тогда как точная
managed symlink или живой валидный sender считаются остатком Mors runtime.

Upgrade и rollback включают telemetry config, init symlink и service state в
lifecycle snapshot. Перед заменой package tree работающий sender останавливается,
а после успешной установки поддерживающего telemetry IPK исходное состояние
`running`/`stopped`/`missing` восстанавливается уже новым init script. При
downgrade на IPK без telemetry валидная конфигурация отключается, управляемый
hook снимается, очередь и credentials сохраняются для явного решения оператора.
Внешний hook не исполняется и не заменяется ни в одном из путей.

## 7. Проверки релиза

- BATS для config validation, privacy whitelist, OTLP JSON, HTTP/partial
  response, bounded queue, cursor и CLI exit codes;
- shell syntax и ShellCheck;
- package-layout проверяет sender, init и library;
- lifecycle tests подтверждают missing/stopped/running snapshot+restore,
  ordinary/full teardown, protected credentials и неожиданный init hook;
- fake transport проверяет headers и payload без реального API-ключа;
- router smoke подтверждает bounded CPU/RAM, stop/restart/reboot и отсутствие
  изменений routing/firewall при ошибке приёмника.
