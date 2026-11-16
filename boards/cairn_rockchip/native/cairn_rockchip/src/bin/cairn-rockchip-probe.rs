//! The board's canary and parity vehicle: `cairn-detect`'s CLI with this
//! board's backends registered. None is registered, so it refuses
//! `--backend rknn` exactly as `cairn-detect` does.

fn main() -> std::process::ExitCode {
    cairn_detect::cli::run(&[])
}
