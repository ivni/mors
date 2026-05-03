# QA Pipeline

Mors использует многоуровневый QA pipeline: быстрые проверки запускаются на pull request, а сборка пакета и smoke на роутере остаются отдельными release gate.

## Быстрый QA

`.github/workflows/qa.yml` запускается на pull request, push в `main` и вручную.

Проверки:

- наличие файлов, которые ожидает Entware-рецепт;
- поиск типовых токенов и приватных ключей;
- CRLF в tracked text-файлах;
- `bash -n` для runtime-скриптов;
- ShellCheck на уровне error;
- BATS-тесты из `tests/`.

Локальный запуск на Linux:

```sh
bash scripts/qa/static.sh
bats tests
```

## Сборка Пакета

`.github/workflows/package.yml` запускается вручную и по тегам `v*`. Workflow готовит Entware buildroot, подключает этот репозиторий как `package/mors`, собирает `.ipk` и публикует `packages/mors_*_all.ipk` как artifact.

Локальный запуск на Linux:

```sh
bash scripts/qa/entware-build.sh
```

Полезные переменные окружения:

- `ENTWARE_DIR` - каталог buildroot, по умолчанию `.qa/entware`;
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
