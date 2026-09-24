# Воспроизводимые fixtures #63

Это инструменты исследования, не runtime Mors и не production Naive-сервер.
Перед любым SSH прочитать `TEST_INFRASTRUCTURE.local.md` и сверить target,
ProxyJump и маршруты Pi. Скрипты не устанавливают пакеты и не меняют RCI,
DNS, firewall или маршруты. Они запускают временный клиент только на
разрешённом disposable роутере. Не запускать `fixture-client.sh` на ПК.

## TLS-стенд

- `make-fixture-certs.py DIR` требует Python + cryptography; создаёт
  одноразовые root/intermediate, сертификаты valid/wrong-name/expired/unknown
  и полную/неполную цепочку. DIR должен быть закрыт ACL до запуска.
  Private keys не копировать на роутер или в Git, CA не устанавливать в OS.
- `node tls-fixture.cjs DIR` слушает только loopback: HTTPS origin 18444,
  HTTPS/HTTP2 CONNECT proxy 18443, 18445–18449. Узел назначения CONNECT
  жёстко ограничен `nonce.fixture.invalid:18444`; произвольного forward нет.
  Учётная запись `fixture:fixture-password` синтетическая, только для опыта.
- Создать SSH reverse forwards с тех же loopback ports роутера к ПК,
  например `-R 127.0.0.1:18443:127.0.0.1:18443`. SOCKS клиента 18100
  доступен workstation через `-L 127.0.0.1:28100:127.0.0.1:18100`.
  Использовать `ExitOnForwardFailure=yes`, проверить доступность портов.
- В closed JSON клиента задать `listen: socks://127.0.0.1:18100`,
  `proxy: https://fixture:fixture-password@proxy.fixture.invalid:18443`,
  `host-resolver-rules: MAP proxy.fixture.invalid 127.0.0.1`.
  В TLS-матрице менять только endpoint port, CA или credentials согласно
  варианту. Для bad-dns убрать MAP. Для resource-run использовать `load.json`
  без NetLog, чтобы запись trace не искажала нагрузку.
- На роутер доставить проверенный `naive`, публичные `root.pem`, `empty.pem`,
  закрытые config и shell helpers в `/opt/tmp/mors-naive63-followup-20260922`.
  Затем `fixture-client.sh prepare`, `start NAME`, probe, `stop`.
- HTTPS nonce генерировать отдельно на каждый probe, ровно 32 hex символа:
  `/nonce?value=NONCE`. Сверять тело ответа с `stats.json` у fixture.
  HTTPS origin curl проверяет по `--cacert root.pem`; на Windows Schannel
  `--ssl-revoke-best-effort` допускает отсутствие CRL у одноразового origin.
  Этот флаг не передаётся Naive и не отключает hostname/chain verification.

Fixture не согласует padding, а применяет стандартный HTTP/2 CONNECT.
Поэтому результаты доказывают TLS/auth/CONNECT и механизмы failure/restore
этого пути, но не WAN, Naive padding, сетевой egress, Keenetic Proxy или
поведение внешнего пользовательского сервера. Локальный управляемый stop
нельзя переименовать в stop внешнего сервера. `stats.json` содержит только
синтетические nonce и счётчики; NetLog всё равно хранить закрытым и удалить.

## Ресурсы

`python resource-run.py DIR 300`: idle 300 s, затем по 300 s запросов с
параллельностью 1/8/32. Каждый ответ — 256 KiB; пауза worker 250 ms.
Samples каждые примерно 30 s: RSS/HWM/PSS, FD, threads, MemAvailable,
process ticks и machine ticks. CPU считать как долю общей CPU capacity
между samples одной фазы; CPU SSH/sampling и других процессов не включён
в process ticks, но присутствует в нагрузке стенда. Заявление о CPU одного
ядра или benchmark WAN из этого измерения недопустимо.

Guard: MemAvailable < 65536 kB или FD > 256 останавливает нагрузку;
это границы безопасности опыта, не принятые продуктовые budgets.
`finally` останавливает клиент; SSH forwards и Node fixture принадлежат
внешнему launcher и должны быть закрыты отдельно с проверкой PID identity.
Не считать запуск с длительностью 10 s полным ресурсным gate.

`resident.sh start 1|2|4|5` запускает короткий resident snapshot из
`profile1.json`–`profile5.json`; `sample` повторяет измерение, `stop`
останавливает только записанные PID после проверки executable. Порты —
18101–18105, тот же fixture endpoint; у profile2 синтетический неправильный
password. Не запускать resident одновременно с однопроцессным benchmark.
Сумма RSS не эквивалентна физической памяти из-за shared pages.

`python diagnose-requests.py DIR 100 32` сравнивает по 100 direct-origin
и router-SOCKS запросов с concurrency 32. Требует работающего fixture и
клиента 18100; сохраняет только числовые результаты и закрытые категории
ошибок, не stderr. В выполненном полном benchmark начальная версия driver
сохранила только количество ошибок; в текущую версию добавлены их exit codes.
Успешный короткий повтор не аннулирует ошибки длительного опыта.

Исходные обезличенные TLS/resource samples и диагностический повтор:
[results-20260922.json](results-20260922.json). Не переносить throughput
этого SSH/loopback fixture на WAN и не выбирать production L только по RSS.

После опыта сверить исходные rules/routes, отсутствие owned PID/listeners,
удалить точный список временных файлов и пустые каталоги. Не применять
recursive delete к вычисленному пути. Сохранить только обезличенные
агрегаты в отчёте; исходный пользовательский keys.txt не изменять.

## Диагностика idle cleanup

`probe-idle-handshake.py PRIVATE_SETTINGS.json RESULTS.json` запускать на Pi
после проверки разрешённого стенда. Settings — закрытый JSON-массив из одного
или двух объектов с полями `label` (`default` или `control`), `host`, `port`,
`username`, `password`. Не коммитить settings; output содержит только закрытые
метки, время и числовые/классифицированные исходы.

Probe сначала проверяет готовность/аутентификацию, затем держит SOCKS handshake
10 s перед отправкой auth. 14 попыток с шагом 5 s пересекают минутную очистку.
Достаточно прямого SOCKS listener: upstream сервер и изменение маршрутов
не нужны. Для исправленного бинарника со штатным idle timeout 600 s все
попытки должны завершать аутентификацию. Probe не заменяет полный load gate.

`idle-handshake-created-at.patch` — минимальное source-исправление для
`klzgrad/naiveproxy` commit `3ba967e2d36cc133a896e81a36257ad4c6ea20f4`:
до первой записи getter возвращает время создания соединения. Проверка
из корня соответствующего upstream checkout:

```sh
git apply --check /path/to/idle-handshake-created-at.patch
```

Полный исправленный Naive-бинарник ещё не собран/не квалифицирован. Большой
idle timeout использован только как диагностический A/B-контроль и не должен
попасть в production defaults. Результаты и ограничения:
[results-20260924-diagnosis.json](results-20260924-diagnosis.json) и
[отчёт](../naiveproxy-runtime-spike.md#причина-ранних-обрывов-диагностика-24092026).
