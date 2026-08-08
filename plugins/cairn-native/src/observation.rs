//! What one sampled frame becomes on the way out: interface #1's shape, as
//! terms.
//!
//! The target is `Cairn.Observation`'s `objects` — `label`, `score`, `bbox`,
//! `track_id`, `observation_kind`, and `embedding` *only when there is one*.
//! That last one is why these are built by hand rather than derived: `nil` and
//! absent are different things there (`Cairn.PluginProtocol.validate_object`),
//! and a derived map would spell an embedder-less object with an
//! `embedding: nil` key that the ndjson path never produced.
//!
//! `observation_kind` is a binary and not an atom for the same reason: the
//! struct holds a `String.t()`, so an atom would only buy task 2.4 an
//! `Atom.to_string/1` per object.
//!
//! Nothing here is the struct itself. Building `Cairn.Observation` — the
//! per-line envelope, `media_ms`, the `ObservationClock` anchoring — is task
//! 2.4's, host-side, where it already is.

use cairn_detect::emit::{Det, ObservationKind};
use rustler::{Encoder, Env, Term};

// Built once, at NIF load. Unlike the error reasons — which are cold and use
// `Atom::from_str` so the mapping stays testable — these are five keys per
// detection per frame, which is the one place in this crate where the
// difference between a cached atom and `enif_make_atom` is worth having.
rustler::atoms! {
    pts,
    observed_at_ms,
    inferred,
    objects,
    label,
    score,
    bbox,
    track_id,
    observation_kind,
    embedding,
}

/// One frame's worth of output.
#[derive(Debug)]
pub struct FrameObservations {
    /// The contract's `pts`, on the 90 kHz clock — derived by
    /// `cairn_detect::decode::pts_90k`, the same function the plugin dates its
    /// lines with.
    pub pts: i64,
    /// Wall clock at the moment this frame cleared the sample gate: the
    /// contract's `observed_at`, in milliseconds since the Unix epoch. Sent as
    /// an integer rather than an RFC3339 string because there is no JSON here
    /// to force a string, and `DateTime.from_unix!/2` is one call.
    pub observed_at_ms: i64,
    /// Whether the model ran on this frame, or the motion gate skipped it and
    /// these objects are the last real pass's, re-reported.
    ///
    /// Derivable from the objects' `observation_kind`, but only when there are
    /// any: a gated frame with nothing remembered and an inferred frame that
    /// found nothing are both an empty list, and they mean different things to
    /// anything counting model passes.
    pub inferred: bool,
    pub objects: Vec<Det>,
}

impl Encoder for FrameObservations {
    fn encode<'a>(&self, env: Env<'a>) -> Term<'a> {
        let encoded: Vec<Term<'a>> = self.objects.iter().map(|det| object(env, det)).collect();
        map(
            env,
            &[
                (pts(), self.pts.encode(env)),
                (observed_at_ms(), self.observed_at_ms.encode(env)),
                (inferred(), self.inferred.encode(env)),
                (objects(), encoded.encode(env)),
            ],
        )
    }
}

fn object<'a>(env: Env<'a>, det: &Det) -> Term<'a> {
    let mut pairs = vec![
        (label(), det.label.encode(env)),
        (score(), det.score.encode(env)),
        (bbox(), det.bbox.as_slice().encode(env)),
        // Reserved on the host side too: `Cairn.Tracker` assigns every
        // identity itself. Present so the object shape is the struct's whole
        // shape and 2.4 has nothing to fill in.
        (track_id(), rustler::types::atom::nil().encode(env)),
        (
            observation_kind(),
            kind_name(det.observation_kind).encode(env),
        ),
    ];
    if let Some(encoded) = det.embedding.as_deref() {
        // The stages carry the feature base64'd because the ndjson line has
        // nowhere else to put bytes; a term does, and the host's `embedding` is
        // raw int8 bytes. Decoded here rather than left for 2.4 so the two
        // spellings never both exist under the same key.
        if let Some(bytes) = decode_base64(encoded) {
            pairs.push((embedding(), make_binary(env, &bytes)));
        }
    }
    map(env, &pairs)
}

/// The host's own vocabulary (`Cairn.PluginProtocol`), which is also the wire's.
fn kind_name(kind: ObservationKind) -> &'static str {
    match kind {
        ObservationKind::Detected => "detected",
        ObservationKind::Tracked => "tracked",
    }
}

fn map<'a>(env: Env<'a>, pairs: &[(rustler::Atom, Term<'a>)]) -> Term<'a> {
    let keys: Vec<Term<'a>> = pairs.iter().map(|(key, _)| key.encode(env)).collect();
    let values: Vec<Term<'a>> = pairs.iter().map(|(_, value)| *value).collect();
    // The keys are distinct literals, so the only way this fails is a rustler
    // contract change; an empty map loses one frame rather than the node.
    Term::map_from_term_arrays(env, &keys, &values).unwrap_or_else(|_| Term::map_new(env))
}

fn make_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = rustler::NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Term::from(binary)
}

/// Standard-alphabet base64 with padding, the inverse of
/// `cairn_detect::infer`'s hand-rolled encoder.
///
/// `None` for anything that is not that, which costs the object its embedding
/// and nothing else — a malformed feature is not a reason to lose the box it
/// belongs to, still less the frame.
fn decode_base64(text: &str) -> Option<Vec<u8>> {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes = text.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for quad in bytes.chunks_exact(4) {
        let padding = quad.iter().rev().take_while(|byte| **byte == b'=').count();
        if padding > 2 {
            return None;
        }
        let mut packed: u32 = 0;
        for (index, byte) in quad.iter().enumerate() {
            let six = if *byte == b'=' {
                // Padding is only legal at the end of the last quad; anywhere
                // else it is a hole in the middle of the feature.
                if index < 4 - padding {
                    return None;
                }
                0
            } else {
                ALPHABET.iter().position(|c| c == byte)? as u32
            };
            packed = (packed << 6) | six;
        }
        for shift in [16, 8, 0].into_iter().take(3 - padding) {
            out.push(((packed >> shift) & 0xff) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// RFC 4648's own vectors, the same ones `cairn-detect` pins its encoder
    /// against — so the two halves are checked against the standard rather
    /// than against each other.
    #[test]
    fn decodes_the_rfc_vectors() {
        for (encoded, decoded) in [
            ("", &b""[..]),
            ("Zg==", b"f"),
            ("Zm8=", b"fo"),
            ("Zm9v", b"foo"),
            ("Zm9vYg==", b"foob"),
            ("Zm9vYmE=", b"fooba"),
            ("Zm9vYmFy", b"foobar"),
        ] {
            assert_eq!(
                decode_base64(encoded).as_deref(),
                Some(decoded),
                "{encoded}"
            );
        }
    }

    /// The two spellings of one feature, checked against each other end to
    /// end. The RFC vectors above exercise five letters; a feature sweeping
    /// the whole int8 range exercises every symbol in the alphabet, which is
    /// where a hand-rolled table goes wrong.
    #[test]
    fn round_trips_the_embedders_own_output() {
        let feature: Vec<f32> = (-127..=127).map(|i| i as f32 / 127.0).collect();
        let expected: Vec<u8> = (-127..=127i32).map(|i| i as i8 as u8).collect();

        let encoded = cairn_detect::infer::quantize_base64(&feature);
        assert_eq!(
            decode_base64(&encoded).as_deref(),
            Some(expected.as_slice())
        );
    }

    #[test]
    fn refuses_what_is_not_base64() {
        for bad in ["Zg=", "Zm9vY", "Zm9*", "Z===", "=Zm8", "Z=m8"] {
            assert!(decode_base64(bad).is_none(), "{bad}");
        }
    }

    #[test]
    fn the_kind_names_are_the_hosts() {
        assert_eq!(kind_name(ObservationKind::Detected), "detected");
        assert_eq!(kind_name(ObservationKind::Tracked), "tracked");
    }
}
