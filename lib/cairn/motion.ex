defmodule Cairn.Motion do
  @moduledoc """
  Frame-to-frame change measurement on a grayscale thumbnail — the port of
  `MotionDetector` in `plugins/cairn-detect/src/motion.rs` to Nx (D-C3),
  producing the crate's verdicts **exactly**, frame for frame.

  The algorithm is Frigate's, adapted: downscale to a small grayscale
  thumbnail (`Cairn.Motion.Thumbnail`), keep a rolling-average background,
  take the absolute difference, threshold it per pixel, and report the
  fraction of the thumbnail that changed. No contours: the gate only ever
  asks "is anything happening", never "where".

  Pure — no clocks and no I/O. Elapsed time is counted in frames, which is
  what keeps the calibration independent of how long a stream took to open
  and the tests independent of wall-clock timing. `new/2` converts the
  five-second calibration window to a frame count at the caller's sample
  rate once, exactly as the crate resolves it from `--sample-fps`.

  ## Why the verdicts are exact, not close

  A divergence here changes *which frames get inferred* — invisible in a
  detection diff, so it is a defect and never a tolerance question. Three
  properties make exactness structural rather than lucky:

    * the thumbnail reproduces the crate's integer arithmetic to the bit
      (see `Cairn.Motion.Thumbnail`);
    * the background is f32 in the same algebraic form the crate uses
      (`bg + alpha * (px - bg)`, one materialized f32 tensor per step —
      `Nx.BinaryBackend` computes each op in f64 and stores f32, which for
      `+`/`-`/`*` of f32 operands is the correctly-rounded IEEE f32 result,
      i.e. the same bits native f32 ops produce);
    * every scalar boundary (`>` the scene-cut fraction, `>=` the area
      floor) compares f32-rounded values on both sides
      (`Cairn.Motion.Config.f32/1`) — including `changed_fraction` itself,
      where double rounding provably cannot bite (see the note at its
      computation).

  The background is f32 and not u8 for the crate's own reason: at alpha 0.02
  an integer average never moves at all, so it would freeze on its first
  frame. `Nx.BinaryBackend` is deliberate (D-C3): the gate exists to *skip*
  the expensive model pass, so it must not need an accelerator — or a native
  dependency — of its own. It is also pinned explicitly on every tensor this
  module and `Cairn.Motion.Thumbnail` mint, so a dependency that changes the
  *global* Nx default backend cannot silently move the arithmetic somewhere
  the exactness argument was never made for.
  """

  alias Cairn.Motion.{Config, Thumbnail}

  @backend Nx.BinaryBackend

  # Rolling-average weight while the background is still being learned, and
  # how many seconds of frames it is used for — converted to a frame count at
  # construction, since this module has no clock of its own. The window spans
  # five seconds of wall clock only when the camera delivers the configured
  # rate; the rate is a ceiling, so a slower camera stretches it.
  @calibration_alpha Config.f32(0.2)
  @calibration_seconds 5

  defstruct [
    :config,
    :background,
    :size,
    :frames,
    :calibration_frames,
    :threshold,
    :alpha,
    :calibration_alpha
  ]

  @typedoc """
  One camera's rolling-average background and the counters around it. The
  background lives at the thumbnail's geometry, on its 0..255 scale, as an
  f32 tensor; `frames` counts thumbnails observed since calibration last
  restarted (the first frame, or the first at a new geometry — the only two
  events that restart it). `threshold`/`alpha`/`calibration_alpha` are the
  config's values as f32 scalar tensors, built once — the per-frame ops
  inherit their pinned backend, and the hot path allocates nothing but its
  results.
  """
  @type t :: %__MODULE__{
          config: Config.t(),
          background: Nx.Tensor.t() | nil,
          size: {pos_integer(), pos_integer()} | nil,
          frames: non_neg_integer(),
          calibration_frames: pos_integer(),
          threshold: Nx.Tensor.t(),
          alpha: Nx.Tensor.t(),
          calibration_alpha: Nx.Tensor.t()
        }

  @typedoc """
  What one frame's comparison against the background says — the same four
  keys the decode NIF mints (`t:Cairn.Native.motion_verdict/0`), so a
  consumer cannot tell which side measured.

  The three ways this reports no motion are not the same thing: a frame
  measured against a background still being learned (`calibrating`), a scene
  cut (`scene_cut` — the whole picture changed, which is not a thing moving
  in the scene, and the background it was measured against no longer
  exists), and a genuinely still scene. Only the last says anything about
  the picture, and the gate downstream refuses to skip work on a verdict
  carrying either of the other two flags.
  """
  @type verdict :: %{
          changed_fraction: float(),
          motion: boolean(),
          calibrating: boolean(),
          scene_cut: boolean()
        }

  @doc """
  A detector for one camera, its calibration window sized to the caller's
  sample rate — `#{@calibration_seconds} * sample_fps` frames.
  """
  @spec new(Config.t(), pos_integer()) :: t()
  def new(%Config{} = config, sample_fps) when is_integer(sample_fps) and sample_fps >= 1 do
    %__MODULE__{
      config: config,
      background: nil,
      size: nil,
      frames: 0,
      calibration_frames: @calibration_seconds * sample_fps,
      threshold: Nx.tensor(config.threshold, type: :f32, backend: @backend),
      alpha: Nx.tensor(config.alpha, type: :f32, backend: @backend),
      calibration_alpha: Nx.tensor(@calibration_alpha, type: :f32, backend: @backend)
    }
  end

  @doc """
  Compare one thumbnail against the background, then fold it in.

  The first frame — and the first at a new geometry — *becomes* the
  background and reports the fixed still verdict: calibrating by
  construction, not a cut, there being no comparison behind it. A frame
  whose changed fraction clears the scene-cut rule replaces the background
  outright rather than averaging toward it (during which every frame would
  read as motion), and `frames` deliberately survives and advances: a
  calibrated detector stays calibrated through a light switching on, and a
  camera that cuts on every sample (an IR-cut filter hunting) still finishes
  calibrating rather than sitting at "no motion" for as long as it flickers.
  """
  @spec observe(t(), Thumbnail.t()) :: {verdict(), t()}
  def observe(%__MODULE__{} = detector, %Thumbnail{} = thumb) do
    if detector.size != Thumbnail.size(thumb) do
      {still(), %{take_background(detector, thumb) | frames: 1}}
    else
      compare(detector, thumb)
    end
  end

  defp compare(detector, thumb) do
    # Read before the frame is folded in, so the flag describes the
    # background this frame was compared against rather than the one the
    # comparison produced.
    calibrating = detector.frames < detector.calibration_frames
    frame = Nx.as_type(thumb.tensor, :f32)

    changed =
      frame
      |> Nx.subtract(detector.background)
      |> Nx.abs()
      |> Nx.greater(detector.threshold)
      |> Nx.as_type(:s64)
      |> Nx.sum()
      |> Nx.to_number()

    # The crate divides f32 by f32 once; this divides in f64 and rounds to
    # f32 — bit-identical, provably. Both operands are exact integers under
    # 2^29 (a thumbnail has far fewer pixels), so if the true quotient q is
    # exactly a 25-bit dyadic (an f32 value or a rounding tie) the f64
    # quotient is q itself and both paths round it identically; otherwise
    # q's distance from the nearest such boundary in its binade 2^-k is at
    # least 1/(total * 2^(25+k)) > 2^(-54-k), which exceeds the f64
    # division's rounding error — so the f64 quotient sits on the same side
    # of every f32 boundary as q, and rounding it to f32 gives the crate's
    # result.
    changed_fraction = Config.f32(changed / Nx.size(detector.background))

    if changed_fraction > Config.lightning_fraction() do
      {%{
         changed_fraction: changed_fraction,
         motion: false,
         calibrating: calibrating,
         scene_cut: true
       }, detector |> take_background(thumb) |> advance()}
    else
      settle(detector, frame, changed_fraction, calibrating)
    end
  end

  defp settle(detector, frame, changed_fraction, calibrating) do
    alpha = if calibrating, do: detector.calibration_alpha, else: detector.alpha

    # The crate's exact form and order: `bg += alpha * (px - bg)`, each step
    # its own f32 tensor. An algebraically equal rearrangement
    # (`alpha * px + (1 - alpha) * bg`) rounds differently and would smuggle
    # noise into every later verdict.
    background =
      Nx.add(
        detector.background,
        Nx.multiply(alpha, Nx.subtract(frame, detector.background))
      )

    verdict = %{
      changed_fraction: changed_fraction,
      motion: not calibrating and changed_fraction >= detector.config.min_area_fraction,
      calibrating: calibrating,
      scene_cut: false
    }

    {verdict, advance(%{detector | background: background})}
  end

  # The verdict for a frame there is nothing to compare against.
  defp still,
    do: %{changed_fraction: 0.0, motion: false, calibrating: true, scene_cut: false}

  defp take_background(detector, thumb),
    do: %{detector | background: Nx.as_type(thumb.tensor, :f32), size: Thumbnail.size(thumb)}

  defp advance(detector), do: %{detector | frames: detector.frames + 1}
end
