//! Every way this crate can fail, as a term the host can match on: the host sees
//! `{:error, {reason, message}}`, where the reason atoms are stable and are the
//! dispatch key and the messages are for the operator.
//!
//! One blast radius on this side: every reason costs the decoder it was
//! raised on, and the caller's remedy is reopening. The engine-wide reasons
//! (`model_load`, `model_poisoned`, `infer`) belong to the inference library
//! (`cairn-ort`), which owns the shared session — a decode stream never
//! touches a model.

use rustler::types::atom::Atom;
use rustler::{Encoder, Env, Term};

#[derive(Debug)]
pub enum NativeError {
    /// Config that would not resolve into what the stages take.
    Config(String),
    /// A stream could not be opened: no decoder, or this camera already has one.
    OpenStream(String),
    /// The decoder rejected an access unit outright, which the tolerated
    /// per-packet errors are not — see [`crate::stream`].
    Decode(String),
    /// `decode_au` on a decoder `close_decoder` already emptied.
    Closed,
    /// A previous call panicked holding this decoder's lock, so its decoder
    /// and motion state may be half-updated.
    Poisoned,
    /// A panic caught at the NIF boundary ([`crate::guarded`]).
    Panicked(String),
}

impl NativeError {
    /// The atom the host dispatches on. `&'static str` rather than a
    /// `rustler::atoms!` table, which is built by calling into the BEAM and would
    /// put this mapping out of reach of every test in this crate.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::Config(_) => "config",
            Self::OpenStream(_) => "open_stream",
            Self::Decode(_) => "decode",
            Self::Closed => "closed",
            Self::Poisoned => "poisoned",
            Self::Panicked(_) => "panicked",
        }
    }

    /// For the operator, not for dispatch.
    pub fn message(&self) -> &str {
        match self {
            Self::Config(message)
            | Self::OpenStream(message)
            | Self::Decode(message)
            | Self::Panicked(message) => message,
            Self::Closed => "the decoder is closed",
            Self::Poisoned => "a previous call panicked while holding this decoder's state",
        }
    }
}

impl Encoder for NativeError {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        // `from_str` refuses only names over 255 bytes, which no `reason` is; the
        // fallback is here so that reporting an error cannot itself panic.
        let reason = match Atom::from_str(env, self.reason()) {
            Ok(atom) => atom.encode(env),
            Err(_) => self.reason().encode(env),
        };
        (reason, self.message()).encode(env)
    }
}

pub type Result<T> = std::result::Result<T, NativeError>;

/// The whole `anyhow` context chain, which is where every stage in
/// `cairn-detect` puts the part naming what it was doing.
pub fn chain(error: &anyhow::Error) -> String {
    format!("{error:#}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn one_of_each() -> Vec<NativeError> {
        vec![
            NativeError::Config("c".into()),
            NativeError::OpenStream("o".into()),
            NativeError::Decode("d".into()),
            NativeError::Closed,
            NativeError::Poisoned,
            NativeError::Panicked("p".into()),
        ]
    }

    #[test]
    fn every_variant_has_its_own_reason() {
        let all = one_of_each();
        let mut reasons: Vec<&str> = all.iter().map(NativeError::reason).collect();
        reasons.sort_unstable();
        reasons.dedup();
        assert_eq!(reasons.len(), all.len());
    }

    #[test]
    fn every_variant_carries_an_operator_message() {
        for error in one_of_each() {
            assert!(!error.message().is_empty(), "{error:?}");
        }
    }

    /// `Encoder`'s over-255-byte fallback should never be the path an error takes.
    #[test]
    fn every_reason_is_a_legal_atom_name() {
        for error in one_of_each() {
            let reason = error.reason();
            assert!(reason.len() <= 255, "{reason}");
            assert!(
                reason.bytes().all(|b| b.is_ascii_lowercase() || b == b'_'),
                "{reason}"
            );
        }
    }

    #[test]
    fn an_anyhow_chain_keeps_every_context_layer() {
        let error = anyhow::anyhow!("no video stream").context("opening a decoder");
        let message = chain(&error);
        assert!(message.contains("opening a decoder"), "{message}");
        assert!(message.contains("no video stream"), "{message}");
    }
}
