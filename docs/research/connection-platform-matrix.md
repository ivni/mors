# Матрица платформ и VPN-возможностей Keenetic

Исследование для [#59](https://github.com/ivni/mors/issues/59), 13.09.2026;
актуализация NaiveProxy — 22.09.2026.
Основание — [контракт #58](../connection-core-requirements.md), прежде всего
REQ-CORE-002, 006–007, 010–011 и 014. Результат документальный: runtime,
конфигурация роутеров и пакет не изменялись.

**Изменение охвата 13.09.2026:** после ознакомления с выводами пользователь
отказался от OpenVPN в общем ядре. Актуальный контракт обновлён в
[REQ-CORE-002](../connection-core-requirements.md). Ниже сведения об OpenVPN
сохранены как результаты исследования исходного #59: они не являются планом
реализации. Все OpenVPN-строки операций, код OV и проверки #84/#85 исключены
из активного объёма; G3 снят. Для остальных протоколов gates сохраняются.
Существующие OpenVPN-подключения остаются нетронутыми; если такое подключение
выбрано в текущем Mors, переход блокируется до выбора поддерживаемого выхода
до любых изменений рабочего состояния (#97/#98). GitHub issues не изменялись.

## Вывод и границы доказательства

**Актуализация 22.09.2026:** Hysteria 2 заменён в плане на NaiveProxy по
REQ-CORE-019–021. Проверены `HEAD = origin/main =
bc046afbcc11c55feb753419524040b086f15a38` после `git fetch origin main`;
исправление decision lock #57 и контракт #58 сохранены. Обновляется этот
документ; при публикации добавлен исходный отчёт предварительного опыта [N6].
Ниже исходные факты 13.09 помечены своей датой; они не являются
повторными испытаниями 22.09. Новые источники — [N1]–[N6].

Обнаружено **подтверждённое ограничение штатной поставки NaiveProxy для MIPS
big endian**: upstream объясняет отсутствие поддержки ограничением Chromium
[N4], а релиз [N1] не содержит MIPS BE asset. Это блокирует обещание одинаковой
доступности NaiveProxy на всех сохраняемых платформах. Порт не исследован;
невозможность любого собственного порта не доказана. MIPS как платформа Mors
не исключается. Решение о неодинаковых capabilities либо отдельном порте
требуется в #61/#62 до зависящей реализации, без скрытого сокращения охвата.

Текущий охват Mors нужно сохранять по трём семействам: **mips, mipsel,
aarch64**. В публичных индексах всех трёх Entware feed найдены все прямые
зависимости Mors. Однако это не доказывает установку, транзитивную разрешимость
зависимостей и выполнение на каждой модели. Канонический builder охватывает
только aarch64. Продуктовый минимум Mors — **KeeneticOS 5**, согласно
[README](../../README.md); полная модельная матрица испытаниями не установлена.
Универсальный Rust-бинарник из `PKGARCH:=all`
не следует. Невозможность сохранить какую-либо платформу пока **не доказана**;
её нельзя молча исключить из перехода.

Штатные VPN имеют разные пороги OS и компонентов. Общий RCI существует,
но подтверждение его транспорта не доказывает полный lifecycle конкретного
VPN. В активном объёме требуют проверки варианты WireGuard ASC и разделение
клиентского выхода, WAN и VPN-сервера. Критичные пробелы
ниже блокируют соответствующую зависящую реализацию, а не превращаются в
успешные испытания после завершения этого документа.

База исследования — актуальный `origin/main`
`43ef141f366a7d7e5a22c6fe0558fc62fa529097`, полученный через `git fetch origin main`.
В нём пакет `1.3.0~rc2`, release `1`. Исходный рабочий HEAD был
`65c15ae55e609f15b99dffdcb747b7ebb8773a70` с чужими незавершёнными изменениями.
Checkout не переключался: актуальные Makefile, контракт и VLESS-архитектура
прочитаны через `git show origin/main:...`; исследуемые README, setup_plan,
vpn, xray, help и builder inputs сверены с `origin/main` и совпадают.
Рабочие изменения не являются источником новых гарантий.

Уровни доказанности (применяются к каждой ячейке):

| Код | Что доказано | Что не доказано |
| --- | --- | --- |
| O | Официальный документ производителя, с указанной версией/редакцией | Запуск на нашем роутере, полнота API |
| S | Прочитан исходный код на указанном SHA | Успех на оборудовании |
| F | Прочитан публичный индекс пакетов 13.09.2026 | Установка и работоспособность |
| L | Локальное описание стенда | Актуальное состояние стенда |
| T | Непосредственное испытание конкретной операции на модели/OS | Другие модели и операции; в исходном #59 успешных T нет |
| T-ref | Результат ранее выполненного опыта из указанного отчёта | Не новое испытание и не проверка всей платформы |
| ? | Доказательства недостаточны; указана следующая проверка | Нельзя трактовать как «не поддерживается» или «готово» |

## Платформы, ABI и минимальные версии

Строка платформы ниже, строка VPN в следующем разделе и операция вместе
образуют проверяемую комбинацию. Это **не** утверждение, что все
комбинации уже испытаны. Модель в URL общей статьи также не доказывает весь
перечисленный в ней набор возможностей именно на этой модели.

Версии появления компонентов ниже — справочные сведения, не минимальная
поддерживаемая Mors прошивка: для продукта действует **KeeneticOS 5+**.
Числа в названиях Entware feed не вводят отдельного требования поддерживать
Linux 3.4/3.10. Фактические ядра рассматриваются внутри поддерживаемого парка OS 5+.

| Семейство и пример модели | Entware feed → package ABI | Toolchain в закреплённом Entware | OS/свидетельство | Состояние Mors и необходимая проверка |
| --- | --- | --- | --- | --- |
| MIPS big endian; Hero DSL KN-2410 | `mipssf-k3.4` → `mips-3.4` | `mips32r2`, soft-float, `-EB`, glibc 2.27, GCC 8.4.0 [E1] | O: производитель предписывает mips-архив [K2]; внутренняя OPKG storage — с 3.7 на применимых моделях, это не общий минимум USB/Mors | S+F; Rust и полный Mors на этой модели не испытаны. #60/#68: ELF, endian, float ABI, loader, зависимости и запуск |
| MIPSel; локальный Netcraze Viva NC-1913 | `mipselsf-k3.4` → `mipsel-3.4` | `mips32r2`, soft-float, glibc 2.27, GCC 8.4.0 [E2] | L: OS 5.0.12 и этот feed записаны в локальном описании; свежая проверка не состоялась | S+F+L; SSH через разрешённый alias завершился `connect failed: Connection refused`, exit 1. Это не тест ABI и не доказательство состояния VPN |
| AArch64; Hero 5G KN-4110 | `aarch64-k3.10` → `aarch64-3.10` | `cortex-a53`, 64 bit, glibc 2.27, GCC 8.4.0 [E3] | O: aarch64-архив явно указан для KN-4110 [K1]; продуктовый минимум Mors — OS 5 | S+F; единственная конфигурация канонического builder. Свежая сборка и запуск на модели в #59 не выполнялись |
| Другие модели этих трёх семейств, включая старые установки | ABI определять по установленному Entware, а не маркетинговому имени/одному `uname -m` | Не переносить параметры соседней модели автоматически | ? До инвентаризации модели, OS, ядра и компонентов | Сохраняются в заявленном охвате; отсутствие стенда не разрешает исключение |
| ARMv7 и x86-64 | В Entware lock есть `armv7-3.2.config`, `x64-3.2.config` | S: существуют конфигурации upstream | Нет свидетельства соответствующего текущего Mors/Keenetic target | Не включены в заявленные README три семейства; наличие Entware target само по себе не расширяет поддержку Mors |

`k3.4`/`k3.10` — базовые версии ядра в обозначении Entware target, не версия
KeeneticOS и не результат `uname -r`. Glibc 2.27 — версия закреплённого
toolchain, не доказанный минимальный ABI будущего Rust-бинарника. Для него
нужны проверка импортируемых GLIBC symbols, ELF interpreter, ISA, atomics и
системных вызовов на старейшем сохраняемом target (#60). Номер OS сам по себе
не заменяет наличие компонента и доступный объём памяти.

Исходные основания:

- [README](../../README.md), раздел требований, прямо называет три семейства.
- [Makefile](../../Makefile) использует `PKGARCH:=all` и не компилирует бинарник;
  [vpn](../../opt/bin/libs/vpn), `dnsmasq_install_wildcard_support`, имеет ветви
  mips/mipsel/aarch64. Это свидетельство исторического охвата кода, а не
  рекомендация запускать эту замену DNSMasq.
- [entware-builder-id.sh](../../scripts/qa/entware-builder-id.sh) фиксирует
  `configs/aarch64-3.10.config`;
  [verify-entware-builder.sh](../../scripts/qa/verify-entware-builder.sh)
  требует единственные aarch64 toolchain и target staging tree.
- [entware.lock](../../scripts/qa/entware.lock) закрепляет Entware
  `2d92d7c0b4055cb27901025f8a08d2e6344e849e`; [E1]–[E3] прочитаны на этом SHA.
- `TEST_INFRASTRUCTURE.local.md` прочитан локально. Его сетевые адреса,
  SSH-параметры и реальные endpoint-данные сюда не перенесены. Заявление
  старого baseline об установленном ПО не принято за актуальный факт.

### Проверка доступности пакетов

13.09.2026 прочитаны `Packages.gz` из [F1], [F2], [F3]; имена сравнивались с
полным `MORS_RUNTIME_DEPENDS` из
[runtime-dependencies.mk](../../builder/entware/runtime-dependencies.mk).
Для каждого feed отсутствующих **прямых** зависимостей — 0.

| Feed | libc | Xray | shadowsocks-libev-ss-redir |
| --- | --- | --- | --- |
| mipssf-k3.4 | 2.27-12 | 26.2.6-1 | 3.3.5-11 |
| mipselsf-k3.4 | 2.27-12 | 26.2.6-1 | 3.3.5-11 |
| aarch64-k3.10 | 2.27-12 | 26.2.6-1 | 3.3.5-11 |

Это изменяемые публичные индексы, а не immutable package attestation. Проверка
не скачивала/не запускала IPK, не меняла OPKG и не обходила release gates.
Mors отдельно задаёт Xray минимум **1.8.24**, tested **26.2.6** в
[libs/xray](../../opt/bin/libs/xray); минимальная версия Shadowsocks в
dependency contract не закреплена. Наличие нового Xray в feed не разрешает
поднимать tested version без compatibility CI.

## NaiveProxy: платформы, транспорт и поставка (22.09.2026)

Кандидат исследования — **v150.0.7871.63-1**, tag разрешён GitHub API в commit
`3ba967e2d36cc133a896e81a36257ad4c6ea20f4`. Это версия проверенного кандидата,
не утверждение о latest. Chromium-линия — `150.0.7871.63` по версии релиза
и `naive --version` в [предварительном опыте](naiveproxy-runtime-spike.md).
Upstream рекомендует следовать выпускам Chrome и стабильным тегам, а не
перебазируемому master [N2]. Обновление Chromium требует повторения gates;
поддерживаемый диапазон версий Mors ещё не установлен (#61/#63).

### ABI / ISA / loader

Имена assets ниже имеют общий префикс `naiveproxy-v150.0.7871.63-1-`.
Размер — сжатый архив в байтах из GitHub API [N1], **не** размер ELF,
установленного пакета или требование RAM. `static` пока означает название
upstream asset; полный ELF-аудит в этой актуализации не выполнялся.

| Платформа Mors | Asset / размер | Уровень и результат | Необходимая проверка |
| --- | --- | --- | --- |
| MIPS BE, `mips-3.4`, soft-float | Нет MIPS BE asset в [N1] | O: [N4] явно указывает отсутствие big-endian в Chrome для `mips_24kc`, `mips_4kec`, `mips_mips32` | BLOCKED для штатного NaiveProxy: #61/#62 должны разрешить разницу capabilities либо обосновать отдельный порт; не исключать MIPS из Mors |
| MIPSel, `mipsel-3.4`, NC-1913 | `openwrt-mipsel_24kc-static.tar.xz`, 3441408 | O + T-ref: бинарник запущен на NC-1913, три TCP HTTPS запроса дали HTTP 200; UDP ASSOCIATE отвергнут | #61/#63: ELF32 little-endian, ISA/float ABI, отсутствие PT_INTERP/DT_NEEDED у static, системные вызовы; полный dataplane, DNS, отказ и восстановление |
| AArch64, `aarch64-3.10` | `openwrt-aarch64_cortex-a53-static.tar.xz`, 3443528 | O: asset существует; запуска в текущем исследовании нет | #61/#63: ELF64, ISA, loader, kernel/syscalls и запуск под эмуляцией; не объявлять аппаратный PASS |
| Динамические альтернативы MIPSel / AArch64 | `linux-mipsel.tar.xz`, 3288328; `linux-arm64.tar.xz`, 3118860; OpenWrt варианты без `static` также есть | O: только метаданные assets | Не подменять Entware glibc случайным OpenWrt ABI. Проверить PT_INTERP, DT_NEEDED, GLIBC symbol versions, ISA и sysroot до запуска |

SHA-256 выбранных архивов по метаданным [N1]:

- MIPSel static: `741b26a2425244f66adf99d93ed3cd41697aa6ba81660157b1f8f7c8dbf8374f`;
- AArch64 cortex-a53 static: `f5ae78ddeed9af8db8370b3ae544ef566fb786d8b7e03071767d2b2a1015246b`.

В предварительном опыте digest MIPSel проверен по скачанному архиву;
здесь архивы повторно не скачивались. [N4] описывает `mipsel_24kc` как общий
mipsel без 24kc tuning; название не заменяет `readelf -h -A -l -d -V` и
проверку на фактическом ядре. Доступный физический стенд — NC-1913;
для MIPS BE/AArch64 допустима эмуляция с явной границей доказательства.

Отдельно [Rust spike #60](rust-entware-spike.md) уже сообщает IPC для шести
dynamic/static ELF трёх семейств под QEMU и обоих MIPSel ELF на NC-1913.
Это T-ref для минимального Rust, не для Chromium/NaiveProxy и не для полного
Mors. Исходная неудача SSH 13.09 в таблице выше остаётся историей #59,
а не заявлением о текущей недоступности стенда.

### TCP, UDP и операции

O + S [N2]/[N3], версия кандидата: локальный SOCKS5 CONNECT передаёт TCP
через HTTP/2 или HTTP/3 CONNECT streams. BIND и UDP ASSOCIATE получают
command-not-supported (`0x07`). T-ref: в опыте ответ на UDP ASSOCIATE —
`05 07 00 01 00 00 00 00 00 00`. Внешний QUIC/HTTP/3 не добавляет
пользовательский UDP; отдельный QUIC путь в опыте не проверялся.

Контракт #58 уже **определил** политику: неподдерживаемый защищаемый UDP
блокируется, без скрытого direct bypass; отсутствие UDP не означает отказ
TCP. Упоминание «незакрытого решения» в предварительном отчёте отражает
момент до обновления #58 и не заменяет REQ-CORE-019–021. Capabilities VLESS,
Shadowsocks и штатных VPN проверяются независимо. Health/selection — общее
ядро; один active для новых сессий. Отдельный Naive health-selector не вводится.

| Операция NaiveProxy | Источник / версия / уровень | Что остаётся BLOCKED |
| --- | --- | --- |
| discover | S: на базовом SHA нет адаптера NaiveProxy; O [N2] описывает отдельный клиент, не RCI-тип | Реестр и поиск принадлежащих Mors объектов #81; не принимать произвольный Proxy за NaiveProxy |
| read | O [N2], кандидат: локальный JSON `listen`/`proxy` | Нормализованный readback, редактирование и секреты #81/#92/#93 |
| create | O [N2]: конфигурация и запуск процесса; T-ref только временный SOCKS listener | Транзакционный create, владение процессом/файлами, Keenetic integration #81 |
| update | O [N2]: конфигурационный формат; live reload этим не доказан | Apply/rollback и сохранность действующих сессий #81/#95 |
| delete | T-ref: очистка временного опыта, не общий lifecycle | Удаление только принадлежащих Mors объектов, crash cleanup #81/#95 |
| enable | T-ref: ручной запуск конкретного MIPSel клиента | Автозапуск, supervisor, атомарная активация и предупреждение TCP-only #81/#65/#78 |
| probe | S + T-ref [N3]: TCP HTTP 200 и отрицательный UDP ASSOCIATE | Source-bound egress/nonce, DNS/no-loop, отсутствие direct при сбое и восстановлении #63/#75/#115 |

Три запроса инициировал curl на ПК через SSH forward к SOCKS listener;
**NaiveProxy исполнялся на роутере**. Это не LAN→Keenetic Proxy тест.
Защищённый DNS и bootstrap сервера проверяются раздельно; прямой DNS как
компенсация TCP-only запрещён. Настройка/наличие Proxy client [K15] не доказывает
совместимость его UDP поведения с NaiveProxy. Активация до доказанного DNS,
UDP fail-closed и no-loop пути остаётся BLOCKED (#63/#78).

### CA trust, ресурсы, лицензии и доставка

O [N2]: Linux-клиент читает `SSL_CERT_FILE`/`SSL_CERT_DIR` и стандартные
системные CA пути. Наличие Entware в `/opt` не гарантирует найденный trust store.
T-ref: в опыте использован временный CA bundle через `SSL_CERT_FILE`, TLS
verification не отключалась. Production gate #61/#63: определить владельца
и обновление CA, проверить корректный сертификат, неверный hostname, истёкший
сертификат, неизвестный CA и пустой bundle; ошибки должны блокировать соединение.

T-ref: RSS после трёх запросов 8024 kB, HWM 8040 kB, четыре потока.
Это одиночный snapshot, не бюджет RAM под нагрузкой. Размер распакованного
ELF, disk peak при обновлении/rollback, нагрузка совместно с Xray и DNS,
число сессий и OOM recovery пока **?**, #61/#63.

O [N5]: корневой LICENSE содержит BSD-условия сохранения copyright,
условий и disclaimer при распространении. Он не является исчерпывающим
реестром лицензий всех включённых Chromium/third-party компонентов.
До поставки #61 должен собрать notices/SBOM для выбранного бинарника,
проверить вложенные лицензии, CA bundle и требования к распространению;
юридическая готовность готового пакета здесь не подтверждается.

На проверенном main `runtime-dependencies.mk` не включает NaiveProxy.
Архив upstream не равен Entware IPK, а `PKGARCH:=all` оболочки Mors не делает
машинный ELF универсальным. #61/#67–#69 должны определить источник и способ
доставки, mapping ABI→asset, immutable SHA/digest, CA/notices, обновление и
rollback. Размеры/дайджесты выше — входные данные исследования, не изменение
канонического builder и не разрешение скачивать latest во время установки.

Воспроизводимая read-only проверка источника и списка поставки:

```sh
gh api repos/klzgrad/naiveproxy/git/ref/tags/v150.0.7871.63-1 --jq '.object'
gh release view v150.0.7871.63-1 --repo klzgrad/naiveproxy --json assets,tagName,url
git show origin/main:builder/entware/runtime-dependencies.mk
```

## Инвентарь VPN и компонентов

«Минимум ?» означает, что официальный источник описывает возможность, но
не устанавливает дату её появления. Для недоступного компонента нужен
путь инструкция → ручное действие пользователя → повторная проверка (#107),
без установки компонентов или обновления OS со стороны Mors.

| VPN / вариант | Компонент OS, представление | Версия и официальный источник | Текущая граница Mors (S) |
| --- | --- | --- | --- |
| OpenVPN client | OpenVPN client and server; `OpenVPN` | O [K3]; минимум всего клиента ?; CLI 4.1 содержит отдельные команды с history 2.10 [K12] | Обнаружение/выбор существующего интерфейса. Полный импорт и lifecycle нового клиента ещё #84/#85 |
| WireGuard | WireGuard VPN; `Wireguard` (регистр RCI важен) | O: с 3.3 [K4] | Обнаружение типа; разбор peers/клиентской роли и полноценный lifecycle #82/#83 |
| WireGuard, базовый ASC | Тот же WireGuard, дополнительные параметры | O: CLI в 4.2 Alpha 2, NDM-3202 [K5]; исправление потери ASC при переподключении в 4.3 Beta 3, SYS-1320 [K6] | Отдельной capability-проверки ASC в setup inventory нет; наличие типа недостаточно |
| WireGuard, расширенный ASC | Тот же компонент; дополнительные `s3`, `s4`, `i1`–`i5` | O: 5.1.1, NDM-4298 [K7]; import validation менялась далее | Нельзя переносить на OS 5.0.12 стенда или автоматически считать совместимым с любой версией AmneziaWG |
| OpenVPN с нестандартной обфускацией/«ASC» | Не установлен отдельный подтверждённый компонент | ?: официального контракта такого варианта среди проверенных [K3], [K5]–[K7] нет | Не смешивать с WireGuard ASC; отдельный формат/расширение требует документации и fixture в #84 |
| IKEv1 client | IKEv1/IKEv2 clients; `IKE` | O: с 3.5 [K8] | Тип обнаруживается, режим/auth/клиентская роль требуют чтения конфигурации; #86 |
| IKEv2 client | Тот же клиентский компонент; `IKE` | O: с 3.5 [K8] | Нельзя определять версию IKE по одному `.type`; #86 |
| SSTP client | SSTP VPN client; `SSTP` | O [K9]; минимум ?; команды доступны в CLI 4.1 [K12] | Выбор существующего; конфигурационный адаптер #87 |
| PPTP client | PPTP client; `PPTP` | O [K10], [K11]; минимум ? | Выбор существующего; адаптер #88 |
| L2TP client | L2TP client; `L2TP` | O [K10], [K11]; минимум ? | Выбор существующего; адаптер #89; сам L2TP не обеспечивает шифрование |
| L2TP/IPsec client | L2TP/IPsec VPN client в IPsec-компоненте; название bundle зависит от OS | O [K13], [K11]; минимум ? | Отдельного фильтра `L2TP/IPsec` нет; отличать от plain L2TP по параметрам/IPsec-связям, fixture требуется; #90 |
| OpenConnect client | OpenConnect VPN client; `OpenConnect` | O: 4.2.1 [K14] | Тип включён; набор auth/протоколов и lifecycle #91. Не путать с OpenConnect server |
| Shadowsocks | Entware `shadowsocks-libev-ss-redir`, `ss-local`, config; не штатный RCI VPN-тип | O: внешняя proxy-точка допускается [K15]; S+F: собственный ss-redir путь Mors; продуктовый минимум OS 5 | Отдельный legacy backend в vpn; это не VLESS/Proxy и не полный общий пул; #80/#97 |
| VLESS Reality | Entware Xray + Proxy client + Netfilter + Netfilter Add-ons | O: Proxy с 3.9 [K15]; S: Xray ≥1.8.24, tested 26.2.6; 3.9 — необходимый порог компонента, не доказанный минимум всего Mors | Реестр VLESS, один Xray и управляемый Proxy21, отдельные health/probe; #79 |
| HTTP/HTTPS/SOCKS5 Proxy | Proxy client; `Proxy` | O: с 3.9 [K15] | Legacy scan включает Proxy вообще, setup_plan принимает только управляемый Proxy21 с ожидаемым описанием. Произвольный Proxy ещё не равен управляемому VPN |
| NaiveProxy | Внешний Chromium-клиент; собственного RCI VPN-типа не установлено | O + S [N1]–[N4], v150.0.7871.63-1; продуктовый минимум OS 5, полный путь не испытан | TCP-only; MIPSel T-ref, MIPS BE upstream не поддержан, AArch64 не испытан; операции раскрыты отдельно выше, адаптер #81 |

## Матрица операций и пути управления

Обозначения внутри ячеек раскрыты ниже; источник и версия наследуются из
определения кода. `?` всегда остаётся отдельной границей, даже рядом с O/S.
Версии VPN/компонента из предыдущей таблицы обязательны дополнительно.

| Тип | discover | read | create | update | delete | enable | probe |
| --- | --- | --- | --- | --- | --- | --- | --- |
| OpenVPN client | R | R; полный профиль ? | C + OV | U + OV | D; backup OV | E | P |
| WireGuard | R; роль ? | R; peers ? | C + WG | U + WG | D | E | P; handshake ? |
| WireGuard ASC базовый | R; вариант ? | A1: round-trip ? | C + A1 | A1 | D | E; сохранность A1 ? | P; совместимость ASC ? |
| WireGuard ASC расширенный | R; вариант ? | A2: round-trip ? | C + A2 | A2 | D | E; сохранность A2 ? | P; совместимость ASC ? |
| OpenVPN с неподтверждённым ASC | ? [K3] | ? [K3] | ? [K3] | ? [K3] | ? [K3] | ? [K3] | ? [K3] |
| IKEv1 client | R; роль ? | R; auth ? | C + I | U + I | D | E | P; SA ? |
| IKEv2 client | R; роль ? | R; auth ? | C + I | U + I | D | E | P; SA ? |
| SSTP client | R | R | C + S | U + S | D | E | P |
| PPTP client | R | R | C + L | U + L | D | E | P |
| L2TP client | R | R; IPsec ? | C + L | U + L | D | E | P |
| L2TP/IPsec client | R; вариант ? | R; IPsec ? | C + LI | U + LI | D; связанные объекты ? | E | P; SA ? |
| OpenConnect client | R | R; полный auth ? | O [K14], 4.2.1; API ? | O [K14], 4.2.1; API ? | ? [K14], 4.2.1 | O UI [K14], 4.2.1; API ? | P |
| Shadowsocks | SS | SS | SS | SS | SS; полное владение ? | SS | SS; общий P ? |
| VLESS Reality | V | V | V | V | V | V | V; общий P ? |
| Произвольный Proxy | R; setup ограничен | R | C + PX | U + PX | D | E | P; UDP зависит от режима |
| NaiveProxy | N; реестр ? | N; readback ? | N; lifecycle ? | N; apply ? | N; владение ? | N; activation ? | N; TCP T-ref, UDP unsupported |

Коды операций:

- **N — O + S + T-ref**, [N1]–[N4], v150.0.7871.63-1: см. отдельную
  таблицу операций NaiveProxy выше. Общего managed lifecycle пока нет;
  ограничения TCP/UDP не наследуются от VLESS или произвольного Proxy.

- **R — S + O:** Mors `setup_plan__inventory_json` читает
  `GET /rci/show/interface`; константы main и callers используют
  `/rci/interface` для параметров. [K12], редакция CLI **4.1**, Appendix B,
  описывает GET настроек, а [K16] — общий RCI. Конкретная полнота read
  секретов, роль, поля и schema по моделям/OS — **?**, #76/#92/#93.
- **C/D/E — O [K12], CLI 4.1:** §3.29 (с. 145–146) —
  `interface {name}` / `no interface {name}`; §3.29.213 (с. 293) —
  `interface {name} up` / `no up`. Это создание оболочки/удаление/включение,
  не готовый VPN. Общая команда имеет history 2.00, но не все позднейшие
  типы существовали в 2.00. Успешный lifecycle через RCI на матрице — **?**.
- **U — O [K12], CLI 4.1, Appendix B:** POST создаёт/изменяет настройки;
  семантика изменения отдельных полей, частичного отказа и rollback — **?**.
  HTTP 200 не является достаточным результатом. JSON-схемы мутаций здесь
  намеренно не выведены из имени команды: нужны точные fixtures (#77).
- **OV — O [K3], редакция 13.09.2026, минимум ?**: загрузка содержимого
  `.ovpn` через поле веб-интерфейса; автоматизированный upload/readback — **?**,
  #84/#85. Отдельный backup обязателен, подробнее ниже.
- **WG — O [K4], с 3.3:** UI ручного создания и импорт файла; round-trip
  настроек через API и избирательное обновление peers — **?**, #82/#83.
- **A1 — O [K5], 4.2 Alpha 2:** CLI
  `interface {name} wireguard asc {jc} {jmin} {jmax} {s1} {s2} {h1} {h2} {h3} {h4}`.
  [K6] фиксирует дефект потери настроек; нужны reconnect/readback fixtures.
- **A2 — O [K7], 5.1.1:** расширение ASC и импорт; точные диапазоны,
  форматы и поведение неподдерживаемого поля — **?**, #82/#83. Это отдельная
  capability, а не изменение минимальной OS всего Mors.
- **I/S/L/LI/PX — O:** соответственно [K8]/3.5, [K9]/минимум ?,
  [K10]/минимум ?, [K13]/минимум ?, [K15]/3.9 описывают настройку клиента.
  Это UI/продуктовые возможности; полнота автоматизированного create/update
  и отказоустойчивость не испытаны. Владельцы: #86–#91 и #77.
- **P — O + ?:** [K9], [K10], [K3] предлагают проверять удалённый ресурс;
  версия — соответствующая строка VPN, для старых клиентов минимум ?.
  Такая проверка сама по себе не доказывает выход через заданный backend.
  Единый source-bound probe, отсутствие прямого fallback, различение общей
  потери интернета, DNS/TCP/UDP и изолированного отказа — **?**, #75/#115.
- **SS — S**, Mors на базовом SHA: `libs/vpn`, конфигурация Shadowsocks,
  функции включения/настройки и [test_tunnel](../../opt/bin/libs/test_tunnel).
  O [K15]/3.9 относится только к возможной proxy-интеграции и не доказывает
  этот ss-redir backend. Официального Keenetic CRUD для Entware SS в
  проверенных источниках нет; общий lifecycle/backup/readback — **?**, #80.
- **V — S**, тот же SHA: [vless](../../opt/bin/libs/vless),
  [vless_store](../../opt/bin/libs/vless_store),
  [vless_runtime](../../opt/bin/libs/vless_runtime),
  [VLESS-архитектура](../vless-architecture.md). O [K15]/3.9 подтверждает
  только Proxy; собственные операции Mors не становятся официальным RCI
  API VLESS. Минимальная OS полного backend и свежие T — **?**, #79.

### OpenVPN: архив исследования импорта и backup, вне целевого охвата

Следующие проверки описывают первоначальный объём до отказа от OpenVPN.
Они больше не требуются для общего ядра; возвращение к ним потребует нового
продуктового решения.

Подтверждённый [K3] путь: Other connections → Create connection → OpenVPN →
вставить содержимое `.ovpn` в поле конфигурации → сохранить. Профиль должен
быть самодостаточным, с inline сертификатами/ключами; список поддерживаемых
опций зависит от встроенного OpenVPN. Нельзя считать все директивы upstream
поддержанными Keenetic.

`startup-config` **не содержит** OpenVPN-профиль [K3]. Перед изменением или
удалением нужен отдельный закрытый backup исходного профиля и всех данных,
необходимых для его восстановления; успешное сохранение общего config не
заменяет его. Точный автоматизированный экспорт уже существующего профиля,
полнота секретов и восстановление ещё требуют испытания #85/#92. При
невозможности полного backup принятие под полное управление блокируется,
а существующее соединение сохраняется.

[K17] документирует в **5.2 Development**, NDM-4556, команду
`interface {name} openvpn import {url}` (рядом WireGuard URL import,
NDM-4555). Это не общая предпосылка для старых OS. URL-import не заменяет
локальный импорт и не решает backup. Не вводить временный публичный сервер
с конфигурацией как обход отсутствующего API.

В #84/#85 отдельно проверить локальную загрузку файла через UI и фактический
HTTP request на disposable target: endpoint, метод, multipart/тело, лимит,
кодировка, auth, результат и readback. **Точный upload endpoint пока ?**;
ни `/rci/interface/.../openvpn`, ни универсальный file-upload API здесь не
объявляются рабочими. Проверить повторное чтение после перезагрузки,
неподдержанную директиву, усечённый файл, сохранение старого профиля при
ошибке и восстановление из отдельного backup. На KN-1110/1210/1310/1410/
1510/1610/1710/1810/1910 документирован общий лимит VPN-config 24 KiB [K3];
нельзя подставлять лимит новых моделей.

## Разделение ролей и архитектурный дефект legacy scan

[setup_plan](../../opt/bin/libs/setup_plan) отбрасывает `.defaultgw == true`,
но включает `PPPOE`. [vpn](../../opt/bin/libs/vpn),
`update_interface_name_list`, использует близкий список и вызывает
`reset_connection` для найденных объектов. Следовательно,
`mors vpn scan|rescan` **не является read-only inventory** и в #59 не запускался.
Практический риск — разрыв существующих соединений при простом поиске.

| Объект | Роль в общем ядре | Как избежать неверного включения |
| --- | --- | --- |
| Ethernet ISP, PPPoE, WISP, DSL, CdcEthernet, UsbLte, UsbModem/UsbQmi | WAN/upstream; не VPN-выход пула | Отдельная upstream-модель; не принимать по признаку «не defaultgw» |
| PPTP/L2TP провайдера | Может быть WAN, несмотря на VPN-подобный тип | Проверять роль и зависимости маршрута; требуется fixture и явное принятие |
| IKE/PPTP/L2TP/SSTP/OpenConnect VPN-сервер, входящие клиенты | Источник клиентского трафика/доступ к LAN | `vpn net` / `vpn guest` в help описывают эту отдельную функцию; сервер не выход пула |
| OpenVPN/WireGuard | Роль определяется настройками/peers, не только именем | Отделить клиентский egress от сервера/site-to-site без Internet egress |
| Произвольный Proxy | Транспорт HTTP/HTTPS/SOCKS5; не доказательство VLESS | Проверить upstream, протокол, владение, UDP и probe; не присваивать чужой |
| Управляемый Proxy21 | Общая точка интеграции Mors VLESS | Не создавать интерфейс/Xray на каждый профиль; соблюдать владельца |
| ZeroTier, IPIP/GRE/EoIP, XFRM | Другие соединения OS | Не добавлять автоматически; в целевом списке #58 не заявлены |

Корректная граница для #76/#77: обнаружение без reconnect, затем классификация
роли и возможностей, затем явное принятие и транзакционный lifecycle.
Чтение `.type` и `.defaultgw` недостаточно. Для уже выбранного legacy PPPoE
или произвольного Proxy нужна явная судьба миграции в #97/#98: нельзя просто
потерять действующую настройку из-за нового фильтра. Если существующих issues
недостаточно, отдельная задача должна ограничиваться совместимостью этих
legacy выходов, без расширения VPN-пула до multi-WAN.

## Воспроизводимость и незакрытые проверки

Выполнено: прочитаны issues #58/#59 и актуальный main; сравнены исходники;
прочитаны официальные документы и три закреплённых Entware config;
проверены три индекса прямых зависимостей. Попытка read-only SSH до тестового
роутера не дошла. Router probes, create/update/delete/enable, перезагрузка,
установка компонентов, package build и сетевые smoke не выполнялись.

Проверка документа: локальные ссылки и ID источников разрешаются, число
колонок таблиц согласовано, файл UTF-8/LF, `git diff --no-index --check`
не обнаружил whitespace-ошибок. `scripts/qa/static.sh` в текущем Windows
окружении не дошёл до проверок: Git Bash не нашёл `dirname`, вложенный bash
завершился `E_ACCESSDENIED`. Это не успешный QA; BATS для изменения только
документации не запускался.

Команды для повторения репозиторных фактов (на workstation):

```sh
gh issue view 59 --repo ivni/mors
gh api repos/ivni/mors/commits/main --jq .sha
git fetch origin main
git show origin/main:Makefile
git show origin/main:opt/bin/libs/setup_plan
git show origin/main:opt/bin/libs/vpn
git show origin/main:scripts/qa/entware-builder-id.sh
gh api 'repos/Entware/Entware/contents/configs?ref=2d92d7c0b4055cb27901025f8a08d2e6344e849e' --jq '.[].name'
```

Для проверки feed скачать на workstation `Packages.gz` по [F1]–[F3],
распаковать gzip, сравнить поля `Package:` с прямыми зависимостями из
`MORS_RUNTIME_DEPENDS` (убрав `+`); для каждой найденной записи сохранить
`Package`, `Version`, `Architecture`. Это не команда `opkg update` на роутере.

Следующий read-only сбор, только после проверки локального описания стенда:

```sh
uname -m
uname -r
cat /opt/etc/entware_release
opkg print-architecture
curl -fsS http://127.0.0.1:79/rci/show/version |
  jq '{model,hw_id,release,arch}'
curl -fsS http://127.0.0.1:79/rci/show/interface |
  jq '[.[] | {type,state,defaultgw}]'
```

Это команды **на разрешённом роутере**, не на обычном host. Для components
локально сверить `/etc/components.xml` и текущие CLI capabilities; сырые
конфигурации/секреты не переносить в отчёт. Sanitized fixture должен сохранять
форму и типы полей, необходимые для различения роли, без реальных endpoint.
`interface {name}` нельзя использовать для read-only проверки существования:
он может создать объект. GET `/rci/interface` может возвращать секреты;
собирать только целевые поля и не сохранять сырой ответ в общий лог.

| Gate | Конкретное недостающее доказательство | Владелец / что блокируется |
| --- | --- | --- |
| G1 | По каждому сохраняемому семейству: модель/OS/kernel/Entware ABI/libc, ELF и запуск минимального Rust; особенно MIPS BE и старейшие установки | #60, #67–#69; блокирует заявление о сохранении платформ и выпуск замены |
| G2 | По каждой строке штатного VPN: sanitized read fixture; create/read/update/read/delete, enable/disable, повтор после reboot, rollback при частичном отказе | #76/#77 и #83–#91; блокирует capability `managed`, пока не испытан соответствующий путь |
| G3 — снят | OpenVPN исключён решением пользователя 13.09.2026; импорт/backup не реализуются | #84/#85 вне объёма; этот gate больше не блокирует общее ядро |
| G4 | ASC A1/A2: импорт, неизвестные поля, round-trip, reconnect, совместимость с конкретным peer и отказ на старой OS | #82/#83; блокирует объявление ASC-варианта готовым |
| G5 | WAN/server/client классификация, судьба выбранного PPPOE/Proxy и безопасный отказ перехода с выбранным OpenVPN | #76/#92/#97/#98; блокирует миграцию таких установок без явного разрешения несовместимости |
| G6 | Source-bound DNS/TCP/UDP probe, upstream outage, отсутствие direct fallback, graceful переключение | #75/#94/#115; блокирует общий health/failover для непроверенной пары backend |
| G7 | Отсутствующий компонент → инструкция → ручная установка → продолжение мастера; безопасный отказ без изменения OS | #65/#107; блокирует завершённый UX для этой capability |
| G8 | NaiveProxy на MIPS BE: upstream не поддерживает big endian; разрешить несовпадение capabilities без исключения платформы либо исследовать отдельный порт. Для MIPSel/AArch64 проверить ELF/ISA/loader/kernel и поставку | #61/#62/#67–#69; BLOCKED для обещания NaiveProxy на всех платформах; Rust QEMU gate не заменяет этот gate |
| G9 | NaiveProxy: доказать защищённый DNS, UDP fail-closed, bootstrap/no-loop, ошибки CA/auth, egress/nonce, переключение и recovery; TCP-only предупреждение до допуска | #63/#65/#75/#78/#81/#115; BLOCKED для production-активации, несмотря на предварительный TCP успех |
| G10 | Закреплённая Chromium-версия, архив/ELF/disk/RAM, CA, notices/SBOM, схема доставки и rollback | #61/#63/#67–#69; BLOCKED для поставки NaiveProxy; наличие upstream archive не является package gate |

Итог #59 — инвентарь доказательств и gates, а не сертификат поддержки всех
моделей. Актуальные #61/#63 относятся к NaiveProxy; исследования Hysteria 2
остаются историческими свидетельствами и не доказывают новый backend. Новые adapters, Rust,
изменение scan, исправление миграции и испытания с мутациями здесь не реализованы.

## Реестр официальных источников

Источники K/E/F прочитаны 13.09.2026, N — 22.09.2026. Если статья не фиксирует минимальную
OS, использована дата редакции/чтения, а минимум помечен `?`. Release notes
с каналом Alpha/Beta/Development не являются обещанием для stable другой модели.

- [K1 — Entware USB, KN-4110](https://support.keenetic.com/hero-5g/kn-4110/en/20980-installing-the-entware-repository-on-a-usb-drive.html).
- [K2 — Entware internal memory, KN-2410](https://support.keenetic.com/hero-dsl/kn-2410/en/18482-1--installing-opkg-entware-in-the-router-s-internal-memory.html).
- [K3 — OpenVPN client and server](https://support.keenetic.com/hero-5g/kn-4110/en/17194-openvpn-client-and-server.html).
- [K4 — WireGuard VPN](https://support.keenetic.com/hero-5g/kn-4110/en/16937-wireguard-vpn.html).
- [K5 — OS 4.2, ASC CLI NDM-3202](https://support.keenetic.com/sprinter/kn-3710/en/36730-keeneticos-4-2.html).
- [K6 — OS 4.3, SYS-1320](https://support.keenetic.com/titan/kn-1812/en/42483-os-4-3.html).
- [K7 — OS 5.1, NDM-4298](https://support.keenetic.com/hero-5g/kn-4110/en/100158-latest-preview-release.html).
- [K8 — IKEv1/IKEv2 clients](https://support.keenetic.com/hero-5g/kn-4110/en/26696-ikev1-ikev2-clients.html).
- [K9 — SSTP client](https://support.keenetic.com/hero/kn-1011/en/16936-sstp-client.html).
- [K10 — PPTP/L2TP client](https://support.keenetic.com/starter/kn-1121/en/16934-pptp-l2tp-client.html).
- [K11 — OS components](https://support.keenetic.com/hero-4g-plus/kn-2311/en/16327-os-component-description.html).
- [K12 — CLI 4.1, KN-2410, §3.29 и Appendix B](https://storage.googleapis.com/docs.help.keenetic.com/cli/4.1/en/cli_manual_kn-2410.pdf).
- [K13 — L2TP/IPsec client](https://support.keenetic.com/hero-5g/kn-4110/en/16935-l2tp-ipsec-client.html).
- [K14 — OpenConnect client](https://support.keenetic.com/hero-5g/kn-4110/en/38656-openconnect-vpn-client.html).
- [K15 — Proxy client](https://support.keenetic.com/hero-5g/kn-4110/en/49443-proxy-client.html).
- [K16 — RCI через HTTP Proxy](https://support.keenetic.com/hero-5g/kn-4110/en/55035-using-api-methods-through-the-http-proxy-service.html).
- [K17 — OS 5.2 Development, NDM-4556/NDM-4555](https://support.keenetic.com/hero/kn-1012/en/35528-latest-development-release.html).
- [K18 — Other connections, исходная ссылка issue](https://support.keenetic.com/explorer/kn-1613/en/14516-other-connections.html).
- [E1 — Entware mips config, закреплённый SHA](https://github.com/Entware/Entware/blob/2d92d7c0b4055cb27901025f8a08d2e6344e849e/configs/mips-3.4.config).
- [E2 — Entware mipsel config, закреплённый SHA](https://github.com/Entware/Entware/blob/2d92d7c0b4055cb27901025f8a08d2e6344e849e/configs/mipsel-3.4.config).
- [E3 — Entware aarch64 config, закреплённый SHA](https://github.com/Entware/Entware/blob/2d92d7c0b4055cb27901025f8a08d2e6344e849e/configs/aarch64-3.10.config).
- [F1 — MIPS index](https://bin.entware.net/mipssf-k3.4/Packages.gz).
- [F2 — MIPSel index](https://bin.entware.net/mipselsf-k3.4/Packages.gz).
- [F3 — AArch64 index](https://bin.entware.net/aarch64-k3.10/Packages.gz).
- [N1 — NaiveProxy v150.0.7871.63-1, assets и digests](https://github.com/klzgrad/naiveproxy/releases/tag/v150.0.7871.63-1).
- [N2 — README кандидата: CONNECT, CA trust, обновления Chromium](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/README.md).
- [N3 — SOCKS5 команды, закреплённый исходник](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/src/net/tools/naive/socks5_server_socket.cc).
- [N4 — Upstream OpenWrt Support, редакция 05.04.2025, прочитано 22.09.2026](https://github.com/klzgrad/naiveproxy/wiki/OpenWrt-Support).
- [N5 — LICENSE кандидата](https://github.com/klzgrad/naiveproxy/blob/3ba967e2d36cc133a896e81a36257ad4c6ea20f4/LICENSE).
- [N6 — Предварительный опыт на NC-1913, 22.09.2026](naiveproxy-runtime-spike.md) — отчёт T-ref, опубликован вместе с матрицей; не официальный upstream и не повторное испытание.

## Проверка актуализации 22.09.2026

Обновлена матрица и добавлен исходный отчёт [N6]; runtime и роутеры не менялись. Проверки
локальных ссылок, кодов источников, структуры таблиц и `git diff --check`
выполнены отдельно от runtime gates. Полный `bash scripts/qa/static.sh`
запущен: package layout и secret scan пройдены, затем проверка остановилась
на CRLF в существующих файлах checkout. Общий static QA — **BLOCKED**;
массовая нормализация несвязанных файлов в #59 не выполняется. Это не
аппаратный тест и не подтверждение готовности NaiveProxy.
