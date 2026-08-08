//! Every way this crate can fail, as a term the host can match on.
//!
//! In-VM there is no process boundary to absorb a fault: a panic here takes
//! the node, every camera and the recordings with it (D-M3 as amended). So
//! nothing on the per-frame path may panic, and this enum is the whole of what
//! replaces it — a stage failure is a value, returned to the calling Elixir
//! process to act on.
//!
//! On the wire each variant is `{reason, message}`, and rustler wraps a failed
//! NIF return in `{:error, _}`, so the host always sees
//! `{:error, {atom, binary}}`. The atom is the thing to dispatch on and the
//! binary is for the operator: the reasons are stable, the messages are not.
//!
//! **Two blast radii, and the reason atom is the only thing that separates
//! them.** `config`, `open_stream`, `decode`, `infer`, `closed` and `poisoned`
//! cost the stream they were raised on, so the host's answer is to close it and
//! open another. `model_load` and `model_poisoned` say the shared session is
//! unusable, so every stream on that engine will answer the same way for as
//! long as the engine lives: the host escalates — a fresh `init/1` behind its
//! canary, or an operator alert — rather than restart-looping one camera
//! against a model that cannot serve it.
//!
//! `panicked` belongs to whichever call raised it, but says nothing about what
//! that call was holding. The *next* call is what says which — and it cannot
//! read that off its own lock, because `push_au` nests stream -> model and a
//! panic in a pass poisons both. So the question is asked of the **model** lock
//! (`StreamRef::poisoned_by`): poisoned there means `model_poisoned` on every
//! stream including the one the panic happened on, and `poisoned` is left to
//! mean what it says — a panic in this camera's own state, which never took
//! the model lock at all.

use rustler::types::atom::Atom;
use rustler::{Encoder, Env, Term};

#[derive(Debug)]
pub enum NativeError {
    /// The init or stream config could not be resolved into what the stages
    /// take — a bad backend name, an out-of-range motion knob, a track floor a
    /// camera's `min_score` cannot honour.
    Config(String),
    /// The model, embedder or label set would not open. **Never an abort**:
    /// model load is the known crash vector (D-M3's risk row), and the point of
    /// returning it is that `Cairn.Native.Host`'s canary (task 2.3) gets to
    /// refuse a model before it reaches a running node.
    ModelLoad(String),
    /// A stream could not be opened: no decoder, or this camera already has one.
    OpenStream(String),
    /// The decoder rejected an access unit outright. Ordinary per-packet decode
    /// errors are *not* this — joining mid-GOP feeds the decoder frames whose
    /// references never arrived, which it resyncs from, exactly as in
    /// `cairn_detect::decode::run`.
    Decode(String),
    /// A model pass failed. Fatal to this stream and to nothing else: the
    /// plugin turns the same error into a process exit, and the in-VM
    /// equivalent of that blast radius is one closed stream.
    ///
    /// This one *can* be a model-wide fault wearing a stream's clothes — a
    /// wedged accelerator answers every stream this way — but telling that from
    /// one camera's bad frame takes the failure ratio across streams, which
    /// only the host sees. It is `Cairn.Native.Host`'s health check that
    /// escalates, and nothing here.
    Infer(String),
    /// `push_au` on a stream `close_stream` already emptied.
    Closed,
    /// A previous call panicked while holding *this stream's* lock and not the
    /// model's, so its decoder, gate and seeds may be half-updated. Refused
    /// rather than resumed, and costs no other stream: the state behind the
    /// lock is one camera's.
    Poisoned,
    /// A previous call panicked inside a model pass, so the shared session's
    /// state is unknown — and it is shared, so this is every stream on the
    /// engine, permanently. Distinct from [`Self::Poisoned`] because the two
    /// call for opposite things: reopen one stream, versus stop trusting this
    /// engine.
    ///
    /// Answered to the stream the panic happened on as well, whose own lock is
    /// poisoned too and says the smaller of the two things. See the module doc.
    ModelPoisoned,
    /// A panic caught at the NIF boundary. Reaching the host at all is the
    /// guarantee — the alternative is `abort()` and a dead node.
    Panicked(String),
}

impl NativeError {
    /// The atom the host dispatches on. `&'static str` rather than a
    /// `rustler::atoms!` table because that table is built by calling into the
    /// BEAM, which puts it out of reach of every test in this crate — and the
    /// one thing worth testing about an error is exactly this mapping.
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
        // `enif_make_atom` on a fixed set of short literals: a hash
        // lookup, on a path that runs once per *failure*. The fallback exists
        // so this cannot panic — `from_str` refuses only strings over 255
        // bytes, which no `reason` is, and a binary reason is a worse term but
        // a better outcome than taking the node down to report an error.
        let reason = match Atom::from_str(env, self.reason()) {
            Ok(atom) => atom.encode(env),
            Err(_) => self.reason().encode(env),
        };
        (reason, self.message()).encode(env)
    }
}

pub type Result<T> = std::result::Result<T, NativeError>;

/// `{:#}` on an [`anyhow::Error`] — the whole context chain, which is where
/// every stage in `cairn-detect` puts the part naming what it was doing.
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

    /// The partition the module doc states, as an exhaustive match: a variant
    /// added without deciding which side it falls on stops compiling here.
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

    /// The two the host must never confuse: one says reopen this camera, the
    /// other says this engine cannot serve any camera again.
    #[test]
    fn the_two_poisonings_are_different_reasons_on_different_sides() {
        assert_ne!(
            NativeError::Poisoned.reason(),
            NativeError::ModelPoisoned.reason()
        );
        assert_eq!(blast(&NativeError::Poisoned), Blast::Stream);
        assert_eq!(blast(&NativeError::ModelPoisoned), Blast::Model);
    }

    /// The reasons the host escalates on, spelled out: this list is the whole
    /// of `Cairn.Native.Host`'s escalate-rather-than-retry branch.
    #[test]
    fn only_the_model_reasons_are_engine_wide() {
        let engine_wide: Vec<&str> = one_of_each()
            .iter()
            .filter(|error| blast(error) == Blast::Model)
            .map(NativeError::reason)
            .collect();
        assert_eq!(engine_wide, vec!["model_load", "model_poisoned"]);
    }

    /// The reason is the dispatch key, so a shared one would make two
    /// different faults indistinguishable to `Cairn.Native.Host`.
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

    /// Atom-safe: `Atom::from_str` refuses a name over 255 bytes, and the
    /// fallback that covers it should never be the path an error takes.
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
