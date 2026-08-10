defmodule Cairn.Pipeline.SampleGate do
  @moduledoc """
  The wall-clock rate gate: which decoded frames become *model passes*.

  `sample_fps`'s one home. The crate used to hold this rule (`Stream::push_au`,
  after the decoder and before the tensor); with decode its own element the
  rule lives in the pipeline, and nothing native second-guesses it — the NIF
  reads the same configured rate only to size the motion detector's
  frame-counted calibration window.

  The semantics phase 3 of the membrane port measured for, restated:

    * sampling decides model passes, **not** decode — every access unit is
      decoded whatever this gate says, because a stateful decoder needs its
      references. Thinning before the decoder caps detection at the GOP rate.
    * the clock is the wall clock, not pts: a burst of access units delivered
      at once must not multiply passes.
    * the interval is spent when a frame **completed** decode under an open
      gate — whether or not its conversion then succeeded, and whether or not
      the motion gate goes on to skip it. A sample is an admission, not a
      model pass.

  Two calls, because the admission is decided *before* the decode call and
  spent only on its answer: `open?/2` before `Cairn.Native.decode_au/4`, then
  `spend/2` when the gate was open and the decoder reported a completed frame.
  """

  @enforce_keys [:interval_ns]
  defstruct [:interval_ns, last: nil]

  @type t :: %__MODULE__{interval_ns: pos_integer(), last: integer() | nil}

  @typedoc "`System.monotonic_time(:nanosecond)`"
  @type now :: integer()

  @doc """
  A gate admitting `sample_fps` frames a second.

  Integer nanoseconds, not a float reciprocal: exact for every legal rate, and
  the same arithmetic as the crate's `decode::sample_interval` — two spellings
  of this interval would be two sample rates.
  """
  @spec new(1..30) :: t()
  def new(sample_fps) when is_integer(sample_fps) and sample_fps in 1..30 do
    %__MODULE__{interval_ns: div(1_000_000_000, sample_fps)}
  end

  @doc "Whether a frame completing now would be admitted."
  @spec open?(t(), now()) :: boolean()
  def open?(%__MODULE__{last: nil}, _now), do: true
  def open?(%__MODULE__{last: last, interval_ns: interval}, now), do: now - last >= interval

  @doc """
  Spend the interval: a frame completed decode while the gate was open.

  The caller's contract is `open?/2` first — spending on a frame that was
  never admitted would stretch the gap between real samples past what
  `sample_fps` asks for.
  """
  @spec spend(t(), now()) :: t()
  def spend(%__MODULE__{} = gate, now), do: %{gate | last: now}
end
