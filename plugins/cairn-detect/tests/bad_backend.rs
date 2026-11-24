//! A `--backend` the build does not carry is this crate's refusal, not
//! clap's: `fatal:` on stderr and exit 1, before the hello line.

use std::process::Command;

#[test]
fn an_unknown_backend_is_fatal_before_the_hello() {
    let out = Command::new(env!("CARGO_BIN_EXE_cairn-detect"))
        .args(["--camera-id", "front", "--udp-port", "17000"])
        .args(["--model", "does/not/exist.onnx", "--backend", "tensorrt"])
        .output()
        .expect("running cairn-detect");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(1), "{stderr}");
    assert!(
        stderr.contains(
            r#"fatal: --backend: backend "tensorrt" is not one this build carries (ort, qnn)"#
        ),
        "{stderr}"
    );
    assert!(
        out.stdout.is_empty(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
}
