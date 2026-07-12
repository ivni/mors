# QA Pipeline

Mors использует многоуровневый QA pipeline: быстрые проверки запускаются на pull request, а сборка пакета и smoke на роутере остаются отдельными release gate.

## Быстрый QA

`.github/workflows/qa.yml` запускается на pull request, push в `main` и вручную.

Проверки:

- наличие файлов, которые ожидает Entware-рецепт;
- поиск типовых токенов и приватных ключей;
- CRLF в tracked text-файлах;
- `bash -n` для runtime-скриптов;
- ShellCheck на уровне error с allowlist для текущих legacy-находок;
- BATS-тесты из `tests/`.

Локальный запуск на Linux:

```sh
bash scripts/qa/static.sh
bats tests
```

## Сборка Пакета

`.github/workflows/package.yml` запускается вручную и по тегам `v*`. Workflow готовит Entware buildroot, подключает этот репозиторий как `package/mors`, явно собирает host `opkg`, проверяет порядок `1.2.0 < 1.3.0~beta2 < 1.3.0`, собирает `.ipk` и публикует `packages/mors_*_all.ipk` как artifact. Для beta дополнительно проверяется точное имя `mors_1.3.0~beta2-1_all.ipk`.

Локальный запуск на Linux:

```sh
bash scripts/qa/entware-build.sh
```

Полезные переменные окружения:

- `ENTWARE_DIR` - каталог buildroot, по умолчанию соседний с репозиторием `.entware-build`;
- `ENTWARE_REPO_URL` - URL репозитория Entware;
- `ENTWARE_CONFIG` - целевой config, по умолчанию `configs/aarch64-3.10.config`;
- `JOBS` - число параллельных make-задач.

## Router Smoke

`.github/workflows/router-smoke.yml` запускается только вручную и требует ввести `install-mors`.

Нужные repository secrets:

- `MORS_ROUTER_HOST`;
- `MORS_ROUTER_SSH_KEY`;
- опционально `MORS_ROUTER_USER`, по умолчанию `root`;
- опционально `MORS_ROUTER_PORT`, по умолчанию `22`.

Smoke job собирает пакет, загружает его в `/opt/tmp/mors-qa`, устанавливает через `opkg` и запускает базовые CLI-проверки. Используйте его только на disposable или специально подготовленном тестовом Keenetic.

Для `1.3.0~beta2` отсутствие такого стенда не блокирует beta, но должно быть явно указано при публикации. До стабильного релиза на авторизованном роутере необходимо проверить:

- cold restart/restore для dnsmasq и Entware-managed AdGuard Home;
- реальные `iptables` counters и conntrack correlation;
- forced-interface HTTPS для поддерживаемых типов Keenetic VPN;
- active/reserve VLESS при параллельном supervisor cycle;
- временный `ss-local` на целевых архитектурах;
- отмену cold событиями WAN/interface/netfilter;
- recovery после SIGKILL и reboot;
- client mode с DNS cache и private/external DNS;
- install, upgrade и rollback IPK с prerelease-версией.
