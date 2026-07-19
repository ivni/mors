# Архитектура `mors test`

Этот документ задаёт обязательные границы реализации глобальной end-to-end
проверки Mors. Пользовательский контракт определён в
`docs/cli-design-system.md`.

## 1. Ответственность

`mors test` доказывает фактический IPv4-тракт:

```text
конфигурация -> DNS роутера -> MORS_LIST -> firewall/route -> тоннель -> HTTPS
```

Status-подкоманды компонентов показывают snapshot, а `debug` собирает подробные
данные. Отдельной top-level `mors status` нет. Test не ремонтирует найденные
проблемы. Legacy `cmd_state_checker` не является частью архитектуры.

## 2. Режимы

- default проверяет активный тракт;
- `--all` после активного тракта последовательно проверяет включённые резервы и
  другие настроенные client tunnels без переключения пользовательского трафика;
- client проверяет наблюдаемый путь конкретного IPv4-клиента;
- cold выполняет явную транзакционную проверку повторного заполнения ipset;
- cold recover восстанавливает незавершённую cold-транзакцию.

## 3. Result model

Каждый этап имеет стабильные `id`, `status`, `reason_code`, русское `message`,
dependencies, признаки `required`/`blocks_cold`, duration, attempts и набор
безопасных булевых evidence. Raw client/external IP и secrets не сохраняются.

Общий статус вычисляется из результатов, а не назначается отдельными probes.
При ошибке prerequisite зависимый этап получает `not_checked`; независимые
этапы продолжаются. Приоритет агрегации: `error`, `degraded`, обязательный
`not_checked`, `working`, с отдельным `unconfigured` до построения графа.
Недоступное необязательное evidence (например direct WAN или DNS из client
cache) даёт общий `degraded`, если обязательный тракт уже доказан.

## 4. Обязательный DAG

1. `configuration` — setup завершён, конфигурация читаема.
2. `dependencies` — доступны обязательные executable dependencies.
3. `dns_backend` — ровно один поддерживаемый активный DNS backend.
4. `target` — встроенная HTTPS-цель присутствует в пользовательском списке.
5. `dns_a` — конкретный A-ответ получен через DNS роутера.
6. `ipset_population` — все адреса этого ответа появились в `MORS_LIST`.
7. `firewall_route` — правила, mark и routing table согласованы с active path.
8. `active_tunnel` — active tunnel настроен и работает.
9. `mors_request` — HTTPS request через обычный Mors path успешен.
10. `forced_tunnel_request` — тот же класс запроса успешен через tunnel adapter.
11. `wan_request` — direct WAN evidence получено, когда это возможно.
12. `exit_comparison` — Mors exit совпадает с forced tunnel и не доказывает
    bypass.
13. `ipv6_bypass_risk` — пассивная оценка AAAA, usable default IPv6 route и
    client-facing global IPv6 на домашнем интерфейсе при отсутствии Mors IPv6
    routing. IPv6-адрес выхода внутри тоннеля, неприменимый default route или
    IPv6 только на WAN не являются доказательством обхода.

Все A-адреса одного ответа обязательны. Обычный Mors request не начинается до
успеха DNS, ipset, firewall/routing и active tunnel prerequisites; forced tunnel
и WAN остаются независимыми evidence. Опрос ipset ограничен общим deadline.

## 5. External evidence

Цели выбираются автоматически: `ifconfig.me`, затем `api.ipify.org`, но только
если домен уже присутствует в пользовательском `mors.list`. Используются HTTPS,
`curl -4`, строгая проверка сертификата и parser полного IPv4 response. Fallback
включается только после timeout, invalid response или mismatch и не считается
retry.

Классификация:

- Mors не работает, forced tunnel работает — ошибка правил Mors;
- Mors и forced tunnel не работают, WAN работает — ошибка tunnel;
- все три запроса не работают — внешняя причина, `not_checked`;
- Mors совпадает с forced tunnel — active path подтверждён;
- Mors отличается от forced tunnel — подтверждённый bypass, `error`;
- WAN недоступен, но Mors совпадает с tunnel — active path работает, различие с
  WAN не проверено.

Firewall counters и conntrack используются как дополнительные evidence и не
подменяют сравнение внешнего выхода.

Router-originated `curl` не считается трафиком Mors только по факту успешного
ответа: на Keenetic клиентские правила обычно находятся в `PREROUTING`.
Обычный запрос считается доказательством Mors-path лишь при корреляции
уникального source port с conntrack mark и изменением счётчика соответствующей
цепочки. Если запрос успешен, но такой корреляции нет, этап получает
`mors_path_not_observed`, а общий результат не может быть `working`. Это
предотвращает ложное сообщение о bypass; полный клиентский тракт доказывается в
client mode.

Для beta `mors_path_not_observed` не блокирует саму транзакцию cold, если DNS,
ipset, firewall/routing и forced-tunnel probes исправны. Cold всё равно
завершается общим `degraded`, пока клиентский тракт не доказан; подтверждённый
bypass или ошибка обязательного dataplane по-прежнему блокируют mutation.

Setup dataplane gate принимает только безусловный канонический путь домашней
сети: точный PREROUTING jump и MARK без дополнительных predicates или инверсий,
точный policy rule и единственный IPv4 default route через выбранный интерфейс
и сохранённый gateway.
`unreachable`, `blackhole`, `prohibit`, `throw`, `linkdown`, а также частичные
правила для отдельного source/destination не подтверждают готовность dataplane.
Сборщик при этом обязан fail-fast вернуть ошибку каждого заявленного guest,
per-IP или per-network правила: обязательный home gate не маскирует частичную
потерю пользовательской политики. Тот же nonzero проходит через VPN switch,
boot hooks и изменяющие список CLI-команды.

Mocked integration исполняет сами init/NDM entrypoints, а не проверяет их текст:
инъекция ошибки mutator должна дать ненулевой exit status, освободить runtime
lock и не запустить следующий сервис или dataplane-шаг. Retry-тесты отдельно
покрывают отсутствующую policy table с nonzero `iproute2`, TCP-only цепочки,
near-miss значений, затеняющий `RETURN`, смену source exclusions, конфликтующие
defaults, потерянные policy rule/table и ошибку чтения `iptables-save`.

## 6. Tunnel adapters и inventory

VLESS использует общий низкоуровневый read-only probe и не вызывает health
cycle supervisor. Shadowsocks использует временный localhost-only `ss-local` с
защищённым config file и обязательным cleanup. Keenetic VPN использует live RCI
desired/link state и forced-interface request.

Inventory `--all` строится из active Mors choice, enabled VLESS registry,
операционно заполненного Shadowsocks config и client VPN interfaces live RCI.
Синтаксически корректный, но незаполненный шаблон Shadowsocks не является
соединением. RCI inventory принимает обе формы Keenetic API — object и array —
без зависимости от regex-функций `jq`. WAN/LAN/bridge, Wi-Fi, server VPN и
disabled connections исключаются. Неизвестный desired state даёт `not_checked`.

Порядок: active, reserves, остальные working connections. Исчерпание бюджета
после успешного active path даёт общий `degraded`.
Каждый дополнительный tunnel probe применяет тот же настроенный fallback
контрольной HTTPS-цели, что и active path: ответ IPv6 не принимается как
доказательство IPv4-тракта, но после него проверяется резервная IPv4-цель.

## 7. Deadline и конкурентное состояние

Timeout — monotonic absolute deadline probes и интерактивного ожидания. Retries
являются дополнительными попытками только неуспешного сетевого этапа. Этап не
начинается, если бюджет исчерпан; обязательный restore уже начатой cold-
транзакции выполняется до безопасного состояния и не обрывается deadline.

До и после логической группы снимается fingerprint релевантной конфигурации,
DNS backend, active interface и rules. При первом изменении результаты группы
отбрасываются и группа повторяется в оставшемся бюджете. Второе изменение даёт
`state_changed_during_test`/`not_checked`.

## 8. Locks

Одновременно выполняется один test. Отдельный reentrant runtime-mutation lock
сериализует изменения DNS, ipset, firewall, routing и tunnel selection.

Порядок вложения:

1. lifecycle lock;
2. test lock;
3. runtime-mutation lock;
4. VLESS decision lock.

Runtime mutator никогда не получает test lock. Busy возвращается немедленно с
безопасной owner metadata. NDM event ставит cancellation marker, cold
восстанавливает snapshot и освобождает runtime lock, после чего hook продолжает
изменение.

Если read-only test попал в промежуточный health-state активного VLESS под
decision lock supervisor, он ограниченно ждёт завершения уже идущего решения и
только затем фиксирует active connection. Временный `unstable` внутри cycle не
должен превращать рабочий active tunnel и все registry entries в резервы.

## 9. Cold transaction и recovery

Cold сначала выполняет read-only baseline. Ошибка любого `blocks_cold` этапа
завершает команду без изменений. После подтверждения:

1. получаются test/runtime locks;
2. атомарно сохраняются affected ipset entries и исходные DNS service states;
3. journal переводится по проверяемым фазам;
4. удаляются только affected entries;
5. очищается/restart активный DNS backend;
6. DNS query должен вернуть все A entries в ipset;
7. выполняется E2E DAG;
8. удаляется объединение исходных и заново полученных A-адресов, после чего
   точный snapshot с timeout metadata и service states восстанавливается;
9. journal удаляется только после проверки восстановления.

Signal trap выполняет restore. SIGKILL/reboot оставляет journal. Startup и любой
следующий mutator сначала выполняют recovery. При неполном restore journal
остаётся, mutators блокируются, test возвращает `error`; разрешён явный
`mors test cold recover`. Широкий reset не выполняется.

## 10. Client mode

Интерактивный режим предлагает нумерованный список известных клиентов;
неинтерактивный принимает точный canonical IPv4. В bounded observation window
оцениваются DNS destination, conntrack/mark/path и external request.

Наблюдаемый DNS роутера подтверждает этап; отсутствие из-за cache даёт
`not_checked`; любой явно наблюдаемый внешний DNS даёт `degraded`, даже если в
том же окне был DNS роутера. Client route считается доказанным только когда IP
контрольной цели и Mors mark находятся в одной conntrack-записи. Raw conntrack
snapshots и введённый пользователем external IP обрабатываются только в памяти;
на диск записываются лишь безопасные булевы evidence. JSON не запрашивает IP и
возвращает `client_exit_ip_not_reported` для этого этапа.

## 11. IPv6

Активные probes IPv4-only (`A`, `curl -4`). Client-facing global IPv6 при отсутствии
Mors IPv6 routing является пассивным bypass risk и даёт `degraded`, но не
отменяет подтверждение IPv4 path. Setup и `mors test` используют один detector
и одинаковые reason codes: риск существует только при одновременном наличии
AAAA-ответа через локальный DNS, usable default IPv6 route и global IPv6 на
домашнем интерфейсе. WAN-only IPv6, unreachable/blackhole default и IPv6-адрес
внешнего выхода внутри принудительного VLESS-туннеля сами по себе не являются bypass.
Реализация IPv6 routing вне scope.

## 12. Release gates

Beta требует static QA, BATS unit/mocked integration, privacy checks, package
layout, Entware build и реальную проверку opkg prerelease ordering. Реальный
Keenetic smoke не имитируется и явно остаётся ограничением beta: DNS restart,
iptables/conntrack, tunnel adapters, NDM cancellation, crash/reboot recovery и
client/private-DNS scenarios проверяются позднее на авторизованном стенде.
