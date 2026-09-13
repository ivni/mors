# Rust на Entware: ограниченный spike #60

Дата: 13.09.2026. Задача: [#60](https://github.com/ivni/mors/issues/60).
Контракт: [REQ-CORE-006–007](../connection-core-requirements.md),
[матрица #59](connection-platform-matrix.md). Timebox — одна сессия.

**Результат: patched Rust compiler, std и dynamic/static ELF собраны для
MIPS, MIPSel и AArch64; все шесть ELF прошли IPC под QEMU. Оба MIPSel ELF
дополнительно прошли IPC на disposable Viva NC-1913.** Кандидат — Rust **1.94.0 с патчами
закреплённого Entware feed**, собственным `std` и Entware GCC/sysroot.
Продуктовый минимум — **KeeneticOS 5**, как указано в [README](../../README.md).
Полная production-совместимость со всеми моделями этим spike не доказывается.
Отсутствие запущенного Docker оказалось устранимым: Docker Desktop
запущен, работа продолжена в disposable контейнерах. Это не основание
отказываться от MIPS, MIPSel или AArch64 либо сокращать охват.

**Ограничение инфраструктуры, уточнённое пользователем:** доступен только
один тестовый роутер — NC-1913. Дополнительные физические роутеры не являются
предпосылкой следующих экспериментов. Реальные испытания выполняются на нём;
MIPS BE/AArch64 проверяются в эмуляции. Версии ядра для дальнейших испытаний
выбираются по поддерживаемым KeeneticOS 5+, а не по названию Entware feed.
Это определяет способ
проверки, но не превращает эмуляцию в доказательство работы на каждой модели.

## База и метод

GitHub API подтвердил текущий `main`:
`43ef141f366a7d7e5a22c6fe0558fc62fa529097`. Локальный HEAD:
`af6823cbde85059c5fc55fd494e207c10abbe7bb`, содержит результат #59 и уточнение
об исключении OpenVPN. Эти ветви расходятся; checkout не переключался, чужие
изменения телеметрии сохранены. Сравнение
`git diff origin/main HEAD -- scripts/qa/entware.lock builder/entware scripts/qa/entware-build.sh`
пустое: исследуемые build inputs совпадают с актуальным main. Результат
добавлен отдельным документом, без переноса локальных runtime-изменений.

Прочитаны закреплённые исходники, выполнены проверки разрешённого стенда
и локальные сборки в Docker. До SSH прочитан `TEST_INFRASTRUCTURE.local.md`.
Сетевые адреса, ключи и endpoint-данные в отчёт не включены. На роутере
пакеты не устанавливались, сервисы, firewall, DNS и маршруты не менялись.
Два тестовых ELF запускались из `/tmp` и удалены после проверки.

Обозначения: **S** — проверенные исходники указанной версии;
**T** — выполненная конкретная проверка; **?** — доказательства нет.
Метаданные target, наличие GCC или успешный SSH не равны запуску Rust.

## Зафиксированные версии

| Компонент | Версия / основание | Уровень |
| --- | --- | --- |
| Entware buildroot | `2d92d7c0b4055cb27901025f8a08d2e6344e849e` из `scripts/qa/entware.lock` | S |
| Entware Rust feed | `379fa6ff578506a50e3158b92ac2c09bc22cb450` из того же lock | S |
| `rustc-dev` и `rustc` feed | `1.94.0-1`; исходный архив SHA-256 `b83f921cd3f321ff614f9c06a8b870d89299fc02888b48a5549683a36823474c` | S [E1], [E2] |
| C toolchain | GCC 8.4.0, binutils 2.34, glibc 2.27 в закреплённых конфигурациях | S [E6], [E7], матрица #59 |
| Фактически запущенный patched Rust compiler | `1.94.0-nightly`, commit `4a4ef493e3a1488c6e321570238084b38948f6db`, LLVM 21.1.8, host `x86_64-unknown-linux-gnu`, собранный stage1 | T |
| Bootstrap compiler | Rust 1.93.0, commit `254b59607d4417e9dffbc307138ae5c86280fe4c`, LLVM 21.1.8 | T |
| Docker client/server | 29.6.2; Linux x86_64, 4 CPU, около 7.7 GiB RAM | T |
| QEMU / host kernel | qemu-aarch64 8.2.2 (`1:8.2.2+ds-0ubuntu1.18`); `6.18.33.2-microsoft-standard-WSL2` | T |

Версия исходного recipe не выдаётся за проверенную сборку toolchain.
`rustc-dev` собирает host compiler и target `library/std` отдельно, задаёт
канал `nightly` для своей сборки, фиксирует LLVM prebuild commit
`4a4ef493e3a1488c6e321570238084b38948f6db`. Это **не** плавающий `rustup nightly`.
Загрузка prebuild и сборка stage1 в этой сессии состоялись. Полный
`rustc-dev/compile` остановлен на повторной stage2-компиляции: для spike
использован уже готовый stage1, далее отдельно собрана target `std`.
Успешный полный install developer toolchain не заявляется.

## Результаты по платформам

| Платформа | Кандидат target и C linker | ABI / заявленная база ядра | ELF, размер, запуск, IPC |
| --- | --- | --- | --- |
| MIPS BE | `mips-openwrt-linux-gnu`, `mips-openwrt-linux-gcc` из соответствующего staging toolchain | S+T: ELF32, big endian, O32, MIPS32r2, FP ABI Soft float, atomics до 32 bit; glibc 2.27, Linux 3.4+ в metadata [E3] | T: dynamic 279084 bytes, static 842108 bytes; ELF и IPC подтверждены в QEMU. Физического BE-испытания нет; граница evidence B4 |
| MIPSel | `mipsel-openwrt-linux-gnu`, `mipsel-openwrt-linux-gcc` | S+T: ELF32, little endian, O32, MIPS32r2, FP ABI Soft float, atomics до 32 bit; glibc 2.27, Linux 3.4+ в metadata [E3] | T: dynamic 279420 bytes, static 842812 bytes; оба ELF прошли QEMU и реальный NC-1913 с OS 5 на `4.9-ndm-5` |
| AArch64 | `aarch64-openwrt-linux-gnu`, `aarch64-openwrt-linux-gcc` | S+T: 64 bit little endian, `+v8a`; C config `cortex-a53`; glibc 2.27, Linux 3.10+ в metadata [E3] | T: dynamic 208144 bytes, static 774984 bytes; оба ELF и IPC проверены в QEMU. Физического AArch64-испытания нет; граница evidence B4 |

Для всех трёх платформ проверен driver GCC 8.4.0 и GNU ld 2.34 из staging
toolchain. `-print-sysroot` возвращает пустую строку: этот driver нельзя
считать неработающим по одному этому результату, нужны его search paths и ELF.
Для MIPS проверены O32 и soft-float в ELF attributes, а не только
`Machine: MIPS`. Полные outputs сохранены в
[evidence JSON](rust-entware-spike-evidence.json).

**Продуктовый минимум — KeeneticOS 5; минимальное ядро отдельно не объявлено.**
Числа 3.4/3.10 выше — metadata patched target и база Entware. Они не задают
поддерживаемый парк Mors и не создают требования испытывать эти ядра в #60.
Реально проверено `4.9-ndm-5` на NC-1913 с OS 5; переносить это значение на
все модели также нельзя. Для будущего kernel gate сначала нужно установить
фактические ядра поддерживаемых KeeneticOS 5+ и требования используемых
syscall/зависимостей. QEMU user-mode проверяет ABI на ядре host.

### Выполненные проверки окружения

Команды Windows PowerShell (SSH aliases определены только локально):

```powershell
Get-Command rustc,cargo,rustup,docker,wsl,bash -ErrorAction SilentlyContinue
docker version
docker image ls --format '{{.Repository}}:{{.Tag}}'
wsl --list --quiet
ssh -o BatchMode=yes -o ConnectTimeout=8 mors-test-pi 'uname -m; uname -r; command -v rustc cargo docker gcc readelf qemu-mipsel; rustc --version; ip route'
ssh -o BatchMode=yes -o ConnectTimeout=8 mors-test-router 'uname -m; uname -r; opkg --version'
ssh -o BatchMode=yes mors-test-router 'command -v rustc cargo gcc readelf; opkg status libc; opkg print-architecture; ls -l /opt/lib/ld*'
```

- Windows: `rustc`, `cargo`, `rustup` не найдены в PATH. Первоначально
  Docker server не был запущен; WSL перечислил только `docker-desktop`.
  После `Start-Process` установленного Docker Desktop с `-WindowStyle Hidden`
  daemon стал доступен. Отдельный WSL distribution не потребовался.
- Raspberry Pi: `aarch64`, Linux `6.18.34+rpt-rpi-v8`; доступны GCC и readelf,
  Rust/Cargo/Docker/qemu-mipsel через `command -v` не найдены;
  `rustc --version`: `command not found`. Маршруты соответствуют локальному
  описанию стенда. Pi с Debian не является AArch64 Entware/Keenetic тестом.
- Тестовый роутер: `uname -m` → `mips`, `uname -r` → `4.9-ndm-5`;
  `libc 2.27-12`, architecture `mipsel-3.4`; дополнительно зарегистрирован
  `mipsel-3.4_kn`; loader `/opt/lib/ld.so.1 -> ld-2.27.so`.
  Ни один из `rustc cargo gcc readelf` не найден в PATH.
  `opkg` сообщает revision `80503d94e356476250adaf1f669ee955ec26de76`
  от 2025-11-05. Read-only `ndmc -c "show version"` с фильтром только
  model/release/arch подтвердил `Viva (NC-1913)`, release `5.00.C.12.0-0`,
  arch `mips`. `curl`/`jq` на стенде отсутствуют; они не устанавливались.
  `uname -m=mips` сам по себе не определяет endian.

Предыдущее SSH `Connection refused` из #59 в этой сессии не воспроизвелось.
Успешный Rust IPC подтверждён отдельным запуском, описанным ниже.

### Выполненный Docker-эксперимент

Исходный локальный image, использованный по digest:
`ghcr.io/ivni/mors-entware-builder@sha256:5eb5bd38560cd981d4396a1b6f6f9988b0a0ee74620647bbfff23f3439c72b4e`.
Manifest сообщает builder ID
`428f8b1260ee7787fcf03e986bb34d80b47bf59e716f878c996255014a7c44ea`.
HEAD buildroot и Rust feed внутри совпали с lock из таблицы.
Это диагностический эксперимент, не прохождение release attestation gate.
Image не изменялся; работа происходила в writable layers контейнеров.

В контейнере запущен `make -j2 package/feeds/rustlang/rustc-dev/compile V=s`.
Архив Rust 1.94.0 скачан с `https://static.rust-lang.org/dist/rustc-1.94.0-src.tar.gz`;
SHA-256 совпал с recipe. Stage1 compiler собрался за 7m19s (только compiler
artifacts, не весь эксперимент). Повторный stage2 остановлен намеренно.
В generated `bootstrap.toml` добавлены `cc`, `cxx`, `ar`, `linker` AArch64
из `staging_dir/toolchain-aarch64_cortex-a53_gcc-8.4.0_glibc-2.27/bin/`
и `default-linker-linux-override = "off"`.

Из каталога исходников
`/opt/entware/build_dir/hostpkg/rustc-dev-1.94.0` выполнено:

```sh
CARGO_HOME=/opt/entware/staging_dir/target-aarch64_cortex-a53_glibc-2.27/host/share/cargo.dev \
  python3 x.py build --stage 1 --keep-stage 0 \
  --target aarch64-openwrt-linux-gnu library/std
```

`--keep-stage 0` сохраняет результат compiler stage0→stage1, но **не**
пропускает target std stage1; она успешно скомпилирована за 33.31s.
Использован compiler `build/x86_64-unknown-linux-gnu/stage1/bin/rustc`.
Bootstrap предупреждал о reuse compiler и неопределённом `STAGING_DIR`
при сборке C builtins; exit 0. При линковке пробы `STAGING_DIR` задан явно.

Для MIPS/MIPSel созданы ещё два контейнера из того же image. В каждом:
`cp configs/mips-3.4.config .config` либо
`cp configs/mipsel-3.4.config .config`, затем `make defconfig` и
`make -j2 toolchain/install V=s`. Начальные стадии выполнялись с `-j1`;
после освобождения CPU сборки корректно прерваны SIGINT и продолжены с `-j2`.
Оба `toolchain/install` завершились с exit 0, включая final GCC, libgcc и
patch-specs. Runtime dependencies/package Mors не собирались.

Соответствующие `staging_dir/toolchain-<arch>_mips32r2_gcc-8.4.0_glibc-2.27`
переданы через `docker cp` в Rust-контейнер с сохранением абсолютного пути.
В bootstrap добавлены target-блоки `cc`, `ar`, `linker` для каждого ABI.
Для MIPSel использовались имена `mipsel-openwrt-linux-gnu-{gcc,ar}`, для
MIPS — `mips-openwrt-linux-{gcc,ar}`; aliases окончательного toolchain
указывали на те же GNU tools. Затем та же команда `x.py` выполнена с
`--target mipsel-openwrt-linux-gnu` и `--target mips-openwrt-linux-gnu`.
Обе std сборки завершились с exit 0. Ранняя MIPSel попытка с промежуточным
C toolchain остановилась на `cannot find -lgcc_s`; после final toolchain
ошибка снята без изменений Rust-кода/ABI. Это prerequisite, не отказ платформы.

Окончательный source пробы ниже имеет SHA-256
`d7c5128b144bda8c2257cb2eeb6a411415302b19caa4d8abde7dacae10ff1cfb` (LF).
Он включает собственный watchdog: на роутере не обнаружен `timeout`.
Watchdog отдельно испытан в QEMU: child без запроса завершился с exit 124.

| ELF | Размер bytes | SHA-256 | Проверка |
| --- | ---: | --- | --- |
| AArch64 dynamic | 208144 | `ab4a5bf221b78c4df474029d8eefb7cab96a41f5c6052e29798f229c9f798409` | QEMU: exit 0, `mors-rust-spike-v1 ipc=ok` |
| AArch64 static glibc | 774984 | `98c2a31ac7d9435df4db994c96a8c419282fc604e8f98dc48a78a8d4d3b8e5fe` | QEMU: exit 0, тот же ответ |
| MIPSel dynamic | 279420 | `db4e75077f94c84365232e163aab5b3d73e31a9908f21b64ae86f544979918ff` | QEMU и NC-1913: exit 0, тот же ответ |
| MIPSel static glibc | 842812 | `22a70d45bdefb1624467082bd1125fb86b7f06708a128b95d80439fcb03359e6` | QEMU и NC-1913: exit 0, тот же ответ |
| MIPS BE dynamic | 279084 | `cea403e5b040084bfbfff634b7a7e3a311a2e3aff373deef1d9876f1db4cb022` | QEMU: exit 0, тот же ответ |
| MIPS BE static glibc | 842108 | `d91f3f58c1fb5b9cfcc7d42906bac6f66780f7e3376136bec5d5d40b6964330c` | QEMU: exit 0, тот же ответ |

Перед QEMU-запусками задан `MORS_SPIKE_RUNNER=/usr/bin/qemu-aarch64`:
родитель явно запускает дочерний ELF через emulator, без изменения глобального
`binfmt`. На настоящем target эта переменная отсутствует, выполняется обычный
exec того же ELF. Запуск dynamic:
`QEMU_LD_PREFIX=/opt/entware/staging_dir/target-aarch64_cortex-a53_glibc-2.27/root-aarch64-3.10 timeout 12 qemu-aarch64 /tmp/probe-aarch64-dynamic`.
Static: `timeout 12 qemu-aarch64 /tmp/probe-aarch64-static`.
ELF interpreter dynamic — `/opt/lib/ld-linux-aarch64.so.1`, RPATH — `/opt/lib`.
`DT_NEEDED`: `libgcc_s.so.1`, `libpthread.so.0`, `libdl.so.2`, `libc.so.6`.
Static не имеет `PT_INTERP`/`DT_NEEDED`. Полный список GLIBC symbol versions
получен через `readelf -V`; он не заменяет проверку нижнего ядра или libc.

Для MIPS/MIPSel `QEMU_LD_PREFIX=/tmp/sysroot-<arch>`, где `opt/lib` — ссылка
на `lib` соответствующего законченного C toolchain;
`MORS_SPIKE_RUNNER=/usr/bin/qemu-<arch>`. Выполнены
`timeout 12 qemu-<arch> /tmp/probe-<arch>-dynamic` и аналогичный static.
Их dynamic interpreter — `/opt/lib/ld.so.1`, RPATH — `/opt/lib`;
`DT_NEEDED`: `libgcc_s.so.1`, `librt.so.1`, `libpthread.so.0`, `libdl.so.2`,
`libc.so.6`, `ld.so.1`. Все static ELF не имеют `PT_INTERP`/`DT_NEEDED`.
Максимальная импортируемая версия GLIBC у каждой dynamic пробы — 2.18;
это не разрешение снизить подтверждённую libc baseline 2.27.

### Испытание на NC-1913

Перед записью проверены `ssh -G mors-test-router`: hostname и ProxyJump
совпали с разрешёнными в локальном infrastructure-файле; маршруты Pi также
совпали с ним. Через `mktemp -d /tmp/mors-rust-60.XXXXXX` создан отдельный
каталог; два MIPSel ELF скопированы через `scp -O`. На роутере выполнены
`sha256sum`, `chmod 700`, `unset MORS_SPIKE_RUNNER QEMU_LD_PREFIX`, затем
`./probe-mipsel-dynamic` и `./probe-mipsel-static`. SHA совпали с таблицей;
оба процесса вернули `mors-rust-spike-v1 ipc=ok`, оба exit code — 0.
После проверки канонического пути удалены только эти два файла и каталог.
Это тест обычного fork/exec, pipes и thread/watchdog на конкретном ядре,
без emulator и без установки compiler/пакетов на роутер.

## Сравнение linking

| Вариант | Преимущество | Ограничения и статус |
| --- | --- | --- |
| Patched Entware Rust + dynamic glibc | Единый проверенный кандидат на все три ABI, соответствует существующему `/opt`; повторное использование системной libc | Все три ELF/IPC подтверждены в QEMU, MIPSel также на NC-1913; dependency list выше. Нижние ядра и остальные реальные модели требуют проверки |
| Официальный Rust + dynamic glibc | Готовый AArch64 `std`; меньше собственной поддержки compiler | AArch64 upstream требует Linux 4.1+ [R1]; его нужно сопоставлять с ядрами поддерживаемых OS 5+, а не с названием Entware feed. MIPSel 1.94.0 Tier 3 имеет `+fpxx,+nooddspreg`, а не Entware soft-float [R2]. Простая смена linker не пересобирает готовый `std`; для общего охвата вариант не доказан |
| Patched Rust + static glibc | Убирает ELF interpreter и внешние ELF-библиотеки у измеренной пробы | Все три ELF/IPC подтверждены в QEMU, MIPSel также на NC-1913. Размер примерно в 3–3.8 раза выше dynamic; resolver/NSS и нижние ядра не проверены |
| Rust + static musl | Можно избежать glibc/loader зависимости | Другая libc и sysroot; нужны совпадающий soft-float `std`, kernel/atomics/DNS проверки. В patch есть musl targets, но их наличие не доказывает поставку musl toolchain. Не заменять Entware libc; только отдельный эксперимент |

В [E4] `-C relocation-model=static` используется **вместе** с
`-Wl,-rpath,/opt/lib`: слово `static` здесь не означает статическую libc.
Окончательный список зависимостей получают из ELF, а не из размера или флагов.
Зависимости пакета самого `rustc` (`libcurl`, `libopenssl`, `libstdcpp` и т. д.)
не следует автоматически переносить в runtime-зависимости будущего ядра.

Отсутствие стандартного rustup target не является отказом от MIPS:
Entware [E1], [E3] уже содержит процедуру сборки compiler и `std`.
Собственный JSON target с непересобранным `std` тоже не закрывает ABI.
Патч старых ядер [E5] меняет отдельные vendored `getrandom`; он не гарантирует
совместимость всех будущих зависимостей ядра или произвольных syscall.

## Рецепт минимального бинарника и дальнейшей проверки

Подготовительные make-команды ниже остаются рецептом полного toolchain;
фактически выполненный сокращённый stage1-путь описан выше. Вход — Entware
buildroot для каждой строки матрицы, точно на lock выше, с установленным
`rustc-dev` и target `std`. Создание постоянного builder относится к #67;
оно не выполнялось здесь. Не запускать `entware-build.sh` ради spike:
его обычный путь собирает пакет Mors и пишет package outputs.

На подготовленном buildroot сначала проверить build-system targets
`make package/feeds/rustlang/rustc-dev/host/compile V=s` и
`make package/feeds/rustlang/rustc-dev/compile V=s`. Это recipe из [E1],
полный install здесь не завершён; prerequisite tools/toolchain должны
быть уже собраны. Не менять immutable image на месте.

Ниже воспроизводимая спецификация минимальной пробы, без бизнес-логики.
Файл создаётся только в scratch. Для каждого ABI передать абсолютные пути
`SPIKE_RUSTC` (patched host rustc) и `SPIKE_CC` (его target GCC), а также
`SPIKE_TARGET` из таблицы. Скрипт требует GNU host tools и Bash.

```bash
set -euo pipefail
: "${SPIKE_RUSTC:?patched host rustc}" "${SPIKE_CC:?Entware target gcc}"
: "${SPIKE_TARGET:?target from matrix}"
spike_dir=$(mktemp -d "${TMPDIR:-/tmp}/mors-rust-60.XXXXXXXX")
cd "$spike_dir"
"$SPIKE_RUSTC" -vV
"$SPIKE_RUSTC" --print target-list | grep -Fx "$SPIKE_TARGET"
"$SPIKE_RUSTC" --target "$SPIKE_TARGET" --print cfg
"$SPIKE_CC" --version
"$SPIKE_CC" -dumpmachine
"$SPIKE_CC" -print-sysroot
cat > probe.rs <<'RS'
use std::io::{self, Read, Write};
use std::process::{Command, Stdio};

fn main() -> io::Result<()> {
    std::thread::spawn(|| {
        std::thread::sleep(std::time::Duration::from_secs(10));
        std::process::exit(124);
    });
    if std::env::args().nth(1).as_deref() == Some("child") {
        let mut request = [0u8; 5];
        io::stdin().read_exact(&mut request)?;
        if &request != b"ping\n" {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "request"));
        }
        io::stdout().write_all(b"pong\n")?;
        return Ok(());
    }
    let exe = std::env::current_exe()?;
    let mut command = match std::env::var_os("MORS_SPIKE_RUNNER") {
        Some(runner) => {
            let mut command = Command::new(runner);
            command.arg(&exe);
            command
        }
        None => Command::new(&exe),
    };
    let mut child = command
        .arg("child").stdin(Stdio::piped()).stdout(Stdio::piped()).spawn()?;
    child.stdin.take().unwrap().write_all(b"ping\n")?;
    let result = child.wait_with_output()?;
    if !result.status.success() || result.stdout != b"pong\n" {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "response"));
    }
    println!("mors-rust-spike-v1 ipc=ok");
    Ok(())
}
RS
"$SPIKE_RUSTC" --edition=2021 --target "$SPIKE_TARGET" probe.rs \
    -C "linker=$SPIKE_CC" -C opt-level=z -C panic=abort \
    -C codegen-units=1 -C strip=symbols -C relocation-model=static \
    -C link-arg=-Wl,-rpath,/opt/lib -o probe
sha256sum probe.rs probe
wc -c < probe
readelf -h -l -d -A -V probe
```

Сохранить stdout/stderr, exit code, compiler commit/LLVM, SHA sysroot/patches,
байтовый размер stripped ELF и его SHA-256. Проверить, что GCC triplet и
Rust target соответствуют одной строке, interpreter указывает в `/opt/lib`,
GLIBC imports не превышают доступную libc, каждый `DT_NEEDED` разрешается.
Для MIPS проверить endian, O32, MIPS32r2 и soft-float. Проверить также
undefined atomic symbols и реальные зависимости от libgcc/libatomic.

Запускать **тот же** ELF по SHA на явно разрешённом target из volatile
scratch. Каждый процесс пробы сам завершается через 10 секунд с exit 124;
внешний `timeout 12 ./probe` использовать дополнительно, если доступен.
Успех: exit 0, ровно `mors-rust-spike-v1 ipc=ok`, нет оставшегося child.
При таймауте завершить только процессы этой пробы. Это проверка
двунаправленных pipes между процессами, не Unix socket API, DNS, TLS,
нагрузки или crash recovery. Затем удалить только созданный scratch после
проверки его абсолютного пути; код пробы в production не переносить.

Отдельно повторить static glibc вариант с
`-C target-feature=+crt-static`, другим именем ELF и теми же проверками.
Отсутствие `PT_INTERP` и `DT_NEEDED` подтвердить readelf, не предполагать.
Для musl нужен отдельный согласованный sysroot/compiler/std; одного
добавления этого флага к GNU target недостаточно. Измерять каждый вариант
отдельно, одинаковыми optimization/strip flags. На ядрах поддерживаемых OS 5+ дополнить
пробу thread/TLS, clocks, randomness, DNS и syscall fallback: pipes не
доказывают пригодность всего будущего ядра.

## Блокеры и критерии продолжения

| ID | Точный пробел | Следующий эксперимент / куда относится |
| --- | --- | --- |
| B1 — снят | Docker запущен; patched Rust stage1, три std и C toolchains доступны и испытаны | Постоянная воспроизводимая интеграция полного toolchain в builder остаётся #67; diagnostic stage1 её не заменяет |
| B2 — снят | Шесть ELF/size/link/IPC подтверждены в QEMU, оба MIPSel — на NC-1913 | Промежуточный `-lgcc_s` prerequisite разрешён завершением C toolchain; отказа от платформы нет |
| B3 — снят как необоснованный | Требование испытать Linux 3.4/3.10 было ошибочно выведено из Entware feed; README ограничивает поддержку KeeneticOS 5+ | Обязательного эксперимента со старыми ядрами в #60 нет. При введении kernel gate в дальнейшем установить реальные ядра поддерживаемых OS 5+, затем выбирать испытания |
| B4 — граница evidence | MIPS BE/AArch64 проверены в QEMU; единственный физический стенд — NC-1913 | Дополнительные роутеры и тест Linux 3.10 не требуются для завершения spike. Сохранять разграничение эмуляции и hardware; production-проверки выполняются в контуре KeeneticOS 5+ |

Исходную гипотезу «подходит stock rustup для всех» использовать нельзя.
Полученных результатов достаточно для рекомендации toolchain и продолжения
следующих задач. Они не заменяют их packaging/runtime/release gates;
локальный workspace #66 сам по себе эти gates не закрывает. Не объявлять
package ABI `all` пригодным для ELF и не исключать платформы.

Критерии #60: версии/target/linking/размер/базовый IPC подтверждены для всех
трёх ABI на указанном уровне; рекомендация и невыполненные проверки
зафиксированы. Spike завершён; обязательных проверок Linux 3.4/3.10 из
продуктового контракта не следует. Полный парк OS 5+ и остальные реальные
модели не объявляются испытанными. Runtime перенос, musl toolchain и
постоянный builder в scope не входят.

## ADR: кандидат toolchain (предложено, 13.09.2026)

**Контекст.** Сохраняются три Entware ABI на KeeneticOS 5+; stock GNU targets
отличаются по float ABI и системным требованиям. Production builder сейчас
только AArch64.

**Рекомендация.** Первым проверять patched Entware Rust 1.94.0 с отдельно
собранным `std` для каждого `*-openwrt-linux-gnu` и dynamic glibc 2.27.
Это рекомендованный путь после успешного spike; production-проверки
последующих задач должны соответствовать поддерживаемому парку OS 5+.
Static musl оставить альтернативой при доказанном недостатке GNU пути;
замораживание древнего Rust и отказ от MIPS не обоснованы результатами.

**Последствия.** Потребуется сопровождать compiler patches, dependency ABI и
kernel gates. Одного успешного AArch64 build недостаточно. Проверка памяти,
flash I/O, thread/atomic зависимостей и packaging остаётся в последующих
задачах; production-код пишется отдельно от этой пробы.

## Источники

Проверка самого изменения: локальные Markdown-ссылки существуют, документ
записан с LF, trailing whitespace отсутствует; Bash-блок прошёл `bash -n`.
Вложенный Rust-код скомпилирован и испытан в описанном Docker-эксперименте.
Проверено совпадение SHA исходника в рецепте с evidence, всех шести размеров
и ELF SHA с таблицей, exit 0 и ожидаемого IPC-ответа у всех шести запусков,
отсутствие dynamic dependencies у static ELF, Soft float у обоих MIPS ABI.
Прототипы остаются только воспроизводимым рецептом в этом отчёте: временные
бинарники и три проверенных собственных контейнера после сбора evidence
удалены, в runtime они не входят. Docker Desktop оставлен работающим.
`scripts/qa/static.sh` через Git Bash с `/mingw64/bin:/usr/bin:/bin` в PATH
прошёл package layout и secret scan, остановился на уже существующих CRLF
в tracked файлах checkout. Полный QA не объявляется успешным; посторонние
файлы не нормализовались. BATS не запускался: изменение только документальное.

Все онлайн-источники прочитаны 13.09.2026; ссылки Entware закреплены на lock.

- [E1 — host compiler и target std recipe](https://github.com/Entware/entware-rust/blob/379fa6ff578506a50e3158b92ac2c09bc22cb450/rustc-dev/Makefile).
- [E2 — native compiler recipe](https://github.com/Entware/entware-rust/blob/379fa6ff578506a50e3158b92ac2c09bc22cb450/rustc/Makefile).
- [E3 — Entware target definitions](https://github.com/Entware/entware-rust/blob/379fa6ff578506a50e3158b92ac2c09bc22cb450/rustc-dev/patches/010-add-new-targets.patch).
- [E4 — cross build flags](https://github.com/Entware/entware-rust/blob/379fa6ff578506a50e3158b92ac2c09bc22cb450/rustc-dev/rust.mk).
- [E5 — old-kernel getrandom patches](https://github.com/Entware/entware-rust/blob/379fa6ff578506a50e3158b92ac2c09bc22cb450/rustc/patches/100-fix-for-old-kernels.patch).
- [E6 — MIPS config](https://github.com/Entware/Entware/blob/2d92d7c0b4055cb27901025f8a08d2e6344e849e/configs/mips-3.4.config).
- [E7 — AArch64 config](https://github.com/Entware/Entware/blob/2d92d7c0b4055cb27901025f8a08d2e6344e849e/configs/aarch64-3.10.config).
- [R1 — upstream AArch64 requirements](https://doc.rust-lang.org/rustc/platform-support/aarch64-unknown-linux-gnu.html) (изменяемый документ, не обещание Entware).
- [R2 — MIPSel target Rust 1.94.0](https://github.com/rust-lang/rust/blob/1.94.0/compiler/rustc_target/src/spec/targets/mipsel_unknown_linux_gnu.rs).
