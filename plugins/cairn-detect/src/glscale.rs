//! GPU NV12 scale-and-convert, for decoders that hand back system memory.
//!
//! The v4l2m2m path decodes on the video ASIC but returns frames in system
//! memory ([`crate::hwdecode`]'s module doc), and on the QCS6490 that memory
//! is an uncached capture buffer: swscale's scattered bilinear taps over it
//! cost ~50 ms a frame, most of the per-camera CPU bill. The same scale as
//! one GPU pass costs ~0.6 ms on that board's Adreno 643L
//! (`.claude/plans/membrane-port/research/spikes/on-device-resize.md`), and
//! uploading the planes is a single sequential pass over the uncached buffer
//! instead of swscale's re-reads. This module is that pass: Y and UV planes
//! up as R8/RG8 textures, one fullscreen triangle through a fragment shader
//! doing the bilinear sample and the YUV→RGB conversion, RGBA read back at
//! the content rectangle's size and stripped to tightly packed RGB24.
//!
//! Nothing here links against GL or EGL. libEGL is dlopened at runtime
//! (`khronos-egl`'s `dynamic` feature) and every GL function comes from
//! `eglGetProcAddress` (`glow`), so the binary loads fine on hosts without a
//! GPU and [`GlScaler::new`] reports their absence as an `Err`, never a
//! link-time failure.
//!
//! The color matrix is BT.601 limited range, fixed rather than negotiated:
//! the fleet is 8-bit H.264 camera streams, and the CPU path this replaces —
//! [`crate::decode::RgbScaler`]'s swscale, which never calls
//! `sws_setColorspaceDetails` — applies exactly that default to them, so both
//! paths produce the same RGB for the same frame.

use anyhow::{anyhow, bail, Context as _, Result};
use glow::HasContext;
use khronos_egl as egl;

use crate::infer::InputSize;
use crate::note;

/// The EGL 1.5 API, dlopened. 1.5 rather than 1.4 because
/// `eglGetPlatformDisplay` is how a headless board names the surfaceless
/// platform, and every stack this runs on (Mesa on the board, Mesa or nothing
/// on dev hosts) has shipped 1.5 for years.
type Egl = egl::DynamicInstance<egl::EGL1_5>;

/// `EGL_PLATFORM_SURFACELESS_MESA`: not in the core headers `khronos-egl`
/// binds, because it is Mesa's extension enum.
const PLATFORM_SURFACELESS_MESA: egl::Enum = 0x31DD;

/// `SURFACE_TYPE 0` is deliberate: the spike found freedreno exposes *zero*
/// configs once a pbuffer bit is requested, and no surface is ever created —
/// rendering goes to an FBO under `EGL_KHR_surfaceless_context`.
const CONFIG_ATTRIBS: [egl::Int; 5] = [
    egl::RENDERABLE_TYPE,
    egl::OPENGL_ES3_BIT,
    egl::SURFACE_TYPE,
    0,
    egl::NONE,
];

/// GLES 3 is the floor: sized R8/RG8 textures and `GL_UNPACK_ROW_LENGTH` —
/// how strides are honoured without repacking on the CPU — arrive with it.
const CONTEXT_ATTRIBS: [egl::Int; 3] = [egl::CONTEXT_MAJOR_VERSION, 3, egl::NONE];

/// One triangle from `gl_VertexID`, no vertex buffer: three invocations whose
/// clip positions cover the viewport, with `v_pos` interpolating 0..1 over it.
const VERT_SRC: &str = r#"#version 300 es
out vec2 v_pos;
void main() {
    vec2 corner = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
    v_pos = corner;
    gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}
"#;

/// BT.601 limited range: Y spans 16..235 (219 steps), chroma 16..240 (224
/// steps) — see the module doc for why this matrix and no other.
///
/// No vertical flip anywhere, on purpose: texture row 0 is the first row
/// uploaded (the top of the picture), and `glReadPixels` returns rows from
/// window row 0 (the bottom of the framebuffer) upward, so sampling
/// `v_pos` directly lands the picture's top row first in the readback —
/// the two inversions cancel.
const FRAG_SRC: &str = r#"#version 300 es
precision highp float;
uniform sampler2D u_y;
uniform sampler2D u_uv;
in vec2 v_pos;
out vec4 o_rgba;
void main() {
    float y = (texture(u_y, v_pos).r * 255.0 - 16.0) / 219.0;
    vec2 c = (texture(u_uv, v_pos).rg * 255.0 - 128.0) / 224.0;
    vec3 rgb = vec3(
        y + 1.402 * c.y,
        y - 0.344136 * c.x - 0.714136 * c.y,
        y + 1.772 * c.x);
    o_rgba = vec4(clamp(rgb, 0.0, 1.0), 1.0);
}
"#;

/// The Y/UV textures currently allocated, and the geometry they were
/// allocated for. Immutable storage (`tex_storage_2d`) cannot be respecified,
/// so a geometry change is an explicit delete-and-recreate here rather than a
/// silent realloc inside the driver.
struct SourcePlanes {
    size: InputSize,
    y: glow::NativeTexture,
    uv: glow::NativeTexture,
}

/// One camera's GPU scaler: an EGL context, the compiled shader pass, and a
/// render target sized to the model input.
///
/// ## Threading: bind-per-call, owned by one caller at a time
///
/// EGL contexts are thread-affine only *while current*: the spec lets a
/// context migrate between threads freely so long as it is current on at most
/// one at a time. The NIF host calls from dirty schedulers, so consecutive
/// calls for the same decoder land on different OS threads — a context left
/// current between calls would be undefined behaviour the first time the
/// scheduler rotated. So every entry binds the context and every exit
/// releases it (the [`Bound`] guard, which releases on unwind too), `&mut
/// self` serialises callers, and the type is `!Sync` (raw EGL handles), so
/// two threads can never race the bind through a shared reference.
///
/// The alternative — a dedicated GL thread owning the context behind a
/// channel — was rejected because the planes would have to cross that
/// channel: either a full-resolution copy of exactly the uncached buffer this
/// module exists to touch once, or smuggled pointers whose lifetime argument
/// is the same promise bind-per-call makes, moved somewhere harder to see. A
/// make-current pair on Mesa is microseconds against the ~0.6 ms scale.
///
/// ## The display is never terminated
///
/// EGL displays are process-global: `eglTerminate` invalidates every context
/// on the display, including other scalers' (multi-camera means several of
/// these in one process). `eglInitialize` on an already-initialized display
/// is specified as a cheap success, so each scaler initializes and none
/// terminates; the display's driver state lives until process exit.
pub struct GlScaler {
    egl: Egl,
    display: egl::Display,
    context: egl::Context,
    gl: glow::Context,
    program: glow::NativeProgram,
    fbo: glow::NativeFramebuffer,
    /// The FBO's color attachment, allocated once at `target` size. Frames
    /// render into its top-left `content` corner via the viewport, so a
    /// mid-run source-geometry change (new `content`) needs no realloc —
    /// `content` never exceeds `target` because a fit's inner rectangle never
    /// exceeds the model input it fits into.
    color: glow::NativeTexture,
    target: InputSize,
    source: Option<SourcePlanes>,
    /// Readback scratch, reused across frames; the RGB24 result is packed out
    /// of it fresh each call.
    rgba: Vec<u8>,
}

// SAFETY: every EGL and GL handle held here is a plain token valid from any
// thread; thread affinity exists only while the context is current, and no
// method returns with it current — the `Bound` guard releases on every exit
// path, unwinding included. Moving the value to another thread therefore
// never moves a *current* context. The type stays `!Sync` (raw pointers in
// the EGL handles), which is load-bearing: see the threading section on
// [`GlScaler`].
unsafe impl Send for GlScaler {}

impl GlScaler {
    /// Open the GPU and build the whole pass. Everything that can be settled
    /// before the first frame is settled here, so a host with no libEGL, no
    /// render device, or no GLES 3 answers with an `Err` at startup instead
    /// of a failure mid-stream.
    pub fn new(target: InputSize) -> Result<Self> {
        let target_w = gl_dim(target.w, "target width")?;
        let target_h = gl_dim(target.h, "target height")?;

        // SAFETY: dlopens the system libEGL; that the found library honours
        // the EGL contract is the usual dynamic-loading bargain, and the same
        // one `ort-load-dynamic` already strikes for onnxruntime.
        let egl = unsafe { Egl::load_required() }.map_err(|e| anyhow!("loading libEGL: {e}"))?;

        let display = open_display(&egl)?;
        egl.initialize(display)
            .context("initializing the EGL display")?;
        egl.bind_api(egl::OPENGL_ES_API)
            .context("binding the GLES API")?;
        let config = egl
            .choose_first_config(display, &CONFIG_ATTRIBS)
            .context("querying EGL configs")?
            .ok_or_else(|| anyhow!("no GLES3-capable EGL config on this device"))?;
        let context = egl
            .create_context(display, config, None, &CONTEXT_ATTRIBS)
            .context("creating the GLES3 context")?;

        // From here the context must be destroyed on any failure; GL objects
        // need no individual cleanup because the context owns them all.
        let built = Bound::new(&egl, display, context)
            .and_then(|bound| {
                // SAFETY: `bound` holds the context current until the state
                // is built.
                let state = unsafe { build_pass(&egl, target_w, target_h) };
                drop(bound);
                state
            })
            .context("building the GL scale pass");
        let (gl, program, fbo, color) = match built {
            Ok(state) => state,
            Err(error) => {
                let _ = egl.destroy_context(display, context);
                return Err(error);
            }
        };

        Ok(Self {
            egl,
            display,
            context,
            gl,
            program,
            fbo,
            color,
            target,
            source: None,
            rgba: Vec::new(),
        })
    }

    /// NV12 in, content-rect RGB24 out: `source` is the frame's own geometry,
    /// `content` the aspect-preserving rectangle the caller computed from it
    /// ([`crate::infer::ResizePolicy::fit`]'s inner size). Returns tightly
    /// packed rows, `content.w * 3 * content.h` bytes — the same shape
    /// [`crate::decode::RgbScaler::rgb_from`] produces on the CPU path.
    pub fn scale_nv12(
        &mut self,
        y: &[u8],
        y_stride: usize,
        uv: &[u8],
        uv_stride: usize,
        source: InputSize,
        content: InputSize,
    ) -> Result<Vec<u8>> {
        validate_nv12(
            source,
            content,
            self.target,
            y.len(),
            y_stride,
            uv.len(),
            uv_stride,
        )?;
        let source_w = gl_dim(source.w, "source width")?;
        let source_h = gl_dim(source.h, "source height")?;
        let content_w = gl_dim(content.w, "content width")?;
        let content_h = gl_dim(content.h, "content height")?;
        // Row lengths are in texels of the plane's format: bytes for R8, RG
        // byte pairs for RG8 (validated even above).
        let y_row = gl_dim(y_stride, "Y stride")?;
        let uv_row = gl_dim(uv_stride / 2, "UV stride")?;

        let bound = Bound::new(&self.egl, self.display, self.context)?;
        // SAFETY: every call in this block requires a current context, which
        // `bound` holds until the block is done (and releases even on
        // unwind). Slice lengths were validated against exactly the extents
        // and row lengths the uploads and the readback are given.
        unsafe {
            let gl = &self.gl;
            let (y_tex, uv_tex) = ensure_source(gl, &mut self.source, source, source_w, source_h)?;

            gl.active_texture(glow::TEXTURE0);
            gl.bind_texture(glow::TEXTURE_2D, Some(y_tex));
            gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, y_row);
            gl.tex_sub_image_2d(
                glow::TEXTURE_2D,
                0,
                0,
                0,
                source_w,
                source_h,
                glow::RED,
                glow::UNSIGNED_BYTE,
                glow::PixelUnpackData::Slice(Some(y)),
            );
            gl.generate_mipmap(glow::TEXTURE_2D);
            gl.active_texture(glow::TEXTURE1);
            gl.bind_texture(glow::TEXTURE_2D, Some(uv_tex));
            gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, uv_row);
            gl.tex_sub_image_2d(
                glow::TEXTURE_2D,
                0,
                0,
                0,
                source_w / 2,
                source_h / 2,
                glow::RG,
                glow::UNSIGNED_BYTE,
                glow::PixelUnpackData::Slice(Some(uv)),
            );
            gl.generate_mipmap(glow::TEXTURE_2D);
            gl.pixel_store_i32(glow::UNPACK_ROW_LENGTH, 0);

            gl.bind_framebuffer(glow::FRAMEBUFFER, Some(self.fbo));
            gl.viewport(0, 0, content_w, content_h);
            gl.use_program(Some(self.program));
            gl.draw_arrays(glow::TRIANGLES, 0, 3);

            self.rgba.resize(content.w * content.h * 4, 0);
            gl.read_pixels(
                0,
                0,
                content_w,
                content_h,
                glow::RGBA,
                glow::UNSIGNED_BYTE,
                glow::PixelPackData::Slice(Some(&mut self.rgba)),
            );
            take_gl_error(gl).context("scaling NV12 on the GPU")?;
        }
        drop(bound);

        Ok(rgb_from_rgba(&self.rgba))
    }
}

impl Drop for GlScaler {
    fn drop(&mut self) {
        // Deleting the GL objects needs the context current; if binding fails
        // mid-teardown, destroying the context reclaims them anyway.
        if let Ok(bound) = Bound::new(&self.egl, self.display, self.context) {
            // SAFETY: the context is current for the lifetime of `bound`, and
            // every handle deleted here was created in it.
            unsafe {
                if let Some(planes) = self.source.take() {
                    self.gl.delete_texture(planes.y);
                    self.gl.delete_texture(planes.uv);
                }
                self.gl.delete_framebuffer(self.fbo);
                self.gl.delete_texture(self.color);
                self.gl.delete_program(self.program);
            }
            drop(bound);
        }
        let _ = self.egl.destroy_context(self.display, self.context);
        // The display is deliberately left initialized — see the type doc.
    }
}

/// Makes the context current for its own lifetime and releases it on drop —
/// on unwind too, which is what keeps a foreign panic from stranding the
/// context current on a thread it will never see again.
struct Bound<'a> {
    egl: &'a Egl,
    display: egl::Display,
}

impl<'a> Bound<'a> {
    fn new(egl: &'a Egl, display: egl::Display, context: egl::Context) -> Result<Self> {
        // No draw/read surface: EGL_KHR_surfaceless_context, everything
        // renders into an FBO.
        egl.make_current(display, None, None, Some(context))
            .context("making the GL context current")?;
        Ok(Self { egl, display })
    }
}

impl Drop for Bound<'_> {
    fn drop(&mut self) {
        // A failed release has no recovery mid-drop; the next `make_current`
        // on this thread will surface whatever went wrong.
        let _ = self.egl.make_current(self.display, None, None, None);
    }
}

/// Mesa's surfaceless platform first — the one that exists on a headless
/// board, where there is no display server to name and the spike proved the
/// path — then `eglGetDisplay`'s default resolution for anything else.
fn open_display(egl: &Egl) -> Result<egl::Display> {
    // SAFETY: `DEFAULT_DISPLAY` is the one native-display value every
    // platform accepts by definition; no pointer of ours is handed over.
    let surfaceless = unsafe {
        egl.get_platform_display(
            PLATFORM_SURFACELESS_MESA,
            egl::DEFAULT_DISPLAY,
            &[egl::ATTRIB_NONE],
        )
    };
    if let Ok(display) = surfaceless {
        return Ok(display);
    }
    // SAFETY: as above.
    unsafe { egl.get_display(egl::DEFAULT_DISPLAY) }.ok_or_else(|| {
        anyhow!("no EGL display: neither the surfaceless platform nor the default opened")
    })
}

/// Everything the pass needs beyond the context: the loaded GL functions, the
/// linked program with its samplers bound, and the completeness-checked FBO.
///
/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn build_pass(
    egl: &Egl,
    target_w: i32,
    target_h: i32,
) -> Result<(
    glow::Context,
    glow::NativeProgram,
    glow::NativeFramebuffer,
    glow::NativeTexture,
)> {
    // EGL 1.5 guarantees `eglGetProcAddress` resolves core functions as well
    // as extensions, and the addresses are context-independent, so loading
    // once here serves every later bind.
    let gl = glow::Context::from_loader_function_cstr(|name| {
        name.to_str()
            .ok()
            .and_then(|name| egl.get_proc_address(name))
            .map_or(std::ptr::null(), |f| f as *const std::ffi::c_void)
    });
    note!("gl scaler: {}", gl.get_parameter_string(glow::RENDERER));

    let program = build_program(&gl)?;

    // Dithering is on by default in GLES and would make the output depend on
    // the driver's taste; the CPU path it must match does not dither.
    gl.disable(glow::DITHER);
    // Plane strides are expressed via UNPACK_ROW_LENGTH alone; without this,
    // odd-width R8 uploads would also need row starts 4-byte aligned.
    gl.pixel_store_i32(glow::UNPACK_ALIGNMENT, 1);

    // RGBA8 rather than RGB8 because an RGBA/UNSIGNED_BYTE readback is the
    // one combination GLES guarantees for every framebuffer; the alpha strip
    // happens on the CPU where it is a ~µs pass over a model-sized buffer.
    let color = gl
        .create_texture()
        .map_err(|e| anyhow!("creating the render target: {e}"))?;
    gl.bind_texture(glow::TEXTURE_2D, Some(color));
    gl.tex_storage_2d(glow::TEXTURE_2D, 1, glow::RGBA8, target_w, target_h);

    let fbo = gl
        .create_framebuffer()
        .map_err(|e| anyhow!("creating the framebuffer: {e}"))?;
    gl.bind_framebuffer(glow::FRAMEBUFFER, Some(fbo));
    gl.framebuffer_texture_2d(
        glow::FRAMEBUFFER,
        glow::COLOR_ATTACHMENT0,
        glow::TEXTURE_2D,
        Some(color),
        0,
    );
    let status = gl.check_framebuffer_status(glow::FRAMEBUFFER);
    if status != glow::FRAMEBUFFER_COMPLETE {
        bail!("framebuffer incomplete: 0x{status:X}");
    }
    take_gl_error(&gl).context("setting up the GL pass")?;

    Ok((gl, program, fbo, color))
}

/// Compile, link, and point the two samplers at texture units 0 and 1 — set
/// once here because sampler uniforms are program state, not per-draw state.
///
/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn build_program(gl: &glow::Context) -> Result<glow::NativeProgram> {
    let vert = compile_shader(gl, glow::VERTEX_SHADER, VERT_SRC)?;
    let frag = compile_shader(gl, glow::FRAGMENT_SHADER, FRAG_SRC)?;
    let program = gl
        .create_program()
        .map_err(|e| anyhow!("creating the program: {e}"))?;
    gl.attach_shader(program, vert);
    gl.attach_shader(program, frag);
    gl.link_program(program);
    // Shaders are owned by the program once linked; deleting the handles
    // here just stops them outliving it.
    gl.delete_shader(vert);
    gl.delete_shader(frag);
    if !gl.get_program_link_status(program) {
        let log = gl.get_program_info_log(program);
        gl.delete_program(program);
        bail!("shader program failed to link: {log}");
    }
    gl.use_program(Some(program));
    for (name, unit) in [("u_y", 0), ("u_uv", 1)] {
        let location = gl
            .get_uniform_location(program, name)
            .ok_or_else(|| anyhow!("sampler uniform {name} missing from the linked program"))?;
        gl.uniform_1_i32(Some(&location), unit);
    }
    Ok(program)
}

/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn compile_shader(
    gl: &glow::Context,
    stage: u32,
    source: &str,
) -> Result<glow::NativeShader> {
    let shader = gl
        .create_shader(stage)
        .map_err(|e| anyhow!("creating a shader: {e}"))?;
    gl.shader_source(shader, source);
    gl.compile_shader(shader);
    if !gl.get_shader_compile_status(shader) {
        let log = gl.get_shader_info_log(shader);
        gl.delete_shader(shader);
        bail!("shader failed to compile: {log}");
    }
    Ok(shader)
}

/// (Re)allocate the source textures when the camera's geometry changes,
/// returning the pair to bind. Linear filtering on both is the bilinear
/// sample; `CLAMP_TO_EDGE` keeps the filter from wrapping at the borders.
///
/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn ensure_source(
    gl: &glow::Context,
    planes: &mut Option<SourcePlanes>,
    size: InputSize,
    w: i32,
    h: i32,
) -> Result<(glow::NativeTexture, glow::NativeTexture)> {
    if let Some(planes) = planes.as_ref() {
        if planes.size == size {
            return Ok((planes.y, planes.uv));
        }
    }
    if let Some(old) = planes.take() {
        gl.delete_texture(old.y);
        gl.delete_texture(old.uv);
    }
    let y = source_texture(gl, glow::R8, w, h)?;
    let uv = source_texture(gl, glow::RG8, w / 2, h / 2)?;
    take_gl_error(gl).context("allocating the source textures")?;
    *planes = Some(SourcePlanes { size, y, uv });
    Ok((y, uv))
}

/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn source_texture(
    gl: &glow::Context,
    format: u32,
    w: i32,
    h: i32,
) -> Result<glow::NativeTexture> {
    let texture = gl
        .create_texture()
        .map_err(|e| anyhow!("creating a source texture: {e}"))?;
    gl.bind_texture(glow::TEXTURE_2D, Some(texture));
    // The full mip chain, and trilinear minification below. A single level
    // with plain LINEAR samples 4 of the ~38 source pixels behind each output
    // pixel at this pipeline's ~6x downscale — aliasing invisible to the eye
    // that cost the detector ~27% of its score on the board (a 0.51 car read
    // 0.37, under the 0.5 default floor). Mip trilinear is the GPU's
    // approximation of the area filtering swscale applies when minifying.
    let levels = 32 - i32::max(w, h).leading_zeros() as i32;
    gl.tex_storage_2d(glow::TEXTURE_2D, levels, format, w, h);
    gl.tex_parameter_i32(
        glow::TEXTURE_2D,
        glow::TEXTURE_MIN_FILTER,
        glow::LINEAR_MIPMAP_LINEAR as i32,
    );
    gl.tex_parameter_i32(
        glow::TEXTURE_2D,
        glow::TEXTURE_MAG_FILTER,
        glow::LINEAR as i32,
    );
    gl.tex_parameter_i32(
        glow::TEXTURE_2D,
        glow::TEXTURE_WRAP_S,
        glow::CLAMP_TO_EDGE as i32,
    );
    gl.tex_parameter_i32(
        glow::TEXTURE_2D,
        glow::TEXTURE_WRAP_T,
        glow::CLAMP_TO_EDGE as i32,
    );
    Ok(texture)
}

/// One flag is enough: GL keeps error flags until read, so a single check
/// after the last call of a sequence sees anything the sequence raised.
///
/// # Safety
///
/// The caller must hold the context current on this thread.
unsafe fn take_gl_error(gl: &glow::Context) -> Result<()> {
    let error = gl.get_error();
    if error == glow::NO_ERROR {
        Ok(())
    } else {
        Err(anyhow!("GL error 0x{error:X}"))
    }
}

/// GL geometry is `i32`; anything a resolved [`InputSize`] carries fits, so a
/// failure here means the caller's numbers were never validated upstream.
fn gl_dim(value: usize, what: &str) -> Result<i32> {
    i32::try_from(value).map_err(|_| anyhow!("{what} {value} exceeds GL's i32 range"))
}

/// Everything about the call that can be checked without touching GL, checked
/// before anything is uploaded — GL would render a wrong answer or read out
/// of bounds where this returns an error naming the actual mismatch.
fn validate_nv12(
    source: InputSize,
    content: InputSize,
    target: InputSize,
    y_len: usize,
    y_stride: usize,
    uv_len: usize,
    uv_stride: usize,
) -> Result<()> {
    if source.w == 0 || source.h == 0 {
        bail!("empty source frame {source}");
    }
    // NV12 chroma is half resolution on both axes; an odd side has no whole
    // number of chroma samples to upload.
    if !source.w.is_multiple_of(2) || !source.h.is_multiple_of(2) {
        bail!("NV12 needs even source dimensions, got {source}");
    }
    if content.w == 0 || content.h == 0 {
        bail!("empty content rectangle {content}");
    }
    if content.w > target.w || content.h > target.h {
        bail!("content {content} exceeds the render target {target}");
    }
    if y_stride < source.w {
        bail!("Y stride {y_stride} is narrower than the {source} frame");
    }
    if uv_stride < source.w {
        bail!("UV stride {uv_stride} is narrower than the {source} frame");
    }
    // UNPACK_ROW_LENGTH counts texels, and a UV texel is an RG byte pair; an
    // odd byte stride cannot be expressed as a whole number of them.
    if !uv_stride.is_multiple_of(2) {
        bail!("UV stride {uv_stride} splits a chroma pair");
    }
    check_plane("Y", y_len, y_stride, source.w, source.h)?;
    check_plane("UV", uv_len, uv_stride, source.w, source.h / 2)?;
    Ok(())
}

fn check_plane(name: &str, len: usize, stride: usize, row_bytes: usize, rows: usize) -> Result<()> {
    let needed = min_plane_len(stride, row_bytes, rows)
        .ok_or_else(|| anyhow!("{name} plane geometry overflows"))?;
    if len < needed {
        bail!("{name} plane holds {len} bytes, needs {needed} ({rows} rows at stride {stride})");
    }
    Ok(())
}

/// Bytes an upload reads from a plane: a full stride for every row but the
/// last, which GL reads only to the row's own width.
fn min_plane_len(stride: usize, row_bytes: usize, rows: usize) -> Option<usize> {
    rows.checked_sub(1)?
        .checked_mul(stride)?
        .checked_add(row_bytes)
}

/// The CPU end of the readback: drop the constant alpha the RGBA8 target
/// carried for readback compatibility. ~µs over a model-sized buffer.
fn rgb_from_rgba(rgba: &[u8]) -> Vec<u8> {
    let mut rgb = Vec::with_capacity(rgba.len() / 4 * 3);
    for pixel in rgba.chunks_exact(4) {
        rgb.extend_from_slice(&pixel[..3]);
    }
    rgb
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shaders_carry_the_bt601_limited_range_constants() {
        // The matrix is the contract with the CPU path; a "fixed" constant
        // here is a silent color shift on every board.
        for constant in [
            "16.0", "219.0", "128.0", "224.0", "1.402", "0.344136", "0.714136", "1.772",
        ] {
            assert!(FRAG_SRC.contains(constant), "{constant} missing");
        }
        for source in [VERT_SRC, FRAG_SRC] {
            assert!(source.starts_with("#version 300 es"));
        }
        assert!(VERT_SRC.contains("gl_VertexID"));
    }

    #[test]
    fn stripping_alpha_keeps_rgb_in_order() {
        let rgba = [1u8, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 0];
        assert_eq!(rgb_from_rgba(&rgba), vec![1, 2, 3, 4, 5, 6, 7, 8, 9]);
        assert!(rgb_from_rgba(&[]).is_empty());
    }

    #[test]
    fn min_plane_len_charges_full_strides_for_all_but_the_last_row() {
        assert_eq!(min_plane_len(2560, 2048, 4), Some(3 * 2560 + 2048));
        assert_eq!(min_plane_len(640, 640, 1), Some(640));
        assert_eq!(min_plane_len(640, 640, 0), None);
        assert_eq!(min_plane_len(usize::MAX, 2, usize::MAX), None);
    }

    const SOURCE: InputSize = InputSize { w: 1280, h: 720 };
    const CONTENT: InputSize = InputSize { w: 640, h: 360 };
    const TARGET: InputSize = InputSize::square(640);

    fn validate(y_len: usize, y_stride: usize, uv_len: usize, uv_stride: usize) -> Result<()> {
        validate_nv12(SOURCE, CONTENT, TARGET, y_len, y_stride, uv_len, uv_stride)
    }

    #[test]
    fn validation_accepts_a_strided_frame_and_names_each_refusal() {
        // 1280x720 with padded strides, planes exactly as long as GL reads.
        assert!(validate(719 * 1536 + 1280, 1536, 359 * 1536 + 1280, 1536).is_ok());

        // short Y plane
        assert!(validate(719 * 1536, 1536, 359 * 1536 + 1280, 1536).is_err());
        // short UV plane
        assert!(validate(719 * 1536 + 1280, 1536, 359 * 1536, 1536).is_err());
        // strides narrower than the frame
        assert!(validate(1280 * 720, 1279, 1280 * 360, 1536).is_err());
        assert!(validate(1280 * 720, 1280, 1280 * 360, 1279).is_err());
        // an odd UV stride splits a chroma pair
        assert!(validate(1280 * 720 + 720, 1281, 1280 * 360, 1281).is_err());
    }

    #[test]
    fn validation_rejects_impossible_geometry() {
        let ok_y = 1280 * 720;
        let ok_uv = 1280 * 360;
        for (source, content) in [
            // odd sources have no whole chroma sample to upload
            (InputSize { w: 1279, h: 720 }, CONTENT),
            (InputSize { w: 1280, h: 719 }, CONTENT),
            (InputSize { w: 0, h: 0 }, CONTENT),
            // empty or target-exceeding content rectangles
            (SOURCE, InputSize { w: 0, h: 360 }),
            (SOURCE, InputSize { w: 641, h: 360 }),
            (SOURCE, InputSize { w: 640, h: 641 }),
        ] {
            assert!(
                validate_nv12(source, content, TARGET, ok_y, 1280, ok_uv, 1280).is_err(),
                "{source} -> {content} accepted"
            );
        }
    }

    /// The property is that a missing GPU is a value, never an abort: this
    /// container has no libEGL, so this walks the `Err` arm; on a host with
    /// working GL (some CI images ship one) construction succeeding and
    /// dropping cleanly is the same property from the other side.
    #[test]
    fn new_reports_a_missing_gpu_as_an_error() {
        match GlScaler::new(TARGET) {
            Ok(scaler) => drop(scaler),
            Err(error) => assert!(!format!("{error:#}").is_empty()),
        }
    }

    /// Needs a real GPU: run with `--ignored` on the QCS6490 board (Adreno
    /// 643L, freedreno) — the hardware the spike's numbers came from.
    #[test]
    #[ignore = "needs a GPU: run on the QCS6490 board (Adreno 643L)"]
    fn gpu_scales_a_flat_gray_frame() {
        let mut scaler = GlScaler::new(TARGET).expect("EGL + GLES3 on the board");
        // Y=128, U=V=128: mid gray in limited range, (128-16)/219*255 ≈ 130
        // in every output channel; flat input makes the bilinear taps exact.
        let y = vec![128u8; SOURCE.w * SOURCE.h];
        let uv = vec![128u8; SOURCE.w * SOURCE.h / 2];
        let rgb = scaler
            .scale_nv12(&y, SOURCE.w, &uv, SOURCE.w, SOURCE, CONTENT)
            .expect("scaling a valid frame");
        assert_eq!(rgb.len(), CONTENT.w * 3 * CONTENT.h);
        for (i, byte) in rgb.iter().enumerate() {
            assert!((128..=133).contains(byte), "byte {i} = {byte}");
        }
    }
}
