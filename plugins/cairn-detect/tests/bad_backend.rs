//! A `--backend` the build does not carry is this crate's refusal, not
//! clap's: `fatal:` on stderr and exit 1, before the hello line — and before
//! `--cpu-baseline`, which ignores the backend but not a broken argv.

use std::process::Command;

fn refused(extra: &[&str]) {
    let out = Command::new(env!("CARGO_BIN_EXE_cairn-detect"))
        .args(["--model", "does/not/exist.onnx", "--backend", "tensorrt"])
        .args(extra)
        .output()
        .expect("running cairn-detect");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{extra:?}: {stderr}");
    assert!(
        stderr.contains(
            r#"fatal: --backend: backend "tensorrt" is not one this build carries (ort, qnn)"#
        ),
        "{extra:?}: {stderr}"
    );
    assert!(
        out.stdout.is_empty(),
        "{extra:?}: {}",
        String::from_utf8_lossy(&out.stdout)
    );
}

#[test]
fn an_unknown_backend_is_fatal_before_the_hello() {
    refused(&["--camera-id", "front", "--udp-port", "17000"]);
}

#[test]
fn an_unknown_backend_is_fatal_under_cpu_baseline_too() {
    refused(&["--cpu-baseline", "5"]);
}
