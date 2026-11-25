//! The `rknn` backend: one `.rknn` artifact on the Rockchip NPU through
//! librknnrt, which is opened at run time ([`sys::Library::load`]) and never
//! linked.
//!
//! No test here calls librknnrt itself: there is no NPU and no library on x86
//! or in CI. The tests cover the struct layouts (as compile-time assertions),
//! the mapping from tensor attrs to [`ModelIo`], the input check, the loader's
//! failure paths, the artifact refusals (empty, not a regular file), and the
//! call sequence, the input descriptor, the output-buffer guard and the input
//! mems' binding, refusals and teardown over stub entry points. The board run
//! is the proof of the runtime.
//!
//! The steps [`Backend::run`] is made of, and the input mems
//! ([`RknnBackend::bind_input`]), are public for the probe's `--infer`, which
//! times them one by one; the NIF reaches the steps only through
//! [`Backend::run`] and never binds an input mem.
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

use std::cell::RefCell;
use std::ffi::{c_int, c_void, OsString};
use std::io::Read as _;
use std::os::fd::{BorrowedFd, RawFd};
use std::path::Path;
use std::ptr::{self, NonNull};

use anyhow::{bail, Context as _, Result};
use cairn_detect::infer::{
    Backend, Capabilities, Declared, Descriptor, InputElement, InputSize, InputTensor, ModelIo,
    Provider, Raw, SessionOptions, TensorLayout, TensorValues, Tensors,
};

/// The runtime the loader's search path finds when nothing names one: no
/// [`with_runtime`] path and no `CAIRN_RKNN_LIBRARY`.
const DEFAULT_LIBRARY: &str = "librknnrt.so";

thread_local! {
    /// The runtime [`with_runtime`] names for the opens on this thread.
    static LIBRARY: RefCell<Option<OsString>> = const { RefCell::new(None) };
}

/// Runs `open` with `library` as the runtime every [`RknnBackend::open`] it
/// makes on the calling thread loads, `librknnrt.so` from the search path for
/// `None`, in place of `CAIRN_RKNN_LIBRARY`.
///
/// For the NIF, which cannot read the variable: the BEAM keeps its own copy of
/// the environment and does not write it back to libc's, so a path the VM set
/// is not in `std::env`. The VM's value arrives as an argument instead. A
/// process of its own, like the probe binary, reads its real environment.
pub fn with_runtime<T>(library: Option<OsString>, open: impl FnOnce() -> T) -> T {
    struct Restore(Option<OsString>);

    impl Drop for Restore {
        fn drop(&mut self) {
            LIBRARY.set(self.0.take());
        }
    }

    let library = library.unwrap_or_else(|| OsString::from(DEFAULT_LIBRARY));
    let _restore = Restore(LIBRARY.replace(Some(library)));
    open()
}

/// The runtime [`RknnBackend::open`] loads on this thread.
pub(crate) fn runtime() -> OsString {
    LIBRARY
        .with_borrow(Clone::clone)
        .or_else(|| std::env::var_os("CAIRN_RKNN_LIBRARY"))
        .unwrap_or_else(|| OsString::from(DEFAULT_LIBRARY))
}

/// This backend as `Cairn.Rockchip.Board.backends/0` mirrors it.
///
/// Dynamic shapes: rknn-toolkit2 compiles to a fixed input geometry, so there
/// is nothing to leave dynamic. Fused NMS is the conservative reading:
/// `docs/npu-backends.md` establishes the ban for QNN only, and no source it
/// cites puts an NMS op on the RKNN NPU either. Refusing an export we may not
/// be able to run costs an operator a profile edit; accepting one that
/// silently does not run costs a deployment.
static RKNN: Descriptor = Descriptor {
    name: "rknn",
    capabilities: Capabilities {
        supports_fused_nms: false,
        supports_dynamic_shapes: false,
        artifact: ".rknn",
    },
};

/// `--backend rknn` for [`cairn_detect::cli::run`].
pub fn provider() -> Provider {
    Provider {
        descriptor: &RKNN,
        open: |model, options| Ok(Box::new(RknnBackend::open(model, options)?)),
    }
}

fn check(call: &str, code: c_int) -> Result<()> {
    if code != 0 {
        bail!("{call} returned {code} ({})", sys::code_name(code));
    }
    Ok(())
}

/// A mem descriptor the runtime returned on a [`Session`]'s context.
struct MemPtr(NonNull<sys::TensorMem>);

// SAFETY: the descriptor is only read, and handed back to the runtime, by
// calls on the context that owns it; `MemPtr` is not `Sync`, so neither is a
// `Session`, and no two threads hold a reference to it at once.
unsafe impl Send for MemPtr {}

/// One live `rknn_context` and the mems created on it, all destroyed on drop.
struct Session {
    library: sys::Library,
    ctx: sys::Context,
    mems: Vec<MemPtr>,
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
        // A mem is freed through its context, so the mems go first. One
        // exists only where the mem entry points loaded.
        if let Ok(api) = &self.library.mem {
            for mem in self.mems.drain(..) {
                // SAFETY: a mem the runtime returned on the live `ctx`,
                // destroyed once, here.
                let code = unsafe { (api.destroy_mem)(self.ctx, mem.0.as_ptr()) };
                if code != 0 {
                    cairn_detect::note!(
                        "rknn: rknn_destroy_mem returned {code} ({})",
                        sys::code_name(code)
                    );
                }
            }
        }
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

/// `Send` through `MemPtr`'s `unsafe impl` alone: the context is an
/// integer handle, and a run's output pointers live in the `RunOutputs` that
/// borrows it.
pub struct RknnBackend {
    session: Session,
    io: ModelIo,
    input_size: InputSize,
    outputs: Vec<OutputMeta>,
    /// The native input attr, queried at the first use.
    native: Option<sys::TensorAttr>,
    /// The last [`RknnBackend::set_input`]'s tensor, whose bytes the runtime
    /// was handed, until the next [`RknnBackend::infer`] takes it.
    held: Option<InputTensor>,
}

/// An input mem the backend created; it destroys every one before its
/// context.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InputMem(usize);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MemSync {
    ToDevice,
    FromDevice,
}

impl Backend for RknnBackend {
    fn open(model: &Path, _: &SessionOptions) -> Result<Self> {
        Self::with_library(sys::Library::load(&runtime())?, model)
    }

    fn descriptor(&self) -> &'static Descriptor {
        &RKNN
    }

    fn io(&self) -> &ModelIo {
        &self.io
    }

    fn run(&mut self, input: InputTensor) -> Result<Box<dyn Tensors + '_>> {
        self.set_input(input)?;
        // The API does not say when the runtime is done with the bytes, so
        // they live until the outputs are fetched.
        let _input = self.infer()?;
        self.outputs()
    }
}

impl RknnBackend {
    /// `rknn_inputs_set` with the frame's bytes. The API does not say the
    /// runtime has copied them by the time it returns, so the backend holds
    /// them until [`Self::infer`] takes them.
    pub fn set_input(&mut self, mut input: InputTensor) -> Result<()> {
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
        // `size` bytes of `input`, which `held` keeps until `infer` has
        // called `rknn_run` (moving the tensor does not move its bytes).
        check("rknn_inputs_set", unsafe {
            (library.inputs_set)(ctx, 1, &mut set)
        })?;
        self.held = Some(input);
        Ok(())
    }

    /// `rknn_run`, blocking. Takes the last [`Self::set_input`]'s tensor and
    /// hands it back when the run succeeds; a failed run drops it.
    pub fn infer(&mut self) -> Result<Option<InputTensor>> {
        let held = self.held.take();
        // SAFETY: `ctx` is live; a null extend is the blocking run.
        check("rknn_run", unsafe {
            (self.session.library.run)(self.session.ctx, ptr::null_mut())
        })?;
        Ok(held)
    }

    /// `rknn_outputs_get`, the buffers checked, released when the result
    /// drops.
    pub fn outputs(&mut self) -> Result<Box<dyn Tensors + '_>> {
        let (library, ctx) = (&self.session.library, self.session.ctx);
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
    /// [`Backend::open`] over a runtime already loaded, so the runtime's path
    /// is chosen in one place. No [`SessionOptions`]: none of it is this
    /// runtime's — the artifact folds its quantisation in and the runtime
    /// dequantizes its own outputs.
    pub fn with_library(library: sys::Library, model: &Path) -> Result<Self> {
        // An unbounded read of a stream or a growing file would exhaust a
        // board's memory, so the read is capped at the size the open file
        // reports.
        let reading = || format!("reading artifact {}", model.display());
        let too_big = || anyhow::anyhow!("artifact {} is over 4 GiB", model.display());
        let mut file = std::fs::File::open(model).with_context(reading)?;
        let metadata = file.metadata().with_context(reading)?;
        if !metadata.is_file() {
            bail!("artifact {} is not a regular file", model.display());
        }
        if u32::try_from(metadata.len()).is_err() {
            return Err(too_big());
        }
        let mut bytes = Vec::new();
        (&mut file)
            .take(metadata.len() + 1)
            .read_to_end(&mut bytes)
            .with_context(reading)?;
        if bytes.len() as u64 > metadata.len() {
            bail!("artifact {} grew while it was read", model.display());
        }
        // `rknn_init` reads `model` as a file path when size is 0.
        if bytes.is_empty() {
            bail!("artifact {} is empty", model.display());
        }
        let len = u32::try_from(bytes.len()).map_err(|_| too_big())?;
        let mut ctx: sys::Context = 0;
        // SAFETY: `bytes` is `len` bytes, non-zero (so `model` is read as
        // bytes, not a path), and outlives the context (it moves into the
        // `Session` that destroys it); flag 0 and a null extend are rk.py's
        // call.
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
            mems: Vec::new(),
            _model: bytes,
        };

        let mut sdk = sys::SdkVersion::zeroed();
        // SAFETY: the SDK-version command fills an `SdkVersion`.
        unsafe { session.query(sys::QUERY_SDK_VERSION, &mut sdk) }?;
        cairn_detect::note!(
            "rknn: api {} driver {}",
            c_text(&sdk.api_version),
            c_text(&sdk.drv_version),
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
            native: None,
            held: None,
        })
    }

    /// The input attr `rknn_query` reports for the NPU's own layout.
    pub fn native_input(&mut self) -> Result<sys::TensorAttr> {
        if let Some(attr) = self.native {
            return Ok(attr);
        }
        // SAFETY: the native-input-attr command fills a tensor attr.
        let attr = unsafe { self.session.attr(sys::QUERY_NATIVE_INPUT_ATTR, 0) }?;
        self.native = Some(attr);
        Ok(attr)
    }

    fn mem_api(&self) -> Result<&sys::MemApi> {
        self.session
            .library
            .mem
            .as_ref()
            .map_err(|missing| anyhow::anyhow!("{missing}"))
    }

    fn mem(&self, mem: InputMem) -> Result<NonNull<sys::TensorMem>> {
        let found = self.session.mems.get(mem.0).map(|m| m.0);
        found.with_context(|| format!("no input mem {}", mem.0))
    }

    /// The native input's `size_with_stride`, refused unless its rows are
    /// packed RGB888, as an RGA slot's are.
    fn packed_input(&mut self) -> Result<u32> {
        let attr = self.native_input()?;
        let InputSize { w, h } = self.input_size;
        let packed = w * h * 3;
        let row_ok = attr.w_stride == 0 || attr.w_stride as usize == w;
        if !row_ok || attr.size_with_stride as usize != packed {
            bail!(
                "the native input is not packed {w}x{h} RGB888: w_stride {} (want 0 or {w}), \
                 size_with_stride {} (want {packed})",
                attr.w_stride,
                attr.size_with_stride
            );
        }
        Ok(attr.size_with_stride)
    }

    /// Owns what `call` returned before checking it, so a mem refused here
    /// is still destroyed.
    fn keep(&mut self, call: &str, mem: *mut sys::TensorMem, size: u32) -> Result<InputMem> {
        let mem = NonNull::new(mem).with_context(|| format!("{call} returned no mem"))?;
        self.session.mems.push(MemPtr(mem));
        // SAFETY: a descriptor the runtime just returned, live until drop.
        let given = unsafe { mem.as_ref() }.size;
        if given < size {
            bail!("{call} returned a {given}-byte mem for a {size}-byte input");
        }
        Ok(InputMem(self.session.mems.len() - 1))
    }

    /// The dma-buf `fd`, mapped at `virt`, wrapped as an input mem
    /// (`rknn_create_mem_from_fd`).
    ///
    /// # Safety
    /// `fd` and a mapping of at least the input's size at `virt` must stay
    /// valid until the backend drops. The runtime is never asked to write an
    /// input, so the mapping may be read-only. Whether `rknn_destroy_mem`
    /// closes `fd` is not documented.
    pub unsafe fn import_input(&mut self, fd: RawFd, virt: *mut c_void) -> Result<InputMem> {
        let size = self.packed_input()?;
        let create = self.mem_api()?.create_mem_from_fd;
        // SAFETY: `ctx` is live; the caller vouches for `fd` and `virt`.
        let mem = unsafe { create(self.session.ctx, fd, virt, size, 0) };
        self.keep("rknn_create_mem_from_fd", mem, size)
    }

    /// An input mem the runtime allocates (`rknn_create_mem`).
    pub fn create_input(&mut self) -> Result<InputMem> {
        let size = self.packed_input()?;
        let create = self.mem_api()?.create_mem;
        // SAFETY: `ctx` is live; a size is all the call takes.
        let mem = unsafe { create(self.session.ctx, size) };
        self.keep("rknn_create_mem", mem, size)
    }

    /// `mem`'s dma-buf and the input's `size_with_stride`: for a
    /// [`Self::create_input`] mem the runtime's fd, for an imported one the
    /// caller's own. Valid while the backend lives, never to be closed here;
    /// dup it to keep it.
    pub fn input_fd(&self, mem: InputMem) -> Result<(BorrowedFd<'_>, usize)> {
        let ptr = self.mem(mem)?;
        // SAFETY: a live descriptor; mems are destroyed only on drop.
        let mem_ref = unsafe { ptr.as_ref() };
        let (fd, size) = (mem_ref.fd, self.native.map_or(0, |a| a.size_with_stride));
        if fd < 0 {
            bail!("input mem {} has no fd ({fd})", mem.0);
        }
        // SAFETY: the runtime's open descriptor, closed only by
        // `rknn_destroy_mem`, which runs on drop, after this borrow ends.
        Ok((unsafe { BorrowedFd::borrow_raw(fd) }, size as usize))
    }

    /// `rknn_set_io_mem` of `mem` as the input, typed UINT8 NHWC with no
    /// pass-through, as `zcin.py` bound it.
    pub fn bind_input(&mut self, mem: InputMem) -> Result<()> {
        let mut attr = self.native_input()?;
        attr.type_ = sys::TENSOR_UINT8;
        attr.fmt = sys::TENSOR_NHWC;
        attr.pass_through = 0;
        let (ptr, api) = (self.mem(mem)?, self.mem_api()?);
        // SAFETY: a live mem of the live `ctx` and a live attr, both read
        // during the call.
        check("rknn_set_io_mem", unsafe {
            (api.set_io_mem)(self.session.ctx, ptr.as_ptr(), &mut attr)
        })
    }

    /// `rknn_mem_sync` of `mem`.
    pub fn sync_input(&mut self, mem: InputMem, mode: MemSync) -> Result<()> {
        let mode = match mode {
            MemSync::ToDevice => sys::MEM_SYNC_TO_DEVICE,
            MemSync::FromDevice => sys::MEM_SYNC_FROM_DEVICE,
        };
        let (ptr, api) = (self.mem(mem)?, self.mem_api()?);
        // SAFETY: a live mem of the live `ctx`; the mode is a plain value.
        check("rknn_mem_sync", unsafe {
            (api.mem_sync)(self.session.ctx, ptr.as_ptr(), mode)
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
        // SAFETY: `outputs` checked this buffer is non-null, f32-aligned and
        // exactly `elems` f32s before returning `self`, and the runtime keeps
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
    use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU32, AtomicUsize, Ordering::SeqCst};
    use std::sync::{Mutex, MutexGuard};

    /// The descriptor's values, in the form `Cairn.Rockchip.Board.backends/0`
    /// mirrors; [`RKNN`]'s note says which are established and which are a
    /// conservative reading. A change here is a change to what a profile may
    /// declare, not a refactor.
    #[test]
    fn the_descriptor_pins_what_a_profile_may_declare() {
        assert_eq!(RKNN.name, "rknn");
        assert!(!RKNN.capabilities.supports_fused_nms);
        assert!(!RKNN.capabilities.supports_dynamic_shapes);
        assert_eq!(
            RKNN.capabilities.to_string(),
            "artifact=.rknn fused-nms=no dynamic-shapes=no"
        );
    }

    /// The probe binary's `--backend`, as the canary passes it: `rknn` is this
    /// provider and the core names stay the core's.
    #[test]
    fn the_provider_answers_its_own_name_and_no_other() {
        use cairn_detect::infer::{select, BackendKind, Selected};

        let providers = [provider()];
        assert!(matches!(
            select("rknn", &providers),
            Ok(Selected::Provided(p)) if std::ptr::eq(p.descriptor, &RKNN)
        ));
        assert!(matches!(
            select("ort", &providers),
            Ok(Selected::Core(BackendKind::Ort))
        ));
        let err = match select("tensorrt", &providers) {
            Ok(_) => panic!("an unknown name selected a backend"),
            Err(err) => err.to_string(),
        };
        assert!(err.ends_with("(rknn, ort, qnn)"), "{err}");
    }

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

    /// Without the environment, which `lib.rs`'s one test owns.
    #[test]
    fn with_runtime_names_the_runtime_and_restores_the_outer_one() {
        with_runtime(None, || {
            assert_eq!(runtime(), DEFAULT_LIBRARY);
            assert_eq!(with_runtime(Some("/inner.so".into()), runtime), "/inner.so");
            assert_eq!(runtime(), DEFAULT_LIBRARY);
        });
        assert_eq!(LIBRARY.with_borrow(Clone::clone), None);
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
    fn a_split_export_reports_its_nine_rank_four_outputs_in_order() {
        let names = [
            "box0", "cls0", "sum0", "box1", "cls1", "sum1", "box2", "cls2", "sum2",
        ];
        let channels = [64, 80, 1];
        let outs: Vec<_> = names
            .iter()
            .enumerate()
            .map(|(i, name)| {
                let side = 80 >> (i / 3);
                let text = format!("{name}\0");
                output(text.as_bytes(), &[1, channels[i % 3], side, side])
            })
            .collect();
        let (io, _, metas) =
            model_io(Path::new("m.rknn"), &input(&[1, 640, 640, 3]), &outs).unwrap();
        let got: Vec<_> = io.outputs.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(got, names);
        assert_eq!(io.outputs[3].dims, Some(vec![1, 64, 40, 40]));
        assert_eq!(io.outputs[8].dims, Some(vec![1, 1, 20, 20]));
        assert_eq!(metas[4].elems, 80 * 40 * 40);
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
    static INITS: AtomicUsize = AtomicUsize::new(0);
    static CALLS: Mutex<Vec<String>> = Mutex::new(Vec::new());
    static SET_INPUT: Mutex<Option<SetInput>> = Mutex::new(None);
    static NATIVE_W_STRIDE: AtomicU32 = AtomicU32::new(0);
    static NATIVE_SIZE: AtomicU32 = AtomicU32::new(72);
    static CREATE_NULL: AtomicBool = AtomicBool::new(false);
    static SET_IO_CODE: AtomicI32 = AtomicI32::new(0);
    static NEXT_FD: AtomicI32 = AtomicI32::new(0);
    static MEM_SHORT: AtomicU32 = AtomicU32::new(0);
    static OUT_VALUES: [f32; 6] = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0];

    struct SetInput {
        n_inputs: u32,
        index: u32,
        size: u32,
        pass_through: u8,
        type_: c_int,
        fmt: c_int,
        bytes: Vec<u8>,
    }

    fn call(name: impl Into<String>) {
        CALLS.lock().unwrap().push(name.into());
    }

    fn stubs() -> MutexGuard<'static, ()> {
        let guard = STUBS
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        RELEASED.store(0, SeqCst);
        DESTROYED.store(0, SeqCst);
        INITS.store(0, SeqCst);
        CALLS.lock().unwrap().clear();
        *SET_INPUT.lock().unwrap() = None;
        N_INPUT.store(1, SeqCst);
        N_OUTPUT.store(1, SeqCst);
        OUT_BYTES.store(24, SeqCst);
        RUN_CODE.store(0, SeqCst);
        NATIVE_W_STRIDE.store(0, SeqCst);
        NATIVE_SIZE.store(72, SeqCst);
        CREATE_NULL.store(false, SeqCst);
        SET_IO_CODE.store(0, SeqCst);
        NEXT_FD.store(0, SeqCst);
        MEM_SHORT.store(0, SeqCst);
        guard
    }

    unsafe extern "C" fn stub_init(
        ctx: *mut sys::Context,
        _: *mut c_void,
        _: u32,
        _: u32,
        _: *mut c_void,
    ) -> c_int {
        INITS.fetch_add(1, SeqCst);
        // SAFETY: `with_library` passes the address of a live `Context`.
        unsafe { *ctx = 7 };
        0
    }

    unsafe extern "C" fn stub_destroy(_: sys::Context) -> c_int {
        call("rknn_destroy");
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
                sys::QUERY_NATIVE_INPUT_ATTR => {
                    let mut native = input(&[1, 4, 6, 3]);
                    native.w_stride = NATIVE_W_STRIDE.load(SeqCst);
                    native.size_with_stride = NATIVE_SIZE.load(SeqCst);
                    *info.cast() = native;
                }
                _ => return -1,
            }
        }
        0
    }

    unsafe extern "C" fn stub_inputs_set(
        _: sys::Context,
        n_inputs: u32,
        input: *mut sys::Input,
    ) -> c_int {
        call("rknn_inputs_set");
        // SAFETY: `set_input` passes one live `Input`.
        let input = unsafe { &*input };
        // SAFETY: its `buf` is `size` bytes the backend holds past the call.
        let bytes =
            unsafe { std::slice::from_raw_parts(input.buf.cast::<u8>(), input.size as usize) };
        *SET_INPUT.lock().unwrap() = Some(SetInput {
            n_inputs,
            index: input.index,
            size: input.size,
            pass_through: input.pass_through,
            type_: input.type_,
            fmt: input.fmt,
            bytes: bytes.to_vec(),
        });
        0
    }

    unsafe extern "C" fn stub_run(_: sys::Context, _: *mut c_void) -> c_int {
        call("rknn_run");
        RUN_CODE.load(SeqCst)
    }

    unsafe extern "C" fn stub_outputs_get(
        _: sys::Context,
        _: u32,
        outs: *mut sys::Output,
        _: *mut c_void,
    ) -> c_int {
        call("rknn_outputs_get");
        // SAFETY: `outputs` passes one live `Output` for the one output reported.
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
        call("rknn_outputs_release");
        RELEASED.fetch_add(1, SeqCst);
        0
    }

    /// A boxed descriptor whose fd numbers it, so the log tells mems apart.
    fn stub_mem(call_name: &str, size: u32) -> *mut sys::TensorMem {
        let fd = NEXT_FD.fetch_add(1, SeqCst);
        call(format!("{call_name} {size} -> {fd}"));
        if CREATE_NULL.load(SeqCst) {
            return ptr::null_mut();
        }
        // SAFETY: null pointers and zeros are valid for every field.
        let mut mem: sys::TensorMem = unsafe { std::mem::zeroed() };
        (mem.fd, mem.size) = (fd, size - MEM_SHORT.load(SeqCst));
        Box::into_raw(Box::new(mem))
    }

    unsafe extern "C" fn stub_create_mem(_: sys::Context, size: u32) -> *mut sys::TensorMem {
        stub_mem("rknn_create_mem", size)
    }

    unsafe extern "C" fn stub_create_mem_from_fd(
        _: sys::Context,
        fd: c_int,
        _: *mut c_void,
        size: u32,
        _: c_int,
    ) -> *mut sys::TensorMem {
        stub_mem(&format!("rknn_create_mem_from_fd({fd})"), size)
    }

    unsafe extern "C" fn stub_destroy_mem(_: sys::Context, mem: *mut sys::TensorMem) -> c_int {
        // SAFETY: a `stub_mem` box; destroying one twice would be a double
        // free.
        let mem = unsafe { Box::from_raw(mem) };
        call(format!("rknn_destroy_mem {}", mem.fd));
        0
    }

    unsafe extern "C" fn stub_set_io_mem(
        _: sys::Context,
        mem: *mut sys::TensorMem,
        attr: *mut sys::TensorAttr,
    ) -> c_int {
        // SAFETY: `bind_input` passes a live mem and a live attr.
        let (mem, a) = unsafe { (&*mem, &*attr) };
        let (ty, fmt) = (sys::type_name(a.type_), sys::format_name(a.fmt));
        call(format!(
            "rknn_set_io_mem {} {ty} {fmt} pt{} {}",
            mem.fd, a.pass_through, a.size_with_stride
        ));
        SET_IO_CODE.load(SeqCst)
    }

    unsafe extern "C" fn stub_mem_sync(
        _: sys::Context,
        mem: *mut sys::TensorMem,
        mode: c_int,
    ) -> c_int {
        // SAFETY: `sync_input` passes a live mem.
        call(format!("rknn_mem_sync {} {mode}", unsafe { &*mem }.fd));
        0
    }

    fn stub_library() -> sys::Library {
        sys::Library {
            init: stub_init,
            destroy: stub_destroy,
            query: stub_query,
            inputs_set: stub_inputs_set,
            run: stub_run,
            outputs_get: stub_outputs_get,
            outputs_release: stub_outputs_release,
            mem: Ok(sys::MemApi {
                create_mem: stub_create_mem,
                create_mem_from_fd: stub_create_mem_from_fd,
                destroy_mem: stub_destroy_mem,
                set_io_mem: stub_set_io_mem,
                mem_sync: stub_mem_sync,
            }),
        }
    }

    fn open_path(path: &Path) -> Result<RknnBackend> {
        open_path_with(path, stub_library())
    }

    fn open_path_with(path: &Path, library: sys::Library) -> Result<RknnBackend> {
        RknnBackend::with_library(library, path)
    }

    fn open_stub(tag: &str) -> Result<RknnBackend> {
        open_stub_with(tag, b"stub", stub_library())
    }

    fn open_stub_with(tag: &str, artifact: &[u8], library: sys::Library) -> Result<RknnBackend> {
        let path =
            std::env::temp_dir().join(format!("rknn-stub-{}-{tag}.rknn", std::process::id()));
        std::fs::write(&path, artifact).unwrap();
        let opened = open_path_with(&path, library);
        std::fs::remove_file(&path).unwrap();
        opened
    }

    fn frame() -> InputTensor {
        let size = InputSize { w: 6, h: 4 };
        InputTensor::new(
            size,
            TensorLayout::Nhwc,
            TensorValues::U8((0..72).collect()),
        )
    }

    fn calls() -> Vec<String> {
        CALLS.lock().unwrap().clone()
    }

    #[test]
    fn a_run_serves_the_outputs_and_releases_them_once_on_drop() {
        let _guard = stubs();
        let mut backend = open_stub("happy").unwrap();
        let outputs = backend.run(frame()).unwrap();
        assert_eq!(RELEASED.load(SeqCst), 0);
        assert_eq!(calls(), ["rknn_inputs_set", "rknn_run", "rknn_outputs_get"]);
        let raw = outputs.get("output").unwrap();
        assert_eq!(raw.dims, [1, 2, 3]);
        assert_eq!(raw.values, OUT_VALUES);
        assert!(err(outputs.get("missing")).contains("no output \"missing\""));
        drop(outputs);
        assert_eq!(RELEASED.load(SeqCst), 1);
        assert_eq!(
            calls(),
            [
                "rknn_inputs_set",
                "rknn_run",
                "rknn_outputs_get",
                "rknn_outputs_release"
            ]
        );
        assert_eq!(DESTROYED.load(SeqCst), 0);
        drop(backend);
        assert_eq!(DESTROYED.load(SeqCst), 1);
    }

    #[test]
    fn a_run_hands_the_runtime_the_frame_as_one_uint8_nhwc_input() {
        let _guard = stubs();
        let mut backend = open_stub("descriptor").unwrap();
        drop(backend.run(frame()).unwrap());
        // Taken, not borrowed: a failed assert below must not poison the mutex
        // for the next test.
        let set = SET_INPUT.lock().unwrap().take();
        let set = set.expect("rknn_inputs_set was not called");
        assert_eq!(set.n_inputs, 1);
        assert_eq!(set.index, 0);
        assert_eq!(set.size, 72);
        assert_eq!(set.pass_through, 0);
        assert_eq!(set.type_, sys::TENSOR_UINT8);
        assert_eq!(set.fmt, sys::TENSOR_NHWC);
        assert_eq!(set.bytes, (0..72).collect::<Vec<u8>>());
    }

    #[test]
    fn an_empty_artifact_is_refused_before_the_runtime_sees_it() {
        let _guard = stubs();
        let msg = err(open_stub_with("empty", b"", stub_library()));
        assert!(
            msg.contains("rknn-stub-") && msg.contains("is empty"),
            "{msg}"
        );
        assert_eq!(INITS.load(SeqCst), 0);
    }

    #[test]
    fn a_directory_as_the_artifact_is_refused_before_the_runtime_sees_it() {
        let _guard = stubs();
        let msg = err(open_path(&std::env::temp_dir()));
        assert!(msg.contains("is not a regular file"), "{msg}");
        assert_eq!(INITS.load(SeqCst), 0);
    }

    /// A device that streams without end reports length 0; reading it would
    /// not return.
    #[test]
    fn an_endless_stream_as_the_artifact_is_refused_before_the_runtime_sees_it() {
        let _guard = stubs();
        let msg = err(open_path(Path::new("/dev/zero")));
        assert!(msg.contains("is not a regular file"), "{msg}");
        assert_eq!(INITS.load(SeqCst), 0);
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
        assert_eq!(calls(), ["rknn_inputs_set", "rknn_run"]);
        assert!(backend.held.is_none());
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

    #[test]
    fn a_bound_pass_sets_the_mem_as_uint8_nhwc_and_never_calls_inputs_set() {
        let _guard = stubs();
        let mut backend = open_stub("bound").unwrap();
        let mem = backend.create_input().unwrap();
        assert_eq!(backend.input_fd(mem).unwrap().1, 72);
        backend.sync_input(mem, MemSync::ToDevice).unwrap();
        backend.bind_input(mem).unwrap();
        assert!(backend.infer().unwrap().is_none());
        drop(backend.outputs().unwrap());
        drop(backend);
        let expected = [
            "rknn_create_mem 72 -> 0",
            "rknn_mem_sync 0 1",
            "rknn_set_io_mem 0 UINT8 NHWC pt0 72",
            "rknn_run",
            "rknn_outputs_get",
            "rknn_outputs_release",
            "rknn_destroy_mem 0",
            "rknn_destroy",
        ];
        assert_eq!(calls(), expected);
    }

    #[test]
    fn mems_are_destroyed_once_each_before_the_context_even_after_a_failed_bind() {
        let _guard = stubs();
        let mut backend = open_stub("teardown").unwrap();
        backend.create_input().unwrap();
        // SAFETY: the stub never reads the fd or the address.
        let imported = unsafe { backend.import_input(9, ptr::null_mut()) }.unwrap();
        SET_IO_CODE.store(-5, SeqCst);
        let msg = err(backend.bind_input(imported));
        assert!(msg.contains("rknn_set_io_mem returned -5"), "{msg}");
        drop(backend);
        let calls = calls();
        let teardown = ["rknn_destroy_mem 0", "rknn_destroy_mem 1", "rknn_destroy"];
        assert_eq!(calls[calls.len() - 3..], teardown, "{calls:?}");
        assert_eq!(calls[1], "rknn_create_mem_from_fd(9) 72 -> 1");
    }

    #[test]
    fn a_padded_native_input_or_a_null_mem_is_refused_by_what_it_is() {
        let _guard = stubs();
        let mut backend = open_stub("refused").unwrap();
        CREATE_NULL.store(true, SeqCst);
        assert!(err(backend.create_input()).contains("rknn_create_mem returned no mem"));
        // SAFETY: the stub never reads the fd or the address.
        let msg = err(unsafe { backend.import_input(9, ptr::null_mut()) });
        assert!(
            msg.contains("rknn_create_mem_from_fd returned no mem"),
            "{msg}"
        );

        let mut backend = open_stub("padded").unwrap();
        NATIVE_W_STRIDE.store(8, SeqCst);
        NATIVE_SIZE.store(96, SeqCst);
        let says = "not packed 6x4 RGB888: w_stride 8 (want 0 or 6), size_with_stride 96 (want 72)";
        assert!(err(backend.create_input()).contains(says));
        // SAFETY: refused before the runtime is called.
        assert!(err(unsafe { backend.import_input(9, ptr::null_mut()) }).contains(says));
        assert_eq!(NEXT_FD.load(SeqCst), 2, "a create past the refusal");
    }

    #[test]
    fn a_mem_smaller_than_the_input_is_refused_and_still_destroyed() {
        let _guard = stubs();
        let mut backend = open_stub("short").unwrap();
        MEM_SHORT.store(1, SeqCst);
        let msg = err(backend.create_input());
        assert!(
            msg.contains("returned a 71-byte mem for a 72-byte input"),
            "{msg}"
        );
        drop(backend);
        assert!(calls().contains(&"rknn_destroy_mem 0".to_string()));
    }

    #[test]
    fn a_runtime_without_the_mem_entry_points_runs_by_copy_and_names_the_missing_one() {
        let _guard = stubs();
        let library = sys::Library {
            mem: Err("the RKNN runtime stub has no rknn_create_mem".into()),
            ..stub_library()
        };
        let mut backend = open_stub_with("nomem", b"stub", library).unwrap();
        drop(backend.run(frame()).unwrap());
        assert!(err(backend.create_input()).contains("has no rknn_create_mem"));
        // SAFETY: refused before the runtime is called.
        let msg = err(unsafe { backend.import_input(9, ptr::null_mut()) });
        assert!(msg.contains("has no rknn_create_mem"), "{msg}");
        drop(backend);
        assert_eq!(calls().last().unwrap(), "rknn_destroy");
    }
}
