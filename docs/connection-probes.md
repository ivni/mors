# Проверки конкретного подключения (#75)

`crates/probe` реализует самостоятельный Rust-компонент для выполнения probes.
Он использует типы наблюдений #70, но не выбирает active, не меняет маршруты,
не запускает backend и не пишет health на диск. База реализации: `main`,
`0046f04642d3e5644f0f164d4c1ed2ab28075f45`.

## Привязка и результат

- `CandidatePath::Native`: каждый TCP-сокет создаётся через безопасный API
  `socket2` и получает `SO_BINDTODEVICE` **до** передачи libcurl. Ошибка
  привязки закрывает сокет и возвращает `Binding`; unbound fallback отсутствует.
  Принимается точное имя интерфейса, а не source IP. Destination IPv4 передаёт
  вызывающий адаптер; `CURLOPT_RESOLVE` сохраняет hostname для Host/SNI и
  проверки сертификата, исключая скрытый DNS-запрос через default WAN.
- `Socks` и `NaiveProxy`: только числовой IPv4 managed loopback listener,
  SOCKS5 hostname resolution и команда CONNECT. `NO_PROXY` не обходит proxy;
  native-путь отключает любые proxy из окружения. Новый easy/multi handle на
  каждую проверку исключает reuse соединения другого кандидата.
- `NaiveProxy` требует HTTPS; HTTP-запрос отклоняется до I/O. Сам Chromium
  продолжает выполнять внешний транспорт; probe не заменяет его TLS/HTTP2.
- Контроль принимает либо точный 2xx статус с пустым телом, либо HTTP 200
  с единственным IPv4, совпадающим с ожидаемым адресом выхода. Адрес остаётся
  внутри проверки; наружу выходит только Success или AddressMismatch.
  Redirect не выполняется. Для NaiveProxy admission следует использовать
  HTTPS address-контроль; один status-контроль не подтверждает egress.
- Listener/interface должен принадлежать кандидату и оставаться закреплённым
  за ним на время probe. Эту lease, expected egress, revision/generation и
  независимость primary/confirmation endpoints обеспечивает вызывающий
  coordinator/adapter. Probe не может доказать внутреннюю маршрутизацию
  некорректно настроенного SOCKS backend; это отдельный platform admission.

`CandidateReport` хранит исходный ticket (generation, sequence, endpoint).
`observation()` превращает выполненную проверку в `Observation` #70 со временем
завершения из monotonic epoch координатора. Health отбрасывает старые generation
и sequence. Компонент не создаёт confirmation ticket и не выполняет retries:
два независимых подтверждения и решение о переключении остаются у health policy.

`upstream()` принимает отдельно заданный native-путь и возвращает другой тип
`UpstreamReport`, который нельзя превратить в candidate observation. Ни успех
upstream не исправляет failed candidate, ни одиночная ошибка контрольного
сервера не объявляет общий upstream Down. Интерпретация нескольких наблюдений
остаётся в coordinator/health по #70.

## Ошибки и возможности

Публичные результаты содержат только закрытые enum и latency. URL, интерфейсы,
адреса, response body, proxy errors и CA paths не имеют Debug/Serialize и не
попадают в отчёт. Раздельны DNS, CA, TLS, authentication, timeout, transport,
binding, неожиданный ответ, несовпадение адреса и превышение лимита.

Нельзя достоверно вывести причину, которую backend скрыл: SOCKS host-unreachable
может означать DNS или другой отказ. Он остаётся Transport. Только явные
libcurl DNS/auth ошибки классифицируются соответственно; auth Chromium,
свёрнутый в общий отказ SOCKS, не объявляется подтверждённым auth failure.
CA и TLS сведены в `Failure::Tls` при передаче в #70, но остаются раздельны
в непосредственном результате probe. Классификация не экспортирует raw error.

UDP NaiveProxy возвращает Unsupported **без сокета**. Для прочих backend этот
TCP-компонент возвращает UnimplementedTransport и не приписывает им отсутствие
UDP. TCP success никогда не повышает UDP capability или runtime admission.
Cancelled, Busy, InvalidRequest и PlatformUnavailable не являются outage и
не создают health observation. Native DNS discovery и защищённый DNS клиентов
остаются отдельными gates #62/#78/#81.

## Ограничения ресурсов и доверие

Один `Runner` на coordinator разделяет лимит candidate/upstream: по умолчанию
2, разрешено 1–16 одновременных probes; очередь отсутствует, переполнение — Busy.
Timeout по умолчанию 10 секунд, диапазон 10 мс–30 секунд. libcurl Multi работает
с неблокирующими сокетами; ожидание не более 10 мс за итерацию, без фоновых
worker threads. По timeout/cancel handle удаляется, transfer закрывается,
permit освобождается. Это deadline выполнения, не real-time гарантия планировщика ОС.

Body ограничен 16–16384 байт (по умолчанию 1024); суммарные HTTP headers — 8192
байта. Лимиты действуют и без Content-Length, включая chunked. Данные не
накапливаются после превышения. Конфигурация ограничена по длине, нет
распаковки ответа, redirect, retries, cookie jar, HSTS файла или durable health.
Память приложения ограничена этими буферами и числом handles; TLS/libcurl имеют
свои внутренние ограниченные протоколом буферы. Это не cgroup/RSS лимит процесса.

TLS peer/hostname verification всегда включена. По умолчанию используется
системный trust store libcurl; можно явно передать абсолютный CA file через
`with_ca_file`. Ответ сервера никогда не задаёт trust. `SSLKEYLOGFILE` запрещён:
при его наличии probe возвращает PlatformUnavailable до сетевого I/O,
чтобы debug-настройка не записала session secrets. Однако constructor crate
`curl` инициализирует библиотеку до `main()` и может создать пустой keylog файл.
**Launcher обязан удалять SSLKEYLOGFILE до exec daemon**; очистка внутри Rust
уже недостаточна для гарантии отсутствия startup-записей. Это обязательный
контракт будущей runtime-интеграции. Окружение должно оставаться неизменным.
Регрессионный тест подтверждает отказ probe и отсутствие TLS secrets даже
в ошибочно настроенном окружении; он не скрывает пустой startup-файл.

## Поставка и проверка

Linux backend требует системный libcurl с TLS и AsyncDNS, `socket2`; unsafe
в исходниках crate запрещён. Не-Linux возвращает PlatformUnavailable.
Host CI устанавливает libcurl headers, pkg-config, Python и OpenSSL.
`Cargo.lock` фиксирует Rust зависимости; host TLS/libcurl поставляет ОС.

Новый crate пока не включён в `mors-core`/router daemon и текущий IPK. Поэтому
Makefile, package release, shell-supervisor и decision lock #57 не меняются.
Target linkage libcurl, ABI/Entware builder admission и подключение scheduler
должны быть проверены при интеграции; host QA не доказывает работу на Keenetic.
Новые зависимости runtime-пакета при такой интеграции должны быть внесены в
канонический dependency manifest. Не расширять #75 до adapters/lifecycle.

Локальные fixtures создают HTTP/HTTPS и SOCKS серверы только на loopback,
одноразовый тестовый сертификат и удаляемый temporary directory. Они проверяют
реальный CONNECT с hostname, HTTPS CA/hostname/TLS, refusal/auth, egress mismatch,
отказ primary/confirmation endpoint, отсутствие redirect и proxy-env bypass,
несуществующий/другой интерфейс при доступном контрольном выходе, byte limits,
отмену in-flight, deadline, backpressure и раздельные TCP/UDP результаты.
DNS mapping дополнительно проверяется таблицей кодов; это не DNS router smoke.

### Фактическая проверка 27.09.2026

- Linux x86_64, Rust 1.94.0, системный libcurl 8.5.0 / OpenSSL 3.0.13.
- `scripts/qa/rust.sh`: PASS — fmt, clippy `-D warnings`, весь workspace,
  doc tests и release build. В `mors-probe`: 1 unit + 11 integration tests.
- `scripts/qa/static.sh`: PASS, включая ShellCheck и actionlint.
- `bats tests`: **508/508 PASS**; shell/runtime-файлы не изменялись.
- Исходники проверены в Linux snapshot с сохранёнными Git modes и LF;
  результат соответствует нормализованным файлам worktree.
- Локальные журналы: `.qa/issue75/rust-final.log`, `static-final.log`, `bats.log`.
- Router smoke, target ABI/linkage и runtime admission в этой задаче не проверялись.
