//! The core build of the plugin: the backends this crate carries and nothing
//! else. A board crate's binary is this file with its own providers.

fn main() -> std::process::ExitCode {
    cairn_detect::cli::run(&[])
}
