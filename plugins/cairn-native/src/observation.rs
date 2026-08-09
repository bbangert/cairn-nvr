//! What one sampled frame becomes on the way out: `Cairn.Observation`'s `objects`,
//! as terms.
//!
//! Built by hand rather than derived because `embedding` is present *only when
//! there is one*: `nil` and absent are different things to
//! `Cairn.PluginProtocol.validate_object`, and a derived map would spell an
//! embedder-less object with an `embedding: nil` key the ndjson path never
//! produced.

use cairn_detect::emit::{Det, ObservationKind};
use rustler::{Encoder, Env, Term};

// Built once, at NIF load: five keys per detection per frame, which is the one
// place in this crate where a cached atom beats `enif_make_atom`.
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

#[derive(Debug)]
pub struct FrameObservations {
    /// The contract's `pts`, from `cairn_detect::decode::pts_90k` — the same
    /// function the plugin dates its lines with.
    pub pts: i64,
    /// The contract's `observed_at`, as milliseconds rather than RFC3339: there is
    /// no JSON here to force a string.
    pub observed_at_ms: i64,
    /// Whether the model ran, or the gate skipped this frame and these objects are
    /// the last real pass re-reported. Not derivable from the objects: a gated
    /// frame with nothing remembered and an inferred frame that found nothing are
    /// both an empty list, and they differ to anything counting passes.
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
        // Always `nil`: `Cairn.Tracker` assigns every identity itself. Present so
        // the object shape is the struct's whole shape.
        (track_id(), rustler::types::atom::nil().encode(env)),
        (
            observation_kind(),
            kind_name(det.observation_kind).encode(env),
        ),
    ];
    if let Some(encoded) = det.embedding.as_deref() {
        // The stages carry the feature base64'd because an ndjson line has nowhere
        // else to put bytes; a term does, and the host's `embedding` is raw int8.
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
    // The keys are distinct literals, so the fallback is unreachable — and losing
    // one frame beats taking the node down.
    Term::map_from_term_arrays(env, &keys, &values).unwrap_or_else(|_| Term::map_new(env))
}

fn make_binary<'a>(env: Env<'a>, bytes: &[u8]) -> Term<'a> {
    let mut binary = rustler::NewBinary::new(env, bytes.len());
    binary.as_mut_slice().copy_from_slice(bytes);
    Term::from(binary)
}

/// Standard-alphabet base64 with padding, the inverse of `cairn_detect::infer`'s
/// hand-rolled encoder. `None` costs the object its embedding and nothing else: a
/// malformed feature is not a reason to lose the box it belongs to.
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
                // Padding anywhere but the end of the quad is a hole in the
                // middle of the feature.
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
    /// against — so both halves are checked against the standard rather than
    /// against each other.
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

    /// The RFC vectors above exercise five letters; a feature sweeping the int8
    /// range exercises every symbol, which is where a hand-rolled table goes wrong.
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
