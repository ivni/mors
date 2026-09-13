# Hysteria 2: кандидат исполнения и план runtime-проверки

Исследование для [#61](https://github.com/ivni/mors/issues/61), 13.09.2026.
**Выбран кандидат для #63: sing-box 1.14.0, отдельный процесс транспорта
Hysteria 2 под управлением Rust-ядра Mors. Готовность на Keenetic не доказана.**
Адаптер, зависимости пакета и конфигурация роутера в этой задаче не меняются.

## Основание и уровень доказательств

База — `origin/main` после `git fetch origin main`:
`43ef141f366a7d7e5a22c6fe0558fc62fa529097`. Создан отдельный detached worktree.
На момент исследования зависимость [#59](https://github.com/ivni/mors/issues/59)
была закрыта, но её [матрица платформ](connection-platform-matrix.md)
отсутствовала в удалённом `main`: использована **зафиксированная локальная**
версия из коммита `af6823c`.
Изменения рабочей копии этой матрицы не приняты за проверенные факты.
Исследуемые `vless`, `vless_config` и `runtime-dependencies.mk` совпадают
с `origin/main`. Нормативные границы VLESS прочитаны на базовом SHA.

Перед публикацией отчёта 13.09.2026 повторно получен `origin/main`
`ed1bef779a0e85450ed6ef2335e04611d7400c24`: он уже содержит результат #59.
Указанные runtime-файлы и VLESS-архитектура не изменились относительно базы
исследования; зависимость и локальные ссылки проверены на этой версии.

[Контракт #58](../connection-core-requirements.md): REQ-CORE-001–007,
013–018. В частности: один общий выбор новых сессий, Hysteria на общих
основаниях, сохранение платформ, Rust-ядро, graceful-семантика, отсутствие
неразрешённого прямого резерва. Применимые PRINC-ID: —; используются REQ-ID.

| Уровень | Что проверено здесь | Чего он не доказывает |
| --- | --- | --- |
| O | Первичные документы и GitHub release API на дату исследования | Работу на конкретной OS/модели |
| S | Исходники на закреплённых SHA, включая build/lifecycle/API | Успешную сборку или runtime |
| A | Скачанные release-архивы: SHA-256, ELF-заголовки и Go build info | Установку, запуск, TCP/UDP, потребление памяти |
| H | Проверка примерного JSON через Windows `sing-box check` | Linux ABI, сеть, реальный endpoint или управляемость на роутере |
| T | Испытание на разрешённом disposable Keenetic | В этой задаче **не выполнялось** |

## Решение (mini-ADR HY2-61)

Статус: **кандидат выбран для испытания**, принятие в production заблокировано
gates ниже. Контекст: нужно поддержать несколько профилей и три семейства
Entware, оставив политику здоровья/выбора общему ядру, а протокол — готовому
клиенту. Ни Go, ни внешняя реализация Hysteria не заменяют требование Rust-ядра.

| Вариант | Возможности и ограничения | Решение |
| --- | --- | --- |
| **sing-box v1.14.0**; SHA `0b8995879f29a9b98ee027bc17b75e101445b238`; релиз 31.08.2026 [S1] | Hysteria2 TCP/UDP, SOCKS inbound, несколько именованных outbound в одном процессе, ручной selector через Clash API; есть три нужных release ABI. Большие сборки, AArch64 loader и reload требуют отдельной проверки | Основной кандидат #63; целевой вариант упаковки — минимальная сборка того же SHA, без лишних протоколов и UI |
| **Официальный Hysteria app/v2.12.2**; SHA `619a6f856b69fb7ee6a7a379e810e68b84004605`; релиз 23.08.2026 [H1] | SOCKS5 TCP/UDP; одна `Server string` в client config, один reconnectable client на процесс. Несколько входных modes обслуживают тот же сервер. Готового MIPS BE asset в релизе нет; `hyperbole.py` знает `mips-sf`, но это не результат сборки | Эталонный сервер для #63 и резервный клиент для сравнительного опыта, если размер/зависимости sing-box окажутся неприемлемыми |
| Переписать Hysteria на Rust или встроить Go runtime через FFI | Добавляет ответственность за QUIC, совместимость протокола и unsafe/ABI вместо интеграции готового транспорта | Не входит в #61; не требуется контрактом Rust-ядра |

Последствия: один Rust-процесс управления, один sing-box для Hysteria-профилей
и существующий **один Xray для всех VLESS**. Количество процессов sing-box
не растёт с числом профилей; число QUIC-сессий, сокетов и буферов может расти.
Это инженерная схема, не измерение памяти и не решение о максимуме профилей.
Не переносить текущий предел четырёх VLESS на весь пул.

Официальный клиент проще как узкий транспорт, но модель «процесс на профиль»
умножает Go runtime и требует внешнего переключателя локальных proxy.
Замена `server` с перезапуском единственного клиента разрывает старые сессии.
Слова graceful shutdown в его логах не доказывают drain пользовательских
сессий. В `app/cmd/client.go` обработаны SIGINT/SIGTERM, подтверждённого
client API для смены профиля/SIGHUP reload не найдено [H2].

Для sing-box обычное переключение **существующего** outbound выполняется
selector API, а не SIGHUP. `cmd_run.go` при SIGHUP закрывает экземпляр и
создаёт новый [S4]; добавление/удаление/изменение состава профилей поэтому
не объявляется бесшовным. #81/#94 должны доказать безопасный lifecycle,
drain либо явно подтверждаемый разрыв. Это граница зависимой реализации,
а не разрешение незаметно ослабить REQ-CORE-013.

## Версии, ABI и зависимости

GitHub API для старого `apernet/hysteria` перенаправляет на
`HyNetworks/hysteria`; использованы официальный tag и SHA, а не зеркало.
На 13.09.2026 API `releases/latest` вернул версии из таблицы выше.
Для повторения использовать **закреплённые tags**, не `latest`.

Матрица #59 сохраняет `mips-3.4` (big endian, soft-float), `mipsel-3.4`
(little endian, soft-float) и `aarch64-3.10`. Название feed обозначает базовое
ядро Entware, а не версию KeeneticOS. `PKGARCH:=all` не гарантирует ABI.

Скачаны и прочитаны следующие **официальные**, не пересобранные артефакты [S1]:

| Entware | Архив sing-box 1.14.0 | Байты архива / ELF | Результат A |
| --- | --- | --- | --- |
| mips-3.4 | `sing-box-1.14.0-linux-mips-softfloat.tar.gz` | 24536575 / 84607133 | ELF32, big endian, EM_MIPS=8; нет PT_INTERP/PT_DYNAMIC; GOARCH=mips, GOMIPS=softfloat |
| mipsel-3.4 | `sing-box-1.14.0-linux-mipsle-softfloat.tar.gz` | 24031101 / 84607133 | ELF32, little endian, EM_MIPS=8; нет PT_INTERP/PT_DYNAMIC; GOARCH=mipsle, GOMIPS=softfloat |
| aarch64-3.10 | `sing-box-1.14.0-linux-arm64.tar.gz` | 29059388 / 75759845 | ELF64, little endian, EM_AARCH64=183; **есть PT_INTERP/PT_DYNAMIC**, interpreter `/lib/ld-linux-aarch64.so.1`; GOARCH=arm64, GOARM64=v8.0 |

SHA-256 архивов (совпали с `assets[].digest` release API):

```text
9860fbb14b302ec2fe2862c3ef7b5799669032cb1fb542b4f09f14a023c0783d  sing-box-1.14.0-linux-mips-softfloat.tar.gz
f50ddc1fed715b8045b2d65cdb123152584d01938de950155cfd7f59389a5ffc  sing-box-1.14.0-linux-mipsle-softfloat.tar.gz
04d9b40bc98dc55b6f509ce3292145c65478f65866bea64826ebb2f382385088  sing-box-1.14.0-linux-arm64.tar.gz
```

SHA-256 извлечённых ELF соответственно:

```text
a757fafb0e68b84bcf6a00a85d9821e0d000494e34d1d036d08c5cb43253311d  mips-softfloat/sing-box
a832456dae2691aff481d2355ff21c8c4298398aa7fdbee37b7945c59a2a922d  mipsle-softfloat/sing-box
4393306b90bb05502fce3b8f1754280f531c0f3ff47df9b1997b7831e3e543d0  arm64/sing-box
```

Все три build info содержат `go1.26.7`, `CGO_ENABLED=0`, `with_quic` и
`with_clash_api`. AArch64 дополнительно содержит `with_purego` и
`with_naive_outbound`. Значит, **CGO_ENABLED=0 недостаточно для заявления
о независимости от динамического загрузчика**. Нельзя подменять отсутствие
`/lib/ld-linux-aarch64.so.1` симлинком наугад или брать glibc/musl-вариант
по имени. DT_NEEDED, требуемые символы/версии libc и запуск AArch64 ещё
не проверены; нахождение имени `.so` среди строк не является DT_NEEDED.
Размер ELF на диске не равен RSS. Проверка ELF MIPS не доказывает наличие
всех нужных syscalls/atomics на старом ядре.

У sing-box `go.mod` объявляет Go 1.25.5, workflow закрепляет **1.26.7** [S2].
У Hysteria app — `go 1.25.0`, `toolchain go1.25.1`, workflow использует
ветку **1.26**; минимальное объявление module не доказывает собираемость
всего графа зависимостей старым toolchain. Go с 1.24 требует Linux ≥3.2,
FUTEX/EPOLL; для mips/mipsle указан MIPS32r1 [G1]. Это необходимые условия,
не обещание поддержки конкретной модели или всей KeeneticOS 3.9.

Состав и владение зависимостями:

- На роутере не нужен Go compiler. Нужны проверенный бинарник, доступный
  файл доверенного CA/системный trust store и корректные часы для TLS,
  loopback sockets, доступный UDP до Hysteria-сервера, Proxy client OS.
  Ядро отвечает за сервис, секретный config, порты, ресурсы и исключения.
- QUIC/TLS/конкретные Go-модули входят в build dependency graph [S2/H2].
  SOCKS-путь не требует TUN, дополнительного Xray, стороннего tun2socks
  или kernel-модуля Hysteria. Наличие userspace Brutal не означает,
  что нужен `tcp-brutal`; mimic/fake-TCP с kernel/XDP сюда не выбран.
- В `MORS_RUNTIME_DEPENDS` сейчас есть Xray и Shadowsocks, **нет sing-box
  или hysteria**. Наличие release tar.gz не означает наличие подходящего
  Entware IPK. Новая зависимость, лицензии/исходники, checksums, установка,
  обновление и rollback относятся к #67–#69/#81/#116, не добавляются здесь.
- Предлагаемая минимальная сборка sing-box: `with_quic,with_clash_api`,
  `CGO_ENABLED=0`, Go 1.26.7, тот же SHA. Удаление необязательных build tags
  — отдельный воспроизводимый артефакт, требующий новых hash/ELF/тестов.
  **Она в #61 не собрана**. Нельзя приписывать ей hashes/размеры upstream.

Команды воспроизведения A на отдельном Linux build-хосте, не на роутере:

```sh
gh api repos/SagerNet/sing-box/releases/tags/v1.14.0 \
  --jq '{tag_name,published_at,assets:[.assets[]|{name,size,digest}]}'
mkdir -p hy61-assets
gh release download v1.14.0 --repo SagerNet/sing-box \
  --pattern 'sing-box-1.14.0-linux-mips-softfloat.tar.gz' \
  --pattern 'sing-box-1.14.0-linux-mipsle-softfloat.tar.gz' \
  --pattern 'sing-box-1.14.0-linux-arm64.tar.gz' --dir hy61-assets
for a in hy61-assets/*.tar.gz; do
  sha256sum "$a"
  tar -xf "$a" -C hy61-assets
done
for b in hy61-assets/*/sing-box; do
  sha256sum "$b"
  readelf -h -l -d -A "$b"
  go version -m "$b"
done
```

В текущей Windows-сессии использованы `gh release download`, `tar`,
`Get-FileHash` и чтение ELF/Go build info без исполнения Linux-файлов.
`readelf` выше — команда независимого повторения, не выданный за выполненный
локальный тест. Новая минимальная сборка для следующего gate:

```sh
git clone --branch v1.14.0 --depth 1 https://github.com/SagerNet/sing-box.git hy61-src
cd hy61-src
test "$(git rev-parse HEAD)" = 0b8995879f29a9b98ee027bc17b75e101445b238
# Выполнять с проверенным Go 1.26.7. Сначала сверить go version.
mkdir -p out
for arch in mips mipsle arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" GOMIPS=softfloat GOTOOLCHAIN=local \
    go build -trimpath -tags with_quic,with_clash_api \
    -ldflags '-s -w -X github.com/sagernet/sing-box/constant.Version=1.14.0' \
    -o "out/sing-box-$arch" ./cmd/sing-box || exit 1
  sha256sum "out/sing-box-$arch"
  readelf -h -l -d -A "out/sing-box-$arch"
done
```

## Data path и интерфейс управления — разные контракты

**Client transport:** удалённое соединение Hysteria 2 — QUIC/TLS поверх UDP;
через него передаются пользовательские TCP и UDP. `network: tcp` в sing-box
ограничивает пользовательские запросы, а не превращает QUIC в TCP; для
обоих видов трафика поле оставляется пустым [S3]. SOCKS5 TCP CONNECT и
UDP ASSOCIATE — локальный интерфейс данных между Keenetic и транспортом.
HTTP CONNECT сам по себе не заменяет UDP ASSOCIATE.

**Control interface:** Rust-ядро генерирует конфигурацию, запускает/останавливает
процесс, проверяет его идентичность и вызывает локальный Clash REST API
sing-box. `GET /proxies/hy-select` возвращает `now`/`all`,
`PUT /proxies/hy-select` с `{"name":"hy-a"}` выбирает существующий outbound
и возвращает 204; неизвестный tag — 400 [S4]. Ответ API и живой PID не равны
успешному probe. API привязан к loopback, с отдельным secret; без web UI,
без самостоятельного urltest-выбора и без cache_file как второго источника
истины. Решение о здоровье/активации принимает только общее ядро.

`interrupt_exist_connections:false` относится к inbound-соединениям;
внутренние соединения selector могут прерываться [S4]. Поэтому graceful
TCP/UDP под реальной нагрузкой остаётся проверкой #94. Управляющий API
sing-box не является RCI Keenetic. Lifecycle Proxy принадлежит отдельному
адаптеру платформы, которым управляет то же ядро.

### Предпочтительная точка интеграции

```text
LAN: выбранные Mors назначения
  -> политика/маршрутизация Keenetic -> один управляемый Proxy (SOCKS5)
  -> loopback-вход точки выбора транспорта
  -> sing-box: выбранный Hysteria outbound -> физический WAN -> HY2 server

Rust core -> реестр/health/decision lock -> backend API и platform adapter
```

В #63 испытывается **прямой** путь Proxy → loopback SOCKS sing-box. Для этого
изолируется тестовая LAN/политика и берётся snapshot; существующий Proxy21
нельзя присвоить или переподключить поверх рабочего VLESS без процедуры #62.
Одновременное присутствие Xray и sing-box не означает, что оба принимают
новые защищаемые сессии или что mixed failover уже проверен.

Схема Proxy относится к внешним proxy-движкам. Она не требует проводить
штатные WireGuard/IKE/SSTP и остальные native VPN через глобальный Proxy
или Xray: у их адаптеров собственные точки применения маршрута в #62.
Для общего пула точка выбора должна направлять новые сессии к текущему backend
и сохранять привязку старых. Где именно расположен общий переключатель,
решает [#62](https://github.com/ivni/mors/issues/62). Переписывать upstream
адрес единственного Proxy на каждом failover без проверки drain — плохая
граница: это связывает выбор с реконфигурацией интерфейса и рискует рвать
сессии. Не добавлять Proxy или Xray на каждый профиль; не расширять sing-box
до замены существующего VLESS runtime внутри #61.

Keenetic документирует компонент **Proxy client с OS 3.9**, SOCKS5 и участие
в политиках [K1]. Статья рекомендует DoT/DoH для DNS, но не даёт достаточного
контракта UDP ASSOCIATE, размера datagram или readback его работоспособности.
Следовательно, «sing-box поддерживает UDP» **не доказывает** UDP LAN→Keenetic
Proxy→sing-box. Проверки прямого SOCKS и пути из LAN должны иметь разные
результаты. Требуются точные OS, компонент и модель; обновлять OS автоматически
для прохождения gate нельзя.

### Защита от петли и DNS

1. До включения перехвата разрешить адреса HY2-сервера через независимый
   bootstrap DNS и установить обход для всех текущих IPv4 endpoint на WAN.
   SNI сохраняется отдельно от подставленного IP; TLS verification включена.
2. Проверить `ip rule`, соответствующие routing tables и маршрут к endpoint
   с фактическими source/mark процесса. `bind_interface`/`routing_mark` sing-box
   [S5] — дополнительные средства, не замена endpoint exclusion. Нельзя
   выбирать Proxy, TUN или общий selector в качестве выхода внешнего QUIC.
3. Согласовать исключения с существующим `MORS_DESTINATION_EXCLUDED`,
   сохраняя чужие/старые ещё используемые endpoint. В #63/#62 проверить
   также путь **локально созданного OUTPUT**, не только LAN PREROUTING.
4. При смене DNS-адреса сначала добавить новый обход и проверить маршрут,
   затем применять endpoint; старые записи снимать после освобождения
   зависимых сессий. Проверить повторное разрешение, WAN reconnect и отказ DNS.
   Port hopping меняет порты, поэтому исключение только UDP/443 недостаточно.
5. Bootstrap DNS самого транспорта, DNS защищаемых клиентов и DNS probe —
   три отдельных потока. DNS клиентов проверяется через выбранный выход;
   UDP/53, TCP fallback и используемый DoT/DoH путь не смешиваются в один PASS.
   В первом опыте использовать фиксированный IPv4 endpoint; DNS-ротацию
   включить отдельным шагом. IPv6 в этом исследовании не добавляется.

На отказе транспорта защищаемый трафик не должен переходить на прямой WAN.
Прямой маршрут к **серверу транспорта/bootstrap resolver** не равен прямому
резерву для пользовательского назначения. Синхронизация исключений и запрет
прямого fallback — условия до активации, а не последующая оптимизация.

### Условная альтернатива: TUN/TPROXY

Альтернатива открывается только если #63 воспроизводимо покажет: прямой
SOCKS UDP работает, но UDP через Proxy не проходит на сохраняемой платформе,
либо #62 докажет другую несовместимость точки интеграции. Тогда отдельный
опыт TUN или TPROXY проверяет capability ядра, netfilter, маршруты, MTU,
владение/rollback и стоимость ресурсов; не менять архитектуру молча.

TUN требует доступного `/dev/net/tun`, прав настройки интерфейса и маршрутов.
TPROXY требует поддержки ядра/xtables и policy routing для TCP и UDP.
TCP REDIRECT не решает UDP. Автоматические routes/redirect sing-box могут
конфликтовать с NDM и захватить собственный QUIC: до их применения нужны
зафиксированные исключения и доказательство #62. Ни один путь не испытан здесь.

Официальный Hysteria TUN переносит только TCP/UDP, **не ICMP**, и отдельно
требует endpoint exclusions [H3]. В sing-box поддержка ICMP других outbound
не распространяется на Hysteria2: его транспорт остаётся TCP/UDP [S3/S6].
Локально синтезированный ответ ping или прямой ICMP обход не является
проверкой туннеля. `hysteria ping` в исходниках — **TCP ping**, не ICMP [H2].

## Минимальный пример для проверки схемы

Это синтетический JSON с TEST-NET endpoint, не готовая конфигурация роутера.
Перед #63 подставляются **локально** реальные данные, свободные порты,
проверенный trust store и физический WAN binding; секреты не попадают в git.
Два inbound позволяют отделить принудительный probe от основного selector.

```json
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "socks", "tag": "hy-main", "listen": "127.0.0.1", "listen_port": 18080},
    {"type": "socks", "tag": "hy-probe-a", "listen": "127.0.0.1", "listen_port": 18081}
  ],
  "outbounds": [
    {
      "type": "hysteria2", "tag": "hy-a",
      "server": "192.0.2.1", "server_port": 443,
      "password": "REPLACE_LOCALLY",
      "tls": {"enabled": true, "server_name": "hy.example.invalid"}
    },
    {
      "type": "selector", "tag": "hy-select", "outbounds": ["hy-a"],
      "default": "hy-a", "interrupt_exist_connections": false
    }
  ],
  "route": {
    "rules": [{"inbound": ["hy-probe-a"], "action": "route", "outbound": "hy-a"}],
    "final": "hy-select"
  },
  "experimental": {
    "clash_api": {"external_controller": "127.0.0.1:19090", "secret": "REPLACE_LOCALLY"}
  }
}
```

H: этот блок **проверен**, exit 0, Windows-бинарником из официального
`sing-box-1.14.0-windows-amd64.zip`, командами `sing-box version` и
`sing-box check -c hy61-example.json`. `run` не вызывается. `check` не
аутентифицируется на сервере и не подтверждает путь DNS/TCP/UDP.
Вывод version: `1.14.0`, `go1.26.7 windows/amd64`, revision
`0b8995879f29a9b98ee027bc17b75e101445b238`. SHA-256 проверенного ZIP:
`3ffb56267da14e287be48bd10cf7e6505260125bad940b75101fbb4d5d58e5d6`.

## Точный план #63 и gates

Владелец следующих проверок — исполнитель
[#63](https://github.com/ivni/mors/issues/63); результаты точки интеграции
зависят также от #62. До подключения он читает локальный
`TEST_INFRASTRUCTURE.local.md`, подтверждает доступность именно разрешённого
disposable target и внешнего управляемого HY2-сервера с UDP. Домашний роутер
не заменяет стенд. Если стенд недоступен — **BLOCKED**, без условного PASS.

Локальный evidence-каталог защищён `umask 077`. У отчёта публичными остаются
модель, OS, ABI, версии/digests, сценарии, численные результаты и
классифицированные ошибки. IP, имена реальных endpoints, credentials,
полные configs, argv и необработанные stderr/pcap туда не переносятся.
Это же относится к будущей телеметрии; внешний клиент не меняет её контракт.

| Шаг | Действия и воспроизводимая проверка | Критерий и область результата |
| --- | --- | --- |
| R0. Baseline/rollback | Локально сохранить модель/OS/components, `uname -r`, `opkg print-architecture`, `/proc/cpuinfo`, `/proc/meminfo`, `ip -4 rule`, `ip -4 route show table all`, текущие owned hooks/rules и конфигурацию затрагиваемого Proxy. Сверить путь возврата #62 и доступ управления | Нет разрешённого target, backup или применимого rollback — BLOCKED до изменений |
| R1. Бинарник | Сопоставить ABI и SHA с таблицей; проверить loader/DT_NEEDED либо собрать минимальный pinned вариант, повторить ELF и hash. На стенде `sing-box version`, затем `sing-box check -c "$HY_CONFIG"` | Нужный version/tags, exit 0, без loader/ISA/syscall ошибок. На AArch64 upstream ELF не запускать как заведомо независимый от libc. Каждая ABI получает отдельный результат; один MIPSel не закрывает три строки |
| R2. Lifecycle | Запустить один процесс foreground под тестовым supervisor с защищённым config, без service install/autostart; записать PID+starttime и время готовности. Проверить loopback listeners, три цикла start/TERM/wait | Запуск и остановка ≤30 s каждый (порог spike, не обещание продукта), нет оставшихся дочерних процессов/сокетов. Port conflict и malformed config не затрагивают текущий VLESS |
| R3. Прямой TCP | На роутере `curl --fail --show-error --max-time 15 --socks5-hostname 127.0.0.1:18081 "$TCP_TEST_URL"`; контролируемый сервер проверяет egress и nonce | Успешный ответ именно через HY2, серверный журнал/счётчики согласуются. 10/10 запросов. Это только SOCKS TCP, ещё не Proxy и не UDP |
| R4. Прямой UDP | Тестовый SOCKS5 probe держит TCP control channel: greeting 05/01/00, UDP ASSOCIATE CMD=03; отправляет UDP-заголовок RSV=0, FRAG=0, ATYP=IPv4 с dst/port и nonce на возвращённый relay, проверяет обратный nonce | 100 datagrams для payload 64/512/1200 байт, записаны loss/latency; на контролируемой ненагруженной линии 100/100 для каждого размера. Повторить после idle > UDP timeout. curl и HTTP/3-запрос не заменяют этот probe |
| R5. Реальный LAN→Proxy | По процедуре #62 направить только disposable LAN-клиент/назначения через SOCKS Proxy. На LAN: `curl --fail --max-time 15 "$TCP_TEST_URL"` без SOCKS-флага; `iperf3 -c "$UDP_TEST_IP" -u -b 1M -t 30 --get-server-output` к контролируемому серверу | TCP egress/nonce и UDP подтверждены на удалённой стороне, исключён direct bypass. UDP loss ≤1% в опыте 1 Mbit/s; фиксировать TCP control iperf отдельно. Если R4 PASS, а R5 UDP FAIL — блокируется Proxy-вариант и исследуется условная альтернатива |
| R6. DNS/петля | Из LAN: `dig @"$ROUTER_DNS" "$TEST_NAME" A` и `dig +tcp @"$ROUTER_DNS" "$TEST_NAME" A`; проверить фактический настроенный DoT/DoH путь. На стенде `ip -4 route get "$HY_IP"`, полный rule/table/source/mark путь и краткий локальный capture QUIC на WAN и loopback; сменить адрес тестового HY2 DNS и переподключить WAN | Endpoint и bootstrap уходят через физический WAN, защищаемый DNS — через назначенный путь. Нет повторного попадания QUIC в Proxy, роста пакетов по кругу, stale endpoint или прямой утечки. Один `route get` без policy/mark/capture недостаточен |
| R7. Ресурсы/сосуществование | По 5 min: baseline, Xray-only, HY2 idle, Xray+HY2 idle, TCP, UDP, смешанная нагрузка; 1/2/4 HY2-профиля, активен один, прочие probe. Нагрузка 1/5/10 Mbit/s, параллелизм 1/8/32; немедленно остановить при деградации управления | Каждые 1 s: VmRSS/VmHWM/Threads/FD процесса, MemAvailable, swap, CPU из delta utime+stime и /proc/stat; при наличии smaps_rollup — PSS; throughput, loss, latency, температура при доступности. Нет OOM/crash, остаточного роста RSS/FD после 10 циклов. Продуктовые RAM/CPU/лимит профилей остаются решением по измерениям, не взяты с потолка |
| R8. Отказ/возврат | На управляемом сервере остановить HY2 на 60 s, сохраняя отдельную WAN-проверку, затем восстановить; во время отказа продолжать новые TCP/UDP из LAN; повторить с серверным запретом UDP, неверным auth и неверным TLS trust | При отказе нет прямого egress; восстановление новых TCP/UDP за ≤60 s после возврата сервера (порог spike). Записать реальное время и причины. Старые сессии могут оборваться: миграция сессий и полный mixed failover не заявляются |
| R9. Readback/cleanup | Через защищённый curl config вызвать GET selector, PUT известного tag и GET readback; затем PUT неизвестного tag и убедиться, что выбор сохранился. Проверить второй HY2-профиль и отдельный probe. Остановить owned PID, вернуть snapshot/rules/Proxy, убрать только принадлежащие опыту секреты | API/выбор воспроизводимы, нет второго владельца policy. VLESS доступен после возврата, посторонние конфигурации/маршруты сохранены; остатки исключений и listeners сверены с baseline |

R4 требует небольшой **тестовый** SOCKS5 UDP probe в #63 (на LAN-хосте
либо на роутере через локальную доставку); его отсутствие — BLOCKED UDP,
не повод поставить Python в runtime-зависимости Mors. Конкретный executable,
его SHA, команда запуска и seed/nonce должны попасть в evidence #63.
iperf3, tcpdump, readelf и генераторы нагрузки — средства стенда/build-хоста,
а не новые обязательные зависимости пользовательского пакета.

Для управления API использовать `curl --config "$API_CURL_CONFIG"`, где
Bearer header хранится в файле 0600; тело `{"name":"hy-a"}` также можно
передать `--data-binary @"$SELECT_REQUEST"`. Не включать secret в argv/log.
Команды R0–R9 — **план**, не выполненные в #61 испытания.

### Регистр нерешённых рисков

| ID | Неизвестное / практический риск | Владелец, проверка и безопасное состояние до результата |
| --- | --- | --- |
| HY61-G1 | Запуск на всех трёх ABI, особенно AArch64 loader и старые MIPS ядра | #63 R1, упаковка #68/#69: соответствующая платформа не объявляется готовой; не исключается из охвата |
| HY61-G2 | Сквозной UDP Keenetic Proxy и отсутствие петли | #62/#63 R4–R6: backend не активируется; TUN/TPROXY только по доказанной необходимости |
| HY61-G3 | RSS/CPU/storage/FD при нескольких профилях и Xray | #63 R7: неизвестны максимальный пул и минимальная RAM; большая upstream-сборка не считается пригодной для слабого роутера по факту скачивания |
| HY61-G4 | Сохранность сессий при смене состава профилей и выборе между backend | #62/#81/#94: запрещён скрытый restart/RCI-reconfigure как graceful; нужен отдельный lifecycle-контракт |
| HY61-G5 | Подходящий Entware пакет, минимальная сборка, trust store и безопасный upgrade | #67–#69/#81/#116: tar.gz не устанавливается как релиз Mors; текущие package dependencies не меняются |

Все G1–G5 **открыты**. Завершение исследования #61 не закрывает их.
Новая работа за границами перечисленных issues, если потребуется: только
доказанный альтернативный TUN/TPROXY data path или отдельный drain-механизм;
не реализация всей подсистемы в рамках этого исследования.

## Первичные источники

- [S1 — sing-box v1.14.0: официальный релиз и assets](https://github.com/SagerNet/sing-box/releases/tag/v1.14.0).
- [S2 — go.mod](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/go.mod), [build workflow](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/.github/workflows/build.yml).
- [S3 — Hysteria2 outbound](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/protocol/hysteria2/outbound.go), [SOCKS inbound](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/protocol/socks/inbound.go), [конфигурация Hysteria2](https://sing-box.sagernet.org/configuration/outbound/hysteria2/).
- [S4 — selector](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/protocol/group/selector.go), [REST handlers](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/experimental/clashapi/proxies.go), [reload/stop](https://github.com/SagerNet/sing-box/blob/0b8995879f29a9b98ee027bc17b75e101445b238/cmd/sing-box/cmd_run.go), [selector docs](https://sing-box.sagernet.org/configuration/outbound/selector/).
- [S5 — dial fields](https://sing-box.sagernet.org/configuration/shared/dial/), [Clash API](https://sing-box.sagernet.org/configuration/experimental/clash-api/).
- [S6 — ICMP routing](https://sing-box.sagernet.org/configuration/route/rule/), [TUN](https://sing-box.sagernet.org/configuration/inbound/tun/).
- [H1 — официальный Hysteria app/v2.12.2](https://github.com/HyNetworks/hysteria/releases/tag/app/v2.12.2).
- [H2 — client lifecycle](https://github.com/HyNetworks/hysteria/blob/619a6f856b69fb7ee6a7a379e810e68b84004605/app/cmd/client.go), [TCP ping](https://github.com/HyNetworks/hysteria/blob/619a6f856b69fb7ee6a7a379e810e68b84004605/app/cmd/ping.go), [build aliases](https://github.com/HyNetworks/hysteria/blob/619a6f856b69fb7ee6a7a379e810e68b84004605/hyperbole.py), [app go.mod](https://github.com/HyNetworks/hysteria/blob/619a6f856b69fb7ee6a7a379e810e68b84004605/app/go.mod).
- [H3 — Full Client Config](https://v2.hysteria.network/docs/advanced/Full-Client-Config/): SOCKS5, transport, sockopts, TUN и exclusions.
- [K1 — Keenetic Proxy client](https://support.keenetic.com/peak/kn-2710/en/49443-proxy-client.html).
- [G1 — Go Minimum Requirements](https://go.dev/wiki/MinimumRequirements).

## Покрытие приёмки #61

Проверки документа: локальные ссылки в рабочем проекте, структура таблиц,
LF и whitespace — PASS. Зависимость #59 отсутствовала в исходном изолированном
worktree, но перед публикацией подтверждена в `origin/main` на SHA выше.
`bash scripts/qa/static.sh` — exit 0 после восстановления LF в изолированном
worktree (исходный checkout Windows конвертировал 172 файла в CRLF).
Package layout, secret scan, line endings и shell syntax прошли;
ShellCheck/actionlint отсутствуют и пропущены штатным скриптом.
BATS и package build не запускались: изменён только исследовательский Markdown,
runtime/Makefile/build inputs не изменялись. Это не полный release QA.

| Критерий issue | Результат исследования |
| --- | --- |
| Первичные источники, версии/ABI, TCP/UDP, TUN/ICMP, профили | Сравнение двух кандидатов, pinned SHA, проверенные release ELF, ограничения и ссылки выше |
| Keenetic Proxy, альтернатива, петля, transport/control | Прямой SOCKS data path отделён от REST/RCI, определены условия альтернативы и обязательные exclusions |
| Зависимости, процессы, слабые платформы, Rust | Выбран внешний транспорт под Rust-ядром; G1/G3/G5 удерживают неизвестные ABI/ресурсы/упаковку |
| Выбранный кандидат и план #63 без ложного runtime PASS | sing-box 1.14.0; R0–R9 с отдельными gates и evidence; испытаний Keenetic в #61 нет |
