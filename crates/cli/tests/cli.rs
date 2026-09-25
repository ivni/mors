use std::process::Command;

fn run(args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_mors-core"))
        .args(args)
        .output()
        .expect("run host scaffold")
}

#[test]
fn safe_help_and_version() {
    for args in [vec![], vec!["--help"], vec!["-h"]] {
        let output = run(&args);
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        assert!(String::from_utf8(output.stdout)
            .unwrap()
            .contains("Управление подключениями пока недоступно"));
    }
    for arg in ["--version", "-V"] {
        let output = run(&[arg]);
        assert!(output.status.success());
        assert!(output.stderr.is_empty());
        assert_eq!(
            String::from_utf8(output.stdout).unwrap(),
            format!("mors-core {}\n", env!("CARGO_PKG_VERSION"))
        );
    }
}

#[test]
fn mutations_and_extra_arguments_are_rejected_without_echoing_input() {
    for args in [
        vec!["setup"],
        vec!["daemon"],
        vec!["--version", "--help"],
        vec!["--help", "private-input"],
        vec!["private-input"],
    ] {
        let output = run(&args);
        assert_eq!(output.status.code(), Some(2));
        assert!(output.stdout.is_empty());
        assert!(!String::from_utf8(output.stderr)
            .unwrap()
            .contains("private-input"));
    }
}

#[cfg(unix)]
#[test]
fn non_utf8_argument_is_rejected_without_panicking() {
    use std::os::unix::ffi::OsStrExt;
    let output = Command::new(env!("CARGO_BIN_EXE_mors-core"))
        .arg(std::ffi::OsStr::from_bytes(&[0xff]))
        .output()
        .unwrap();
    assert_eq!(output.status.code(), Some(2));
    assert!(output.stdout.is_empty());
}
