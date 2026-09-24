# NaiveProxy: runtime-spike #63

## Принятые ограничения продолжения от 24.09.2026

Пользователь подтвердил: внешний сервер недоступен для управления, его
остановка невозможна. Server-side logs и stop/restore этого сервера остаются
непроверенными; повторный запрос такого доступа не является следующим шагом.
Это принятая граница исследования, не PASS соответствующего опыта.

Разрешено продолжить остальные проверки. Рабочий ПК используется только
как управляющий клиент: его routes/DNS/firewall, службы и домашний роутер
не меняются. Docker разрешён только с очисткой собственных ресурсов;
существующие контейнеры, volumes и настройки не затрагиваются.

Текущий проход ограничен изолированным LAN/Proxy опытом на NC-1913:
отдельный test-client namespace на Pi, отдельный временный Proxy, source-scoped
fail-closed правила и восстановление только owned state. Существующий
Proxy21 сохраняется. Не включаются default routing для всей LAN, DHCP/DNS
перенастройка или forwarding/NAT между домашней и тестовой сетями на Pi.
Windows не служит нагрузочным генератором.

Промежуточный порядок N2/N3 → N4 уточнён для этого ограниченного опыта:
уже подтверждённые direct TCP и TLS-negative используются как основание для
наблюдения LAN/Proxy без доступа к серверным логам. Полный WAN nonce/log,
clock/AIA/TTL gate при этом не объявляется закрытым, production admission
не разрешается. Неразрешённые вопросы фиксируются отдельно и не блокируют
независимые безопасные измерения.

**Итог #63: runtime-исследование завершено.
Production admission остаётся BLOCKED.** Получены
проверяемые результаты по всем направлениям issue на доступном NC-1913:
LAN/Proxy, TLS/DoH, UDP-negative, lifecycle/recovery, large payload и
нагрузка L+1 с рабочим VLESS/TLS. В новом нагрузочном опыте зарегистрированы
два отказа Naive; последующая диагностика воспроизвела минутную очистку
ещё не завершивших handshake соединений. Причина — нулевой last-write timestamp
в upstream-кандидате; см. заключительный раздел «Причина ранних обрывов».
AArch64-кандидат имеет отдельный отрицательный ISA результат.
Недоступность управления внешним сервером принята пользователем.
Финальная сводка — «Итоговый проход и заключение #63» в конце документа;
промежуточные выводы ниже сохранены как история наблюдений.

Дата: 22.09.2026. По решению пользователя NaiveProxy заменяет Hysteria 2
в плане общего пула. Это продуктовая смена направления; предыдущие тайм-ауты
HY2 не доказывают неисправность всех HY2 серверов или протокола.

## Подтверждённый результат

На разрешённом NC-1913 запущен официальный статический MIPSel клиент
NaiveProxy v150.0.7871.63-1, `naive --version`: `150.0.7871.63`.
Использован asset `naiveproxy-v150.0.7871.63-1-openwrt-mipsel_24kc-static.tar.xz`.
SHA-256 сверен с GitHub release digest:
`741b26a2425244f66adf99d93ed3cd41697aa6ba81660157b1f8f7c8dbf8374f`.
Это проверка конкретного static ELF на данном стенде, не всей матрицы ABI.

Прочитан локальный infrastructure-файл, сверены alias/ProxyJump, адрес
роутера и маршруты Pi. Config создан из выданного `naive+https` URI:
схема преобразована в `https`, credentials сохранены в URI без раскрытия,
fragment исключён; query в предоставленной ссылке отсутствует. Loopback
listener — SOCKS5 18091. Временные файлы защищены ACL/0700/0600.

На роутере не найдены стандартные CA bundle по проверенным путям, поэтому
только для процесса задан SSL_CERT_FILE с временным bundle, полученным
по HTTPS с https://curl.se/ca/cacert.pem. SHA-256 bundle:
`f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9`.
TLS verification не отключалась, системный trust store не менялся.

Через SSH `-L 127.0.0.1:28091:127.0.0.1:18091 mors-test-router` выполнены:

```powershell
curl.exe --silent --output NUL --connect-timeout 20 --max-time 30 --socks5-hostname 127.0.0.1:28091 --write-out 'http_code=%{http_code} time_total=%{time_total}\n' https://example.com/
```

| Проба | HTTP | curl exit | Время, s |
| --- | --- | --- | --- |
| 1 | 200 | 0 | 0.985110 |
| 2 | 200 | 0 | 0.356166 |
| 3 | 200 | 0 | 0.438394 |

NaiveProxy исполнялся непосредственно на роутере. Это успешный предварительный
SOCKS→HTTPS TCP путь, не сквозное LAN→Keenetic Proxy испытание, не нагрузка
и не контролируемый egress/nonce gate. Передача защищаемого DNS, exclusions,
no-loop, совместная работа Xray, отказ/восстановление ещё не доказаны.

Snapshot после запуска: RSS 6784 kB, HWM 6960 kB, 4 threads. После трёх
запросов: RSS 8024 kB, HWM 8040 kB, 4 threads. Это не idle/load benchmark.

## Существенное ограничение UDP

Выполнен SOCKS5 greeting `05 01 00`, получен `05 00`. На UDP ASSOCIATE
`05 03 00 01 00 00 00 00 00 00` получен ответ
`05 07 00 01 00 00 00 00 00 00`: command not supported.
[Закреплённый исходник](https://github.com/klzgrad/naiveproxy/blob/v150.0.7871.63-1/src/net/tools/naive/socks5_server_socket.cc)
также явно возвращает command-not-supported для BIND/UDP ASSOCIATE.
[README](https://github.com/klzgrad/naiveproxy/blob/v150.0.7871.63-1/README.md)
описывает HTTP/2 и HTTP/3 CONNECT streams. Внешний HTTP/3 не означает
поддержку пользовательских UDP datagrams.

Кандидат подтверждён только как TCP-only через официальный SOCKS endpoint.
Политика защищаемого UDP остаётся незакрытым решением #58/#62/#78: запрещено
молча отправлять UDP напрямую или считать успешный TCP доказательством UDP.
Если общий контракт требует UDP через этот backend, production-активация
блокируется до отдельного решения и доказанного совместимого пути; UoT или
другой runtime нельзя считать доступными на предоставленном сервере без опыта.

## Изменение плана issues

Прямые ссылки на HY2 заменяются в #58, #61, #63, #81, #115, #120.
Capability, архитектурные и зависимые требования уточняются в #59, #62,
#75, #78, #94, #95, #102. Исследование/контракт/матрица/ADR #58/#59/#61/#62
возвращаются в работу из-за смены требований; предыдущие HY2 исследования
остаются историческими свидетельствами. Не переносить выбор sing-box,
selector API, модель процессов, ABI и ресурсные выводы HY2 автоматически.

Дальнейшие результаты: `naiveproxy-runtime.md` (#61), полный runtime gate
(#63), затем production adapter (#81). Эта проверка не закрывает эти задачи
и не меняет runtime/package/release. Домашний роутер не изменялся; DNS,
firewall, RCI, маршруты и автозапуск не менялись. После опыта процесс и SSH
forward остановлены; временные configs, ключи, CA и бинарник удалены.

## Повтор по актуальному контракту #63: 22.09.2026

Прочитаны актуальная [issue #63](https://github.com/ivni/mors/issues/63),
закрытые зависимости #61/#62, [план N0–N9](naiveproxy-runtime.md),
[ADR](../adr/0001-connection-core-boundaries.md) и локальное описание стенда.
После `git fetch origin main` HEAD и origin/main совпали:
`a4343635e56327c1a1670ff69d56022fe815ce30`.
Несвязанные рабочие изменения сохранены. Runtime/package не изменялись.

### Стенд, доставка и ограничения наблюдения

Проверены SSH alias, ProxyJump, адрес br0 и маршруты Pi: default через
домашнюю сеть по wlan0, тестовая LAN по eth0, IPv6 default отсутствует.
Клиент исполнялся **на разрешённом NC-1913**, probes — на Windows через
loopback SSH forward. Это не клиент LAN через Keenetic Proxy.
Домашний роутер не изменялся.

Свежие наблюдения: `uname -m=mips`, kernel `4.9-ndm-5`, OPKG
`80503d94e356476250adaf1f669ee955ec26de76`; RAM total 254640 kB,
available 171260 kB перед доставкой; /opt около 7.3 GiB свободного места.
Модель NC-1913 и OS 5.0.12 взяты из описания стенда, в этом повторе не
подтверждены отдельным запросом версии RCI. Полная ISA/ABI инвентаризация
и AArch64 QEMU не повторялись; предыдущий ELF-анализ находится в #61.

Использован закреплённый static MIPSel asset из #61:

```text
version: 150.0.7871.63
archive SHA-256: 741b26a2425244f66adf99d93ed3cd41697aa6ba81660157b1f8f7c8dbf8374f
ELF SHA-256: 25531478648e9b586af7f85f5188e20151cc0a0f77940a2926d86658d5eaef95
CA SHA-256: f66dff1bdf8f96060b8177976f8b7d9254bc89bc4db933d769f7384d28480bc9
```

Архив и ELF проверены на роутере. BusyBox `tar -xf` не распаковал xz
(`invalid tar magic`); доставлен ранее распакованный ELF, digest проверен
до исполнения. `--version` и `--help` завершились успешно.
CA получен с HTTPS curl.se, digest совпал с предыдущим опытом. Это
временная доставка для исследования, не реализация pinned CA package.

Использован один `naive+https` URI из указанного пользователем локального
файла: преобразование схемы в `https`, удаление fragment, отсутствие query
проверено. URI не передавался в argv. Локальный каталог защищён ACL,
роутерный — 0700, config/CA — 0600. Рабочий каталог опыта:
`/opt/tmp/mors-naive63-20260922`. Сырые журналы и NetLog не публикуются.

### Lifecycle и владение listener

Десять циклов: запуск с config, через 1 s проверка `/proc/PID/exe` и
LISTEN на `127.0.0.1:18091`, TERM, wait и отсутствие PID. Все десять
завершились ожидаемым status 143. Это не измерение start/stop latency и
не доказательство graceful drain. Неверные JSON и URI дали exit 1.

**Неожиданный результат bind conflict:** второй процесс с тем же config
продолжал работать через 1 s и в отдельном повторе через 5 s. В `/proc/net/tcp`
одновременно две LISTEN записи одного `127.0.0.1:18091`. Ещё один повтор
сопоставил socket inode из `/proc/PID/fd` с TCP-таблицей: первый и второй
процессы владели каждый одним listener на этом адресе. После остановки
второго осталась одна запись. Точный механизм socket reuse здесь не исследован.

Следствие для #81/#78: проверка только PID, открытого порта или успешного
bind недостаточна для эксклюзивного владения generation. Требуются уникальные
порты, сериализация выделения и readback socket ownership; иначе запрос может
попасть к другой generation. Поведение смешанных credentials на одном порте
не проверялось. Production-адаптер в этом spike не реализован.

### Прямой TCP, egress и HTTP/2

Три запроса `https://example.com/` через router SOCKS:

| Проба | HTTP | curl exit | Время, s |
| --- | --- | --- | --- |
| 1 | 200 | 0 | 1.456590 |
| 2 | 200 | 0 | 0.499063 |
| 3 | 200 | 0 | 0.469119 |

Отдельные запросы `https://api.ipify.org` напрямую с Windows и через router
SOCKS завершились успешно; возвращённые egress различались. Значения не
сохранены в отчёте. Это внешнее свидетельство смены выхода, но не серверный
nonce/log gate и не доказательство отсутствия direct bypass во всех фазах.

SOCKS greeting: `050100` → `0500`. UDP ASSOCIATE:
`05030001000000000000` → `05070001000000000000` — unsupported.
Это подтверждает capability клиента, не блокировку защищаемого LAN UDP.

В отдельном TLS-опыте ниже NetLog содержал `SSL_CONNECT` (type 67)
с `next_proto=h2` и `HTTP2_SESSION_INITIALIZED` (type 265) с `protocol=h2`.
Имена типов сверены с constants этого NetLog. Таким образом, HTTP/2
наблюдался у роутерного Naive-клиента; серверные журналы не получены.

### Пустой CA store: отрицательный gate не пройден

После остановки исходного процесса запущен новый с пустым CA file и пустой
CA directory через обе переменные `SSL_CERT_FILE` и `SSL_CERT_DIR`.
HTTPS неожиданно дал HTTP 200, exit 0 за 0.838022 s.

Для исключения ошибки выбора listener повтор выполнен на отдельном свободном
`127.0.0.1:18092`. До запуска LISTEN отсутствовал, после появилась одна запись;
проверены executable и обе переменные непосредственно в `/proc/PID/environ`.
Снова HTTP 200, exit 0 за 0.876384 s. NetLog содержит `cert_status=0`;
классификатор не нашёл `net_error=-202` (authority invalid).

**Изоляция доверия двумя переменными не подтверждена.** Это не доказательство
отключённой TLS verification: возможен дополнительный источник доверия.
Ранее сохранённый исходник `system_trust_store.cc` содержит композицию
Chrome root store и платформенного хранилища, но фактический источник доверия
данной сборки не установлен. Утверждение #61 о достаточности file+directory
для изоляции требует уточнения до production admission. Нужен отдельный
контролируемый сертификат/сервер и проверка реального trust backend сборки.
Unknown CA, wrong hostname, expired/incomplete chain, auth failure, неверное
время и bootstrap DNS failure этим опытом не проверены. Системное время,
trust store и TLS-настройки не изменялись, insecure-флаги не применялись.

### Ресурсы и границы приёмки

| Snapshot одного процесса | RSS, kB | HWM, kB | Threads | FD |
| --- | ---: | ---: | ---: | ---: |
| После запуска до probes | 6788 | 6964 | 4 | 8 |
| После TCP/UDP capability и egress probes | 7980 | 8044 | 4 | 9 |

Это snapshots, не idle 5 min / load 15 min benchmark. CPU/PSS/throughput,
1/8/32 streams, L=1/2/4 + candidate, сосуществование Xray/DNS и конечные
platform budgets не измерены. Указание ключа в локальном файле не предоставило
управляемый сервер или доступ к журналам; server stop/restore BLOCKED.

| Gate #61 | Состояние по этому повтору |
| --- | --- |
| N0 | Частично: доступ, маршруты, RAM/disk, owned paths; полная baseline-инвентаризация не выполнена |
| N1 | Частично: digests, version/help, 10 циклов, invalid config; ожидаемый отказ bind не получен, CA isolation не подтверждена |
| N2 | Частично: SOCKS TCP, отличный egress, h2; нет контролируемого серверного nonce/log |
| N3 | BLOCKED: пустые file+dir не изолировали доверие; остальные TLS/bootstrap gates не закрыты |
| N4/N5 | BLOCKED: по плану следуют после N2/N3; Proxy/DNS/UDP policy и captures не выполнялись |
| N6/N7 | BLOCKED: ingress/drain и bounded resource matrix не проверены |
| N8 | BLOCKED: TERM/start не заменяет transport failure/server stop/restore |
| N9 | Очистка owned PID/listeners/files и readback rules/routes PASS; полного readback DNS/firewall/RCI/services нет |

Без N2/N3 начинать LAN/Proxy мутации противоречит последовательности #61.
Нельзя реализовать routing/drain/координатор из зависимых задач внутри этого
spike. Issue #63 не закрыта; результаты не допускают production NaiveProxy.

### Воспроизведение и cleanup

После безопасной доставки закреплённых ELF, CA и закрытого config:

```sh
# На разрешённом роутере; D — закрытый каталог опыта, B — проверенный ELF.
SSL_CERT_FILE="$D/ca.pem" "$B" "$D/client.json" > "$D/run.log" 2>&1 &
pid=$!
readlink "/proc/$pid/exe"
awk '$2=="0100007F:46AB" && $4=="0A" {print}' /proc/net/tcp
# Один цикл: проверить identity и LISTEN, затем TERM/wait/отсутствие PID.
kill -TERM "$pid"
wait "$pid"
# CA-negative требует отдельного порта и пустых file+directory:
SSL_CERT_FILE="$D/empty-ca.pem" SSL_CERT_DIR="$D/empty-ca-dir" \
  "$B" "$D/isolated.json" > "$D/isolated.log" 2>&1 &
```

На workstation loopback forward соответствует выбранному порту роутера:

```powershell
ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:28091:127.0.0.1:18091 mors-test-router
curl.exe -sS -o NUL --connect-timeout 15 --max-time 25 --socks5-hostname 127.0.0.1:28091 -w 'http=%{http_code} seconds=%{time_total}\n' https://example.com/
```

Все запущенные SSH forwards закрыты в `finally`. При финальной очистке
процессы отбирались по точному `/proc/PID/exe` внутри owned каталога;
после TERM подтверждены отсутствие таких процессов и обоих listeners.
`ip -4 rule` и `ip -4 route show table all` совпали с исходными снимками.
Удалены перечисленные файлы опыта; `rmdir` подтвердил пустоту и удаление
каталогов: `ROUTER_CLEANUP_PASS`. Локальные config и NetLog удалены:
`LOCAL_SECRET_CLEANUP_PASS`; исходный пользовательский файл сохранён.
DNS/firewall/RCI/Proxy, пакеты и автозапуск не изменялись. Полного снимка
этих подсистем не было, поэтому их readback PASS не заявляется.

## Продолжение: контролируемый TLS-стенд, 22.09.2026

Отсутствие управления внешним сервером не блокирует весь spike. Продолжены
независимые опыты без изменения RCI, Proxy, DNS, firewall и маршрутов.
Повторены проверки alias/ProxyJump, br0 и маршрутов Pi. `ndmc -c "show version"`
теперь непосредственно подтвердил `Viva (NC-1913)`, release `5.00.C.12.0-0`;
`opkg print-architecture`: `all 100`, `mipsel-3.4 150`, `mipsel-3.4_kn 200`.

### Источник доверия установлен; трактовка CA исправлена

Upstream [обсуждение #751](https://github.com/klzgrad/naiveproxy/issues/751)
объясняет: `SSL_CERT_FILE` предназначен для пользовательских дополнительных
CA, доверие сохраняет политику Chrome. Закреплённый
[system_trust_store.cc](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/cert/internal/system_trust_store.cc)
в `CreateSslSystemTrustStoreChromeRoot` объединяет `TrustStoreChrome` и
`TrustStoreUnix`, а не подменяет встроенный root store файлом окружения.

Проверено на том же MIPSel ELF и реальном пользовательском профиле:
`SSL_CERT_FILE` содержит только синтетический test root, `SSL_CERT_DIR` пуст.
Запрос `https://example.com/` через router SOCKS дал HTTP 200 / exit 0.
Закрытый NetLog содержит `CERT_VERIFY_PROC_CHROME_ROOT_STORE_VERSION`
(type 492), `version_major=33`, и `is_issued_by_known_root=true`.
Имена событий/ошибок сверены с constants самого NetLog. Поэтому прежнее
«источник доверия не установлен» снято. Публичный сертификат при пустых
file+directory не является отрицательным TLS-тестом для данного клиента.

Исправлены пояснения #61 и ADR: trust set включает встроенные roots
binary revision и дополнительные Unix roots. Проверка обязательного
поставляемого CA bundle остаётся обязанностью admission, отсутствие файла
само по себе не обязано останавливать upstream-процесс.

### Контролируемая TLS/auth/DNS матрица

В [naiveproxy-63](naiveproxy-63/README.md) сохранены воспроизводимые fixtures.
Python/cryptography генерирует одноразовые CA/сертификаты. Node.js поднимает
loopback HTTPS origin и HTTP/2 CONNECT proxy с жёстко ограниченным target.
Роутер достигает их через SSH reverse forward. Каждый случай использует
отдельный запуск официального Naive, проверенный ELF и isolated config;
успех требует одноразового HTTPS nonce в ответе и в серверном журнале.
Сертификаты fixture не устанавливаются в системные trust stores.

**Граница:** fixture — standard unpadded HTTP/2 CONNECT через SSH, а не
внешний Naive сервер с padding и WAN path. Он доказывает приведённые
TLS/auth/CONNECT свойства, не WAN egress, exclusions или Keenetic Proxy.
Реальный WAN TCP и отличный egress проверены отдельно выше; эти два опыта
не объединяются в ложное утверждение о серверном nonce внешнего endpoint.

| Случай | curl exit | Ключевой NetLog результат | HTTPS nonce на сервере |
| --- | ---: | --- | --- |
| Правильное имя, доверенный synthetic CA | 0 | h2 | Да, совпал с ответом |
| Пустые CA file+directory, synthetic leaf | 35 | CERT_AUTHORITY_INVALID (-202) | Нет |
| Отсутствующий CA file, пустая directory | 35 | CERT_AUTHORITY_INVALID (-202) | Нет |
| Неверное имя | 35 | CERT_COMMON_NAME_INVALID (-200) | Нет |
| Просроченный сертификат | 35 | CERT_DATE_INVALID (-201) | Нет |
| Leaf без необходимого intermediate | 35 | CERT_AUTHORITY_INVALID (-202) | Нет |
| Та же intermediate chain целиком | 0 | h2 | Да, совпал с ответом |
| Сертификат от другого synthetic root | 35 | CERT_AUTHORITY_INVALID (-202) | Нет |
| Неверный proxy password | 35 | h2, PROXY_AUTH_UNSUPPORTED (-115), INVALID_RESPONSE (-320) | Нет |
| Bootstrap hostname .invalid без MAP | 35 | NAME_NOT_RESOLVED (-105), PROXY_CONNECTION_FAILED (-130) | Нет |

`ERR_ADDRESS_UNREACHABLE=-109` также встречался в trace, включая успешные
случаи: наличие одиночного error event не классифицировалось как итоговый
отказ. Для таблицы использованы конечный curl, nonce и релевантный TLS/auth/DNS
код; полный trace не публикуется.

В первой подготовительной пробе Windows Schannel отказал самому HTTPS
origin из-за отсутствия revocation status (curl 60); до nonce запрос не дошёл.
В матрице curl использует `--cacert root.pem --ssl-revoke-best-effort`:
это допускает отсутствие CRL у одноразового origin, сохраняя проверку chain
и hostname. Настройки TLS Naive не ослаблялись, `--insecure` не использован.

Системное время не менялось. Clock-skew, AIA network fetch, DNS TTL/IP
replacement и сертификатные особенности реального сервера не проверены;
TLS-матрица не закрывает весь N3 или защиту служебного трафика.

### SO_REUSEPORT объясняет совместный listener

В закреплённом
[tcp_server_socket.cc](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/socket/tcp_server_socket.cc)
перед bind вызывается `SetDefaultOptionsForServer`. Его реализация в
[tcp_socket_posix.cc](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/socket/tcp_socket_posix.cc)
включает `SO_REUSEPORT`, если опция доступна. Это согласуется с двумя
одновременно подтверждёнными owned listeners выше. Наблюдение больше
не трактуется как неизвестный механизм или зависший второй процесс.
Для #81 остаётся проверяемое требование эксклюзивного выделения порта и
readback ownership; reuse нельзя использовать как механизм selection/drain.

### Реальный stop/restore локального сервера

При работающем router-клиенте исходный nonce прошёл. Затем Node fixture
остановлен по проверенному PID/command line; новый запрос завершился curl 35
без тела. После запуска fixture новая TCP-сессия дала exit 0, совпали
nonce в ответе и серверном журнале. Клиент между этими probes не перезапускался.

Это фактическая остановка **локального контролируемого сервера**, не local
deny и не остановка внешнего сервера пользователя. Она проверяет базовое
восстановление новых сессий данного CONNECT-пути. Sticky selection, no
automatic failback, внешний WAN server failure и судьба живых сессий
этим опытом не доказаны.

### Полный по длительности ресурсный прогон одного клиента

Сохранены [обезличенные измерения](naiveproxy-63/results-20260922.json) и
[драйвер](naiveproxy-63/resource-run.py). После 300 s простоя выполнено
по 300 s нагрузки с 1/8/32 workers; уже начатые запросы завершались после
deadline, поэтому фактическая длительность последних фаз немного больше.
Ответ — 256 KiB, worker делает паузу 250 ms, curl connect timeout 8 s,
общий timeout 20 s. NetLog на этой фазе отключён. Это unpadded CONNECT
через SSH, не WAN throughput; одновременно работал один Naive, без Xray.

| Фаза | Длительность, s | Успех / ошибка | RSS min–max, kB | FD max | CPU capacity, % | Успешные MiB/s | Среднее / max успешного запроса, s |
| --- | ---: | --- | --- | ---: | ---: | ---: | --- |
| Idle | 300.02 | 0 / 0 | 6364–6364 | 8 | 0.00 | — | — |
| 1 worker | 300.06 | 412 / 2 | 7576–7820 | 10 | 8.37 | 0.343 | 0.451 / 1.348 |
| 8 workers | 301.52 | 1243 / 6 | 8096–8332 | 17 | 24.55 | 1.031 | 1.658 / 3.158 |
| 32 workers | 306.66 | 1323 / 16 | 10316–17636 | 41 | 24.93 | 1.079 | 7.050 / 10.104 |

Samples примерно каждые 30 s. CPU — отношение delta process ticks к
delta общих CPU ticks, не процент одного ядра. HWM max по фазам:
6364 / 7888 / 8392 / 17636 kB; threads — 4. PSS недоступен:
на роутере отсутствует читаемый `/proc/PID/smaps`. Минимальный наблюдавшийся
MemAvailable 154264 kB. Guard MemAvailable < 65536 kB или FD > 256
не сработал. Временный каталог после последующих опытов занимал 54760 KiB;
это snapshot с Xray и логами, не измеренный package/staging peak.

**Стабильность не объявляется PASS:** ошибки 2/6/16 не скрыты. Начальная
версия драйвера сохранила количество, но не коды curl этих ошибок; причина
по этому прогону не установлена. В сохранённый драйвер добавлены числовые
классификации для последующих запусков. Затем отдельный свежий клиент с
NetLog проверен [диагностическим драйвером](naiveproxy-63/diagnose-requests.py):
100 direct-origin и 100 SOCKS запросов при concurrency 32, все 200 успешны.
В его NetLog найден только сопутствующий `ERR_ADDRESS_UNREACHABLE=-109`,
также встречавшийся в успешных TLS-пробах. Короткий повтор не воспроизвёл
длительный отказ и не аннулирует исходные 24 ошибки. Нельзя приписывать их
WAN, runtime или fixture без дополнительного наблюдения. Рост RSS на
нагрузке сам по себе не доказывает утечку или её отсутствие.

### Resident L+1, изоляция credentials и один Xray

После нагрузки отдельно сняты короткие snapshots по
[resident.sh](naiveproxy-63/resident.sh), без её наложения на benchmark:

| Число Naive процессов | Сумма RSS, kB | Сумма FD | Сумма threads |
| --- | ---: | ---: | ---: |
| 1 | 6372 | 8 | 4 |
| 2 | 12376 | 16 | 8 |
| 4 | 25512 | 32 | 16 |
| 5 (L=4 + candidate) | 32176 | 40 | 20 |

Все процессы используют один ELF и разные loopback ports. Сумма RSS
повторно учитывает shared pages и не является точной физической стоимостью
пула. Это точки опыта, не принятый production L и не L+1 load benchmark.

На одном endpoint у profile1 правильный password, у profile2 неправильный,
процессы раздельны. Последовательность nonce probes: profile1 exit 0,
profile2 exit 35 без nonce, снова profile1 exit 0, profile5 exit 0.
Ошибка credentials второго процесса не сломала первый.

Дополнительно запущен **один временный Xray 26.2.6**, revision `12ee51e`,
`go1.25.7 linux/mipsle`, из release asset `Xray-linux-mips32le.zip`:

```text
archive SHA-256: 1590b2bcefe64fb0604f29c8c75219bfbe8f63daa3bc8e3956edfa6da97c5869
ELF SHA-256: 3d2588c5ef770a6a7e1bfdd5db511130fb3acd79eb91bfcb108753b3e1dda1f6
```

Digest архива сверен с release API, ELF повторно на роутере; `run -test`
успешен. Xray имеет loopback SOCKS и blackhole outbound, не реальный VLESS.
Его snapshot: RSS 26672 kB, HWM 27128 kB, 8 threads, 6 FD. При нём все
указанные Naive probes выполнены, Xray отвечает SOCKS greeting `0500`.
После probes пять Naive: RSS sum 35796 kB, FD sum 43; MemAvailable 162600 kB.
Проверено сосуществование процессов/listeners, не mixed VLESS data path,
DNS-нагрузка или production budget. Чужих Xray процессов не было и не
останавливалось; временный процесс убран вместе с опытом.

### Сессии, process failure и обычный port conflict

Длинный HTTPS ответ fixture — 30 × 1024 bytes за примерно 15 s.
Во время сессии profile1 остановлен отдельный profile5/candidate:
curl exit 0, получены все 30720 bytes. Это изоляция процессов, не selection
или drain через общий ingress, которого опыт не создаёт.

Затем во время другого потока profile1 по проверенному executable/PID
получил SIGKILL. Curl завершился exit 56 после 8192 bytes. После запуска
нового profile1 на том же порте новая nonce-сессия дала exit 0 и совпавшее
тело. Миграция оборванной сессии не обещается.

Для port conflict сначала ошибочно передан `log: true`; parser вернул
`Invalid log`. Этот подготовительный exit 1 **не** учитывается как bind gate.
После исправления на строковый `log: ""` Naive остался жив при занятом
Xray порте; поэтому Xray тоже не использован как эксклюзивная резервация.
Окончательный опыт занял другой loopback port отдельным SSH reverse listener:
Naive завершился exit 1, в закрытом логе подтверждён `ADDRESS_IN_USE`.
Исходный Xray PID сохранён. Временная SSH резервация затем снята.

### AArch64: подтверждённый SIGILL на существующем Linux host

Docker Desktop запущен, но Linux engine не поднялся: backend завершился
на ошибке `dockerInference` listener; попытка запуска `com.docker.service`
не смогла открыть службу. QEMU gate не выполнен. Factory reset и правки
Docker settings не выполнялись: они выходят за этот spike.

Как отдельное host-свидетельство использован существующий Pi runner:
`aarch64`, kernel `6.18.34+rpt-rpi-v8`, CPU flags `fp asimd evtstrm crc32 cpuid`.
Это Raspberry Pi 3, **не Keenetic AArch64 и не QEMU**. Доставлен именно
закреплённый `aarch64_cortex-a53-static`, archive digest
`f5ae78ddeed9af8db8370b3ae544ef566fb786d8b7e03071767d2b2a1015246b`,
ELF digest `af0170d7482b03d4bdadf699cf412736633c432f01df28ff0a4567d8eae2c16f`
повторно совпал на Pi.

Уже `naive --version` получил `Illegal instruction`. Gdb без init-файлов
и debuginfod подтвердил SIGILL в `sha1_block_data_order_hw`, PC `0x35c4cc`,
инструкция `sha1h s3, s0`; следующие инструкции включают `sha1c` и `sha1su0`.
У host нет `sha1` CPU feature. `--version` на AArch64 получил **FAIL**;
help/lifecycle не запускались после отказа и остаются BLOCKED. Имя asset
не даёт предположительного PASS. Этот единичный отказ
не устанавливает полный список требований ISA и не объявляет все Keenetic
AArch64 несовместимыми; он блокирует универсальный допуск по одному ABI.
Для #69/#81 нужен feature gate либо проверенная сборка с нужным fallback.
Временный Pi каталог удалён после проверки отсутствия процесса:
`ARM64_HOST_CLEANUP_PASS`; сеть и пакеты runner не менялись.

### Итоговая граница #63 после продолжения

| Область | Что теперь подтверждено | Что не закрыто |
| --- | --- | --- |
| N0/N1 | Identity NC-1913/OS/ABI, digests, 10 MIPSel циклов, invalid config, обычный bind conflict, source объяснение reuse | AArch64 candidate SIGILL на host без SHA; minimum ISA/kernel matrix и точные latency budgets |
| N2/N3 | Реальный WAN SOCKS TCP/egress; отдельно fixture HTTPS nonce/h2, TLS/auth/DNS negative и Chrome roots | Серверный nonce/log внешнего endpoint, WAN bootstrap/TTL/exclusions/AIA/clock-skew |
| N4/N5 | SOCKS UDP unsupported | LAN→Keenetic Proxy, защищённый DNS, UDP-negative/capture при apply/failure/restore |
| N6/N7 | Credential isolation, короткий L+1 snapshot, один Xray blackhole, полный по длительности однопроцессный benchmark | 24 ошибки benchmark не локализованы; нет L+1 load, mixed VLESS/DNS, queue/drain и конечных budgets |
| N8 | Local fixture server stop/restore, process failure/new sessions, чужой candidate не рвёт поток | Реальный WAN server stop/restore, selection/sticky/failback и общий ingress/drain |
| N9 | Owned процессы/файлы убраны, rules/routes readback совпал, Pi очищен | Полного исходного DNS/firewall/RCI snapshot не было; его PASS не заявляется |

Независимые испытания продолжены несмотря на недоступность внешних server
logs/control. Остаточный BLOCKED относится к перечисленным конкретным
gates, а не к возможности любой дальнейшей работы. Для LAN/Proxy сохраняется
последовательность N2/N3 → N4 из #61; локальный SSH fixture не выдаётся за
WAN transport/exclusion proof. Реализация координатора, production admission
и обновление runtime package остаются за пределами #63. Issue не закрыта.

Финальный readback продолжения: `ROUTER_CLEANUP_PASS`, отсутствие remote
каталога и всех experiment listeners, `PI_DIR_ABSENT`,
`LOCAL_LISTENERS_ABSENT`, `LOCAL_PRIVATE_FILES_CLEANUP_PASS`. Удалены
временные private keys fixture, копия пользовательского URI, configs,
NetLog и логи; исходный keys.txt сохранён. Оставлены только обезличенный JSON,
fixtures и отчёт. Проверены синтаксис Python/Node/shell helpers, локальные
Markdown-ссылки, whitespace и отсутствие значений реального ключа в
изменённых документах/fixtures. BATS и полный package QA не запускались:
packaged runtime Mors не менялся, release не готовился.

## LAN/Proxy и fail-closed транзакция: 24.09.2026

Продолжение выполнено с принятым выше ограничением внешнего сервера.
Рабочий ПК не перенастраивался: routes/DNS/firewall, службы Windows,
Docker containers/networks/volumes не изменялись. Docker только проверен
read-only и для опыта не понадобился. Нагрузка и TLS fixture перенесены на Pi;
на ПК выполнялись управление, обработка закрытых файлов и один bounded
SOCKS probe. Домашний роутер не менялся. Несвязанные рабочие изменения сохранены.

### Scope и подготовка безопасного readback

Перед mutation повторно прочитана локальная инфраструктура; проверены alias,
ProxyJump, br0, NC-1913/OS и маршруты Pi. Обнаружен существующий `Proxy21`;
его не меняли. Для опыта выбран отсутствовавший `Proxy63` с уникальным
описанием, один loopback Naive listener 18163, отдельная source policy
priority 1000/table 163 и две owned цепочки `M63_FWD`/`M63_IN`.
Свободные идентификаторы проверены до применения; это номера конкретного
опыта, не defaults для других роутеров. BusyBox отверг первоначальный table
3163; частичная подготовка была очищена до повтора с допустимым 163.

Клиент — отдельный namespace `mors63-lan` на Pi с macvlan только на test-LAN
eth0. Перед назначением адреса выполнен ARP DAD (exit 0). Default route
самого Pi через wlan0 и `ip_forward=0` сохранены; bridging/NAT между двумя
сетями не создавались. IPv6 выключен только внутри namespace. Все probes
выполнены из него, а не из обычной сети рабочего ПК.

Entware iptables 1.4.21, tcpdump 4.99.6/libpcap 1.10.6 и минимальный
Python 3.13.9 распакованы только в закрытый временный каталог. IPK SHA-256
сверены с HTTPS feed index; `opkg install` не использовался. Windows tar
не сохранил часть Unix symlinks, поэтому для исполнения data.tar.gz
распакованы на роутере. Для xtables-multi созданы только временные entrypoints.
Системные библиотеки, init и NDM hooks не заменялись.

Stock `iptables-save` не понимает Keenetic match `ndmmark`, поэтому его
ошибка не трактовалась как отсутствие firewall. Одноразовый read-only
инспектор через `libip4tc` сохранил цепочки, policies и opaque rule bytes,
включая неизвестные matches. Из сравнения исключены только packet/byte
counters и kernel cache/traversal bookkeeping (`nfcache`, `comefrom`);
никаких `iptc_commit` или restore полного ruleset не выполнялось.
ABI entry проверен перед чтением, два baseline snapshot совпали до mutation.
Итог совпал с исходным для всех трёх таблиц:

| Таблица | Цепочки | Правила | Итоговое canonical сравнение |
| --- | ---: | ---: | --- |
| filter | 34 | 111 | Совпало |
| nat | 21 | 35 | Совпало |
| mangle | 27 | 34 | Совпало |

Также сняты rules/routes, RCI interfaces и running-config. Сырые snapshots
содержат приватные значения, в репозиторий не перенесены и после сравнения
удалены. Таймер на Pi ограничивал жизнь namespace, роутерный watchdog
переводил только test source в DROP при превышении времени; он не сработал.

### Текущий внешний профиль и граница контролируемого fixture

Один URI из пользовательского файла проверен без вывода credentials.
Bootstrap IPv4 закреплён через MAP при сохранении hostname/SNI. Прямой
router SOCKS probe дал HTTP 000, curl 28 примерно через 8 s. В ограниченном
WAN capture — 26 исходящих TCP SYN, без SYN-ACK. Route указывал физический
WAN. Это наблюдение недоступного TCP handshake на данном пути сегодня,
не доказательство остановки или неисправности внешнего сервера.
Повторного запроса серверного доступа не было.

Для независимых LAN/Proxy опытов использован временный TLS fixture на Pi,
доступный роутеру через физический eth3/WAN и wlan0 Pi. Он принимает только
source тестового роутера и CONNECT к одному синтетическому target; общего
открытого proxy нет. HTTPS origin доступен только loopback Pi. Стенд использует
Python ssl и временные pure-Python h2 4.3.0 / hpack 4.2.0 / hyperframe 6.1.0,
без глобальной установки. Одноразовый CA передан только процессам Naive/curl,
не установлен в OS trust stores. Проверка TLS hostname/chain не отключалась.

Fixture — standard HTTP/2 CONNECT **без Naive padding**, находящийся в
upstream LAN, а не сервер в интернете. Поэтому здесь подтверждены
физический WAN путь и интеграция компонентов; не заявляются public-internet
egress, доступность провайдера или protocol-padding benchmark.

### LAN HTTPS, защищённый DoH, локальный failure/restore

После корректной подготовки guard получен путь:

```text
Pi test namespace → eth0 → NC-1913 br0 → Proxy63/t2s63
  → loopback Naive → TLS/h2 через eth3/WAN → Pi wlan0 fixture
  → loopback HTTPS origin
```

Первый HTTPS probe: HTTP 200 за 0.279273 s; случайный nonce совпал с телом
ответа и независимым журналом fixture. Затем имя target разрешено через
DoH внутри этого же защищённого TCP пути: HTTP 200 за 0.410309 s, сервер
зарегистрировал DNS query и совпавший nonce. Bootstrap DoH host задавался
через `--resolve`, имя application target разрешалось только DoH.
Это явная конфигурация тестового клиента, не внедрение общего DNS Mors.

Guard разрешал source TCP только через t2s63, блокировал весь его UDP и
доступ test source к локальным сервисам роутера. Пять UDP probes:
TEST-NET UDP/53, UDP/443, UDP/9, внешний DNS/53 и DNS/53 самого роутера.
Четыре увеличили source FORWARD DROP, один — INPUT DROP. При SIGSTOP
owned Naive новый HTTPS запрос дал HTTP 000/curl 28, nonce не появился
в журнале даже после CONT. После CONT новый DoH/HTTPS дал HTTP 200/exit 0
и подтверждённый nonce. Дополнительные UDP-пробы при failure и restore
увеличили FORWARD UDP DROP до 10; INPUT DROP остался 1.

Удаление только разрешающего default route из table 163 оставило
`unreachable default`, поэтому TCP дал curl 7 без fallback в main table.
После возврата route — HTTP 200 и серверный nonce. Это локальная ошибка
runtime/route, не остановка внешнего сервера и не proof graceful migration.

### Обнаруженная гонка с NDM и проверенный порядок применения

Первоначальный guard, установленный **до** создания Proxy через RCI, был
удалён при NDM rebuild firewall. Test namespace немедленно удалён;
source rule и route при этом сохранились. Этот начальный опыт не объявляется
UDP PASS. Нельзя считать вручную добавленную iptables-цепочку постоянной
защитой, независимой от RCI/NDM.

В последующих опытах Proxy сначала создавался при отсутствии test client;
затем устанавливался guard, проверялись его hooks/rules и только после
этого запускался namespace. Дополнительно испытана транзакция с уже
работающим test client:

1. Подтвердить успешные DoH/HTTPS и nonce до изменения.
2. Удалить разрешающий route, оставив source rule и `unreachable default`.
3. Удалить/создать только owned Proxy63. Во время rebuild посылать ограниченные
   TCP/UDP probes. Прочитать source rule и unreachable route после RCI.
4. Восстановить owned guard и проверить rules/hooks. Только затем добавить
   route через t2s63 и проверить новый DoH/HTTPS nonce.

В окончательном повторе: 90 UDP отправлены, все 30 TCP attempts заблокированы,
TCP success 0. После guard readback/route commit — HTTP 200 и совпавший
серверный nonce. Watchdog не сработал. Это bounded prototype конкретного
перехода NC-1913, не готовый production координатор, не доказательство
всех NDM событий, аварии питания или сохранения старых сессий.

Были выявлены и исправлены **дефекты одноразового fixture**: обработка
обычного CONNECT без `:path` и позднего DATA после закрытия upstream stream.
Во втором случае закрытый fd прерывал общую h2 session; первый post-recreate
probe получил timeout. Этот отказ не приписан Keenetic. После исправления
выполнен новый опыт с положительным baseline до транзакции и положительным
результатом после неё. Настройки проверки TLS Naive не ослаблялись.
Эти находки не объясняют автоматически 24 ошибки другого benchmark от 22.09.

### Packet evidence и границы отсутствия обхода

Использованы ограниченные `tcpdump -p -s 96 -c 2000` на br0 и eth3.
WAN filter включал TCP к fixture, UDP к синтетическому TEST-NET target и
трафик к benchmark target; это **не весь WAN трафик** остальных клиентов.
Сырые pcap не опубликованы. Счётчики относятся к декодированному IPv4:

| Опыт | LAN UDP / из них TEST-NET | WAN packets | WAN UDP в фильтре | Прямой TCP к target на WAN |
| --- | --- | --- | ---: | ---: |
| HTTPS/DoH, runtime failure/restore, route withdrawal | 14 / 12 | 316 TCP: 168 к fixture, 148 обратно | 0 | 0 |
| Финальный Proxy recreate под unreachable policy | 90 / 90 | 139 TCP: 75 к fixture, 64 обратно | 0 | 0 |

Финальный LAN capture содержит также 120 TCP и 2 прочих IPv4 пакета.
WAN capture показывает только ожидаемый TLS путь к fixture; UDP probes
доходят до LAN и не появляются на наблюдаемом WAN-пути. Вместе с source
guard counters, fail-closed rule/readback и nonce это подтверждает отсутствие
direct bypass в данных bounded опытах. Не заявляется отсутствие любого
возможного leak при других конфигурациях, fastpath/старых UDP flows,
других NDM событиях или после reboot.

### Вывод для архитектуры и оставшиеся границы

| Риск / ограничение | Владелец и trigger | Безопасное состояние |
| --- | --- | --- |
| NDM пересоздаёт netfilter и удаляет guard | #78/#81: любой RCI apply/rebuild, затрагивающий forwarding | До mutation закрыть source routing независимо от удаляемого guard; после — reconcile/readback до открытия TCP |
| Нет управления внешним сервером | Принято пользователем 24.09; пересмотр только при новом доступе по его инициативе | Не обещать внешний stop/restore, продолжать остальные опыты |
| 24 ошибки старого нагрузочного прогона не локализованы | #63/resource gate: новый инструментированный длительный прогон | Не утверждать стабильность/продуктовые L+1 budgets по коротким probes |
| AArch64 ELF SIGILL без SHA extension | #69/#81: выбор артефакта и admission на AArch64 | Не выбирать ELF только по machine/имени asset |
| Полные DNS/bootstrap и lifecycle сценарии | #63/#78/#115: TTL/AIA/clock, DNS ownership, mixed VLESS, rollback/reboot/старые flows | Ограничить выводы проверенным fixture и source policy |

В этом продолжении закрыты конкретные LAN/Proxy, DoH, UDP-negative и
локальные failure/restore/RCI-transition наблюдения. Не выполнялись новый
длительный benchmark, large-payload/MTU матрица, production DNS setup или
реализация общего ingress/drain/selection. Старые результаты не переименованы
в PASS; приёмка всей подсистемы этим spike не заявляется.

### Cleanup и сохранённый результат

Namespace удалён до снятия router guards. Остановлены только owned Naive,
tcpdump, fixture и watchdog, удалён только Proxy63 и точные source rules,
routes/chains. `Proxy21` сохранён. Финальные canonical firewall, rules и
routes совпали с исходными; running-config совпал по всем непустым
командным строкам, различается только один служебный комментарий генератора.
Host routes Pi и `ip_forward` совпали, namespace/macvlan/listeners отсутствуют.

Проверены `PI_NETWORK_AND_LISTENERS_RESTORED`,
`FINAL_FIREWALL_RULES_ROUTES_PASS`, `CONFIG_COMMANDS_RESTORED`.
Закрытые каталоги с tools, ключами fixture, копией URI, config, pcap и raw
snapshots удалены на роутере/Pi. Временный прототип не переносится в Mors;
сохранены только отчёт и [обезличенный результат](naiveproxy-63/results-20260924.json).
Исходный keys.txt и несвязанные рабочие изменения не менялись.

## Итоговый проход и заключение #63: 24.09.2026

Исследование ограничено runtime и необходимыми стендовыми проверками.
В него не включены реализация общего Rust-координатора, production DNS
adapter, packaging или исправление upstream-клиента. База HEAD и обновлённый
origin/main совпали: `a4343635e56327c1a1670ff69d56022fe815ce30`.
Полные обезличенные samples, ошибки и результаты сохранены в
[results-20260924-final.json](naiveproxy-63/results-20260924-final.json).

### Дополненный ресурсный опыт

Сервер и генератор нагрузки перенесены на Pi. На рабочем ПК не запускались
fixture-сервер, VM, Docker или нагрузочные workers; его сеть/службы не менялись.
Временный Node 22.22.0 ARM64 проверен по официальному SHASUMS256, распакован
только в каталог опыта. Установки системных пакетов не было.

На NC-1913 одновременно работали пять отдельных Naive процессов
(`L=4 + candidate`) и **один Xray с реальным VLESS/TLS data path** к тестовому
Xray server на Pi. Это VLESS/TLS, не Reality и не blackhole. Проверка CA/name
оставалась включённой; fixture UUID/config передавались через закрытые файлы.
Naive MIPSel ELF SHA-256 повторно совпал:
`25531478648e9b586af7f85f5188e20151cc0a0f77940a2926d86658d5eaef95`.
Xray 26.2.6 MIPSel ELF:
`3d2588c5ef770a6a7e1bfdd5db511130fb3acd79eb91bfcb108753b3e1dda1f6`.

Ресурсный профиль: 300 s warm idle, затем по 300 s с 1/8/32 Naive workers;
одновременно один VLESS worker, DoH примерно каждые 2 s и последовательная
проверка одного из четырёх остальных Naive процессов примерно каждые 15 s.
Каждый data response — 256 KiB, ограничение curl 64 KiB/s на запрос,
connect timeout 8 s, общий 20 s. Завершение уже начатых запросов увеличило
фактические фазы до 304.26 / 304.89 / 307.97 s. Нагрузочные SOCKS listeners
были привязаны только к test-LAN адресу с синтетической аутентификацией;
это стендовый способ подачи нагрузки, не изменение loopback production-контракта.
Данный benchmark не включает CPU overhead Keenetic Proxy: его data path
проверен отдельными LAN/MTU опытами.

| Naive workers | Naive успех / отказ | VLESS успех / отказ | DoH успех / отказ | Standby успех / отказ |
| --- | --- | --- | --- | --- |
| 1 | 70 / 0 | 70 / 0 | 140 / 0 | 16 / 0 |
| 8 | 564 / 2 | 70 / 0 | 134 / 0 | 16 / 0 |
| 32 | 1353 / 0 | 70 / 0 | 41 / 0 | 16 / 0 |

| Фаза | Сумма Naive RSS max, kB | Xray RSS max, kB | FD max одного Naive | FD max пула | MemAvailable min, kB | CPU пула, % общей capacity |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Idle | 33988 | 28088 | 9 | 51 | 162376 | 0.01 |
| 1 worker | 39664 | 31676 | 12 | 59 | 157584 | 3.77 |
| 8 workers | 40440 | 31848 | 20 | 67 | 155788 | 13.42 |
| 32 workers | 48768 | 31832 | 43 | 91 | 146728 | 26.88 |

Samples собирались каждые примерно 10 s. Часы роутера отставали от Pi
примерно на 6 s; часы **не менялись**. Для фазовых агрегатов применён сдвиг
6 s и исключены 10 s у границ фаз. Это исключает попадание начала 32 workers
в предыдущую фазу. RSS sum повторно учитывает shared pages, PSS на ядре
недоступен. Guard MemAvailable < 65536 kB или FD > 256 на процесс не сработал.
Это защитные пороги опыта, не автоматически принятые product budgets.

Максимальная latency успешного DoH выросла с 0.585 s при одном worker до
1.434 s при восьми и 7.782 s при 32. Следовательно, headroom RAM сам по себе
не доказывает пригодности health/DNS timeout или неограниченного concurrency.
Для #117 получен измеренный envelope L=4+1; лимит продукта должен учитывать
контрольный трафик и отказные результаты, а не только отсутствие OOM.

### Диагностика отказов: отрицательный результат сохранён

В фазе 8 workers две почти одновременные пробы завершились до HTTP:
curl 97 за 0.014982 s и curl 35 за 0.214519 s. В VLESS, DoH и standby
ошибок в полном прогоне не было. Naive info log не содержал non-OK закрытий,
серверный error counter в сохранённом snapshot benchmark был пуст.
Это не устанавливает виновника: остаются client/runtime/fixture/network
границы, а не доказанная неисправность конкретного компонента.

После полного прогона отдельно включён приватный NetLog и выполнен burst
512 запросов с concurrency 32 **без** rate limit: 512 HTTP 200, нужная длина
ответа, ноль ошибок. В NetLog — только сопутствующий код -109, встречавшийся
и в успешных probes. Последующие server-side ECONNRESET из других edge cases
не приписываются задним числом benchmark. Старые 24 ошибки от 22.09 также
не объявлены исправленными. Итог по стабильности — **BLOCKED для допуска**;
получение воспроизводимых измерений не превращает failed probes в PASS.

### Заключительные edge cases

| Опыт | Факт | Граница |
| --- | --- | --- |
| Warm lifecycle, 10 циклов | fork/exec → единственный listener 86.773–95.233 ms; TERM → reap 1.879–2.484 ms; PID identity и освобождение listener проверены | Тёплый ELF cache; socket readiness, не TLS health или graceful drain |
| Полная intermediate chain | HTTP 200, curl 0 | Контроль той же fixture CA |
| Неполная chain с доступным AIA issuer URL | curl 35, CERT_AUTHORITY_INVALID (-202); AIA HTTP requests 0 | В данном single-profile TLS пути intermediate не получен; нельзя обещать автоматическое исправление chain или отсутствие любых AIA во всех режимах |
| Not-yet-valid сертификат | curl 35, CERT_DATE_INVALID (-201) | Проверка периода валидности без изменения системных часов |
| Injected bootstrap failure | curl 35, NAME_NOT_RESOLVED (-105), PROXY_CONNECTION_FAILED (-130), без HTTP | MAP `~NOTFOUND`; это не измерение автоматического DNS TTL refresh ядром |
| LAN→Proxy→Naive, 64 MiB | HTTP 200, 67108864 bytes за 60.792831 s, полный SHA-256 совпал | Штатный test-LAN MTU 1500 |
| Тот же путь, MTU 1280 только в namespace | HTTP 200, 8388608 bytes за 7.459672 s, SHA-256 совпал | WAN/host MTU не менялись |
| Уже установленный UDP | Один socket/5-tuple, 37/37 echo до deny, conntrack ASSURED; после deny 24 отправлены, 0 получены клиентом и **0 получены независимым сервером** | Hardware PPE acceleration отдельно не подтверждена |

UDP control был заранее явно ограничен только test source → одноразовый
Pi echo endpoint; общего разрешения direct не создавалось. В переходной
фазе до подтверждения deny отправлены 11/получены 9 пакетов; это ещё
разрешённая старая control policy. Ноль доставок относится к packets,
помеченным клиентом **после** readback нового deny. UDP получатель считал
фазы независимо, поэтому отсутствие ответов не подменяет отсутствие утечки.
Scoped NAT exception, host route, namespace, Proxy и guard затем удалены;
canonical firewall вновь совпал с baseline.

### Приёмка исследовательской задачи и решение

| Критерий issue | Итог исследования |
| --- | --- |
| Платформа/digests, TLS/lifecycle, direct SOCKS и LAN/Proxy | Выполнено на NC-1913; nonce/egress и точные границы внешнего/контролируемого путей записаны. AArch64 host SIGILL — отдельный отрицательный результат, не скрытая совместимость |
| Bootstrap/CA, физический WAN, защищённый DNS, no-loop | Выполнены controlled bootstrap/CA negative, DoH, WAN packet evidence. Автоматический TTL/exclusion reconciliation и общий DNS adapter принадлежат #78/#81; их реализации здесь нет |
| UDP unsupported и negative apply/failure/restore | Выполнено на isolated client, включая established ASSURED flow и контролируемое пересоздание Proxy; всеобщая hardware-offload/reboot матрица не заявляется |
| Idle/load RAM/CPU/FD, start/stop, invalid config/port conflict, Xray coexistence | Измерено, в том числе L+1 и рабочий VLESS/TLS. Стабильность получила отрицательную границу: два отказа не локализованы; product admission BLOCKED |
| Failure/restore и новые TCP-сессии | Локальные process/route/controlled-server сценарии выполнены. Stop/restore внешнего провайдера не выполняется по принятому ограничению пользователя |
| Воспроизводимые факты, cleanup и границы | Отчёт и обезличенные datasets сохранены; временный код/ключи/инструменты не становятся runtime Mors |

**Решение:** кандидат MIPSel доказал работоспособность TCP-пути и пригодность
для дальнейшей разработки адаптера, но не получил production admission.
Результат #63 — измерения, выявленные ограничения и решения для следующих
задач. Исследование не требует сначала реализовать эти зависимости:

- **#81/#117:** квалифицировать наблюдавшиеся SOCKS/TLS отказы и утвердить
  error/latency/session budgets до активации. Новый runtime/server/driver
  должен проверяться отдельным инструментированным прогоном; исторические
  failed probes остаются в evidence.
- **#78/#115:** source-bound quiesce, NDM guard reconciliation, DNS/endpoint
  generations и расширенные recovery/offload сценарии. Проверенный временный
  сценарий не заменяет координатор, durable intent или rollback implementation.
- **#69/#81:** AArch64 ISA/crypto feature gate и корректная поставка. Название
  `cortex-a53` не отменяет зафиксированный SIGILL на host без SHA.

Это отрицательный/ограниченный verdict о допуске runtime, а не невыполненное
из-за внешнего доступа исследование. Релиз, production activation и общий
Rust-координатор в #63 не создавались.

### Финальная уборка и проверка артефактов

После остановки только процессов опыта исходные rules/routes и canonical
firewall тестового роутера совпали с baseline. Running configuration совпала
после исключения пустых строк и служебных комментариев. Временные Proxy63,
namespace, link и listeners отсутствуют. На Pi сохранены исходные маршруты,
`ip_forward=0` и MTU eth0 1500. Сеть и службы рабочего ПК не менялись.

Закрытые каталоги именно финального прогона удалены на роутере, Pi и ПК:
синтетические ключи/UUID, сырые NetLog/config snapshots, скачанные бинарники
и временные прототипы не оставлены. Сохранён обезличенный dataset; его суммы,
JSON, локальные ссылки и `git diff --check` проверены. Runtime/package Mors
не изменялся, поэтому BATS и сборка пакета для этого документального итога
не запускались. Публикация и закрытие GitHub issue не выполнялись.

## Причина ранних обрывов: диагностика 24.09.2026

**Причина воспроизведённых отказов — idle cleanup в закреплённом Naive,
а не отказ внешнего провайдера.** У нового соединения оба last-write timestamp
равны нулю до первой записи данных. `CleanUpIdleConnections()` раз в минуту
вычисляет `now - GetLastWriteTime()` и сравнивает результат с idle timeout.
На работающем дольше timeout роутере новый handshake ошибочно выглядит
просроченным и закрывается. Обычная задержка WAN расширяет окно этой гонки;
сама по себе разница Ethernet/Wi-Fi не доказывает дефект Wi-Fi.

Для Linux-кандидата штатный idle timeout — **600 s**, tunnel timeout — 1800 s.
Прямой эксперимент ниже получил закрытие после паузы всего **10 s**.
Источник ошибки проверен в закреплённых
[constructor/getter](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/naive_connection.cc),
[idle cleanup](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/naive_proxy.cc)
и [defaults](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/naive_config.h).
Просмотренный upstream HEAD `64c969277106de290d985f2656d50420f8505798`
содержит тот же getter без fallback к времени создания.

### Изоляция и воспроизведение

Данные: [results-20260924-diagnosis.json](naiveproxy-63/results-20260924-diagnosis.json).
Во всех опытах генератор находился на Pi, Naive — на NC-1913. Рабочий ПК
не обслуживал трафик fixture; его сеть и службы не менялись.

| Опыт | Результат | Что он устанавливает |
| --- | --- | --- |
| Ethernet, один Naive; 1/8/32 workers, 60/600/180 s | Naive 1836/0 ошибок, прямой HTTPS 200/0 | Ошибка не постоянна; быстрый путь не гарантирует попадание в окно cleanup |
| WAN роутера → Wi-Fi Pi; 5 Naive + VLESS/TLS + DoH, 8 workers, 300 s | Naive 570 успехов/3 ошибки; VLESS 71/0, DoH 128/0, standby 16/0, SOCKS без HTTP/2 72/0 | Воспроизведены curl 97 peer reset и curl 35 EOF/broken pipe. Провайдер не участвовал |
| Пауза 10 s после SOCKS greeting, оба клиента со штатным timeout | По 4 закрытия из 14 у HTTP/2 и прямого SOCKS-клиента | Отказ воспроизводится до обращения к origin, в том числе без HTTP/2 |
| Повтор с подтверждённой готовностью: увеличен idle timeout только HTTP/2-клиента | HTTP/2 14/14 auth; неизменённый прямой клиент 11/14 | Исключение ошибочного сравнения с нулём убирает этот отказ |
| Финальный минимальный A/B: **оба клиента прямые**, без запущенного TLS/HTTP2 fixture | Штатный timeout: 12/14 auth; контрольный: 14/14 | Причина не требует WAN, TLS fixture, VLESS или внешнего сервера |

Во всех нагрузочных probes: 256 KiB, curl limit 64 KiB/s, connect timeout 8 s,
общий timeout 20 s. Прямой контроль в WAN-опыте — отдельный Naive без proxy,
то есть SOCKS→origin без HTTP/2, а не полностью независимый от Naive бинарник.
Это диагностические сравнения, не новая оценка production CPU/RAM бюджета.

Пара новых ошибок завершилась практически одновременно; ещё один отказ
произошёл примерно через 120 s. NetLog показывает отмену HTTP/2 stream клиентом,
а сервер затем видит `ECONNRESET` во время TLS handshake с origin. Это следствие
раннего закрытия, а не доказательство неисправности сервера. В snapshot NetLog
по-прежнему были только сопутствующие `net_error=-109`: отсутствие отрицательного
кода не доказывает успех прикладного запроса. `Disconnect()` может закрыть
незавершённый handshake без обычного завершения connect callback.

В первом A/B один запрос попал в старт процесса и получил connection refused;
он сохранён отдельно и не входит в готовый A/B. Следующий запуск сохраняемого
probe был остановлен readiness-проверкой после штатного TTL стенда; итоговый
минимальный опыт выполнен на заново запущенных и проверенных двух клиентах.

Исторические две ошибки предыдущего полного benchmark не имеют per-request
NetLog. Их точное ретроспективное отождествление с этой гонкой невозможно;
теперь воспроизведён и локализован тот же класс отказов. Старые failed probes
не переписываются в PASS, а неизвестная причина заменяется конкретным
проверяемым дефектом кандидата. Все 24 ошибки более раннего опыта отдельно
не квалифицировались.

### Исправление и граница проверки

Подготовлен [минимальный upstream patch](naiveproxy-63/idle-handshake-created-at.patch):
если обе отметки записи ещё нулевые, `GetLastWriteTime()` возвращает `created_at_`.
После первой записи продолжает использоваться последнее время активности.
Это сохраняет нормальное завершение действительно простаивающих соединений.

Патч прошёл `git apply --check` на исходнике кандидата. Тело реального getter
проверено небольшим C++ harness с заменой `TimeTicks` на простой monotonic-time
тип: baseline exit 1, patched exit 0. Проверены начальное время, молодой
handshake, настоящий idle timeout и обновления активности в обоих направлениях.
Это проверка функции, **не сборка Chromium и не проверка исправленного ELF**.

В A/B `idle-timeout=2147483647` временно превышал monotonic uptime стенда,
что исключало ошибочную ветку. Это только причинный контроль. Значение
**не предлагается как production workaround**: оно меняет политику очистки.
После опытов контрольные процессы остановлены.

Сохраняемый [probe-idle-handshake.py](naiveproxy-63/probe-idle-handshake.py)
проверяет готовность и аутентификацию до опыта; затем делает 14 попыток на
профиль с шагом 5 s и паузой 10 s после greeting. Он не выполняет CONNECT
к origin и не сохраняет endpoint/credentials. Инструкция — в
[README](naiveproxy-63/README.md#диагностика-idle-cleanup).

**Оставшаяся техническая граница:** проверенная сборка Naive с этим исправлением
должна пройти данный regression probe со **штатным** timeout и смешанный
нагрузочный опыт. Ни source patch, ни большой timeout не являются готовым
бинарным исправлением. Допуск закреплённого неизменённого ELF ограничен теперь
конкретным upstream-дефектом; дальнейшая разработка адаптера от этого не
становится запретной. Создание production toolchain/поставки не подменяется
исследовательской задачей #63.

Диагностический прогон убран: все его процессы и listeners остановлены,
rules/routes NC-1913 совпали с baseline; default route Pi через wlan0,
`ip_forward=0` и MTU eth0 1500 сохранены. Приватные каталоги этого прогона
удалены на роутере, Pi и ПК. Проверены JSON-суммы, локальные ссылки,
отсутствие ключей в артефактах, синтаксис probe и `git diff --check`.
Патч, probe и обезличенные результаты сохранены локально; upstream/GitHub
не изменялись. Несвязанные изменения telemetry сохранены.
