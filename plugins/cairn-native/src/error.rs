//! Every way this crate can fail, as a term the host can match on: the host sees
//! `{:error, {reason, message}}`, where the reason atoms are stable and are the
//! dispatch key and the messages are for the operator.
//!
//! Two blast radii, separated by the reason alone. `config`, `open_stream`,
//! `decode`, `infer`, `closed`, `poisoned` and `panicked` cost the stream they
//! were raised on, so the host closes it and opens another. `model_load` and
//! `model_poisoned` say the shared session is unusable for as long as the engine
//! lives, so the host escalates — a fresh `init/1` behind its canary, or an
//! operator alert — rather than restart-looping one camera against a model that
//! cannot serve it.

use rustler::types::atom::Atom;
use rustler::{Encoder, Env, Term};

#[derive(Debug)]
pub enum NativeError {
    /// Config that would not resolve into what the stages take.
    Config(String),
    /// The model, embedder or label set would not open. Never an abort: model
    /// load is the known crash vector (D-M3's risk row), and returning it is what
    /// lets `Cairn.Native.Host`'s canary refuse a model before it reaches a
    /// running node.
    ModelLoad(String),
    /// A stream could not be opened: no decoder, or this camera already has one.
    OpenStream(String),
    /// The decoder rejected an access unit outright, which the tolerated
    /// per-packet errors are not — see [`crate::stream`].
    Decode(String),
    /// A model pass failed. It *can* be a model-wide fault wearing a stream's
    /// clothes — a wedged accelerator answers every stream this way — but telling
    /// that from one camera's bad frame takes the failure ratio across streams,
    /// which only the host sees.
    Infer(String),
    /// `push_au` on a stream `close_stream` already emptied.
    Closed,
    /// A previous call panicked holding *this stream's* lock and not the
    /// model's, so its decoder, gate and seeds may be half-updated.
    Poisoned,
    /// A previous call panicked inside a model pass, so the shared session is
    /// unusable for every stream on the engine, permanently. The two poisonings
    /// call for opposite host actions — reopen one stream, versus stop trusting
    /// this engine — and only the model lock tells them apart, since `push_au`
    /// nests stream -> model and a pass that panics poisons both. So a poisoned
    /// model outranks a poisoned stream on every stream *including the one the
    /// panic happened on*, which is the case a stream reading only its own lock
    /// gets backwards ([`crate::StreamRef::poisoned_by`]).
    ModelPoisoned,
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
            Self::ModelLoad(_) => "model_load",
            Self::OpenStream(_) => "open_stream",
            Self::Decode(_) => "decode",
            Self::Infer(_) => "infer",
            Self::Closed => "closed",
            Self::Poisoned => "poisoned",
            Self::ModelPoisoned => "model_poisoned",
            Self::Panicked(_) => "panicked",
        }
    }

    /// For the operator, not for dispatch.
    pub fn message(&self) -> &str {
        match self {
            Self::Config(message)
            | Self::ModelLoad(message)
            | Self::OpenStream(message)
            | Self::Decode(message)
            | Self::Infer(message)
            | Self::Panicked(message) => message,
            Self::Closed => "the stream is closed",
            Self::Poisoned => "a previous call panicked while holding this stream's state",
            Self::ModelPoisoned => {
                "a previous call panicked inside a model pass; this engine's session is unusable"
            }
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
            NativeError::ModelLoad("m".into()),
            NativeError::OpenStream("o".into()),
            NativeError::Decode("d".into()),
            NativeError::Infer("i".into()),
            NativeError::Closed,
            NativeError::Poisoned,
            NativeError::ModelPoisoned,
            NativeError::Panicked("p".into()),
        ]
    }

    #[derive(Debug, PartialEq)]
    enum Blast {
        Stream,
        Model,
    }

    /// The module doc's partition as an exhaustive match: a variant added
    /// without deciding which side it falls on stops compiling here.
    fn blast(error: &NativeError) -> Blast {
        match error {
            NativeError::Config(_)
            | NativeError::OpenStream(_)
            | NativeError::Decode(_)
            | NativeError::Infer(_)
            | NativeError::Closed
            | NativeError::Poisoned
            | NativeError::Panicked(_) => Blast::Stream,
            NativeError::ModelLoad(_) | NativeError::ModelPoisoned => Blast::Model,
        }
    }

    #[test]
    fn the_two_poisonings_are_different_reasons_on_different_sides() {
        assert_ne!(
            NativeError::Poisoned.reason(),
            NativeError::ModelPoisoned.reason()
        );
        assert_eq!(blast(&NativeError::Poisoned), Blast::Stream);
        assert_eq!(blast(&NativeError::ModelPoisoned), Blast::Model);
    }

    /// `Cairn.Native.Host`'s escalate-rather-than-retry branch, in full.
    #[test]
    fn only_the_model_reasons_are_engine_wide() {
        let engine_wide: Vec<&str> = one_of_each()
            .iter()
            .filter(|error| blast(error) == Blast::Model)
            .map(NativeError::reason)
            .collect();
        assert_eq!(engine_wide, vec!["model_load", "model_poisoned"]);
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
