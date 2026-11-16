//! The board's canary and parity vehicle: `cairn-detect`'s CLI with this
//! board's backends registered, so `--backend rknn` opens the artifact on the
//! NPU through [`cairn_rockchip::rknn`].

fn main() -> std::process::ExitCode {
    cairn_detect::cli::run(&[cairn_rockchip::rknn::provider()])
}
