# #77: адресация native-интерфейса через RCI и NDM

Дата: 27.09.2026. Target: разрешённый disposable NC-1913, OS 5.0.12.
Перед опытами проверены локальные TEST_INFRASTRUCTURE, SSH ProxyJump, модель
и Pi routes. Домашний роутер не изменялся. Все созданные PPTP77/PPTP78 заранее
проверялись на отсутствие; cleanup удалял их только по известному marker.
После каждого завершённого опыта сравнивался canonical SHA-256 `/rci/interface`.
Исходные конфигурации/endpoint/credentials в отчёт не копировались.

## Источники и метод

- [Официальное описание HTTP API](https://support.keenetic.com/starter/kn-1121/en/55035-using-api-methods-through-the-http-proxy-service.html): GET/POST JSON `/rci`, сходство с CLI.
- [Публичный NDM C API](https://github.com/ndmsystems/libndm/blob/e54163d0fb7e9bd10cc2abcfb68c8f9cf3dbe153/include/ndm/core.h): config/execute/parse, help, event stream. `agent` обозначает приложение, последним изменившее конфигурацию; это не lease.
- [Реализация request/session](https://github.com/ndmsystems/libndm/blob/e54163d0fb7e9bd10cc2abcfb68c8f9cf3dbe153/src/core.c): Unix socket `/var/run/ndm.core.socket`, Binary XML; response ID увеличивается клиентом, а не является generation интерфейса.

В опубликованном API не найден контракт conditional interface mutation.
Live help `system configuration` показал только factory-reset/fail-safe/save;
root/system/interface help не предъявили exclusive object lease. Это результат
проверки доступных поверхностей, не утверждение об отсутствии всех закрытых API.

Для persistent CLI-context использован ограниченный диагностический клиент
Binary XML на Go, статически собранный для MIPSel soft-float в отдельном контейнере.
Он не входит в ядро/пакет, не читает credentials и выводит только operation,
коды, имена команд справки и prompt. Обычный `ndmc -c` не сохраняет контекст между
вызовами; интерактивный ndmc требует входа, поэтому не использовались чужие пароли.
Исходник и скрипты опыта сохранены локально в `.qa/issue77/ndm/`.

## Результаты

| Механизм | Наблюдение | Вывод |
| --- | --- | --- |
| HTTP If-Match | Заведомо неверный header не помешал up временного PPTP77 | Не является conditional write на проверенной OS |
| RCI index | До и после delete/create PPTP77 index=77 | Не является incarnation |
| Открытая CLI-сессия | Enter PPTP77; параллельное удаление разрешено; новый PPTP77 down; `up` из старого context изменил новый объект на up | Context не удерживает безопасный object handle |
| Старый alias после обычного delete/create | CLI отклонил lookup, новый PPTP77 остался down | Защищает от обычного повторного использования ID |
| Alias перенесён на новый объект | Прежняя команда опять сработала | Не защищает от копирования/восстановления alias |
| HTTP по `Mors` + 32 hex | Up/down по alias работают; stale alias даёт semantic errors 6553730/6553609, новый ID остаётся down | Подходит для согласованного alias-only writer |
| Один alias для PPTP77 и PPTP78 | Второе назначение отклонено с 72155139; alias остался у PPTP77 | В проверенном RCI alias уникален среди текущих интерфейсов |

В отдельном stale-context опыте состояние нового объекта измерено явно:
до старой команды down/down/no; после неё up/down/no. То есть изменён admin state,
но никакой Internet egress/Ready не получен. Full configuration checksum восстановлен.

GET `show/interface/<alias>` не дал usable single-object response в этом опыте;
writer использует проверенный полный read-only inventory и точечный rename lookup.
Запросы на запись всегда используют alias. Детерминированный alias в опытах —
синтетическая fixture; production preparation должна брать `fresh_alias()` CSPRNG.

## Принятое решение

Пользователь явно выбрал продолжение через уникальный alias с перечисленными
ограничениями. Установленный alias — отдельный адрес управления, не доказательство
неизменности физического экземпляра при внешнем копировании конфигурации.
Отсутствие alias, несовпадение mapping и недостоверное чтение не разрешают fallback.
Подготовка/adoption должна объяснить переименование и сохранить прежнее имя.
Нельзя применять alias скрыто во время обычного start/stop или автоматически
восстанавливать потерянный alias на объекте с тем же canonical ID.

Операции Mors сериализуются; атомарности с внешними writers RCI не заявляется.
Наблюдаемый до POST state drift блокирует запись. Recovery принимает observed down,
а не восстанавливает прежнее up. Копирование alias и одновременные ручные изменения
после проверки остаются известными границами этого согласованного контракта.

## Проверка production Rust на живом RCI

[Очищенный результат](native-vpn-77-rust-live.json) получен вызовом реальных
`LocalNative`, `Backend` и durable `Executor` из Linux x86_64 контейнера.
Fixed loopback endpoint перенаправлялся прозрачным relay через loopback-only SSH
на RCI disposable router. В request/response не подставлялись fixture-ответы;
сырой трафик не сохранялся. SSH key не копировался в контейнер.

Подтверждены grant, реальный stop, повтор stop, UserStart с Timeout при неготовом
PPTP, recovery pending, Reconciled после внешнего down, Policy для AutomaticStart,
OwnershipConflict после пересоздания ID без alias и сохранение нового объекта down.
Baseline восстановлен. Это подтверждает семантику RCI и host Rust integration;
не подтверждает target ABI, MIPSel Rust ELF, все VPN-типы и версии OS или Ready
с реальным сервером. Go probe — только средство исследования NDM, не runtime Mors.
