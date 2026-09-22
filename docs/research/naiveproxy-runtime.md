# NaiveProxy: исполнение, поставка и план runtime-проверки

Исследование [#61](https://github.com/ivni/mors/issues/61), 22.09.2026.
База: свежий `origin/main`, `b2e9d2ebb2e6208cb7b7491317285741ee371633`;
работа выполнена в отдельном detached worktree. Применяются
[REQ-CORE-001–007, 013–021](../connection-core-requirements.md) и
[матрица #59](connection-platform-matrix.md). PRINC-ID в AGENTS.md не заданы.

**Кандидат для #63 — официальный Chromium-клиент NaiveProxy
v150.0.7871.63-1, static OpenWrt assets для MIPSel и AArch64.
Production-активация и поставка пока BLOCKED. Для MIPS big-endian
штатного upstream решения нет.** Rust остаётся управляющим ядром;
реализация протокола, TLS и HTTP/2 принадлежит внешнему клиенту.

Это результат новой редакции #61. Старый [отчёт Hysteria 2](hysteria2-runtime.md)
сохраняет исторический смысл, но не задаёт runtime, API и процессы NaiveProxy.
[ADR-0001](../adr/0001-connection-core-boundaries.md) ещё содержит Hysteria/Clash;
его актуализация принадлежит #62. Этот отчёт передаёт решение в #62,
не реализует адаптер, routing, packaging или новую архитектуру ядра.
Существующие VLESS decision lock #57 и один Xray остаются без изменений.

## Доказательства и выбор

| Уровень | Фактически выполнено в #61 | Граница |
| --- | --- | --- |
| O | Прочитаны upstream README, USAGE, OpenWrt Support, workflow, Keenetic Proxy client; проверены tag и release API | Документы не доказывают runtime на Keenetic |
| S | Прочитаны parser, startup, SOCKS5, trust store и certificate-fetch context на закреплённом SHA | Выводы по коду, не интеграционное испытание |
| A | Скачаны два release-архива, сверены digests, состав, размеры и ELF headers | Не запуск, не проверка всего набора инструкций/syscalls |
| T-ref | Прочитан опубликованный [предварительный опыт](naiveproxy-runtime-spike.md) | Не повторён: MIPSel на NC-1913, три HTTP 200 через SSH-forward; не LAN/Proxy gate |
| T | Новые испытания роутера в #61 не выполнялись | Полный план ниже передан #63 |

Tag [S1] разрешается в commit `3ba967e2d36cc133a896e81a36257ad4c6ea20f4`.
`CHROMIUM_VERSION` на этом SHA — `150.0.7871.63` [S2]. Это закреплённый
кандидат, не заявление о latest или допустимом диапазоне версий.

| Вариант | Оценка |
| --- | --- |
| Официальный NaiveProxy, static OpenWrt | Выбран для испытания: тот же Chromium network stack и padding; отсутствует зависимость от loader/glibc Entware у проверенных ELF |
| Linux или динамический OpenWrt asset | Не выбран: потребуется отдельный анализ loader, libc/symbol versions и sysroot; название архитектуры недостаточно |
| Собственная реализация Rust / обычный HTTPS proxy | Не эквивалентны подтверждённому Chromium-клиенту; новый протокол и доказательство совместимости выходят за #61 |
| Порт Chromium на MIPS BE | Отдельное исследование неизвестной стоимости, не скрытая часть адаптера #81 |

## ABI, ISA, зависимости и размеры

Префикс архивов: `naiveproxy-v150.0.7871.63-1-`, расширение `.tar.xz` [S1].
Оба распакованных файла `naive` — `ET_EXEC`; ни `PT_INTERP`, ни
`PT_DYNAMIC`, ни `SHT_DYNAMIC` не обнаружены. Следовательно, у этих ELF
нет динамического загрузчика и таблицы `DT_NEEDED`; заменять это наблюдение
одним словом `static` в имени архива нельзя.

| Entware / asset suffix | Архив, bytes | ELF, bytes | Проверенные свойства A; ограничения |
| --- | ---: | ---: | --- |
| `mipsel-3.4` / `openwrt-mipsel_24kc-static` | 3441408 | 13911244 | ELF32 LE, EM_MIPS=8, flags `0x70001005`; `.MIPS.abiflags`: ISA 32/r2, GPR=32, CPR1 absent, FP ABI=3 (soft-float), O32 по e_flags. Не универсальный MIPS32r1 binary |
| `aarch64-3.10` / `openwrt-aarch64_cortex-a53-static` | 3443528 | 12268480 | ELF64 LE, EM_AARCH64=183, flags=0. Workflow задаёт cortex-a53; ELF header не подтверждает совместимость со всеми AArch64 CPU |
| `mips-3.4` / MIPS BE | — | — | Upstream явно не поддерживает big-endian [S3]; asset отсутствует. NaiveProxy capability BLOCKED, поддержка самой платформы Mors не удаляется |

SHA-256 скачанных архивов совпали с `assets[].digest` release API:

```text
mipsel archive 741b26a2425244f66adf99d93ed3cd41697aa6ba81660157b1f8f7c8dbf8374f
mipsel ELF     25531478648e9b586af7f85f5188e20151cc0a0f77940a2926d86658d5eaef95
arm64 archive  f5ae78ddeed9af8db8370b3ae544ef566fb786d8b7e03071767d2b2a1015246b
arm64 ELF      af0170d7482b03d4bdadf699cf412736633c432f01df28ff0a4567d8eae2c16f
```

Workflow [S4] задаёт MIPSel r2/soft-float; обе static-сборки отключают
allocator shim и PartitionAlloc. OpenWrt config [S5] задаёт musl и `-static`.
Это не Entware glibc binary: static musl устраняет внешний libc loader,
но не требования к CPU, ядру, syscalls, времени, энтропии и trust store.
Минимальное совместимое ядро NaiveProxy **не установлено**. Названия feeds
`3.4`/`3.10` не доказывают его; продуктовый минимум Mors остаётся KeeneticOS 5+.
Не переносить Rust/QEMU результаты #60 на Chromium.

ELF разобран локальным Node.js-парсером заголовков и `.MIPS.abiflags`;
скрипт [inspect-naiveproxy-elf.cjs](naiveproxy-61/inspect-naiveproxy-elf.cjs)
сохранён для повторения. Это ограниченная инспекция, не дизассемблирование.
Docker Desktop был запущен, но завершил инициализацию ошибкой службы
`dockerInference`; `readelf` и QEMU в этом проходе не использовались.
Runtime AArch64 и аппаратная матрица остаются BLOCKED до своих gates.

## Data path и управление

```text
защищаемый TCP LAN
  -> Keenetic Proxy -> точка входа общего координатора (#62/#78)
  -> loopback SOCKS5 CONNECT выбранного Naive runtime
  -> TLS с проверкой hostname/CA -> HTTPS HTTP/2 CONNECT -> сервер -> цель

защищаемый UDP -> блокировка по REQ-CORE-019–021
ядро -> typed config / start / probe / selection / routing / stop
```

Промежуточная точка входа здесь — требование к интеграции #62/#78, а не
уже существующий listener или готовый компонент. Она должна позволить
направлять только **новые** сессии в выбранный runtime, сохранять привязку
существующих и наблюдать их завершение. Одного изменения адреса Proxy
через RCI недостаточно для заявления о drain; его семантика не доказана.

[S6]/[S7] подтверждают SOCKS CONNECT; BIND и UDP ASSOCIATE получают `0x07`.
HTTP/3 (`quic://`) — иной внешний carrier TCP streams, не пользовательский
UDP. Для первого gate выбран `https://`/HTTP/2; HTTP/3, UDP/UoT и ICMP
не включены. Само наличие TCP-сессии ещё не доказывает negotiated HTTP/2:
#63 должен получить ALPN/серверное свидетельство без публикации секретов.

Keenetic [K1] описывает HTTP/HTTPS/SOCKS5 Proxy client с OS 3.9 и отдельно
рекомендует DoT/DoH. Это не меняет минимум Mors 5+ и не доказывает, что
защищаемый DNS действительно проходит выбранный выход. Прямой DNS вместо
неподдерживаемого UDP запрещён. `redir` NaiveProxy поднимает свой UDP
fake-IP resolver [S6]; его не выбираем: он создаёт второй владелец DNS,
пересекается с Mors DNS/ipset и теряет mapping при рестарте.

## Несколько профилей, bounded lifecycle и drain

**Факт S:** `listen` и `proxy` принимают массивы [S6]/[S8]. При двух и более
proxy chains число listeners должно совпадать; соответствие позиционное,
для каждого строится отдельный request context [S9]. Несколько listeners
не являются selector API. Startup читает JSON один раз и входит в RunLoop;
в исследованных startup/config/NaiveProxy файлах и USAGE не найдено
публичного live reload, переключения профиля, drain API или dry-run `check`.
Не посылать SIGHUP по аналогии с sing-box и не считать TERM graceful drain.

**Ограничение S:** `auth_store` в [S8] индексируется `SchemeHostPort`,
а не ID профиля. Для одинакового endpoint разные credentials записываются
в один ключ; последнее присваивание заменяет предыдущее. Поэтому общий
multi-profile process нельзя принять за универсальную модель пула.
Кроме того, startup перемещает `cert_net_fetcher` в первый context;
поведение последующих contexts с неполной цепочкой сертификатов требует
отдельного опыта. Этот отчёт не объявляет наблюдение по коду TLS bypass.

**Выбранная модель для #63/#81:** изоляция профилей процессами, один
loopback listener и один `https` endpoint на процесс. Это сознательная
плата RAM/FD за независимость auth, config и lifecycle. Нет отдельного
health-selector; все решения принимает общий координатор. Число процессов
Xray не меняется; пользовательский Keenetic Proxy не создаётся на профиль.

Предел не выводится из существующих четырёх VLESS:

- `L` — утверждённый по #63 лимит одновременно живых Naive профилей,
  включая active, проверяемые резервы и draining. Вне этого набора записи
  остаются в реестре; очередь probe ограничена и обслуживается ядром.
- Не более `L + 1` Naive процессов: один дополнительный слот только для
  candidate/reconfigure. `L` — обязательный конечный platform budget;
  до его измерения production admission BLOCKED. Для эксперимента проверить
  `L=1,2,4`, это точки нагрузки, не объявленный продуктовый максимум.
- На процесс один занятый loopback port; candidate получает новый порт.
  Порты назначает единый владелец с проверкой фактического bind, не поиск
  «свободного» порта без обработки гонки. Число sessions/FD и очередь
  соединений также имеют budget и отказ при превышении.
- Только одна mutation/reconfigure одновременно. При заполненных слотах
  новое действие ожидает в ограниченной очереди либо получает busy;
  бесконечное накопление draining generations запрещено.

Последовательность reconfigure: typed validation -> secret candidate 0600
в owned 0700 directory -> отдельный процесс/порт -> readiness + source-bound
probe -> атомарное переключение **новых** сессий через общий routing owner
-> drain старой generation -> scoped stop и очистка. Реестр, PID/start
identity, generation и ownership должны переживать crash recovery.
Секреты передаются через файл, argv содержит только путь; raw stderr,
NetLog и SSL key log не включаются в CLI/телеметрию.

Старый процесс нельзя убивать до подтверждённого завершения его сессий.
У native-клиента не найден публичный счётчик drain; общий ingress должен
давать учёт либо #62/#78 должны доказать другую точку наблюдения.
Если это невозможно, graceful capability остаётся BLOCKED. По deadline
не допускается скрытый разрыв: требуется предусмотренное контрактом
подтверждение прерывания или отказ/отложенное действие. Ошибка candidate
сохраняет предыдущую рабочую generation и закрытый защищаемый маршрут.

USAGE задаёт tunnel timeout 1800 s и idle timeout 600 s для non-Android;
они могут оборвать долгие TCP-сессии [S6]. Это не drain API и не обещание
бессрочного SSH. #63 измеряет фактическую семантику, #81 документирует
принятые значения; непроверенное «0 означает бесконечность» запрещено.

## TLS/CA, bootstrap и недопущение direct bypass

`TrustStoreUnix` [S10] читает CA file **и** директории. Непустой
`SSL_CERT_FILE` заменяет список стандартных файлов; непустой `SSL_CERT_DIR`
заменяет список каталогов. Одного `SSL_CERT_FILE` недостаточно, чтобы
ограничить доверие только выбранным bundle. Для воспроизводимой поставки
#69 задаёт явный read-only bundle и отдельный owned пустой CA directory;
#81 задаёт обе переменные только своему child process. Общий CA store
не переписывается. Пустая строка env не отключает системные defaults.

Рекомендуемый владелец bundle — пакет поставки #69 с версией, источником,
digest и лицензией, обновляемый вместе с проверенной ревизией trust policy.
Системный Entware bundle допустим только после явного dependency/path
контракта #62/#69. Текущий `runtime-dependencies.mk` не содержит NaiveProxy;
наличие curl не доказывает расположение/состав CA. Нельзя скачивать CA
из latest URL при активации. Custom CA — только явное действие пользователя,
без отключения проверки hostname/цепочки и без изменения чужого trust store.

`BuildCertURLRequestContext` [S9] создаёт отдельный context с пустым
proxy config, используемый certificate fetcher. **Вывод по коду:** возможные
AIA/служебные certificate fetches нужно учитывать отдельно от tunnel;
факт их выхода на WAN и условия запуска в #61 не измерены. #63 проверяет
полную/неполную server chain, DNS и packet capture, включая эти запросы.
Активация BLOCKED, если необходимый служебный путь не вписывается в
утверждённые endpoint exclusions и политику #62/#78. Нельзя разрешать
весь исходящий трафик процесса как компенсацию.

Bootstrap endpoint и DNS защищаемых целей — разные потоки. Ядро должно
получить актуальные A-адреса endpoint разрешённым bootstrap способом,
установить узкие WAN exclusions до запуска candidate и отслеживать смену
IP/TTL. `host-resolver-rules: MAP ...` [S6] позволяет оставить hostname
в HTTPS URI (SNI/verification) и закрепить адрес; это средство, не готовая
bootstrap policy. В URI нельзя подменять hostname IP без проверки TLS.
Защищаемые имена должны разрешаться через проверенный DNS/TCP путь;
SOCKS с domain name позволяет server-side resolution, но не заменяет
DNS клиента LAN. IPv6 не объявляется поддержанным; опыт должен исключить
его обход, не меняя настройки домашнего роутера.

Preflight #81 обязан отвергать отсутствующий/пустой proxy, direct, цепочки,
неподдерживаемые схемы и неизвестные опасные параметры. Upstream по
умолчанию использует direct и bind `0.0.0.0` [S6]/[S9]; Mors всегда
генерирует явные `https` endpoint и `socks://127.0.0.1:<owned-port>`.
Import `naive+https` — typed преобразование, не передача строки shell:
credentials декодируются/кодируются без потерь, query не игнорируется молча,
fragment не становится конфигурацией. Пример формы, не рабочий профиль:

```json
{
  "listen": "socks://127.0.0.1:18091",
  "proxy": "https://USER:PASSWORD@proxy.example.invalid:443"
}
```

## Лицензии, обновления и входные данные поставки #69

Каждый скачанный архив содержит только `naive`, `config.json`, `LICENSE`
и `USAGE.txt`. `LICENSE` совпадает с корневым Chromium BSD-3-Clause [S11];
его notice/условия/disclaimer должны сопровождать binary distribution.
Это **не полный** перечень статически включённых зависимостей.
OpenWrt musl [S5], Chromium/third-party, BoringSSL и zlib требуют
собственного учёта; наличие LICENSE upstream не доказывает готовность IPK.
Проверены исходные LICENSE BoringSSL/zlib [S12]/[S13], но полный link-derived
SBOM и notices для release binary не предоставлены этими четырьмя файлами.
**Gate поставки BLOCKED:** #69 должен получить проверяемый состав сборки
и соответствующие notices (включая musl/sysroot и CA) либо воспроизводимо
пересобрать тот же кандидат с manifest. Угадывать состав по ELF strings нельзя.

Передаваемый контракт #62/#69:

- Явное ABI→asset отображение из таблицы, закреплённые tag/commit/archive
  digest/ELF digest. MIPS BE не получает чужой little-endian binary.
- Архитектурный runtime package либо эквивалентная доказанная доставка по
  #62; `all.ipk` сам по себе не разрешает включить ELF одной архитектуры.
- Пассивная установка без запуска, DNS/firewall/RCI изменений. Проверка
  archive extraction, machine/ISA, version/help, CA и лицензий до admission.
- Chromium обновляется по стабильным upstream tags, не rebasing master [S2].
  Ответственность за отслеживание выпусков и уязвимостей — сопровождающий
  runtime package. Новая версия проходит ABI, TLS, TCP, UDP-negative,
  lifecycle и ресурсные gates до повышения проверенной версии.
- Upgrade/rollback сохраняют предыдущие binary/config/CA revisions;
  rollback уязвимой версии требует явной политики, не вечной фиксации
  старого Chromium. Автоматический runtime download latest запрещён.

Один экземпляр ELF на диске может использоваться многими процессами, но
private memory умножается. Минимальный staging peak «старый ELF + новый ELF
+ новый архив» для одинакового размера версии: MIPSel 31263896 bytes,
AArch64 27980488 bytes; сверх этого нужны CA, notices, IPK/распаковка,
configs, filesystem overhead и запас. Это арифметический нижний ориентир,
не установленный disk/RAM budget. T-ref RSS 8024 kB после трёх запросов
не эквивалентен суммарному RSS/PSS `L+1` процессов с Xray и DNS.

## Точный план #63 и критерии допуска

Каждый опыт фиксирует platform/OS/kernel, digest, время, конфигурационную
generation, команды без секретов, exit status и независимое наблюдение.
Перед подключением читается локальный `TEST_INFRASTRUCTURE.local.md`;
только разрешённый disposable target. Router client и PC/LAN probe
отмечаются отдельно. Нет стенда/сервера/наблюдения — **BLOCKED**, не PASS.

| Gate | Опыт и достаточное свидетельство |
| --- | --- |
| N0 — identity и rollback | Сверить модель/ISA/OS/kernel, свободные RAM/disk/ports, owned paths; снять исходные состояния только затрагиваемых процессов/Proxy/DNS/routes/firewall; подготовить cleanup и канал восстановления |
| N1 — ABI/lifecycle | Проверить digests/ELF, version/help; start/stop 10 циклов, неверный JSON/URI, отсутствующий CA, bind conflict, PID identity и отсутствие orphan. MIPSel hardware; AArch64 QEMU отдельно, без аппаратного PASS |
| N2 — direct SOCKS TCP | Реальный контролируемый сервер и HTTPS nonce endpoint; клиент на роутере, запрос через SOCKS. Совпавший одноразовый nonce в серверном журнале и независимый egress, HTTP/2/ALPN; route get или публичный HTTP 200 отдельно недостаточны |
| N3 — TLS/bootstrap | Valid CA, unknown CA, wrong hostname, expired cert, пустые file+dir, неверное время, полная/неполная chain; auth failure; endpoint DNS failure/смена IP/TTL, WAN exclusions, capture AIA/DNS. Ошибки не дают direct или ложную readiness |
| N4 — LAN/Proxy и DNS | Только после N2/N3: клиент LAN→Keenetic Proxy→выбранный Naive; nonce/egress, защищённые DNS-запросы и TCP fallback, packet capture no-loop. DoT/DoH должен идти разрешённым защищённым путём, а не просто быть включён |
| N5 — UDP-negative | SOCKS greeting и UDP ASSOCIATE возвращает unsupported; LAN DNS/UDP, QUIC/UDP и произвольный защищаемый UDP блокируются. Проверить WAN capture/counters при apply, отказе и restore; браузерный TCP fallback не доказывает отсутствие UDP утечки |
| N6 — профили и drain | `L=1,2,4`, в том числе одинаковый endpoint с разными credentials в отдельных процессах; serial probe/reconfigure, `L+1` slots. Длинная TCP-сессия остаётся на старой generation, новые идут только на выбранную. Проверить timeout, переполнение, отказ candidate и rollback; отсутствие счётчика/управления ingress блокирует graceful capability |
| N7 — ресурсы | Idle 5 min и TCP load 15 min на 1/8/32 параллельных streams (начать с малого); RAM RSS/PSS где доступно/HWM, CPU, FD, threads, throughput, latency, disk peak, start/stop time, влияние Xray/DNS. Прекратить при заранее установленном запасе RAM/FD; выбрать конечные platform budgets по измерениям |
| N8 — failure/restore | Local process failure отдельно от server stop/restore; управляемый сервер обязателен для второго опыта. Новые сессии после восстановления, no direct, sticky/no automatic failback, обрыв/сохранение старых явно отмечены. Локальный deny не заменяет server stop |
| N9 — cleanup/readback | Удалить только owned experiment state и восстановить затронутый snapshot; сверить DNS/firewall/routes/Proxy/services, отсутствие listeners/PID/temp credentials; чужой Xray сохранён. Не сообщать PASS до readback |

N0–N9 в этой задаче **не пройдены**; T-ref не закрывает строки таблицы.
Для MIPS BE требуется решение #62 о несовпадении capabilities либо отдельный
порт; автоматическое исключение платформы из Mors недопустимо.
Продуктовые численные budgets, защищённый DNS, endpoint service traffic,
ingress/drain и notices остаются явными блокерами #69/#81, а не условиями,
которые можно молча пропустить после успешного HTTPS smoke.

## Воспроизведение host-проверки

В отдельном каталоге исследования, не на роутере:

```sh
gh api repos/klzgrad/naiveproxy/git/ref/tags/v150.0.7871.63-1
gh release view v150.0.7871.63-1 --repo klzgrad/naiveproxy --json assets
gh release download v150.0.7871.63-1 --repo klzgrad/naiveproxy \
  --pattern '*mipsel_24kc-static.tar.xz' --pattern '*aarch64_cortex-a53-static.tar.xz'
sha256sum ./*.tar.xz
tar -xf naiveproxy-v150.0.7871.63-1-openwrt-mipsel_24kc-static.tar.xz
tar -xf naiveproxy-v150.0.7871.63-1-openwrt-aarch64_cortex-a53-static.tar.xz
node /path/to/mors/docs/research/naiveproxy-61/inspect-naiveproxy-elf.cjs \
  naiveproxy-v150.0.7871.63-1-openwrt-mipsel_24kc-static/naive \
  naiveproxy-v150.0.7871.63-1-openwrt-aarch64_cortex-a53-static/naive
# Дополнительная независимая проверка при наличии binutils (здесь не выполнена):
readelf -h -A -l -d -V naiveproxy-v150.0.7871.63-1-openwrt-mipsel_24kc-static/naive
```

На Windows SHA-256 получен `Get-FileHash -Algorithm SHA256`; архивы
распакованы `tar.exe`. Бинарники и upstream sources не включаются в Git.

Проверка результата: `static.sh` завершился с exit 0 в изолированной
копии после восстановления baseline LF, преобразованных Windows checkout.
ShellCheck/actionlint отсутствовали и были пропущены штатным скриптом;
полный CI gate этим не заявляется. Локальные ссылки, число столбцов таблиц,
JSON-пример и whitespace проверены отдельно; ELF helper выполнен на обоих
скачанных бинарниках. BATS не запускался: runtime/CLI не менялись.

## Первичные источники

Все закреплённые исходники ниже относятся к SHA кандидата; прочитаны
22.09.2026. Wiki [S3] изменяемая, показанная редакция 05.04.2025.

- [S1 — release и assets](https://github.com/klzgrad/naiveproxy/releases/tag/v150.0.7871.63-1).
- [S2 — README](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/README.md), [CHROMIUM_VERSION](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/CHROMIUM_VERSION).
- [S3 — OpenWrt Support](https://github.com/klzgrad/naiveproxy/wiki/OpenWrt-Support).
- [S4 — build workflow](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/.github/workflows/build.yml).
- [S5 — OpenWrt build config](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/build/config/openwrt/BUILD.gn).
- [S6 — USAGE](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/USAGE.txt).
- [S7 — SOCKS5](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/socks5_server_socket.cc).
- [S8 — config parser и auth_store](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/naive_config.cc).
- [S9 — startup, request contexts и listeners](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/naive_proxy_bin.cc).
- [S10 — TrustStoreUnix](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/cert/internal/system_trust_store.cc).
- [S11 — Chromium LICENSE](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/LICENSE).
- [S12 — BoringSSL LICENSE](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/third_party/boringssl/src/LICENSE).
- [S13 — zlib LICENSE](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/third_party/zlib/LICENSE).
- [K1 — Keenetic Proxy client](https://support.keenetic.com/peak/kn-2710/en/49443-proxy-client.html).
