defmodule Cairn.Motion.Config do
  @moduledoc """
  The motion gate's knobs, exactly as `plugins/cairn-detect/src/motion.rs`
  spells them: the same JSON vocabulary (`--motion-json` / a camera's
  `motion` key), the same defaults, the same refusals, the same layering —
  defaults, then the global overrides, then the camera's own, each layer
  overriding only the knobs it names.

  The float knobs are stored **rounded to single precision** (`f32/1`),
  because that is what the crate's serde parse does to them — and
  `Cairn.Motion`'s verdict boundaries (`>=` the area floor, `>` the
  scene-cut fraction) are exact comparisons against these values, so holding
  them at double precision would move the boundaries by a hair and change
  which frames get inferred.

  `resolve/2` returning `nil` is the difference between "off" and "on with a
  threshold of zero": no detector is built, no thumbnail is taken, and the
  buffer metadata's `motion` stays absent all the way to the model.
  """

  f32 = fn x ->
    <<value::float-32>> = <<x::float-32>>
    value
  end

  @default_threshold 25
  @default_min_area_fraction f32.(0.005)
  @default_alpha f32.(0.02)
  @default_linger_ms 12_000
  @default_epoch_bypass_ms 15_000
  @default_reverify_ms 10_000

  # Changed fraction above which a frame is a scene cut, not motion — the
  # algorithm constant `Cairn.Motion` decides on; validation needs it because
  # an area floor at or above it is unreachable.
  @lightning_fraction f32.(0.8)

  defstruct enabled: false,
            threshold: @default_threshold,
            min_area_fraction: @default_min_area_fraction,
            alpha: @default_alpha,
            linger_ms: @default_linger_ms,
            epoch_bypass_ms: @default_epoch_bypass_ms,
            reverify_ms: @default_reverify_ms

  @typedoc """
  The resolved knobs one camera's detector runs under. `linger_ms`,
  `epoch_bypass_ms` and `reverify_ms` belong to the gate *policy* and are
  read by the inference side's gate, not by the measurement — carried here
  so the vocabulary stays one shape on both paths.
  """
  @type t :: %__MODULE__{
          enabled: boolean(),
          threshold: 1..254,
          min_area_fraction: float(),
          alpha: float(),
          linger_ms: non_neg_integer(),
          epoch_bypass_ms: non_neg_integer(),
          reverify_ms: non_neg_integer()
        }

  @typedoc "One layer of overrides: only the knobs it names, `nil` for unset."
  @type overrides :: %{optional(atom()) => term()}

  @knobs %{
    "enabled" => :enabled,
    "threshold" => :threshold,
    "min_area_fraction" => :min_area_fraction,
    "alpha" => :alpha,
    "linger_ms" => :linger_ms,
    "epoch_bypass_ms" => :epoch_bypass_ms,
    "reverify_ms" => :reverify_ms
  }

  @doc """
  The nearest single-precision value, as an Elixir float.

  Widening f32 to f64 is exact, so a value that went through this helper
  compares `==` against the same f32 held by the crate — the property every
  exactness claim in `Cairn.Motion` rests on.
  """
  @spec f32(number()) :: float()
  def f32(x) when is_number(x) do
    <<value::float-32>> = <<x::float-32>>
    value
  end

  @doc "The scene-cut fraction, for `Cairn.Motion` and for `validate/1`."
  @spec lightning_fraction() :: float()
  def lightning_fraction, do: @lightning_fraction

  @doc """
  Decode one JSON layer of knobs, refusing what no run could honour.

  Unknown keys are errors, as the crate's `deny_unknown_fields`: the failure
  mode of a mistyped knob is a gate that silently runs on defaults. An
  explicitly `null` knob reads as unset, exactly as serde maps it.
  """
  @spec parse(String.t()) :: {:ok, overrides()} | {:error, String.t()}
  def parse(json) when is_binary(json) do
    with {:ok, decoded} <- decode(json),
         {:ok, overrides} <- take_knobs(decoded),
         :ok <- validate(overrides) do
      {:ok, overrides}
    end
  end

  @doc """
  Reject a knob no run could honour, at the point the operator can still read
  the message.

  Two of these are rules from the measurement rather than range checks: a
  threshold of 255 counts no pixel as changed (the per-pixel compare is
  strict and 255 is the largest difference there is), and an area floor at
  or above the scene-cut fraction is swallowed by that rule before it is
  ever reached. Both messages name the rule, because the symptom they
  produce — a gate that starts clean and answers the same thing for every
  frame it will ever see — is not diagnosable from outside this module.
  """
  @spec validate(overrides()) :: :ok | {:error, String.t()}
  def validate(overrides) do
    with :ok <- validate_threshold(Map.get(overrides, :threshold)),
         :ok <- validate_fraction(Map.get(overrides, :min_area_fraction)) do
      validate_alpha(Map.get(overrides, :alpha))
    end
  end

  @doc """
  The config one camera measures under: defaults, then the process-wide
  layer, then that camera's own — `nil` when the resolved gate is disabled,
  which is the default.
  """
  @spec resolve(overrides(), overrides()) :: t() | nil
  def resolve(global, per_camera) do
    config = %__MODULE__{} |> apply_overrides(global) |> apply_overrides(per_camera)
    if config.enabled, do: config
  end

  @doc """
  One `motion_json` straight to a resolved config — the exact resolution the
  decode NIF applies to the same string (`RawDecoderParams`: the JSON as the
  global layer, nothing camera-specific on top). `nil` in is the gate left
  unconfigured.
  """
  @spec resolve_json(String.t() | nil) :: {:ok, t() | nil} | {:error, String.t()}
  def resolve_json(nil), do: {:ok, nil}

  def resolve_json(json) when is_binary(json) do
    with {:ok, overrides} <- parse(json) do
      {:ok, resolve(overrides, %{})}
    end
  end

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _other} ->
        {:error, "motion knobs must be a JSON object"}

      {:error, _reason} ->
        {:error, "motion knobs are not valid JSON"}
    end
  end

  defp take_knobs(decoded) do
    Enum.reduce_while(decoded, {:ok, %{}}, fn {key, value}, {:ok, overrides} ->
      with {:ok, knob} <- knob(key),
           {:ok, value} <- coerce(knob, value) do
        {:cont, {:ok, Map.put(overrides, knob, value)}}
      else
        {:error, _message} = error -> {:halt, error}
      end
    end)
  end

  defp knob(key) do
    case Map.fetch(@knobs, key) do
      {:ok, knob} -> {:ok, knob}
      :error -> {:error, "unknown motion knob #{inspect(key)}"}
    end
  end

  # `null` is the same "unset" an absent key produces — serde's reading,
  # pinned by the crate's own tests, so a template layer that emits nulls for
  # the knobs it has no value for runs on the defaults.
  defp coerce(_knob, nil), do: {:ok, nil}

  defp coerce(:enabled, value) when is_boolean(value), do: {:ok, value}

  defp coerce(:enabled, value),
    do: {:error, "enabled must be true or false, got #{inspect(value)}"}

  defp coerce(:threshold, value) when is_integer(value) and value in 0..255, do: {:ok, value}

  defp coerce(:threshold, value),
    do: {:error, "threshold must be an integer in 0..255, got #{inspect(value)}"}

  # The crate parses these into f32 fields; rounding here is what keeps the
  # `>=`/`>` boundaries downstream on the same side for the same inputs.
  defp coerce(knob, value) when knob in [:min_area_fraction, :alpha] and is_number(value),
    do: {:ok, f32(value)}

  defp coerce(knob, value) when knob in [:min_area_fraction, :alpha],
    do: {:error, "#{knob} must be a number, got #{inspect(value)}"}

  # Bounded above as well as below: the same JSON reaches the inference
  # side's Rust parser, whose u64 fields refuse anything larger — accepting
  # it here would build a pipeline that only fails at stream open.
  defp coerce(_knob, value)
       when is_integer(value) and value >= 0 and value <= 18_446_744_073_709_551_615,
       do: {:ok, value}

  defp coerce(knob, value),
    do: {:error, "#{knob} must be a non-negative 64-bit integer, got #{inspect(value)}"}

  defp validate_threshold(nil), do: :ok

  defp validate_threshold(0),
    do: {:error, "motion threshold must be 1..=254; 0 counts every pixel as changed"}

  defp validate_threshold(255) do
    {:error,
     "motion threshold must be 1..=254; the per-pixel compare is strict and 255 " <>
       "is the largest difference there is, so 255 counts no pixel as changed"}
  end

  defp validate_threshold(_threshold), do: :ok

  defp validate_fraction(nil), do: :ok

  defp validate_fraction(fraction) when not (fraction > 0.0 and fraction <= 1.0),
    do: {:error, "motion min_area_fraction must be in (0, 1], got #{fraction}"}

  defp validate_fraction(fraction) when fraction >= @lightning_fraction do
    {:error,
     "motion min_area_fraction must be below #{@lightning_fraction}, got #{fraction}: " <>
       "a frame that changes more than that share of the thumbnail is treated as a " <>
       "scene cut and reports no motion, so a floor at or above it is reachable at " <>
       "best by a frame that changes exactly that share"}
  end

  defp validate_fraction(_fraction), do: :ok

  defp validate_alpha(nil), do: :ok

  defp validate_alpha(alpha) when not (alpha > 0.0 and alpha <= 1.0),
    do: {:error, "motion alpha must be in (0, 1], got #{alpha}"}

  defp validate_alpha(_alpha), do: :ok

  defp apply_overrides(config, overrides) do
    Enum.reduce(overrides, config, fn
      {_knob, nil}, config -> config
      {knob, value}, config -> Map.replace!(config, knob, value)
    end)
  end
end
