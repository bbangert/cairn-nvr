defmodule Cairn.Native.Config do
  @moduledoc """
  The two term shapes `cairn-native` decodes — per-VM model config for `init/1`
  and per-stream scene config for `open_stream/3` — and the argv the same model
  config becomes for the canary.

  Every key has to be present in the term: rustler's `NifMap` decode fails on a
  missing one rather than defaulting it, deliberately, so that an absent value
  is spelled `nil` by the host and never guessed by the crate. Filling them in
  is this module's whole job.

  **Seam for task 3.3.** Profile expansion still lives in `Cairn.Config`, which
  produces the six `@model_flags` as argv for a plugin group's command. Until
  3.3 rewrites that to produce this map, callers hand `normalize/1` a plain map
  or keyword list in the same vocabulary the flags use (`backend: "qnn"`,
  `input_size: "640x352"`) and nothing here knows what a profile is.
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

  @type t :: map()

  @doc """
  A model config in the shape `Cairn.Native.init/1` decodes.

  Unknown keys are an error rather than an omission: a misspelled `--backend`
  equivalent that silently kept the default would run every camera on the CPU
  and report nothing wrong.
  """
  @spec normalize(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def normalize(config) do
    given = Map.new(config)

    with :ok <- reject_unknown(given, Map.keys(@model_defaults) ++ [:model]),
         {:ok, model} <- fetch_model(given),
         {:ok, sample_fps} <- fetch_sample_fps(given),
         {:ok, qnn} <- normalize_qnn(Map.get(given, :qnn, %{})) do
      merged = Map.merge(@model_defaults, given)

      {:ok,
       %{
         model: model,
         backend: string(merged.backend),
         model_profile: string(merged.model_profile),
         input_size: string(merged.input_size),
         labels: string(merged.labels),
         allow_label_mismatch: merged.allow_label_mismatch == true,
         embedder_model: string(merged.embedder_model),
         decoder: string(merged.decoder),
         sample_fps: sample_fps,
         qnn: qnn
       }}
    end
  end

  @doc "One stream's scene config, in the shape `Cairn.Native.open_stream/3` decodes."
  @spec stream_params(map() | keyword()) :: {:ok, t()} | {:error, String.t()}
  def stream_params(params) do
    given = Map.new(params)

    case reject_unknown(given, Map.keys(@stream_defaults)) do
      :ok -> {:ok, Map.merge(@stream_defaults, given)}
      error -> error
    end
  end

  @doc """
  The same model config as `cairn-detect` argv, for the canary's probe load.

  Only the model half: the scene knobs (`--motion-json`, `--track-floor-json`,
  `--min-score-json`) are per stream and operator-owned, and nothing about them
  can make a model load or fail to load.
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

  # `sample_fps` reaches the crate as a number where the model fields around it
  # reach it as a string, so a wrong type here is still a wrong type at rustler's
  # decode: it raises inside `Cairn.Native.init/1`, taking the host GenServer
  # with it, rather than coming back as the config error `string/1`'s fields do.
  # The range is the crate's own (`SAMPLE_FPS` in
  # `plugins/cairn-native/src/config.rs`, and the `--sample-fps` value parser),
  # checked twice so the second answer is an error and not a crash.
  defp fetch_sample_fps(given) do
    case Map.get(given, :sample_fps, @model_defaults.sample_fps) do
      fps when is_integer(fps) and fps >= 1 and fps <= 30 -> {:ok, fps}
      other -> {:error, "sample_fps must be an integer in 1..30, got #{inspect(other)}"}
    end
  end

  defp normalize_qnn(qnn) do
    given = Map.new(qnn)

    case reject_unknown(given, Map.keys(@qnn_defaults)) do
      :ok ->
        merged = Map.merge(@qnn_defaults, given)

        {:ok,
         %{
           merged
           | library: string(merged.library),
             performance_mode: string(merged.performance_mode)
         }}

      error ->
        error
    end
  end

  defp reject_unknown(given, known) do
    case Map.keys(given) -- known do
      [] ->
        :ok

      unknown ->
        {:error, "unknown config keys: #{Enum.map_join(Enum.sort(unknown), ", ", &inspect/1)}"}
    end
  end

  # The crate parses these with the same clap value parsers the flags use, so an
  # atom spelling of a flag value (`backend: :qnn`) is the same value.
  defp string(nil), do: nil
  defp string(value) when is_atom(value), do: Atom.to_string(value)
  defp string(value), do: to_string(value)

  defp option(_flag, nil), do: []
  defp option(flag, value), do: [flag, to_string(value)]

  defp flag(flag, true), do: [flag]
  defp flag(_flag, _false), do: []
end
