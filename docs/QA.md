# QA Pipeline

Mors использует многоуровневый QA pipeline: быстрые проверки запускаются на pull request, а сборка пакета и smoke на роутере остаются отдельными release gate.

## Быстрый QA

`.github/workflows/qa.yml` запускается на pull request, push в `main`, вручную и как обязательный reusable gate из release workflow.

Проверки:

- наличие файлов, которые ожидает Entware-рецепт;
- поиск типовых токенов и приватных ключей;
- CRLF в tracked text-файлах;
- `bash -n` для runtime-скриптов;
- ShellCheck на уровне error с allowlist для текущих legacy-находок;
- actionlint для всех GitHub Actions workflows с проверенным pinned binary;
- BATS-тесты из `tests/`.

Локальный запуск на Linux:

```sh
bash scripts/qa/static.sh
bats tests
```

## Сборка Пакета

`.github/workflows/package.yml` запускается вручную или как обязательный reusable gate из release workflow. Push тега намеренно не запускает сборку: release tag создаётся только после успешного кандидата.

Workflow готовит Entware buildroot, подключает этот репозиторий как `package/mors`, явно собирает host `opkg`, с изолированной пустой host-конфигурацией проверяет, что prerelease-версия сортируется ниже соответствующей стабильной версии, собирает `.ipk` и публикует `packages/mors_*_all.ipk` как artifact. Ожидаемое имя вычисляется из `PKG_VERSION` и `PKG_RELEASE`; отдельной жёстко заданной копии версии в build-скрипте нет.

Ревизии Entware buildroot и всех feeds закреплены в `scripts/qa/entware.lock`. Перед индексацией существующие feeds проверяются на отсутствие локальных изменений и переключаются на точные lock-ревизии, после индексации все HEAD проверяются повторно. GitHub Actions на закреплённом образе `ubuntu-24.04` кеширует buildroot по хешу lock-файла, архитектуре runner и версии схемы кеша: при cache miss выполняется полная холодная сборка, а при cache hit повторно используются tools, toolchain и собранные зависимости. Результат `package/mors` перед каждым запуском принудительно очищается и не сохраняется в кеше, поэтому `.ipk` всегда создаётся из текущего SHA Mors. При обновлении Entware измените ревизии в lock-файле; это автоматически создаст новый изолированный кеш.

Локальный запуск на Linux:

```sh
bash scripts/qa/entware-build.sh
```

Полезные переменные окружения:

- `ENTWARE_DIR` - каталог buildroot, по умолчанию соседний с репозиторием `.entware-build`;
- `ENTWARE_REPO_URL` - URL репозитория Entware;
- `ENTWARE_REVISION` - 40-символьная ревизия buildroot; по умолчанию берётся из lock-файла;
- `ENTWARE_LOCK_FILE` - путь к альтернативному lock-файлу buildroot и feeds;
- `ENTWARE_CONFIG` - целевой config, по умолчанию `configs/aarch64-3.10.config`;
- `JOBS` - число параллельных make-задач.

## Release Gate

`.github/workflows/release.yml` запускается только вручную на выбранном commit/branch и требует:

- tag, точно соответствующий `PKG_VERSION` (`~` в версии преобразуется в `-` в tag);
- русский заголовок и release notes;
- явное подтверждение `publish-mors`;
- выбор prerelease/stable.

Workflow на одном `github.sha` выполняет:

1. Проверку соответствия tag, `Makefile` и первой записи `HISTORY.md`.
2. Полный reusable `qa.yml` gate.
3. Полный reusable `package.yml` gate.
4. Проверку единственного `.ipk`: имя, `debian-binary`, control metadata, обязательные runtime-файлы и SHA-256.
5. Только после успеха всех gates — создание аннотированного неизменяемого tag и GitHub Release. Если публикация Release оборвалась уже после tag push, повторный workflow может использовать tag только при точном совпадении SHA; tag никогда не перемещается.

Имя upload asset заранее нормализуется так же, как GitHub (`~` заменяется на `.`); внутренняя control-версия сохраняет `~`. Секция с именем файла, control version, размером и SHA-256 добавляется к release notes автоматически.

Для проверки кандидата без tag/release запускайте `package.yml` вручную. Не создавайте tag вручную «для запуска сборки»: это нарушает связь между проверенным SHA и опубликованным релизом.

## Router Smoke

`.github/workflows/router-smoke.yml` запускается только вручную и требует ввести
`install-mors-passive`.

Нужные repository secrets:

- `MORS_ROUTER_HOST`;
- `MORS_ROUTER_SSH_KEY`;
- опционально `MORS_ROUTER_USER`, по умолчанию `root`;
- опционально `MORS_ROUTER_PORT`, по умолчанию `22`.

Smoke job собирает пакет, загружает его в `/opt/tmp/mors-qa`, устанавливает через
`opkg`, подтверждает отсутствие Mors hooks/dataplane, затем выполняет пассивный
`mors uninstall --yes` и сравнивает DNS services/configs, firewall и ipset с
состоянием непосредственно после установки. Используйте его только на
disposable или специально подготовленном тестовом Keenetic.

Для `1.3.0~beta8` физический стенд обязателен; фактический объём smoke и все пропуски должны быть явно указаны при публикации. До стабильного релиза на авторизованном роутере необходимо проверить:

- cold restart/restore для dnsmasq и Entware-managed AdGuard Home;
- реальные `iptables` counters и conntrack correlation;
- forced-interface HTTPS для поддерживаемых типов Keenetic VPN;
- active/reserve VLESS при параллельном supervisor cycle;
- временный `ss-local` на целевых архитектурах;
- отмену cold событиями WAN/interface/netfilter;
- recovery после SIGKILL и reboot;
- client mode с DNS cache и private/external DNS;
- install, upgrade и rollback IPK с prerelease-версией.
- opt-in telemetry: успешную тестовую запись Monium, offline queue/recovery,
  отсутствие full-file rewrite при длительной ошибке, stop/restart/reboot,
  lifecycle snapshot/rollback, bounded CPU/RAM и неизменность routing/firewall
  при ошибке облачного приёмника.
