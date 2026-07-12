![GitHub Repo stars](https://img.shields.io/github/stars/ivni/mors?color=orange) ![GitHub closed issues](https://img.shields.io/github/issues-closed/ivni/mors?color=success) ![GitHub last commit](https://img.shields.io/github/last-commit/ivni/mors) ![GitHub commit activity](https://img.shields.io/github/commit-activity/y/ivni/mors) ![GitHub top language](https://img.shields.io/github/languages/top/ivni/mors) ![GitHub code size in bytes](https://img.shields.io/github/languages/code-size/ivni/mors) 

---

# Mors (Морс)

Исторически проект является форком оригинального продукта [github.com/qzeleza/kvas](https://github.com/qzeleza/kvas), но текущие пакет, CLI и runtime-пути используют имя `mors`.

### VPN, SHADOWSOCKS и VLESS клиент для [роутеров Keenetic](https://keenetic.ru/ru/)

Минимальная поддерживаемая версия прошивки — **KeeneticOS 5**.

#### Пакет представляет собой обвязку или интерфейс командной строки для защиты Вашего соединения при обращении к определенным доменам.

#### В пакете реализуется связка: **ipset** + один из вариантов связки DNS сервера:
- **dnsmasq (с поддержкой wildcard)** + **dnscrypt-proxy2** + блокировщик рекламы **adblock** или
- **AdGuardHome** (уже включает в себя и шифрование **DNS** трафика и блокировщик рекламы).

> В связи с использованием в пакете утилиты dnsmasq с **wildcard**, можно работать с любыми доменными именами третьего и выше уровней. 
> Т.е. в белый список достаточно добавить **domen.com** и маршрутизация трафика 
> будет идти как к **sub1.domen.com**, так и к любому другому поддоменному имени типа **subN.domen.com**.


## Возможности
1. **Морс** работает на всех платформах произведенных **Keenetic** устройств, ввиду легковесности задействованных пакетов: **mips, mipsel, aarch64**.
2. **Морс** использует **dnsmasq**, **с поддержкой регулярных выражений**, а это в свою очередь дает одно, но большое преимущество: можно работать с соцсетями и прочими высоко-нагруженными сайтами, добавив лишь корневые домены по этим сайтам.
3. **Морс** позволяет **отображать статус/отключать/включать** блокировку рекламы (модуль **adblock** + **dnsmasq**);
4. **Морс** позволяет **отображать статус/отключать/включать** шифрование **DNS** (пакет **dnscrypt-proxy2**);
5. **Морс** позволяет тестировать и выводить отладочную информацию по всем элементам связки **ipset + (dnsmasq + dnscrypt-proxy2) | AdGuardHome**.
6. **Морс** позволяет подключить **AdGuardHome** в качестве **DNS** сервера, вместо связки **dnsmasq + dnscrypt-proxy2 + adblock**.
7. **Морс** позволяет оперировать со списком исключений при блокировке рекламы, добавляет и удаляет домены в этом списке.
8. **Морс** поддерживает маршрутизацию через **VLESS Reality** с помощью **Xray** и системного Proxy-интерфейса Keenetic.

### Совместимость с Xray

- Минимальная поддерживаемая версия Xray для VLESS Reality: **1.8.24**.
- Последняя проверенная версия: **26.2.6** (пакет Entware `26.2.6-1`).
- Mors не закрепляет точную версию пакета: `opkg` устанавливает актуальную сборку `xray` из подключенного репозитория Entware.
- Более старые версии блокируются при запуске VLESS. Более новые разрешаются с предупреждением и обязательной проверкой конфигурации через `xray run -test`.

Проверить установленную версию и её совместимость можно командой:

```sh
mors vless version
```

Для обновления Xray используйте:

```sh
opkg update
opkg install xray
```

### Управляемые VLESS-соединения

Mors хранит от одного до четырёх именованных VLESS Reality соединений. Одно исправное соединение остаётся активным, пока не произойдёт подтверждённый сбой. После сбоя supervisor выбирает наиболее здоровый резерв по свежести проверок, недавним ошибкам и задержке. Автоматического возврата на восстановившееся соединение нет.

Основной способ настройки:

```sh
mors vless
```

Команда открывает интерактивное меню. Для автоматизации доступны явные команды:

```sh
mors vless add --name "Финляндия" --link "vless://..."
mors vless update "Финляндия" --link "vless://..." --yes
mors vless disable "Финляндия"
mors vless activate "Германия"
mors vless remove "Старое" --yes
mors vless status
mors vless check --json
```

VLESS-ссылка после разбора не сохраняется целиком. Чувствительные параметры хранятся в отдельных файлах с правами `600` и не выводятся в status, JSON или события.
Для ручной настройки безопаснее вводить ссылку через `mors vless`: параметр `--link` нужен для автоматизации, но может остаться в shell history.

По умолчанию, если недоступны все VLESS-соединения, прямой выход через провайдера запрещён. Явно изменить политику можно командой:

```sh
mors vless policy direct-fallback on --yes
```

`mors vless status` отвечает за отображение данных. `mors vless check` предназначен для внешнего мониторинга: `0` означает исправное состояние, `1` - работа без готового резерва или запуск, `2` - недоступность либо прямой резерв, `3` - VLESS не настроен или приостановлен, `4` - неизвестное состояние.

### Диагностика Mors (beta)

Команды диагностики имеют разные задачи:

- status-подкоманды (`mors vpn status`, `mors vless status` и другие) показывают
  состояние соответствующего компонента без активного end-to-end доказательства;
- `mors test` выполняет активную IPv4 end-to-end проверку DNS → `MORS_LIST` → firewall/routing → tunnel → внешний HTTPS-выход;
- `mors debug` собирает подробные технические свидетельства для ручного анализа.

Основные режимы:

```sh
mors test
mors test --all
mors test --json
mors test --client 192.0.2.10
mors test cold
mors test cold recover
```

Обычный test, `--all` и client не меняют постоянное состояние роутера. Cold — отдельная подтверждаемая транзакция: Mors сохраняет затрагиваемые записи `ipset` и состояние DNS, проверяет повторное заполнение и восстанавливает snapshot. После аварийного завершения дальнейшие runtime-изменения блокируются до `mors test cold recover`.

Итоги и коды: `РАБОТАЕТ`/`0`, `ДЕГРАДАЦИЯ`/`1`, `ОШИБКА`/`2`, `НЕ ПРОВЕРЕНО` или `НЕ НАСТРОЕНО`/`3`; ошибка аргументов возвращает `64`. JSON имеет версионную схему и не содержит IP клиента/внешнего выхода или секретов.

Новый workflow выпускается как beta: static/BATS/mocked/package проверки выполняются без реального Keenetic, а DNS restart, реальные firewall/conntrack, NDM cancellation и crash/reboot recovery требуют последующего smoke-теста на авторизованном роутере.

Подробные контракты описаны в [дизайн-системе CLI](docs/cli-design-system.md), [архитектуре test](docs/test-architecture.md) и [архитектуре VLESS](docs/vless-architecture.md).

## Установка пакета 
1. Скачайте актуальный пакет `mors_*_all.ipk` из [GitHub Releases](https://github.com/ivni/mors/releases) или соберите пакет самостоятельно.
2. Зайдите в **entware** своего роутера и установите пакет командой `opkg install /полный/путь/к/mors_*_all.ipk`.
3. После установки выполните `mors setup`: сначала будет показан план, и только
   после явного подтверждения начнутся сетевые изменения. Само `opkg install`,
   а также `mors`, `mors help` и `mors version` DNS/firewall не меняют.

Совместная установка со старым пакетом `kvas` не поддерживается. Если он уже установлен на роутере, удалите его перед установкой `mors`. Старые артефакты `kvas_*` в каталоге `ipk/` относятся к историческому пакету Kvas и не являются пакетами Морса.

## Используемые в проекте продукты
- Для проведения тестов, в проекте используется пакет [BATS](https://github.com/bats-core/bats-core/blob/master/LICENSE.md) от нескольких [АВТОРОВ](https://github.com/bats-core/bats-core/blob/master/AUTHORS).

## Документация по проекту
- [Перейти по ссылке](https://github.com/ivni/mors/wiki).
- [Дизайн-система CLI](docs/cli-design-system.md).
- [Архитектура end-to-end проверки](docs/test-architecture.md).
- [Архитектура управляемых VLESS-соединений](docs/vless-architecture.md).

## Релизы проекта
- [GitHub Releases](https://github.com/ivni/mors/releases)
- [Каталог `ipk/`](https://github.com/ivni/mors/tree/main/ipk) содержит исторические артефакты Kvas и не заменяет актуальные релизы Морса.

## История "Звезд"

[![Star History Chart](https://api.star-history.com/svg?repos=ivni/mors&type=Timeline)](https://star-history.com/#ivni/mors&Timeline)

--- 
