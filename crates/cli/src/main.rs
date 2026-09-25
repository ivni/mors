use std::process::ExitCode;

const HELP: &str = "mors-core — каркас управляющего ядра Mors\n\nИспользование: mors-core [--help | --version]\n\n  -h, --help       Показать справку\n  -V, --version    Показать версию каркаса\n\nУправление подключениями пока недоступно.";

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let first = args.next();
    if args.next().is_some() {
        eprintln!("Ошибка: ожидается только --help или --version.");
        return ExitCode::from(2);
    }
    match first.as_deref().and_then(|arg| arg.to_str()) {
        None if first.is_none() => println!("{HELP}"),
        Some("--help" | "-h") => println!("{HELP}"),
        Some("--version" | "-V") => println!("mors-core {}", env!("CARGO_PKG_VERSION")),
        _ => {
            eprintln!("Ошибка: неизвестный аргумент. Используйте mors-core --help.");
            return ExitCode::from(2);
        }
    }
    ExitCode::SUCCESS
}
