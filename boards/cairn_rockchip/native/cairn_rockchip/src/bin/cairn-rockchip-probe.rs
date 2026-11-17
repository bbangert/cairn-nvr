//! The board's canary and parity vehicle: `cairn-detect`'s CLI with this
//! board's backends registered, so `--backend rknn` opens the artifact on the
//! NPU through [`cairn_rockchip::rknn`]; `--rk-probe` runs the MPP decode
//! probe ([`cairn_rockchip::probe`]) instead.

fn main() -> std::process::ExitCode {
    let args: Vec<String> = std::env::args_os()
        .skip(1)
        .map(|arg| arg.to_string_lossy().into_owned())
        .collect();
    if args.iter().any(|arg| arg == "--rk-probe") {
        return cairn_rockchip::probe::run(&args);
    }
    cairn_detect::cli::run(&[cairn_rockchip::rknn::provider()])
}
