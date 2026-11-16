//! The `rknn` backend: one `.rknn` artifact on the Rockchip NPU through
//! librknnrt, which is opened at run time ([`sys::Library::load`]) and never
//! linked.
//!
//! No test here calls librknnrt itself: there is no NPU and no library on x86
//! or in CI. The tests cover the struct layouts (as compile-time assertions),
//! the mapping from tensor attrs to [`ModelIo`], the input check, the loader's
//! failure paths, and the call sequence and output-buffer guard over stub
//! entry points. The board run is the proof of the runtime.
//!
//! The artifact folds its normalisation and quantisation in, so it takes the
//! frame's own bytes ([`InputElement::U8Pixels`]), NHWC; the runtime hands
//! back dequantized f32 outputs (`want_float`), so nothing is listed in
//! [`ModelIo::u8_outputs`].
//!
//! Which channel order and scale an artifact folds in is fixed at conversion
//! ("Input conventions" in `tools/rknn-export/README.md`) and nothing queried
//! here reports it: a profile whose encoding is not the artifact's opens
//! cleanly and detects badly.

pub mod sys;

use std::ffi::{c_int, c_void, OsString};
use std::path::Path;
use std::ptr;

use anyhow::{bail, Context as _, Result};
use cairn_detect::cli::Provider;
use cairn_detect::infer::{
    Backend, BackendKind, Declared, InputElement, InputSize, InputTensor, ModelIo, Raw,
    SessionOptions, TensorLayout, TensorValues, Tensors,
};

/// `CAIRN_RKNN_LIBRARY` names the runtime to load; unset, the loader's search
/// path finds this one.
const DEFAULT_LIBRARY: &str = "librknnrt.so";

/// `--backend rknn` for [`cairn_detect::cli::run`].
pub fn provider() -> Provider {
    Provider {
        kind: BackendKind::Rknn,
        open: |model, options| Ok(Box::new(RknnBackend::open(model, options)?)),
    }
}

fn check(call: &str, code: c_int) -> Result<()> {
    if code != 0 {
        bail!("{call} returned {code} ({})", sys::code_name(code));
    }
    Ok(())
}

/// One live `rknn_context`, destroyed on drop.
struct Session {
    library: sys::Library,
    ctx: sys::Context,
    /// The artifact bytes `rknn_init` was handed. rk.py keeps its copy for the
    /// context's lifetime and the API does not say the runtime copies it, so
    /// this one is freed only after `rknn_destroy`.
    _model: Vec<u8>,
}

impl Session {
    /// # Safety
    /// `T` must be the struct `cmd` writes.
    unsafe fn query<T>(&self, cmd: c_int, info: &mut T) -> Result<()> {
        let size = std::mem::size_of::<T>() as u32;
        // SAFETY: `ctx` is live, and `info` is a `T` of `size` bytes, the
        // struct the caller vouches `cmd` fills.
        let code = unsafe { (self.library.query)(self.ctx, cmd, ptr::from_mut(info).cast(), size) };
        check(&format!("rknn_query({cmd})"), code)
    }

    fn input_attr(&self, index: u32) -> Result<sys::TensorAttr> {
        // SAFETY: the input-attr command fills a tensor attr.
        unsafe { self.attr(sys::QUERY_INPUT_ATTR, index) }
    }

    fn output_attr(&self, index: u32) -> Result<sys::TensorAttr> {
        // SAFETY: the output-attr command fills a tensor attr.
        unsafe { self.attr(sys::QUERY_OUTPUT_ATTR, index) }
    }

    /// # Safety
    /// `cmd` must be a command that fills a tensor attr.
    unsafe fn attr(&self, cmd: c_int, index: u32) -> Result<sys::TensorAttr> {
        let mut attr = sys::TensorAttr::zeroed();
        attr.index = index;
        // SAFETY: the caller vouches `cmd` fills a tensor attr.
        unsafe { self.query(cmd, &mut attr) }?;
        Ok(attr)
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        // SAFETY: `ctx` came from a successful `rknn_init` and is destroyed
        // once, here; no output borrowed from it outlives the backend.
        let code = unsafe { (self.library.destroy)(self.ctx) };
        if code != 0 {
            cairn_detect::note!(
                "rknn: rknn_destroy returned {code} ({})",
                sys::code_name(code)
            );
        }
    }
}

/// An output as the run serves it.
struct OutputMeta {
    name: String,
    dims: Vec<i64>,
    elems: usize,
}

/// `Send` with no `unsafe impl`, because it stores no raw pointer: the
/// context is an integer handle, and a run's output pointers live in the
/// `RunOutputs` that borrows it.
pub struct RknnBackend {
    session: Session,
    io: ModelIo,
    input_size: InputSize,
    outputs: Vec<OutputMeta>,
}

impl Backend for RknnBackend {
    fn open(model: &Path, options: &SessionOptions) -> Result<Self> {
        let path = std::env::var_os("CAIRN_RKNN_LIBRARY")
            .unwrap_or_else(|| OsString::from(DEFAULT_LIBRARY));
        Self::with_library(sys::Library::load(&path)?, model, options)
    }

    fn kind(&self) -> BackendKind {
        BackendKind::Rknn
    }

    fn io(&self) -> &ModelIo {
        &self.io
    }

    fn run(&mut self, mut input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
        let bytes = check_input(&mut input, self.input_size)?;
        let (library, ctx) = (&self.session.library, self.session.ctx);
        let size = u32::try_from(bytes.len()).context("rknn input over 4 GiB")?;
        let mut set = sys::Input {
            index: 0,
            buf: bytes.as_mut_ptr().cast(),
            size,
            pass_through: 0,
            type_: sys::TENSOR_UINT8,
            fmt: sys::TENSOR_NHWC,
        };
        // SAFETY: one input, as `ctx` was checked to have at open; `buf` is
        // `size` bytes this function owns until it returns, so they outlive
        // `rknn_run` too, should the runtime read them there.
        check("rknn_inputs_set", unsafe {
            (library.inputs_set)(ctx, 1, &mut set)
        })?;
        // SAFETY: `ctx` is live; a null extend is the blocking run.
        check("rknn_run", unsafe { (library.run)(ctx, ptr::null_mut()) })?;

        let mut outs: Vec<sys::Output> = (0..self.outputs.len() as u32)
            .map(|index| sys::Output {
                want_float: 1,
                is_prealloc: 0,
                index,
                buf: ptr::null_mut(),
                size: 0,
            })
            .collect();
        // SAFETY: `outs` is one entry per output the context reported.
        check("rknn_outputs_get", unsafe {
            (library.outputs_get)(ctx, outs.len() as u32, outs.as_mut_ptr(), ptr::null_mut())
        })?;
        // From here the runtime owns buffers only `rknn_outputs_release`
        // frees, so the guard that calls it exists before anything can fail.
        // A failed `rknn_outputs_get` builds no guard and releases nothing,
        // as rk.py does: whether the runtime hands back anything to free on
        // that path is not documented.
        let run = RunOutputs {
            backend: self,
            outs,
        };
        for (out, meta) in run.outs.iter().zip(&run.backend.outputs) {
            if out.buf.is_null() {
                bail!(
                    "rknn_outputs_get returned no buffer for output {:?}",
                    meta.name
                );
            }
            if !(out.buf as usize).is_multiple_of(std::mem::align_of::<f32>()) {
                bail!(
                    "rknn_outputs_get returned a misaligned buffer for output {:?}",
                    meta.name
                );
            }
            if meta.elems.checked_mul(4) != Some(out.size as usize) {
                bail!(
                    "rknn_outputs_get returned {} bytes for output {:?}, whose {:?} is {} f32 values",
                    out.size,
                    meta.name,
                    meta.dims,
                    meta.elems
                );
            }
        }
        Ok(Box::new(run))
    }
}

impl RknnBackend {
    /// [`Backend::open`] over a runtime already loaded, so the environment is
    /// read in one place.
    pub fn with_library(
        library: sys::Library,
        model: &Path,
        options: &SessionOptions,
    ) -> Result<Self> {
        let mut bytes = std::fs::read(model)
            .with_context(|| format!("reading artifact {}", model.display()))?;
        let len = u32::try_from(bytes.len())
            .with_context(|| format!("artifact {} is over 4 GiB", model.display()))?;
        let mut ctx: sys::Context = 0;
        // SAFETY: `bytes` is `len` bytes and outlives the context (it moves
        // into the `Session` that destroys it); flag 0 and a null extend are
        // rk.py's call.
        check("rknn_init", unsafe {
            (library.init)(
                &mut ctx,
                bytes.as_mut_ptr().cast::<c_void>(),
                len,
                0,
                ptr::null_mut(),
            )
        })
        .with_context(|| format!("loading artifact {}", model.display()))?;
        let session = Session {
            library,
            ctx,
            _model: bytes,
        };

        if let Some(mask) = options.rknn.core_mask {
            let mask = c_int::try_from(mask).with_context(|| format!("core mask {mask:#x}"))?;
            // SAFETY: `ctx` is live; the mask is a plain value.
            check("rknn_set_core_mask", unsafe {
                (session.library.set_core_mask)(session.ctx, mask)
            })?;
        }

        let mut sdk = sys::SdkVersion::zeroed();
        // SAFETY: the SDK-version command fills an `SdkVersion`.
        unsafe { session.query(sys::QUERY_SDK_VERSION, &mut sdk) }?;
        cairn_detect::note!(
            "rknn: api {} driver {}, core mask {}",
            c_text(&sdk.api_version),
            c_text(&sdk.drv_version),
            options
                .rknn
                .core_mask
                .map_or("runtime default".to_string(), |mask| format!("{mask:#x}"))
        );
        let mut num = sys::IoNum::default();
        // SAFETY: the in/out-count command fills an `IoNum`.
        unsafe { session.query(sys::QUERY_IN_OUT_NUM, &mut num) }?;
        if num.n_input != 1 || num.n_output == 0 {
            bail!(
                "artifact {} has {} inputs and {} outputs; a detector takes one input and \
                 reads at least one output",
                model.display(),
                num.n_input,
                num.n_output
            );
        }
        let input = session.input_attr(0)?;
        let outputs = (0..num.n_output)
            .map(|index| session.output_attr(index))
            .collect::<Result<Vec<_>>>()?;
        let (io, input_size, outputs) = model_io(model, &input, &outputs)?;
        Ok(Self {
            session,
            io,
            input_size,
            outputs,
        })
    }
}

/// A run's outputs, in the runtime's buffers until drop releases them.
struct RunOutputs<'a> {
    backend: &'a RknnBackend,
    outs: Vec<sys::Output>,
}

impl Tensors for RunOutputs<'_> {
    fn get(&self, name: &str) -> Result<Raw<'_>> {
        let index = self
            .backend
            .outputs
            .iter()
            .position(|meta| meta.name == name)
            .with_context(|| format!("the artifact has no output {name:?}"))?;
        let meta = &self.backend.outputs[index];
        // SAFETY: `run` checked this buffer is non-null, f32-aligned and
        // exactly `elems` f32s before building `self`, and the runtime keeps
        // it until `rknn_outputs_release`, which only drop calls — and drop
        // cannot run while this borrow of `self` lives.
        let values =
            unsafe { std::slice::from_raw_parts(self.outs[index].buf as *const f32, meta.elems) };
        Ok(Raw {
            dims: meta.dims.clone(),
            values,
        })
    }
}

impl Drop for RunOutputs<'_> {
    fn drop(&mut self) {
        let session = &self.backend.session;
        // SAFETY: `outs` is exactly what a successful `rknn_outputs_get`
        // filled, released once, here.
        let code = unsafe {
            (session.library.outputs_release)(
                session.ctx,
                self.outs.len() as u32,
                self.outs.as_mut_ptr(),
            )
        };
        if code != 0 {
            cairn_detect::note!(
                "rknn: rknn_outputs_release returned {code} ({})",
                sys::code_name(code)
            );
        }
    }
}

/// The text of a fixed `char` array, which a foreign runtime may leave
/// without its NUL.
fn c_text(bytes: &[u8]) -> String {
    let end = bytes.iter().position(|&b| b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// An attr's dims, refusing a rank its own array cannot hold.
fn attr_dims(attr: &sys::TensorAttr) -> Result<&[u32]> {
    attr.dims.get(..attr.n_dims as usize).with_context(|| {
        format!(
            "tensor {:?} reports {} dims, more than {}",
            c_text(&attr.name),
            attr.n_dims,
            sys::MAX_DIMS
        )
    })
}

/// What the artifact's attrs say, as [`ModelIo`] and the geometry the run
/// checks against.
fn model_io(
    model: &Path,
    input: &sys::TensorAttr,
    outputs: &[sys::TensorAttr],
) -> Result<(ModelIo, InputSize, Vec<OutputMeta>)> {
    let artifact = model.display();
    if input.fmt != sys::TENSOR_NHWC || input.type_ != sys::TENSOR_INT8 {
        bail!(
            "artifact {artifact} takes {} {} input; this backend feeds NHWC INT8 artifacts \
             (rknn-toolkit2 quantized, mean/std folded in)",
            sys::format_name(input.fmt),
            sys::type_name(input.type_)
        );
    }
    let size = match *attr_dims(input)? {
        [1, h, w, 3] if h > 0 && w > 0 => InputSize {
            w: w as usize,
            h: h as usize,
        },
        ref dims => bail!("artifact {artifact} input is {dims:?}; this backend feeds [1, H, W, 3]"),
    };
    let outputs = outputs
        .iter()
        .map(|attr| {
            let name = c_text(&attr.name);
            let dims: Vec<i64> = attr_dims(attr)?.iter().map(|&d| i64::from(d)).collect();
            if dims.is_empty() || dims.contains(&0) {
                bail!("artifact {artifact} output {name:?} is {dims:?}");
            }
            let elems = dims
                .iter()
                .try_fold(1usize, |n, &d| n.checked_mul(d as usize))
                .with_context(|| format!("artifact {artifact} output {name:?} is {dims:?}"))?;
            Ok(OutputMeta { name, dims, elems })
        })
        .collect::<Result<Vec<_>>>()?;
    let io = ModelIo {
        input_name: c_text(&input.name),
        declared_input_size: Some(size),
        declared_input_batch: Some(1),
        outputs: outputs
            .iter()
            .map(|meta| Declared {
                name: meta.name.clone(),
                dims: Some(meta.dims.clone()),
            })
            .collect(),
        input_element: InputElement::U8Pixels,
        u8_outputs: Vec::new(),
        input_layout: TensorLayout::Nhwc,
    };
    Ok((io, size, outputs))
}

/// The one input shape this artifact takes, checked here because librknnrt
/// does not: handed NCHW uint8 through `rknn_inputs_set` it returns 0 and
/// runs the previous frame again (observed on the board).
fn check_input(input: &mut InputTensor, size: InputSize) -> Result<&mut [u8]> {
    let want = [1, size.h as i64, size.w as i64, 3];
    if input.layout != TensorLayout::Nhwc || input.shape != want {
        bail!(
            "rknn input must be NHWC {want:?}, got {:?} {:?}",
            input.layout,
            input.shape
        );
    }
    let TensorValues::U8(bytes) = &mut input.values else {
        bail!("rknn input must be u8 pixel bytes, got f32");
    };
    if bytes.len() != size.tensor_len() {
        bail!(
            "rknn input must be {} bytes, got {}",
            size.tensor_len(),
            bytes.len()
        );
    }
    Ok(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicI32, AtomicU32, AtomicUsize, Ordering::SeqCst};
    use std::sync::{Mutex, MutexGuard};

    fn attr(fmt: c_int, type_: c_int, dims: &[u32], name: &[u8]) -> sys::TensorAttr {
        let mut attr = sys::TensorAttr::zeroed();
        attr.fmt = fmt;
        attr.type_ = type_;
        attr.n_dims = dims.len() as u32;
        attr.dims[..dims.len()].copy_from_slice(dims);
        attr.name[..name.len()].copy_from_slice(name);
        attr
    }

    fn input(dims: &[u32]) -> sys::TensorAttr {
        attr(sys::TENSOR_NHWC, sys::TENSOR_INT8, dims, b"images\0")
    }

    fn output(name: &[u8], dims: &[u32]) -> sys::TensorAttr {
        attr(sys::TENSOR_NCHW, sys::TENSOR_FLOAT16, dims, name)
    }

    fn err<T>(result: Result<T>) -> String {
        match result {
            Ok(_) => panic!("accepted"),
            Err(err) => format!("{err:#}"),
        }
    }

    #[test]
    fn attrs_map_to_a_pixel_byte_nhwc_model_io() {
        let outs = [
            output(b"dets\0", &[1, 300, 4]),
            output(b"labels\0", &[1, 300, 91]),
        ];
        let (io, size, metas) =
            model_io(Path::new("m.rknn"), &input(&[1, 384, 640, 3]), &outs).unwrap();
        assert_eq!(size, InputSize { w: 640, h: 384 });
        assert_eq!(io.input_name, "images");
        assert_eq!(io.declared_input_size, Some(size));
        assert_eq!(io.declared_input_batch, Some(1));
        assert_eq!(io.input_element, InputElement::U8Pixels);
        assert_eq!(io.input_layout, TensorLayout::Nhwc);
        assert!(io.u8_outputs.is_empty());
        // The model's own order, which a single-output layout reads from.
        let names: Vec<_> = io.outputs.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(names, ["dets", "labels"]);
        assert_eq!(io.outputs[1].dims, Some(vec![1, 300, 91]));
        assert_eq!(metas[1].elems, 300 * 91);
    }

    #[test]
    fn an_input_that_is_not_nhwc_int8_is_refused_by_what_it_is() {
        let outs = [output(b"output\0", &[1, 84, 85])];
        let nchw = attr(sys::TENSOR_NCHW, sys::TENSOR_INT8, &[1, 3, 64, 64], b"x\0");
        let msg = err(model_io(Path::new("m.rknn"), &nchw, &outs));
        assert!(msg.contains("m.rknn") && msg.contains("NCHW INT8"), "{msg}");
        let fp16 = attr(
            sys::TENSOR_NHWC,
            sys::TENSOR_FLOAT16,
            &[1, 64, 64, 3],
            b"x\0",
        );
        let msg = err(model_io(Path::new("m.rknn"), &fp16, &outs));
        assert!(msg.contains("NHWC FP16"), "{msg}");
        for dims in [
            &[1, 64, 64][..],
            &[1, 64, 64, 4],
            &[2, 64, 64, 3],
            &[1, 0, 64, 3],
        ] {
            let msg = err(model_io(Path::new("m.rknn"), &input(dims), &outs));
            assert!(msg.contains("[1, H, W, 3]"), "{dims:?}: {msg}");
        }
    }

    /// Attrs come from a foreign runtime: nonsense in them is an error, not a
    /// panic.
    #[test]
    fn malformed_attrs_are_errors() {
        let good_in = input(&[1, 64, 64, 3]);
        let mut deep = input(&[1, 64, 64, 3]);
        deep.n_dims = 17;
        assert!(err(model_io(Path::new("m.rknn"), &deep, &[])).contains("17 dims"));

        let mut deep = output(b"o\0", &[1, 84, 85]);
        deep.n_dims = u32::MAX;
        assert!(err(model_io(Path::new("m.rknn"), &good_in, &[deep])).contains("dims"));
        let zero = output(b"o\0", &[1, 0, 85]);
        assert!(err(model_io(Path::new("m.rknn"), &good_in, &[zero])).contains("\"o\""));
        let rankless = output(b"o\0", &[]);
        assert!(err(model_io(Path::new("m.rknn"), &good_in, &[rankless])).contains("\"o\""));

        // A name filling its array with no NUL is read to the end.
        let unterminated = output(&[b'a'; sys::MAX_NAME_LEN], &[1, 84, 85]);
        let (io, ..) = model_io(Path::new("m.rknn"), &good_in, &[unterminated]).unwrap();
        assert_eq!(io.outputs[0].name, "a".repeat(sys::MAX_NAME_LEN));
    }

    #[test]
    fn only_nhwc_u8_bytes_of_the_opened_size_pass_the_input_check() {
        let size = InputSize { w: 6, h: 4 };
        let bytes = || TensorValues::U8(vec![0; 6 * 4 * 3]);
        let mut ok = InputTensor::new(size, TensorLayout::Nhwc, bytes());
        assert_eq!(check_input(&mut ok, size).unwrap().len(), 72);

        let mut nchw = InputTensor::new(size, TensorLayout::Nchw, bytes());
        assert!(err(check_input(&mut nchw, size)).contains("NHWC"));
        let mut swapped = InputTensor::new(InputSize { w: 4, h: 6 }, TensorLayout::Nhwc, bytes());
        assert!(err(check_input(&mut swapped, size)).contains("NHWC"));
        let mut short = InputTensor::new(size, TensorLayout::Nhwc, TensorValues::U8(vec![0; 71]));
        assert!(err(check_input(&mut short, size)).contains("72 bytes"));
        let mut float =
            InputTensor::new(size, TensorLayout::Nhwc, TensorValues::F32(vec![0.0; 72]));
        assert!(err(check_input(&mut float, size)).contains("f32"));
    }

    // The stubs' counters and knobs are process-global, so every test using
    // them holds `STUBS` for its whole body.
    static STUBS: Mutex<()> = Mutex::new(());
    static RELEASED: AtomicUsize = AtomicUsize::new(0);
    static DESTROYED: AtomicUsize = AtomicUsize::new(0);
    static N_INPUT: AtomicU32 = AtomicU32::new(1);
    static N_OUTPUT: AtomicU32 = AtomicU32::new(1);
    static OUT_BYTES: AtomicU32 = AtomicU32::new(24);
    static RUN_CODE: AtomicI32 = AtomicI32::new(0);
    static OUT_VALUES: [f32; 6] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0];

    fn stubs() -> MutexGuard<'static, ()> {
        let guard = STUBS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        RELEASED.store(0, SeqCst);
        DESTROYED.store(0, SeqCst);
        N_INPUT.store(1, SeqCst);
        N_OUTPUT.store(1, SeqCst);
        OUT_BYTES.store(24, SeqCst);
        RUN_CODE.store(0, SeqCst);
        guard
    }

    unsafe extern "C" fn stub_init(
        ctx: *mut sys::Context,
        _: *mut c_void,
        _: u32,
        _: u32,
        _: *mut c_void,
    ) -> c_int {
        // SAFETY: `with_library` passes the address of a live `Context`.
        unsafe { *ctx = 7 };
        0
    }

    unsafe extern "C" fn stub_destroy(_: sys::Context) -> c_int {
        DESTROYED.fetch_add(1, SeqCst);
        0
    }

    unsafe extern "C" fn stub_query(
        _: sys::Context,
        cmd: c_int,
        info: *mut c_void,
        _: u32,
    ) -> c_int {
        // SAFETY: `Session::query` passes a live struct of the type `cmd`
        // fills, which is the one written here.
        unsafe {
            match cmd {
                sys::QUERY_SDK_VERSION => {
                    let mut sdk = sys::SdkVersion::zeroed();
                    sdk.api_version[..3].copy_from_slice(b"1.0");
                    sdk.drv_version[..3].copy_from_slice(b"2.0");
                    *info.cast() = sdk;
                }
                sys::QUERY_IN_OUT_NUM => {
                    *info.cast() = sys::IoNum {
                        n_input: N_INPUT.load(SeqCst),
                        n_output: N_OUTPUT.load(SeqCst),
                    };
                }
                sys::QUERY_INPUT_ATTR => *info.cast() = input(&[1, 4, 6, 3]),
                sys::QUERY_OUTPUT_ATTR => *info.cast() = output(b"output\0", &[1, 2, 3]),
                _ => return -1,
            }
        }
        0
    }

    unsafe extern "C" fn stub_inputs_set(_: sys::Context, _: u32, _: *mut sys::Input) -> c_int {
        0
    }

    unsafe extern "C" fn stub_run(_: sys::Context, _: *mut c_void) -> c_int {
        RUN_CODE.load(SeqCst)
    }

    unsafe extern "C" fn stub_outputs_get(
        _: sys::Context,
        _: u32,
        outs: *mut sys::Output,
        _: *mut c_void,
    ) -> c_int {
        // SAFETY: `run` passes one live `Output` for the one output reported.
        unsafe {
            (*outs).buf = ptr::from_ref(&OUT_VALUES).cast_mut().cast();
            (*outs).size = OUT_BYTES.load(SeqCst);
        }
        0
    }

    unsafe extern "C" fn stub_outputs_release(
        _: sys::Context,
        _: u32,
        _: *mut sys::Output,
    ) -> c_int {
        RELEASED.fetch_add(1, SeqCst);
        0
    }

    unsafe extern "C" fn stub_set_core_mask(_: sys::Context, _: c_int) -> c_int {
        0
    }

    fn open_stub(tag: &str) -> Result<RknnBackend> {
        let path =
            std::env::temp_dir().join(format!("rknn-stub-{}-{tag}.rknn", std::process::id()));
        std::fs::write(&path, b"stub").unwrap();
        let library = sys::Library {
            init: stub_init,
            destroy: stub_destroy,
            query: stub_query,
            inputs_set: stub_inputs_set,
            run: stub_run,
            outputs_get: stub_outputs_get,
            outputs_release: stub_outputs_release,
            set_core_mask: stub_set_core_mask,
        };
        let opened = RknnBackend::with_library(library, &path, &SessionOptions::default());
        std::fs::remove_file(&path).unwrap();
        opened
    }

    fn frame() -> InputTensor {
        let size = InputSize { w: 6, h: 4 };
        InputTensor::new(size, TensorLayout::Nhwc, TensorValues::U8(vec![0; 72]))
    }

    #[test]
    fn a_run_serves_the_outputs_and_releases_them_once_on_drop() {
        let _guard = stubs();
        let mut backend = open_stub("happy").unwrap();
        let outputs = backend.run(frame()).unwrap();
        assert_eq!(RELEASED.load(SeqCst), 0);
        let raw = outputs.get("output").unwrap();
        assert_eq!(raw.dims, [1, 2, 3]);
        assert_eq!(raw.values, OUT_VALUES);
        assert!(err(outputs.get("missing")).contains("no output \"missing\""));
        drop(outputs);
        assert_eq!(RELEASED.load(SeqCst), 1);
        assert_eq!(DESTROYED.load(SeqCst), 0);
        drop(backend);
        assert_eq!(DESTROYED.load(SeqCst), 1);
    }

    #[test]
    fn a_wrong_sized_output_buffer_is_refused_and_still_released() {
        let _guard = stubs();
        let mut backend = open_stub("size").unwrap();
        OUT_BYTES.store(20, SeqCst);
        let msg = err(backend.run(frame()));
        assert!(
            msg.contains("20 bytes") && msg.contains("\"output\""),
            "{msg}"
        );
        assert_eq!(RELEASED.load(SeqCst), 1);
    }

    #[test]
    fn a_failed_rknn_run_is_named_and_releases_nothing() {
        let _guard = stubs();
        let mut backend = open_stub("run").unwrap();
        RUN_CODE.store(-1, SeqCst);
        let msg = err(backend.run(frame()));
        assert!(
            msg.contains("rknn_run returned -1 (RKNN_ERR_FAIL)"),
            "{msg}"
        );
        assert_eq!(RELEASED.load(SeqCst), 0);
    }

    #[test]
    fn an_artifact_that_is_not_one_in_n_out_is_refused_and_destroyed() {
        let _guard = stubs();
        for (n_input, n_output, what) in [(2, 1, "2 inputs"), (1, 0, "0 outputs")] {
            N_INPUT.store(n_input, SeqCst);
            N_OUTPUT.store(n_output, SeqCst);
            DESTROYED.store(0, SeqCst);
            let msg = err(open_stub("io"));
            assert!(msg.contains(what), "{msg}");
            assert_eq!(DESTROYED.load(SeqCst), 1, "{what}");
        }
    }
}
