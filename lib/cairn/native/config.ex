defmodule Cairn.Native.Config do
  @moduledoc """
  The two term shapes `cairn-native` decodes — per-VM model config for `init/1`
  and per-stream scene config for `open_stream/3` — and the argv the same model
  config becomes for the canary.

  Every key has to be present in the term: rustler's `NifMap` decode fails on a
  missing one rather than defaulting it, so an absent value is spelled `nil`.

  Nothing here knows what a profile is: a hardware profile renders itself into
  this vocabulary (`Cairn.Config.Profile.native_config/1`), the same fields it
  renders as plugin argv, and callers that have no profile write the vocabulary
  themselves (`backend: "qnn"`, `input_size: "640x352"`).
  """

  @model_defaults %{
    backend: "ort",
    model_profile: nil,
    input_size: nil,
    labels: nil,
    allow_label_mismatch: false,
    embedder_model: nil,
    decoder: "auto",
    sample_fps: 5,
    qnn: %{}
  }

  @qnn_defaults %{
    library: nil,
    soc_model: nil,
    htp_arch: nil,
    performance_mode: nil,
    vtcm_mb: nil
  }

  @stream_defaults %{
    min_score: %{},
    motion_json: nil,
    track_floor_json: nil,
    stream_epoch: nil
  }

  # Rustler raises on a wrong term type before the guarded NIF body runs, reaching
  # the caller as `badarg` rather than an error value — and `Cairn.Native.Host`
  # calls from its GenServer, so a mistyped config would crash every camera.
  @model_types [
    backend: :string,
    model_profile: {:optional, :string},
    input_size: {:optional, :string},
    labels: {:optional, :string},
    allow_label_mismatch: :boolean,
    embedder_model: {:optional, :string},
    decoder: :string,
    # The crate's own range (`SAMPLE_FPS` in config.rs), checked twice because its
    # check is on the far side of a decode that raises.
    sample_fps: {:integer, 1..30}
  ]

  @qnn_types [
    library: {:optional, :string},
    soc_model: {:optional, :u32},
    htp_arch: {:optional, :u32},
    performance_mode: {:optional, :string},
    vtcm_mb: {:optional, :u32}
  ]

  @stream_types [
    min_score: :score_map,
    motion_json: {:optional, :string},
    track_floor_json: {:optional, :string},
    stream_epoch: {:optional, :string}
  ]

  @type t :: map()

  @doc """
  A model config in the shape `Cairn.Native.init/1` decodes.

  An unknown key is an error: a misspelled `--backend` that silently kept the
  default would run every camera on the CPU and report nothing wrong.
  """
  @spec normalize(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def normalize(config) when is_map(config) or is_list(config) do
    given = Map.new(config)

    with :ok <- reject_unknown(given, Map.keys(@model_defaults) ++ [:model]),
         {:ok, model} <- fetch_model(given),
         {:ok, qnn} <- normalize_qnn(Map.get(given, :qnn, %{})),
         {:ok, fields} <- coerce(@model_types, Map.merge(@model_defaults, given), "") do
      {:ok, Map.merge(fields, %{model: model, qnn: qnn})}
    end
  end

  def normalize(other),
    do: {:error, "config must be a map or keyword list, got #{inspect(other)}"}

  @doc "The rate a config that names none samples at — the crate's own clap value."
  @spec default_sample_fps() :: pos_integer()
  def default_sample_fps, do: @model_defaults.sample_fps

  @doc "One stream's scene config, in the shape `Cairn.Native.open_stream/3` decodes."
  @spec stream_params(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def stream_params(params) when is_map(params) or is_list(params) do
    given = Map.new(params)

    case reject_unknown(given, Map.keys(@stream_defaults)) do
      :ok -> coerce(@stream_types, Map.merge(@stream_defaults, given), "")
      error -> error
    end
  end

  def stream_params(other),
    do: {:error, "params must be a map or keyword list, got #{inspect(other)}"}

  # `ort` is onnxruntime's own CPU execution provider; every other backend name
  # is a device the CPU is the fallback for.
  @cpu_backends ~w(ort)

  @doc """
  Whether this config runs on something other than the CPU.

  False means there is no accelerator to judge, and nothing a CPU baseline could
  be three times faster than (`Cairn.Native.Health`).
  """
  @spec accelerator?(t()) :: boolean()
  def accelerator?(config), do: config.backend not in @cpu_backends

  @doc """
  The same model config as `cairn-detect` argv, for the canary's probe load. The
  model half only: nothing about a scene knob can make a model load or fail to.
  """
  @spec to_argv(t()) :: [String.t()]
  def to_argv(config) do
    [
      "--model",
      config.model,
      "--backend",
      config.backend,
      "--decoder",
      config.decoder,
      "--sample-fps",
      to_string(config.sample_fps)
    ] ++
      flag("--allow-label-mismatch", config.allow_label_mismatch) ++
      option("--model-profile", config.model_profile) ++
      option("--input-size", config.input_size) ++
      option("--labels", config.labels) ++
      option("--embedder-model", config.embedder_model) ++
      option("--qnn-library", config.qnn.library) ++
      option("--qnn-soc-model", config.qnn.soc_model) ++
      option("--qnn-htp-arch", config.qnn.htp_arch) ++
      option("--qnn-performance-mode", config.qnn.performance_mode) ++
      option("--qnn-vtcm-mb", config.qnn.vtcm_mb)
  end

  defp fetch_model(given) do
    case Map.get(given, :model) do
      model when is_binary(model) and model != "" -> {:ok, model}
      nil -> {:error, "model is required"}
      other -> {:error, "model must be a path, got #{inspect(other)}"}
    end
  end

  @qnn_env [
    library: "CAIRN_QNN_LIBRARY",
    soc_model: "CAIRN_QNN_SOC_MODEL",
    htp_arch: "CAIRN_QNN_HTP_ARCH",
    performance_mode: "CAIRN_QNN_PERFORMANCE_MODE",
    vtcm_mb: "CAIRN_QNN_VTCM_MB"
  ]
  @qnn_env_ints ~w(soc_model htp_arch vtcm_mb)a

  @doc """
  The `CAIRN_QNN_*` environment as the `config :cairn, :qnn` keyword.

  Called from runtime.exs, and a function here rather than inline there so
  the parse is testable and a malformed value fails boot naming the
  variable — a bare `String.to_integer` crash names neither, and the vagus
  add-on log is where an operator would have to diagnose it.
  """
  @spec node_qnn_from_env(%{optional(String.t()) => String.t()}) :: keyword()
  def node_qnn_from_env(env) do
    for {key, var} <- @qnn_env, value = Map.get(env, var) do
      {key, parse_env_value(key, var, value)}
    end
  end

  # The full u32 range here, not just integer-ness: the crate decodes these
  # as u32, and an out-of-range value that parsed would fail later as a
  # generic qnn.* error instead of a boot crash naming the variable.
  defp parse_env_value(key, var, value) when key in @qnn_env_ints do
    case Integer.parse(value) do
      {n, ""} when n >= 0 and n <= 4_294_967_295 ->
        n

      _not_a_u32 ->
        raise ArgumentError, "#{var} must be an integer in 0..4294967295, got #{inspect(value)}"
    end
  end

  defp parse_env_value(_key, _var, value), do: value

  # The crate's `RawQnnOptions` is not an `Option`, so a bare `nil` would be a
  # decode error rather than a default.
  defp normalize_qnn(nil), do: normalize_qnn(%{})

  defp normalize_qnn(qnn) when is_map(qnn) or is_list(qnn) do
    given = Map.merge(node_qnn(), Map.new(qnn))

    case reject_unknown(given, Map.keys(@qnn_defaults)) do
      :ok -> coerce(@qnn_types, Map.merge(@qnn_defaults, given), "qnn.")
      error -> error
    end
  end

  defp normalize_qnn(other),
    do: {:error, "qnn must be a map or keyword list, got #{inspect(other)}"}

  # Node-level qnn facts under the model config's: where the EP library sits
  # and what SoC this is belong to the node (the container image, the board),
  # not to a profile, which is a model claim portable across hosts — and the
  # only other override (`Cairn.Native.Host`'s `:config`) pins the whole model
  # config, defeating ladder resolution. `config :cairn, :qnn` is set from
  # CAIRN_QNN_* env in runtime.exs; a typo'd key still errors through
  # `reject_unknown` in `normalize_qnn/1`.
  defp node_qnn, do: Map.new(Application.get_env(:cairn, :qnn, []))

  # In table order, so the message names the first field that is wrong rather
  # than whichever one a map happened to yield first.
  defp coerce(types, given, prefix) do
    Enum.reduce_while(types, {:ok, %{}}, fn {field, type}, {:ok, coerced} ->
      case coerce_field(type, Map.fetch!(given, field)) do
        {:ok, value} -> {:cont, {:ok, Map.put(coerced, field, value)}}
        {:error, problem} -> {:halt, {:error, "#{prefix}#{field} #{problem}"}}
      end
    end)
  end

  defp coerce_field({:optional, _type}, nil), do: {:ok, nil}
  defp coerce_field({:optional, type}, value), do: coerce_field(type, value)

  # The crate parses these with the same clap value parsers the flags use, so an atom
  # or number spelling (`backend: :qnn`, `input_size: 384`) is the same value.
  # Nothing else is: a list or map would become a string nobody wrote.
  defp coerce_field(:string, value) when is_binary(value), do: {:ok, value}

  # Not `Option<String>` on the crate's side, so `nil` is a decode error there and
  # `to_string(nil)` would hide it as the empty string.
  defp coerce_field(:string, nil), do: {:error, "must be a string, got nil"}

  defp coerce_field(:string, value) when is_atom(value) or is_number(value),
    do: {:ok, to_string(value)}

  defp coerce_field(:string, other), do: {:error, "must be a string, got #{inspect(other)}"}

  defp coerce_field(:boolean, value) when is_boolean(value), do: {:ok, value}

  defp coerce_field(:boolean, other),
    do: {:error, "must be true or false, got #{inspect(other)}"}

  defp coerce_field(:u32, value) when is_integer(value) and value >= 0 and value <= 4_294_967_295,
    do: {:ok, value}

  defp coerce_field(:u32, other),
    do: {:error, "must be an integer in 0..4294967295, got #{inspect(other)}"}

  defp coerce_field({:integer, first..last//_}, value)
       when is_integer(value) and value >= first and value <= last,
       do: {:ok, value}

  defp coerce_field({:integer, first..last//_}, other),
    do: {:error, "must be an integer in #{first}..#{last}, got #{inspect(other)}"}

  # `HashMap<String, f64>`: rustler decodes a `String` from a binary term and
  # nothing else, so an atom key is a decode error, while its `f64` takes either
  # spelling of a number.
  defp coerce_field(:score_map, value) when is_map(value) do
    if Enum.all?(value, fn {label, floor} -> is_binary(label) and is_number(floor) end) do
      {:ok, value}
    else
      {:error, score_map_problem(value)}
    end
  end

  defp coerce_field(:score_map, other), do: {:error, score_map_problem(other)}

  defp score_map_problem(value),
    do: "must be a map of label string => number, got #{inspect(value)}"

  defp reject_unknown(given, known) do
    case Map.keys(given) -- known do
      [] ->
        :ok

      unknown ->
        {:error, "unknown config keys: #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}"}
    end
  end

  defp option(_flag, nil), do: []
  defp option(flag, value), do: [flag, to_string(value)]

  defp flag(flag, true), do: [flag]
  defp flag(_flag, _false), do: []
end
