//! Diagnostics that cannot take the host down.
//!
//! `eprintln!` panics if the write fails, and in production stderr is a pipe or
//! a redirect — `run_erl`, a journal socket, `> log 2>&1` — whose reader can go
//! away under a log rotation or a detached console. The BEAM ignores `SIGPIPE`,
//! so that write returns `EPIPE` and the macro panics.
//!
//! In the plugin that cost one child process. In `cairn-native` the stages run
//! in the BEAM, and the per-frame ones run **under the shared model lock**, so
//! the same panic poisons a session that is deliberately never recovered — one
//! log rotation would end detection on every camera until the node restarts.
//!
//! So a failed diagnostic is dropped rather than raised. Every logging site
//! that can run per frame, or under a lock, goes through [`crate::note!`].

use std::io::Write;

/// Write one line to stderr, discarding a failed write. Use [`crate::note!`].
///
/// Locked once for the pair so a line and its newline cannot be split by a
/// concurrent writer — two cameras log from two threads.
pub fn line(args: std::fmt::Arguments<'_>) {
    let mut stderr = std::io::stderr().lock();
    let _ = stderr.write_fmt(args);
    let _ = stderr.write_all(b"\n");
}

/// `eprintln!` that cannot panic on a broken stderr.
///
/// Same arguments, same output; the only difference is what a failed write
/// does, and see this module for why that difference is load-bearing.
#[macro_export]
macro_rules! note {
    ($($arg:tt)*) => {
        $crate::log::line(format_args!($($arg)*))
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The contract is only that the arguments are formatted and nothing
    /// panics; where they land is stderr's business and the test harness's.
    #[test]
    fn a_note_formats_its_arguments_and_returns() {
        line(format_args!("{} {:?} {:.2}", 1, "two", 3.0));
        note!("plain");
        note!("camera {}: {} error", "front", "decode");
    }
}
