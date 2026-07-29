//! Settling which profile a model runs under, and at what input size.
//!
//! Sniffing is deliberately strict: a shape that fits *two* built-in profiles
//! is an error naming both, never a silent pick — the two are decoded
//! completely differently and the wrong one emits plausible garbage rather
//! than failing.

use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use ort::value::ValueType;

use super::catalog::{names, PROFILES};
use super::geometry::{InputSize, MAX_INPUT_DIM, MAX_INPUT_PIXELS};
use super::profile::{
    grid_anchors, show, InputSizeSource, Layout, ModelProfile, OutputSpec, Outputs, Roles, Shapes,
};

/// A grid head only decodes at a size its strides divide.
///
/// [`grid_anchors`] floor-divides, and so does the walk in
/// `heads::grid_objectness`. At a size the coarsest stride does not divide,
/// both
/// agree with each other and neither agrees with the model: a real head lays
/// its cells out by the ceiling its own downsampling produced. The total-count
/// check in [`validate_layout`] catches that whenever the two totals differ,
/// but they can coincide — and when they do every box lands in the wrong cell,
/// which is wrong coordinates with nothing on stderr. So the size is rejected
/// at startup instead, where the operator who typed it is still watching.
pub(super) fn check_grid_divides_input(layout: Layout, size: InputSize) -> Result<()> {
    let Layout::GridObjectness { strides, .. } = layout else {
        return Ok(());
    };
    let Some(&coarsest) = strides.iter().max() else {
        return Ok(());
    };
    if !size.w.is_multiple_of(coarsest) || !size.h.is_multiple_of(coarsest) {
        bail!(
            "input size {size} is not a multiple of {coarsest}, the coarsest stride of a \
             grid-objectness head — its cells would be walked in a layout the model does not \
             use, putting every box in the wrong cell. Round each axis to a multiple of \
             {coarsest}."
        );
    }
    Ok(())
}

/// One of the model's outputs, as its own metadata declares it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Declared {
    pub name: String,
    /// Dims when the export pins the ones that identify a layout, `None`
    /// otherwise. See [`static_output_dims`].
    pub dims: Option<Vec<i64>>,
}

/// The model's outputs, for an error that has to say what it actually found.
fn describe_outputs(declared: &[Declared]) -> String {
    if declared.is_empty() {
        return "no outputs".to_string();
    }
    declared
        .iter()
        .map(|output| match &output.dims {
            Some(dims) => format!("{:?} {dims:?}", output.name),
            None => format!("{:?} (dynamic)", output.name),
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Output dims when the export pins the ones that matter, `None` when it does
/// not.
///
/// A symbolic *batch* axis is not a dynamic layout. This plugin feeds exactly
/// one frame per run, so axis 0 is 1 whatever the export left there, and
/// refusing to read the rest would leave every RF-DETR export — which pins
/// `[?, 300, 4]` and `[?, 300, 91]` and nothing else — unsniffable for a
/// reason that says nothing about how it decodes. Every *other* axis carries
/// a count a layout is identified by, and a symbolic one there really does
/// leave nothing to go on.
pub(super) fn static_output_dims(dtype: &ValueType) -> Option<Vec<i64>> {
    let ValueType::Tensor { shape, .. } = dtype else {
        return None;
    };
    let mut dims = shape.to_vec();
    let (batch, rest) = dims.split_first_mut()?;
    if !rest.iter().all(|d| *d > 0) {
        return None;
    }
    if *batch < 0 {
        *batch = 1;
    }
    Some(dims)
}

/// Bind a layout's roles to this model's actual outputs.
///
/// [`Outputs::One`] takes the model's first output, exactly as every
/// single-output family always has: an export with auxiliary outputs stays
/// readable rather than becoming newly fatal.
///
/// [`Outputs::BoxesAndLogits`] reads the roles off the *shapes* rather than
/// the names, because the two RF-DETR export toolchains disagree about names
/// and agree about shapes — Roboflow's own `export()` emits `dets`/`labels`,
/// the transformers/onnx-community conversion emits `pred_boxes`/`logits`, and
/// a name table would reject whichever it did not list. The rank-3 output
/// whose last axis is 4 is the boxes; the rank-3 output over the same query
/// axis is the logits. Two candidates for a role (a genuinely 4-class DETR
/// would do it) or none is an error naming what the model offers, never a
/// guess at which is which.
///
/// An export that pins *no* shape at all — `optimum`'s `dynamic_axes` will
/// happily leave the query axis symbolic, giving `[?, ?, 4]` / `[?, ?, 91]` —
/// leaves the shape rule nothing to read, and falls back to
/// [`bind_detr_by_name`]. See its comment for why that is safe here and not a
/// general licence to bind by name.
fn bind(roles: Roles, declared: &[Declared]) -> Result<Outputs<Declared>> {
    match roles {
        Outputs::One(()) => declared
            .first()
            .cloned()
            .map(Outputs::One)
            .ok_or_else(|| anyhow!("model has no outputs")),
        Outputs::BoxesAndLogits { .. } => {
            let (mut boxes, mut logits) = (None, None);
            let mut clash = false;
            for output in declared {
                let Some(dims) = output.dims.as_deref() else {
                    continue;
                };
                if dims.len() != 3 || dims[0] != 1 || dims[1] < 1 || dims[2] < 1 {
                    continue;
                }
                let slot = if dims[2] == 4 {
                    &mut boxes
                } else {
                    &mut logits
                };
                clash |= slot.is_some();
                *slot = Some(output.clone());
            }
            let paired = match (boxes, logits) {
                (Some(boxes), Some(logits)) if !clash => {
                    let queries = |output: &Declared| output.dims.as_ref().map(|d| d[1]);
                    (queries(&boxes) == queries(&logits))
                        .then_some(Outputs::BoxesAndLogits { boxes, logits })
                }
                _ => None,
            };
            // Only when the export pins nothing: a model that declares shapes
            // and does not fit is a mismatch to report, not a name to guess at.
            let unshaped = declared.iter().all(|output| output.dims.is_none());
            paired
                .or_else(|| unshaped.then(|| bind_detr_by_name(declared)).flatten())
                .ok_or_else(|| {
                    anyhow!(
                        "expected one [1, Q, 4] box output and one [1, Q, nc] logit output over \
                         the same Q queries, but the model offers {}{}",
                        describe_outputs(declared),
                        // The shape rule had nothing to read, so say what the
                        // fallback wanted rather than repeating shapes.
                        if unshaped {
                            "; with no shape to read the roles from, the names have to say which \
                             is which (pred_boxes/logits or dets/labels)"
                        } else {
                            ""
                        }
                    )
                })
        }
    }
}

/// Bind a DETR pair by name, for an export that pins neither shape.
///
/// This is the fallback the shape rule refuses to be: names are a weaker
/// signal, and the two RF-DETR exporters disagree about them, which is exactly
/// why `bind` reads shapes first. It is safe as a *last* resort because the
/// binding is not trusted — [`super::heads::decode_output`] re-runs
/// [`validate_layout`]
/// against the real runtime dims on every frame, so a pair bound the wrong way
/// round fails loudly on the first output (the boxes tensor would not have a
/// last axis of 4) instead of decoding garbage. Without it, an export whose
/// query axis is symbolic cannot be run at all, not even with
/// `--model-profile rfdetr`, and the error blames the profile rather than the
/// export.
///
/// Both known exporters are covered — Roboflow's `dets`/`labels` and the
/// transformers conversion's `pred_boxes`/`logits`. A name that claims both
/// roles or neither settles nothing, and two claims on one role is an
/// ambiguity to report rather than an order to trust.
fn bind_detr_by_name(declared: &[Declared]) -> Option<Outputs<Declared>> {
    let (mut boxes, mut logits) = (None, None);
    for output in declared {
        let name = output.name.to_ascii_lowercase();
        let says_boxes = name.contains("box") || name.contains("det");
        let says_logits =
            name.contains("logit") || name.contains("label") || name.contains("score");
        let slot = match (says_boxes, says_logits) {
            (true, false) => &mut boxes,
            (false, true) => &mut logits,
            _ => continue,
        };
        if slot.is_some() {
            return None;
        }
        *slot = Some(output.clone());
    }
    Some(Outputs::BoxesAndLogits {
        boxes: boxes?,
        logits: logits?,
    })
}

/// The shapes bound to a layout's roles, when the export pins all of them.
fn static_shapes(roles: Roles, declared: &[Declared]) -> Option<Shapes> {
    bind(roles, declared)
        .ok()?
        .try_map(|output| output.dims.clone())
}

/// Read a layout's own counts off a real output shape, or say why it does not
/// fit.
///
/// Nothing here guesses: the layout kind is given, and this only fills in what
/// the shape declares (`nc`) and refuses shapes the kind cannot describe.
fn fit_layout(layout: Layout, shapes: &Shapes, size: InputSize) -> Result<Layout> {
    // Every arm requires the roles to match first, so a two-tensor shape can
    // never be read as a one-tensor head or the reverse.
    let fitted = match (layout, shapes) {
        (Layout::EndToEnd, Outputs::One(dims)) if rank3(dims) && dims[2] == 6 => {
            Some(Layout::EndToEnd)
        }
        // The anchor axis of a channels-first head runs into the thousands
        // against a channel axis of `4 + nc`, which is what orients it.
        (Layout::RawClasses { .. }, Outputs::One(dims))
            if rank3(dims) && dims[1] >= 5 && dims[2] > dims[1] * 4 =>
        {
            Some(Layout::RawClasses {
                nc: (dims[1] - 4) as usize,
            })
        }
        (Layout::GridObjectness { strides, .. }, Outputs::One(dims))
            if rank3(dims) && dims[2] >= 6 && dims[1] == grid_anchors(size, strides) as i64 =>
        {
            Some(Layout::GridObjectness {
                nc: (dims[2] - 5) as usize,
                strides,
            })
        }
        (Layout::DetrQueries { .. }, Outputs::BoxesAndLogits { boxes, logits })
            if rank3(boxes)
                && rank3(logits)
                && boxes[2] == 4
                && logits[2] >= 1
                && boxes[1] == logits[1] =>
        {
            Some(Layout::DetrQueries {
                nc: logits[2] as usize,
            })
        }
        _ => None,
    };
    fitted.ok_or_else(|| {
        anyhow!(
            "output shape {} does not fit {layout}; expected {}",
            show(shapes),
            layout.expected(size)
        )
    })
}

/// A single-frame rank-3 output, the shape every layout here indexes.
fn rank3(dims: &[i64]) -> bool {
    dims.len() == 3 && dims[0] == 1
}

/// Does a *resolved* layout describe `dims` exactly?
///
/// Deliberately not [`fit_layout`]: that one discriminates between kinds and
/// leans on heuristics ("the anchor axis is far longer than the channel axis")
/// to do it. Once the kind and its counts are settled, the only question left
/// is whether this tensor has the extents that layout indexes by — a head with
/// one anchor is perfectly decodable and the sniffing heuristic would refuse
/// it.
pub(super) fn validate_layout(layout: Layout, shapes: &Shapes, size: InputSize) -> Result<()> {
    let ok = match (layout, shapes) {
        (Layout::EndToEnd, Outputs::One(dims)) => rank3(dims) && dims[2] == 6,
        (Layout::RawClasses { nc }, Outputs::One(dims)) => {
            rank3(dims) && dims[1] == (4 + nc) as i64
        }
        (Layout::GridObjectness { nc, strides }, Outputs::One(dims)) => {
            rank3(dims)
                && dims[1] == grid_anchors(size, strides) as i64
                && dims[2] == (5 + nc) as i64
        }
        (Layout::DetrQueries { nc }, Outputs::BoxesAndLogits { boxes, logits }) => {
            rank3(boxes)
                && rank3(logits)
                && boxes[2] == 4
                && boxes[1] == logits[1]
                && logits[2] == nc as i64
        }
        _ => false,
    };
    if !ok {
        bail!(
            "expected a {layout} output at input {size}, got {}",
            show(shapes)
        );
    }
    Ok(())
}

/// The same, for a whole output half.
pub(super) fn fit_output(spec: OutputSpec, shapes: &Shapes, size: InputSize) -> Result<OutputSpec> {
    Ok(OutputSpec {
        layout: fit_layout(spec.layout, shapes, size)?,
        ..spec
    })
}

/// Which built-in profiles this output shape could be.
///
/// Returning every match rather than the first is the whole point: at 640x384
/// a `[1, 5040, 6]` output is a 1-class yolox grid head *and* an end-to-end
/// `[1, N, 6]` row set, because 5040 is exactly that input's anchor count and
/// 6 is exactly the end-to-end row width. Picking one silently would read four
/// numbers that are cell offsets and log extents as final pixel corners, or
/// the reverse — plausible boxes, wrong ones.
///
/// (`[1, 8400, 84]` at 640 is *not* an example of this: `RawClasses` requires
/// `dims[2] > dims[1] * 4`, which an anchor-major shape fails, so that one
/// sniffs as yolox alone.)
fn sniff(declared: &[Declared], size: InputSize) -> Vec<ModelProfile> {
    PROFILES
        .iter()
        .filter_map(|profile| {
            let shapes = static_shapes(profile.output.layout.roles(), declared)?;
            fit_output(profile.output, &shapes, size)
                .ok()
                .map(|output| ModelProfile { output, ..*profile })
        })
        .collect()
}

/// Settle which profile this model is run under.
///
/// `explicit` is `--model-profile`; it wins outright and is then *validated*
/// against the model's real output, because a profile that does not describe
/// the model is worse than no profile at all.
pub(super) fn resolve_profile(
    explicit: Option<ModelProfile>,
    declared: &[Declared],
    size: InputSize,
    model: &Path,
) -> Result<(ModelProfile, Outputs<String>, Option<OutputSpec>)> {
    let Some(profile) = explicit else {
        return sniff_profile(declared, size, model);
    };
    let mismatch = || {
        format!(
            "--model-profile {profile} does not describe model {}",
            model.display()
        )
    };
    // A profile that names roles the model does not offer is settled here,
    // before any frame is packed for it.
    let bound = bind(profile.output.layout.roles(), declared).with_context(mismatch)?;
    let output = match bound.try_map(|output| output.dims.clone()) {
        Some(shapes) => Some(fit_output(profile.output, &shapes, size).with_context(mismatch)?),
        // A dynamic output shape declares nothing to validate against; the
        // input half is still fully known, so frames can be packed correctly
        // and only `nc` waits for the first real output. This covers the
        // two-tensor families as well as the one-tensor ones: `bind` has
        // already settled the roles above — by shape where the export pins
        // them, by name where it pins nothing — and `decode_output` re-checks
        // the layout against the real dims on every frame, so a deferral that
        // guessed wrong fails on the first output rather than decoding it.
        None => None,
    };
    Ok((profile, bound.map(|output| output.name.clone()), output))
}

/// The `--model-profile`-less half of [`resolve_profile`].
fn sniff_profile(
    declared: &[Declared],
    size: InputSize,
    model: &Path,
) -> Result<(ModelProfile, Outputs<String>, Option<OutputSpec>)> {
    let mut candidates = sniff(declared, size);
    let named = |profiles: &[ModelProfile], sep: &str| {
        profiles
            .iter()
            .map(|p| p.name)
            .collect::<Vec<_>>()
            .join(sep)
    };
    match candidates.len() {
        1 => {
            let profile = candidates.remove(0);
            let bound = bind(profile.output.layout.roles(), declared)?;
            Ok((
                profile,
                bound.map(|output| output.name.clone()),
                Some(profile.output),
            ))
        }
        // Nothing bound *and* pinned its shapes for any profile: there is no
        // shape here to have found unsupported, only an export that declined
        // to declare one.
        0 if !PROFILES
            .iter()
            .any(|p| static_shapes(p.output.layout.roles(), declared).is_some()) =>
        {
            bail!(
                "model {} leaves its output shape dynamic, so there is nothing to sniff a \
                 profile from — and the encoding and resize policy have to be settled before \
                 the first frame is converted. Pass --model-profile <{}>.",
                model.display(),
                names()
            )
        }
        0 => bail!(
            "model {} has unsupported outputs {} at input {size}; expected {}",
            model.display(),
            describe_outputs(declared),
            PROFILES
                .iter()
                .map(|p| format!("{} ({})", p.output.layout.expected(size), p.name))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        _ => bail!(
            "model {} has outputs {}, which at input {size} fit more than one profile: {}. \
             Nothing in the shapes says which, and they decode differently — pass \
             --model-profile <{}> to say.",
            model.display(),
            describe_outputs(declared),
            named(&candidates, " and "),
            named(&candidates, "|")
        ),
    }
}

/// Spatial dims declared by a `[N, 3, H, W]` model input, if it pins them.
///
/// Only a confidently NCHW 3-channel shape yields a size. Everything else —
/// a non-tensor input, a rank other than 4, an NHWC `[1, H, W, 3]`, a dynamic
/// or non-3 channel axis, and the common case of an export with dynamic
/// spatial axes (which onnxruntime reports as `-1`) — returns `None` and
/// leaves the size to `--input-size` or the profile's default.
///
/// The channel axis is checked rather than skipped over because the whole
/// pipeline hardcodes 3-channel RGB: [`RgbScaler`] emits RGB24 and
/// [`InputSize::tensor_len`] packs `3 * w * h`. Without the check an NHWC
/// export reads as `w = 3`, which builds a 3-pixel-wide scaler and a garbage
/// tensor before onnxruntime ever sees the mismatch.
///
/// [`RgbScaler`]: crate::decode::RgbScaler
pub(super) fn declared_input_size(dtype: &ValueType) -> Option<InputSize> {
    let ValueType::Tensor { shape, .. } = dtype else {
        return None;
    };
    if shape.len() != 4 || shape[1] != 3 {
        return None;
    }
    let (h, w) = (shape[2], shape[3]);
    if h <= 0 || w <= 0 {
        return None;
    }
    Some(InputSize {
        w: w as usize,
        h: h as usize,
    })
}

/// Settle the size the whole pipeline is built for.
///
/// A flag that contradicts a model's static shape is rejected here rather
/// than left to fail inside `Session::run` on the first sampled frame, where
/// the message is onnxruntime's and the process has already been running for
/// a minute. A profile's own size is only a last resort: it is a family
/// default, not a statement about this export.
///
/// A profile carrying [`ModelProfile::variant_sizes`] has no usable default at
/// all, so it supplies none: for a family whose every export leaves its spatial
/// axes dynamic, one variant's resolution guessed at another's is not a
/// wrong-but-working run, it is a camera that silently detects nothing. The
/// error lists the resolutions instead of picking one.
pub(super) fn resolve_input_size(
    declared: Option<InputSize>,
    requested: Option<InputSize>,
    profile: Option<ModelProfile>,
    model: &Path,
) -> Result<(InputSize, InputSizeSource)> {
    let fallback = profile
        .filter(|profile| profile.variant_sizes.is_none())
        .map(|profile| profile.input.size);
    let (size, source) = match (requested, declared) {
        (Some(requested), Some(declared)) if requested != declared => bail!(
            "--input-size {requested} contradicts model {}, whose input is {declared}",
            model.display()
        ),
        (Some(requested), _) => (requested, InputSizeSource::Flag),
        (None, Some(declared)) => (declared, InputSizeSource::Model),
        (None, None) => match (fallback, profile.and_then(|p| p.variant_sizes)) {
            (Some(fallback), _) => (fallback, InputSizeSource::Profile),
            // The profile is known and still cannot answer: say so, and say
            // what the answer is likely to be, rather than reporting a bare
            // "does not pin" that reads as if the profile were missing too.
            (None, Some(sizes)) => bail!(
                "model {} does not pin its input width and height, and the {} profile has no \
                 default to fall back on — every export in the family leaves its spatial axes \
                 dynamic and declares nothing that says which variant it is. Pass --input-size \
                 WxH (or N); the variants are trained at {sizes}. A wrong size here is silent: \
                 the model runs and detects nothing.",
                model.display(),
                profile.map(|p| p.name).unwrap_or_default(),
            ),
            (None, None) => bail!(
                "model {} does not pin its input width and height; pass --input-size WxH (or N)",
                model.display()
            ),
        },
    };
    // Every provenance funnels through here, so both ceilings cover a model's
    // declared dims as well as a typo'd flag. Zero is already impossible:
    // `dim` rejects it on the flag and `declared_input_size` requires `> 0`.
    if size.w > MAX_INPUT_DIM || size.h > MAX_INPUT_DIM {
        bail!("input size {size} ({source}) exceeds the {MAX_INPUT_DIM} per-dimension limit");
    }
    // The per-axis bound is about casts; this one is about memory, and a size
    // inside the first can be far outside the second (8192x8192 is a 1 GB
    // working set per camera). `saturating_mul` because the product is exactly
    // what is being questioned.
    let pixels = size.w.saturating_mul(size.h);
    if pixels > MAX_INPUT_PIXELS {
        bail!(
            "input size {size} ({source}) is {pixels} pixels, over the {MAX_INPUT_PIXELS}-pixel \
             limit (2048x2048): the CHW f32 tensor alone would be {} MB, per camera",
            pixels.saturating_mul(3 * std::mem::size_of::<f32>()) / (1024 * 1024),
        );
    }
    Ok((size, source))
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use ort::value::ValueType;

    use super::super::catalog::{RFDETR, YOLOV10, YOLOV8, YOLOX};
    use super::super::encoding::TensorEncoding;
    use super::super::geometry::{InputSize, ResizePolicy};
    use super::super::profile::*;
    use super::*;

    /// The shapes of a one-tensor head, as a layout reads them.
    fn one(dims: &[i64]) -> Shapes {
        Outputs::One(dims.to_vec())
    }

    /// A model declaring exactly one static output, as sniffing sees it.
    fn declared(dims: &[i64]) -> Vec<Declared> {
        vec![Declared {
            name: "output".into(),
            dims: Some(dims.to_vec()),
        }]
    }

    /// A model that pins nothing about its output.
    fn dynamic() -> Vec<Declared> {
        vec![Declared {
            name: "output".into(),
            dims: None,
        }]
    }

    /// An RF-DETR-shaped model: boxes and logits over the same queries, under
    /// the names the transformers/onnx-community conversion uses.
    fn declared_detr(queries: i64, nc: i64) -> Vec<Declared> {
        vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, queries, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, queries, nc]),
            },
        ]
    }

    fn detr_shapes(queries: i64, nc: i64) -> Shapes {
        Outputs::BoxesAndLogits {
            boxes: vec![1, queries, 4],
            logits: vec![1, queries, nc],
        }
    }

    const SQUARE: InputSize = InputSize::square(640);
    /// What `yolox_nano.onnx` from the Megvii 0.1.1rc0 release declares.
    const YOLOX_416: InputSize = InputSize::square(416);
    /// 8^2 + 4^2 + 2^2 = 84 anchors: small enough to reason about by hand.
    const TINY: InputSize = InputSize::square(64);
    const STRIDES: &[usize] = &[8, 16, 32];

    // ---- profiles: layout fitting, sniffing, ambiguity ---------------------

    fn tensor_type(dims: &[i64]) -> ValueType {
        ValueType::Tensor {
            ty: ort::value::TensorElementType::Float32,
            shape: ort::value::Shape::new(dims.to_vec()),
            dimension_symbols: ort::value::SymbolicDimensions::new(
                dims.iter().map(|_| String::default()),
            ),
        }
    }

    #[test]
    fn every_built_in_profile_is_reachable_by_name() {
        for profile in PROFILES {
            assert_eq!(ModelProfile::parse(profile.name).unwrap(), *profile);
        }
        assert_eq!(ModelProfile::parse("  YOLOX ").unwrap(), YOLOX);
        assert_eq!(ModelProfile::parse("RFDETR").unwrap(), RFDETR);
        let err = ModelProfile::parse("yolov7").unwrap_err().to_string();
        for expected in ["yolox", "yolov10", "yolov8", "rfdetr"] {
            assert!(err.contains(expected), "{err}");
        }
        // and the error names the aliases too, because `yolo11` resolving to
        // the yolov8 profile is exactly the thing a reader needs told
        assert!(err.contains("yolo11"), "{err}");
    }

    #[test]
    fn the_ultralytics_generations_are_aliases_of_one_profile_not_profiles() {
        // Every one of these exports the same tensor, so each is a *name* for
        // the yolov8 profile. Were they separate entries in `PROFILES`, an
        // ordinary `[1, 84, 8400]` head would sniff as four candidates and
        // hard-error on an ambiguity that does not exist.
        for name in ["yolov8", "yolov9", "yolo11", "yolov11"] {
            assert_eq!(ModelProfile::parse(name).unwrap(), YOLOV8, "{name}");
        }
        // yolo26 is end-to-end like yolov10 — UNVERIFIED against a real
        // export, which is why it is an alias rather than its own decode.
        assert_eq!(ModelProfile::parse("yolo26").unwrap(), YOLOV10);
        assert_eq!(ModelProfile::parse("rf-detr").unwrap(), RFDETR);
        // an alias resolves to the profile's canonical identity, so the
        // startup line and every error say `yolov8`, not the alias
        assert_eq!(ModelProfile::parse("yolo11").unwrap().to_string(), "yolov8");
        // ...and one profile per distinct decode keeps sniffing unambiguous
        assert_eq!(PROFILES.len(), 4);
        assert_eq!(sniff(&declared(&[1, 84, 8400]), SQUARE).len(), 1);
        assert_eq!(sniff(&declared(&[1, 300, 6]), SQUARE).len(), 1);
    }

    #[test]
    fn the_built_in_profiles_are_the_documented_steps() {
        assert_eq!(YOLOX.input.encoding, TensorEncoding::RawBgr);
        assert_eq!(YOLOX.input.resize, ResizePolicy::Letterbox { pad: 114 });
        assert_eq!(YOLOX.input.size, YOLOX_416);
        assert_eq!(
            YOLOX.output.layout,
            Layout::GridObjectness {
                nc: 80,
                strides: &[8, 16, 32]
            }
        );
        assert_eq!(YOLOX.output.score, ScoreComposition::ObjTimesClass);
        assert_eq!(YOLOX.output.nms, Some(DEFAULT_NMS));

        assert_eq!(YOLOV10.input.encoding, TensorEncoding::UnitRgb);
        assert_eq!(YOLOV10.input.resize, ResizePolicy::Stretch);
        assert_eq!(YOLOV10.output.layout, Layout::EndToEnd);
        assert_eq!(YOLOV10.output.score, ScoreComposition::Class);
        assert!(YOLOV10.output.nms.is_none());

        assert_eq!(YOLOV8.input.encoding, TensorEncoding::UnitRgb);
        assert_eq!(YOLOV8.input.resize, ResizePolicy::Stretch);
        assert_eq!(YOLOV8.output.layout, Layout::RawClasses { nc: 80 });
        assert_eq!(YOLOV8.output.score, ScoreComposition::Class);
        assert_eq!(YOLOV8.output.nms, Some(DEFAULT_NMS));

        // Measured against onnx-community/rfdetr_nano-ONNX, not assumed: the
        // export's own `preprocessor_config.json` and RF-DETR's
        // `kornia_transforms` agree on ImageNet mean/std, its square
        // `A.Resize` is a stretch, its `postprocess` sigmoids raw logits, and
        // set prediction means no NMS.
        assert_eq!(RFDETR.input.encoding, TensorEncoding::ImageNetRgb);
        assert_eq!(RFDETR.input.resize, ResizePolicy::Stretch);
        assert_eq!(RFDETR.input.size, InputSize::square(384));
        assert_eq!(RFDETR.output.layout, Layout::DetrQueries { nc: 91 });
        assert_eq!(RFDETR.output.score, ScoreComposition::SigmoidClass);
        assert!(RFDETR.output.nms.is_none());
        // it is the only family here that reads more than one tensor
        for profile in PROFILES {
            let two = matches!(
                profile.output.layout.roles(),
                Outputs::BoxesAndLogits { .. }
            );
            assert_eq!(two, profile.name == "rfdetr", "{}", profile.name);
        }
    }

    #[test]
    fn the_nms_defaults_are_the_upstream_ones() {
        // Asserted by literal value, not by symbol. Every other test that
        // mentions these writes `DEFAULT_NMS.max_candidates + 200` or similar,
        // so a changed value stays self-consistent and nothing notices — and
        // the golden fixtures pin `iou` only to the band the planted overlaps
        // straddle (their IoUs are 0.679 and 0.600), so a typo'd 0.5 would
        // suppress and keep exactly the same boxes.
        //
        // 0.45 is Ultralytics' own default for a detect head and YOLOX's demo
        // value; 300 is the candidate cap that bounds NMS's O(k^2) against a
        // 640x640 head's 8400 anchors.
        assert_eq!(DEFAULT_NMS.iou, 0.45);
        assert_eq!(DEFAULT_NMS.max_candidates, 300);
    }

    #[test]
    fn a_row_width_of_six_is_the_end_to_end_layout() {
        // yolov10n's own export
        assert_eq!(sniff(&declared(&[1, 300, 6]), SQUARE), vec![YOLOV10]);
        assert_eq!(
            fit_layout(Layout::EndToEnd, &one(&[1, 300, 6]), SQUARE).unwrap(),
            Layout::EndToEnd
        );
    }

    #[test]
    fn a_long_anchor_axis_is_the_raw_detect_head() {
        // coco yolov8n at 640x640
        let sniffed = sniff(&declared(&[1, 84, 8400]), SQUARE);
        assert_eq!(sniffed.len(), 1);
        assert_eq!(sniffed[0].name, "yolov8");
        assert_eq!(sniffed[0].output.layout, Layout::RawClasses { nc: 80 });
        // a single-class model at a small input still has far more anchors
        // than channels
        assert_eq!(
            fit_layout(
                Layout::RawClasses { nc: 80 },
                &one(&[1, 5, 189]),
                InputSize::square(128)
            )
            .unwrap(),
            Layout::RawClasses { nc: 1 }
        );
    }

    #[test]
    fn the_grid_anchor_count_is_what_names_the_yolox_layout() {
        // yolox_nano.onnx from the Megvii 0.1.1rc0 release: 416x416 input,
        // 52^2 + 26^2 + 13^2 = 3549 anchors, 5 + 80 columns
        assert_eq!(grid_anchors(YOLOX_416, STRIDES), 3549);
        let sniffed = sniff(&declared(&[1, 3549, 85]), YOLOX_416);
        assert_eq!(sniffed.len(), 1);
        assert_eq!(sniffed[0].name, "yolox");
        assert_eq!(
            sniffed[0].output.layout,
            Layout::GridObjectness {
                nc: 80,
                strides: STRIDES
            }
        );
        assert_eq!(grid_anchors(SQUARE, STRIDES), 8400);
    }

    #[test]
    fn a_shape_that_fits_two_profiles_is_an_error_naming_both() {
        // A 1-class yolox head is `[1, A, 6]`, and 6 is also the end-to-end
        // row width. At 640x384 that is 5040 anchors either way and nothing in
        // the shape says which — one decodes boxes out of a stride grid, the
        // other reads them as final pixel corners, so picking silently emits
        // plausible garbage.
        let wide = InputSize { w: 640, h: 384 };
        assert_eq!(grid_anchors(wide, STRIDES), 80 * 48 + 40 * 24 + 20 * 12);
        assert_eq!(
            sniff(&declared(&[1, 5040, 6]), wide)
                .iter()
                .map(|p| p.name)
                .collect::<Vec<_>>(),
            vec!["yolox", "yolov10"]
        );
        let err = resolve_profile(None, &declared(&[1, 5040, 6]), wide, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("yolox"), "{err}");
        assert!(err.contains("yolov10"), "{err}");
        assert!(err.contains("--model-profile"), "{err}");
        assert!(err.contains("[1, 5040, 6]"), "{err}");
        // the same collision at the default square input
        assert_eq!(sniff(&declared(&[1, 8400, 6]), SQUARE).len(), 2);
    }

    #[test]
    fn a_transposed_looking_shape_is_yolox_alone_because_ultralytics_is_channels_first() {
        // Worth pinning: `[1, 8400, 84]` at 640 *looks* like it could be
        // either family, and it is a 79-class yolox. It is not ambiguous
        // because a stock Ultralytics detect head is channels-first — its
        // anchor axis is the long one — so `RawClasses` refuses this
        // orientation outright rather than reading nc as 8396.
        let sniffed = sniff(&declared(&[1, 8400, 84]), SQUARE);
        assert_eq!(sniffed.len(), 1, "{sniffed:?}");
        assert_eq!(sniffed[0].name, "yolox");
        assert_eq!(
            sniffed[0].output.layout,
            Layout::GridObjectness {
                nc: 79,
                strides: STRIDES
            }
        );
        // adding a transposed-Ultralytics profile would make this genuinely
        // ambiguous, and the resolution above is what would then catch it
        assert!(fit_layout(Layout::RawClasses { nc: 80 }, &one(&[1, 8400, 84]), SQUARE).is_err());
    }

    #[test]
    fn an_explicit_profile_resolves_a_shape_that_is_otherwise_ambiguous() {
        let (profile, _names, output) = resolve_profile(
            Some(YOLOX),
            &declared(&[1, 8400, 84]),
            SQUARE,
            Path::new("m.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "yolox");
        assert_eq!(
            output.unwrap().layout,
            Layout::GridObjectness {
                nc: 79,
                strides: STRIDES
            }
        );
        // ...and the other reading of the same shape is available too
        let (profile, _names, output) = resolve_profile(
            Some(YOLOV10),
            &declared(&[1, 5040, 6]),
            InputSize { w: 640, h: 384 },
            Path::new("m.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "yolov10");
        assert_eq!(output.unwrap().layout, Layout::EndToEnd);
    }

    #[test]
    fn an_explicit_profile_that_does_not_fit_the_model_fails_loudly() {
        // yolox at an input size whose grid the output does not match: 3549
        // anchors are 416's, not 640's
        let err = resolve_profile(
            Some(YOLOX),
            &declared(&[1, 3549, 85]),
            SQUARE,
            Path::new("m.onnx"),
        )
        .unwrap_err();
        let text = format!("{err:#}");
        assert!(text.contains("--model-profile yolox"), "{text}");
        assert!(text.contains("[1, 8400, 5 + nc]"), "{text}");
        // an end-to-end profile pointed at a raw head
        assert!(resolve_profile(
            Some(YOLOV10),
            &declared(&[1, 84, 8400]),
            SQUARE,
            Path::new("m.onnx")
        )
        .is_err());
        // a channels-first profile pointed at an anchor-major head
        assert!(resolve_profile(
            Some(YOLOV8),
            &declared(&[1, 8400, 84]),
            SQUARE,
            Path::new("m.onnx")
        )
        .is_err());
    }

    #[test]
    fn an_unrecognizable_shape_names_every_profile() {
        for (dims, size) in [
            (vec![1, 84, 84], SQUARE),      // no axis long enough to be anchors
            (vec![1, 3, 640, 640], SQUARE), // rank 4
            // yolov5 at 640: same rank and row width as a yolox head, but
            // three anchor boxes per cell make A exactly 3x a yolox's, and
            // its boxes are already in pixels — decoding it against the yolox
            // grid would emit plausible garbage
            (vec![1, 25200, 85], SQUARE),
            // a real yolox shape read against the wrong input size
            (vec![1, 3549, 85], SQUARE),
            (vec![1, 8400, 85], YOLOX_416),
            (vec![2, 84, 8400], SQUARE), // batched
        ] {
            assert!(
                sniff(&declared(&dims), size).is_empty(),
                "{dims:?} matched something"
            );
            let err = resolve_profile(None, &declared(&dims), size, Path::new("m.onnx"))
                .unwrap_err()
                .to_string();
            assert!(err.contains("yolox"), "{err}");
            assert!(err.contains("yolov10"), "{err}");
            assert!(err.contains("yolov8"), "{err}");
        }
    }

    #[test]
    fn a_static_output_shape_settles_the_profile_at_startup() {
        let dims = static_output_dims(&tensor_type(&[1, 84, 8400])).unwrap();
        assert_eq!(sniff(&declared(&dims), SQUARE)[0].name, "yolov8");
        let dims = static_output_dims(&tensor_type(&[1, 3549, 85])).unwrap();
        assert_eq!(sniff(&declared(&dims), YOLOX_416)[0].name, "yolox");
    }

    #[test]
    fn a_dynamic_output_shape_needs_the_flag_and_settles_nc_later() {
        assert!(static_output_dims(&tensor_type(&[1, 84, -1])).is_none());
        assert!(static_output_dims(&tensor_type(&[-1, -1, -1])).is_none());
        // nothing to sniff, and the encoding has to be known before the first
        // frame is converted, so this is a startup failure rather than a guess
        let err = resolve_profile(None, &dynamic(), SQUARE, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("--model-profile"), "{err}");
        assert!(err.contains("yolox"), "{err}");
        // with the flag, the input half is settled now and nc waits
        let (profile, _names, output) =
            resolve_profile(Some(YOLOX), &dynamic(), SQUARE, Path::new("m.onnx")).unwrap();
        assert_eq!(profile.input.encoding, TensorEncoding::RawBgr);
        assert!(output.is_none());
    }

    // ---- multi-output binding ----------------------------------------------

    #[test]
    fn a_detr_pair_is_bound_by_shape_so_either_export_convention_works() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        // the transformers / onnx-community conversion
        let bound = bind(roles, &declared_detr(300, 91)).unwrap();
        assert_eq!(
            bound.map(|output| output.name.clone()),
            Outputs::BoxesAndLogits {
                boxes: "pred_boxes".into(),
                logits: "logits".into()
            }
        );
        // Roboflow's own export(): different names, and nothing says the
        // boxes come first, so the roles are read off the shapes.
        let roboflow = vec![
            Declared {
                name: "labels".into(),
                dims: Some(vec![1, 300, 91]),
            },
            Declared {
                name: "dets".into(),
                dims: Some(vec![1, 300, 4]),
            },
        ];
        assert_eq!(
            bind(roles, &roboflow).unwrap().map(|o| o.name.clone()),
            Outputs::BoxesAndLogits {
                boxes: "dets".into(),
                logits: "labels".into()
            }
        );
    }

    #[test]
    fn a_detr_export_pinning_no_shape_at_all_is_bound_by_name_instead() {
        // `optimum`'s dynamic_axes leaves the query axis symbolic, so both
        // tensors read as [?, ?, N] and neither declares a shape. Without a
        // fallback such an export cannot be run at all — not even with
        // `--model-profile rfdetr`, whose whole job is to answer for an export
        // that says nothing.
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        let dynamic = |names: [&str; 2]| -> Vec<Declared> {
            names
                .iter()
                .map(|name| Declared {
                    name: (*name).into(),
                    dims: None,
                })
                .collect()
        };
        for names in [
            ["pred_boxes", "logits"],
            ["logits", "pred_boxes"],
            ["dets", "labels"],
            ["labels", "dets"],
        ] {
            let bound = bind(roles, &dynamic(names))
                .unwrap()
                .map(|o| o.name.clone());
            let expected = |role: fn(&str) -> bool| {
                names.iter().copied().find(|n| role(n)).unwrap().to_string()
            };
            assert_eq!(
                bound,
                Outputs::BoxesAndLogits {
                    boxes: expected(|n| n.contains("box") || n.contains("det")),
                    logits: expected(|n| n.contains("logit") || n.contains("label")),
                },
                "{names:?}"
            );
        }

        // ...and the profile that names it then starts, deferring `nc` to the
        // first real output exactly as a one-tensor family does.
        let (profile, outputs, output) = resolve_profile(
            Some(RFDETR),
            &dynamic(["pred_boxes", "logits"]),
            InputSize::square(384),
            Path::new("rfdetr_dynamic.onnx"),
        )
        .unwrap();
        assert_eq!(profile.name, "rfdetr");
        assert_eq!(
            outputs,
            Outputs::BoxesAndLogits {
                boxes: "pred_boxes".into(),
                logits: "logits".into()
            }
        );
        assert!(output.is_none(), "nc waits for the first real output");
    }

    #[test]
    fn names_that_settle_nothing_are_an_error_rather_than_an_output_order() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        let unnamed = |names: [&str; 2]| -> Vec<Declared> {
            names
                .iter()
                .map(|name| Declared {
                    name: (*name).into(),
                    dims: None,
                })
                .collect()
        };
        // nothing in either name claims a role, and position is not a signal
        let err = bind(roles, &unnamed(["output0", "output1"]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("pred_boxes/logits"), "{err}");
        assert!(err.contains("(dynamic)"), "{err}");
        // two claims on one role is an ambiguity, not a first-wins
        assert!(bind(roles, &unnamed(["pred_boxes", "dets"])).is_err());
        // a name claiming both roles claims neither
        assert!(bind(roles, &unnamed(["box_logits", "logits"])).is_err());

        // An export that *does* pin its shapes and misses is a shape mismatch
        // to report; the name fallback must not paper over it.
        let shaped = vec![Declared {
            name: "pred_boxes".into(),
            dims: Some(vec![1, 300, 6]),
        }];
        let err = bind(roles, &shaped).unwrap_err().to_string();
        assert!(err.contains("[1, 300, 6]"), "{err}");
        assert!(!err.contains("pred_boxes/logits"), "{err}");
    }

    #[test]
    fn a_pair_that_cannot_be_told_apart_is_an_error_naming_the_outputs() {
        let roles = Layout::DetrQueries { nc: 91 }.roles();
        // a single-output model has no pair at all
        let err = bind(roles, &declared(&[1, 300, 91]))
            .unwrap_err()
            .to_string();
        assert!(err.contains("[1, Q, 4]"), "{err}");
        assert!(err.contains("\"output\""), "{err}");

        // a genuinely 4-class DETR: both tensors end in 4 and nothing says
        // which is the box regression
        let four = vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 300, 4]),
            },
        ];
        assert!(bind(roles, &four).is_err());

        // a pair whose query axes disagree is not a pair
        let mismatched = vec![
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4]),
            },
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 100, 91]),
            },
        ];
        assert!(bind(roles, &mismatched).is_err());

        // and a single-output layout is unaffected by any of it: it takes the
        // first output and leaves an export's extras alone
        assert_eq!(
            bind(Layout::EndToEnd.roles(), &declared_detr(300, 91)).unwrap(),
            Outputs::One(Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 300, 4])
            })
        );
    }

    #[test]
    fn a_two_tensor_model_sniffs_as_rfdetr_and_a_one_tensor_model_never_does() {
        // what rfdetr_nano.onnx declares, at its own 384
        let size = InputSize::square(384);
        let sniffed = sniff(&declared_detr(300, 91), size);
        assert_eq!(sniffed.len(), 1, "{sniffed:?}");
        assert_eq!(sniffed[0].name, "rfdetr");
        assert_eq!(sniffed[0].output.layout, Layout::DetrQueries { nc: 91 });
        assert_eq!(sniffed[0].input.encoding, TensorEncoding::ImageNetRgb);

        // The roles are what keep the families apart: no single-tensor head
        // can match a layout that reads two, and `pred_boxes` on its own fits
        // none of the one-tensor layouts either.
        for dims in [
            vec![1, 300, 6],
            vec![1, 84, 8400],
            vec![1, 3549, 85],
            vec![1, 300, 4],
        ] {
            assert!(
                sniff(&declared(&dims), size)
                    .iter()
                    .all(|p| p.name != "rfdetr"),
                "{dims:?} sniffed as rfdetr"
            );
        }
        assert_eq!(
            fit_layout(Layout::DetrQueries { nc: 91 }, &detr_shapes(300, 91), size).unwrap(),
            Layout::DetrQueries { nc: 91 }
        );
    }

    #[test]
    fn a_detr_whose_logits_come_first_can_collide_with_the_yolox_grid() {
        // The new ambiguity the fifth profile introduces, and the reason
        // binding a role is not the same as sniffing a profile.
        //
        // A single-tensor layout binds the model's *first* output. At 128x128
        // a yolox grid has 16^2 + 8^2 + 4^2 = 336 anchors, so a 336-query DETR
        // that happens to declare its logits first offers `[1, 336, 85]` — a
        // perfectly good 80-class yolox head — while the pair is a perfectly
        // good rfdetr. Nothing in the shapes says which, and they decode
        // completely differently.
        let size = InputSize::square(128);
        assert_eq!(grid_anchors(size, STRIDES), 336);
        let logits_first = vec![
            Declared {
                name: "logits".into(),
                dims: Some(vec![1, 336, 85]),
            },
            Declared {
                name: "pred_boxes".into(),
                dims: Some(vec![1, 336, 4]),
            },
        ];
        assert_eq!(
            sniff(&logits_first, size)
                .iter()
                .map(|p| p.name)
                .collect::<Vec<_>>(),
            vec!["yolox", "rfdetr"]
        );
        let err = resolve_profile(None, &logits_first, size, Path::new("m.onnx"))
            .unwrap_err()
            .to_string();
        assert!(err.contains("yolox"), "{err}");
        assert!(err.contains("rfdetr"), "{err}");
        assert!(err.contains("--model-profile"), "{err}");
        // the error has to name the outputs, since the shapes alone no longer
        // identify what was looked at
        assert!(err.contains("\"logits\""), "{err}");

        // ...and naming the profile settles it either way
        let (profile, _names, output) =
            resolve_profile(Some(RFDETR), &logits_first, size, Path::new("m.onnx")).unwrap();
        assert_eq!(profile.name, "rfdetr");
        assert_eq!(output.unwrap().layout, Layout::DetrQueries { nc: 85 });
    }

    #[test]
    fn naming_a_profile_whose_roles_the_model_lacks_fails_at_startup() {
        // rfdetr pointed at a one-tensor yolo export: caught here rather than
        // by an output lookup failing inside the inference thread.
        let err = resolve_profile(
            Some(RFDETR),
            &declared(&[1, 300, 6]),
            InputSize::square(384),
            Path::new("m.onnx"),
        )
        .unwrap_err();
        let text = format!("{err:#}");
        assert!(text.contains("--model-profile rfdetr"), "{text}");
        assert!(text.contains("[1, Q, 4]"), "{text}");

        // and the reverse: a single-tensor profile against a DETR export
        // binds `pred_boxes` and then fails to fit it
        assert!(resolve_profile(
            Some(YOLOV10),
            &declared_detr(300, 91),
            InputSize::square(384),
            Path::new("m.onnx")
        )
        .is_err());
    }

    #[test]
    fn a_dynamic_batch_axis_is_not_a_dynamic_layout() {
        // Every RF-DETR export pins its query and class axes and leaves batch
        // symbolic. Reading that as "nothing to sniff" would make the family
        // permanently unsniffable for a reason that says nothing about how it
        // decodes.
        assert_eq!(
            static_output_dims(&tensor_type(&[-1, 300, 4])),
            Some(vec![1, 300, 4])
        );
        assert_eq!(
            static_output_dims(&tensor_type(&[-1, 84, 8400])),
            Some(vec![1, 84, 8400])
        );
        // a symbolic axis anywhere else still declares nothing
        assert!(static_output_dims(&tensor_type(&[-1, 84, -1])).is_none());
        assert!(static_output_dims(&tensor_type(&[1, -1, 8400])).is_none());
        assert!(static_output_dims(&tensor_type(&[-1, -1, -1])).is_none());
        // and a static batch of 2 is a real batched export, which no layout
        // here indexes
        assert_eq!(
            static_output_dims(&tensor_type(&[2, 84, 8400])),
            Some(vec![2, 84, 8400])
        );
        assert!(sniff(&declared(&[2, 84, 8400]), SQUARE).is_empty());
    }

    // ---- input size resolution ---------------------------------------------

    fn nchw(dims: [i64; 4]) -> ValueType {
        ValueType::Tensor {
            ty: ort::value::TensorElementType::Float32,
            shape: ort::value::Shape::new(dims),
            dimension_symbols: ort::value::SymbolicDimensions::new([
                String::default(),
                String::default(),
                String::default(),
                String::default(),
            ]),
        }
    }

    #[test]
    fn reads_hw_from_a_static_nchw_input() {
        assert_eq!(
            declared_input_size(&nchw([1, 3, 352, 640])),
            Some(InputSize { w: 640, h: 352 })
        );
    }

    #[test]
    fn a_dynamic_or_odd_rank_input_declares_nothing() {
        // onnxruntime reports a symbolic axis as -1
        assert_eq!(declared_input_size(&nchw([1, 3, -1, -1])), None);
        assert_eq!(declared_input_size(&nchw([-1, 3, 640, -1])), None);
        // a zero axis declares nothing either, so it can never reach the
        // scaler as a 0-wide frame
        assert_eq!(declared_input_size(&nchw([1, 3, 0, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 3, 640, 0])), None);
        assert_eq!(
            declared_input_size(&ValueType::Tensor {
                ty: ort::value::TensorElementType::Float32,
                shape: ort::value::Shape::new([3, 640, 640]),
                dimension_symbols: ort::value::SymbolicDimensions::new([
                    String::default(),
                    String::default(),
                    String::default()
                ]),
            }),
            None
        );
    }

    #[test]
    fn a_channels_last_input_declares_nothing() {
        // [1, H, W, 3] is rank 4 like NCHW, so only the channel axis tells
        // them apart: read positionally it would give w=3 and build a
        // 3-pixel-wide scaler.
        assert_eq!(declared_input_size(&nchw([1, 640, 640, 3])), None);
        assert_eq!(declared_input_size(&nchw([1, 352, 640, 3])), None);
        // a dynamic or non-3 channel axis is equally unreadable
        assert_eq!(declared_input_size(&nchw([1, -1, 640, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 1, 640, 640])), None);
        assert_eq!(declared_input_size(&nchw([1, 4, 640, 640])), None);
    }

    #[test]
    fn the_model_supplies_the_size_when_the_flag_does_not() {
        let model = Path::new("m.onnx");
        let declared = Some(InputSize { w: 320, h: 320 });
        assert_eq!(
            resolve_input_size(declared, None, None, model).unwrap(),
            (InputSize::square(320), InputSizeSource::Model)
        );
        // ...and it outranks a profile's family default, which is only a
        // fallback for an export that declares nothing
        assert_eq!(
            resolve_input_size(declared, None, Some(YOLOX), model).unwrap(),
            (InputSize::square(320), InputSizeSource::Model)
        );
    }

    #[test]
    fn the_flag_supplies_the_size_a_dynamic_model_cannot() {
        let model = Path::new("m.onnx");
        assert_eq!(
            resolve_input_size(None, Some(SQUARE), None, model).unwrap(),
            (SQUARE, InputSizeSource::Flag)
        );
        // the flag outranks a profile default too
        assert_eq!(
            resolve_input_size(None, Some(SQUARE), Some(YOLOX), model).unwrap(),
            (SQUARE, InputSizeSource::Flag)
        );
        // a profile default is the last resort...
        assert_eq!(
            resolve_input_size(None, None, Some(YOLOX), model).unwrap(),
            (YOLOX_416, InputSizeSource::Profile)
        );
        // ...and without any of the three there is nothing to build a scaler
        // from
        let err = resolve_input_size(None, None, None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("--input-size"), "{err}");
    }

    #[test]
    fn a_multi_resolution_profile_refuses_to_supply_a_size_it_cannot_know() {
        let model = Path::new("rfdetr_small.onnx");
        // Nano's 384 sits in the profile, but every RF-DETR export leaves its
        // spatial axes dynamic and declares nothing that says which variant it
        // is, so a `small` fed 384 runs to completion and detects nothing.
        // Refusing is the only honest answer; the error carries the set.
        let err = resolve_input_size(None, None, Some(RFDETR), model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("--input-size"), "{err}");
        assert!(err.contains("rfdetr"), "{err}");
        assert!(err.contains(&model.display().to_string()), "{err}");
        for size in ["384", "512", "560", "576", "704"] {
            assert!(err.contains(size), "variant {size} missing from {err}");
        }

        // The flag it asks for is all it needs.
        assert_eq!(
            resolve_input_size(None, Some(InputSize::square(512)), Some(RFDETR), model).unwrap(),
            (InputSize::square(512), InputSizeSource::Flag)
        );
        // A model that pins its own size answers for itself, profile or not.
        assert_eq!(
            resolve_input_size(Some(InputSize::square(512)), None, Some(RFDETR), model).unwrap(),
            (InputSize::square(512), InputSizeSource::Model)
        );
        // A family whose exports pin their geometry still gets its default.
        assert_eq!(
            resolve_input_size(None, None, Some(YOLOX), model).unwrap(),
            (YOLOX_416, InputSizeSource::Profile)
        );
    }

    #[test]
    fn an_absurd_size_is_rejected_whichever_provenance_it_came_from() {
        let model = Path::new("m.onnx");
        let absurd = InputSize::square(64_000_000);
        // a typo'd flag...
        let err = resolve_input_size(None, Some(absurd), None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("64000000x64000000"), "{err}");
        assert!(err.contains("8192"), "{err}");
        assert!(err.contains("--input-size"), "{err}");

        // ...and a model declaring the same nonsense, which no flag touches
        let err = resolve_input_size(Some(absurd), None, None, model)
            .unwrap_err()
            .to_string();
        assert!(err.contains("64000000x64000000"), "{err}");
        assert!(err.contains("8192"), "{err}");
        assert!(err.contains("from model"), "{err}");

        // one oversized axis is enough
        assert!(resolve_input_size(
            None,
            Some(InputSize {
                w: MAX_INPUT_DIM + 1,
                h: 640
            }),
            None,
            model
        )
        .is_err());
        assert!(resolve_input_size(
            Some(InputSize {
                w: 640,
                h: MAX_INPUT_DIM + 1
            }),
            None,
            None,
            model
        )
        .is_err());
    }

    #[test]
    fn the_limit_itself_is_allowed() {
        let model = Path::new("m.onnx");
        // The widest shape both limits admit: 8192 on one axis is what the
        // i32 casts are bounded for, and 512 on the other keeps the area
        // inside what the allocations are bounded for.
        let at_limit = InputSize {
            w: MAX_INPUT_DIM,
            h: MAX_INPUT_PIXELS / MAX_INPUT_DIM,
        };
        assert_eq!(at_limit.w * at_limit.h, MAX_INPUT_PIXELS);
        assert_eq!(
            resolve_input_size(None, Some(at_limit), None, model).unwrap(),
            (at_limit, InputSizeSource::Flag)
        );
        assert_eq!(
            resolve_input_size(Some(at_limit), None, None, model).unwrap(),
            (at_limit, InputSizeSource::Model)
        );
        // the ceilings are what they protect: the cast stays inside its type
        // and the tensor inside a working set an NVR host can hold
        assert!(i32::try_from(MAX_INPUT_DIM).is_ok());
        assert_eq!(at_limit.tensor_len(), 3 * MAX_INPUT_PIXELS);
        assert!(at_limit.tensor_len() * 4 <= 64 * 1024 * 1024);
        // the square at the same area is admitted too
        assert!(resolve_input_size(Some(InputSize::square(2048)), None, None, model).is_ok());
    }

    #[test]
    fn a_size_inside_the_per_axis_limit_can_still_be_too_large_to_allocate() {
        // The case the per-axis bound alone lets through: a hostile or corrupt
        // ONNX declaring [1, 3, 8192, 8192] passes every dimension check and
        // then asks for an 805 MB tensor plus a 201 MB RGB frame on the first
        // frame, per decode thread, plus one parked in every multiplexed
        // member's slot. Four cameras is over 4 GB of RSS decided by a file.
        let model = Path::new("hostile.onnx");
        let square = InputSize::square(MAX_INPUT_DIM);
        assert!(square.w <= MAX_INPUT_DIM && square.h <= MAX_INPUT_DIM);
        for (declared, requested, source) in [
            (Some(square), None, "from model"),
            (None, Some(square), "--input-size"),
        ] {
            let err = resolve_input_size(declared, requested, None, model)
                .unwrap_err()
                .to_string();
            assert!(err.contains("8192x8192"), "{err}");
            assert!(err.contains(&MAX_INPUT_PIXELS.to_string()), "{err}");
            assert!(err.contains(source), "{err}");
            // the number that makes the case, in MB
            assert!(err.contains("768 MB"), "{err}");
        }
        // one pixel over is over, on either axis
        for over in [
            InputSize {
                w: 2048,
                h: 2048 + 1,
            },
            InputSize {
                w: 2048 + 1,
                h: 2048,
            },
        ] {
            assert!(resolve_input_size(None, Some(over), None, model).is_err());
        }
    }

    #[test]
    fn a_grid_head_refuses_an_input_its_strides_do_not_divide() {
        let grid = Layout::GridObjectness {
            nc: 80,
            strides: STRIDES,
        };
        // 350 is not a multiple of 32: `grid_anchors` and the decode walk both
        // floor-divide and agree with each other, and a real head at that size
        // lays its cells out differently. The total-count check only catches
        // that when the totals differ; when they coincide every box lands in
        // the wrong cell, which is wrong coordinates with nothing on stderr.
        let err = check_grid_divides_input(grid, InputSize { w: 640, h: 350 })
            .unwrap_err()
            .to_string();
        assert!(err.contains("640x350"), "{err}");
        assert!(err.contains("32"), "{err}");

        // the sizes that matter still pass
        for size in [YOLOX_416, SQUARE, TINY, InputSize { w: 640, h: 384 }] {
            assert!(check_grid_divides_input(grid, size).is_ok(), "{size}");
        }
        // and no other layout has a grid to divide
        for layout in [Layout::EndToEnd, Layout::RawClasses { nc: 80 }] {
            assert!(check_grid_divides_input(layout, InputSize { w: 640, h: 350 }).is_ok());
        }
    }

    #[test]
    fn a_flag_contradicting_the_model_fails_at_startup() {
        let err = resolve_input_size(
            Some(InputSize::square(640)),
            Some(InputSize::square(320)),
            None,
            Path::new("m.onnx"),
        )
        .unwrap_err()
        .to_string();
        assert!(err.contains("640x640") && err.contains("320x320"), "{err}");
        // agreeing is not a contradiction
        assert!(resolve_input_size(Some(SQUARE), Some(SQUARE), None, Path::new("m.onnx")).is_ok());
    }
}
