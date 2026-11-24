//! The Rockchip board library's native half: one cdylib the BEAM loads as
//! `Cairn.Rockchip.Native`; the [`rknn`] backend; the [`mpp`] decoder binding
//! and the [`rga`] scaler, which blits into [`dma`] buffers held in a
//! [`pool`], all four driven by the `decoder` NIFs; and the probe binary that
//! runs `cairn-detect`'s CLI with that backend registered, or for
//! `--rk-probe` the decode, scale and infer [`probe`].
//!
//! The engine NIFs are `CairnOrt`'s surface over [`rknn::provider`]: same
//! functions, arities, schedulers, term shapes and `{reason, message}` errors,
//! because each one wraps the body `cairn-ort` exports — but for `init`, which
//! also takes the runtime's path. That crate is linked
//! with its own NIF entry off (`default-features = false`), so this library's
//! `rustler::init!` registers only the functions below and `decoder`'s, and
//! the resource types rustler collects binary-wide: `decoder`'s two, and
//! `cairn-ort`'s `EngineRef` and `StreamRef` with their deferred-teardown
//! destructors.
//!
//! No `cpu_baseline_ms`: the host measures the CPU baseline in a subprocess.

mod decoder;
pub mod dma;
pub mod mpp;
pub mod pool;
pub mod probe;
pub mod rga;
pub mod rknn;

use std::ffi::OsString;
use std::sync::Arc;
use std::time::Duration;

use cairn_ort::{
    guarded, Engine, EngineRef, FrameObservations, RawFrameMeta, RawInitConfig, RawInputSpec,
    RawStreamParams, Result, StreamRef,
};
use rustler::{Atom, Binary, Env, ResourceArc};

/// Load librknnrt and the artifact, once per VM. DirtyCpu, as `CairnOrt`'s:
/// `rknn_init` builds the NPU context.
///
/// `library` is the VM's `CAIRN_RKNN_LIBRARY`, which this library cannot read
/// itself ([`rknn::with_runtime`]); `nil` is the loader's search path. The one
/// argument `CairnOrt`'s `init/1` does not take: `Cairn.Rockchip.Native`'s
/// `init/1` adds it.
#[rustler::nif(schedule = "DirtyCpu")]
fn init(config: RawInitConfig, library: Option<String>) -> Result<ResourceArc<EngineRef>> {
    guarded("init", || {
        Ok(ResourceArc::new(EngineRef(Arc::new(open_engine(
            config, library,
        )?))))
    })
}

/// `init`'s body short of the resource, which needs the BEAM.
fn open_engine(config: RawInitConfig, library: Option<String>) -> Result<Engine> {
    let config = config.resolve()?;
    rknn::with_runtime(library.map(OsString::from), || {
        Engine::with_provider(config, &rknn::provider())
    })
}

#[rustler::nif]
fn engine_spec(engine: ResourceArc<EngineRef>) -> RawInputSpec {
    engine.0.input_spec.into()
}

#[rustler::nif(schedule = "DirtyCpu")]
fn open_stream(
    engine: ResourceArc<EngineRef>,
    stream_id: String,
    params: RawStreamParams,
) -> Result<ResourceArc<StreamRef>> {
    guarded("open_stream", || {
        Ok(ResourceArc::new(StreamRef::open(
            &engine.0, stream_id, params,
        )?))
    })
}

#[rustler::nif(schedule = "DirtyCpu")]
fn push_frame(
    stream: ResourceArc<StreamRef>,
    payload: Binary<'_>,
    meta: RawFrameMeta,
    time_base: (i32, i32),
) -> Result<(Vec<FrameObservations>, Vec<String>)> {
    guarded("push_frame", || {
        Ok((
            stream.push(meta.frame(payload.as_slice(), time_base))?,
            Vec::new(),
        ))
    })
}

#[rustler::nif(schedule = "DirtyIo")]
fn close_stream(stream: ResourceArc<StreamRef>) -> Result<bool> {
    guarded("close_stream", || Ok(stream.close()))
}

/// Drains this library's teardown queue, not `CairnOrt`'s: each cdylib has
/// its own.
#[rustler::nif(schedule = "DirtyIo")]
fn drain_teardown(timeout_ms: u64) -> bool {
    cairn_ort::teardown::drain(Duration::from_millis(timeout_ms))
}

/// `cairn_ort::CONTRACT` of the `cairn-ort` this was built on. The number
/// also covers the decoder surface and `DmaFrame`, which this crate's own
/// decoder produces, and reporting it checks neither.
#[rustler::nif]
fn contract() -> u32 {
    cairn_ort::CONTRACT
}

#[rustler::nif]
fn frame_meta_keys(env: Env<'_>) -> (Vec<Atom>, Vec<Atom>) {
    cairn_ort::frame_meta_atoms(env)
}

rustler::init!("Elixir.Cairn.Rockchip.Native", load = decoder::load);

#[cfg(test)]
mod tests {
    use super::*;
    use rustler::codegen_runtime::{inventory, ResourceRegistration};
    use rustler::SchedulerFlags;

    fn raw_config(backend: &str) -> RawInitConfig {
        RawInitConfig {
            model: "does/not/exist.rknn".into(),
            backend: backend.into(),
            model_profile: None,
            input_size: None,
            labels: None,
            allow_label_mismatch: false,
            embedder_model: None,
            qnn: cairn_ort::RawQnnOptions {
                library: None,
                soc_model: None,
                htp_arch: None,
                performance_mode: None,
                vtcm_mb: None,
            },
        }
    }

    fn refusal(config: RawInitConfig, library: Option<&str>) -> cairn_ort::NativeError {
        match open_engine(config, library.map(String::from)) {
            Ok(_) => panic!("the engine opened"),
            Err(error) => error,
        }
    }

    /// What this library's `rustler::init!` hands the BEAM, from the
    /// inventory it iterates: `CairnOrt`'s engine surface minus
    /// `cpu_baseline_ms` and with the runtime's path on `init`, none of
    /// `CairnOrt`'s own registrations, and the decoder's.
    #[test]
    fn the_nif_surface_is_the_engine_without_a_baseline_and_the_decoder() {
        let mut nifs: Vec<(String, u32, u32)> = inventory::iter::<rustler::Nif>()
            .map(|nif| {
                // SAFETY: `name` is the macro's NUL-terminated literal.
                let name = unsafe { std::ffi::CStr::from_ptr(nif.name) };
                (name.to_str().unwrap().to_string(), nif.arity, nif.flags)
            })
            .collect();
        nifs.sort();
        let (normal, cpu, io) = (
            SchedulerFlags::Normal as u32,
            SchedulerFlags::DirtyCpu as u32,
            SchedulerFlags::DirtyIo as u32,
        );
        let expected = [
            ("close_decoder", 1, io),
            ("close_stream", 1, io),
            ("contract", 0, normal),
            ("decode_au", 4, io),
            ("download", 1, cpu),
            ("drain_teardown", 1, io),
            ("engine_spec", 1, normal),
            ("frame_meta_keys", 0, normal),
            ("init", 2, cpu),
            ("open_decoder", 2, io),
            ("open_stream", 3, cpu),
            ("push_frame", 4, cpu),
            ("release", 1, io),
        ]
        .map(|(name, arity, flags)| (name.to_string(), arity, flags));
        assert_eq!(nifs, expected);
        // `cairn-ort`'s `EngineRef` and `StreamRef` and the decoder's
        // `DecoderRef` and `LeaseRef`, all registered by this library's load.
        assert_eq!(inventory::iter::<ResourceRegistration>().count(), 4);
    }

    #[test]
    fn a_backend_this_library_does_not_run_is_config_before_any_load() {
        for backend in ["ort", "qnn"] {
            let error = refusal(raw_config(backend), None);
            assert_eq!(error.reason(), "config", "{backend}");
            assert!(
                error
                    .message()
                    .contains(&format!("runs rknn; backend {backend}")),
                "{error:?}"
            );
        }
    }

    /// The only test here that touches the environment, and `rknn`'s own tests
    /// never read it (they load stubs through `RknnBackend::with_library`).
    /// The path `init` is handed wins over the process's variable, which in the
    /// VM never holds what the base's artifact store set; `None` does not
    /// consult it either, and outside `with_runtime` it is what is read.
    #[test]
    fn a_missing_runtime_is_a_model_load_term() {
        let library = "/does/not/exist/librknnrt.so";
        let ignored = "/not/this/one/librknnrt.so";
        std::env::set_var("CAIRN_RKNN_LIBRARY", ignored);
        let error = refusal(raw_config("rknn"), Some(library));
        let default = rknn::with_runtime(None, rknn::runtime);
        let outside = rknn::runtime();
        std::env::remove_var("CAIRN_RKNN_LIBRARY");
        assert_eq!(default, "librknnrt.so");
        assert_eq!(outside, ignored);
        assert_eq!(error.reason(), "model_load");
        assert!(error.message().contains(library), "{error:?}");
        assert!(!error.message().contains(ignored), "{error:?}");
    }
}
