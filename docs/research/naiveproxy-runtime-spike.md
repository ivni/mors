# NaiveProxy: предварительная проверка замены HY2

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
