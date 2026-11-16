defmodule Cairn.Stage.FrameMeta do
  @moduledoc """
  The buffer metadata a decode-side element owes an infer-side one: the
  source geometry, when the frame was sampled, the session it belongs to and,
  when something measured it, the motion verdict.

  `fetch/1` never raises, because an infer element drops and counts a frame
  without these keys rather than crash on a producer that speaks the stream
  format but not this contract. The base's inference element matches the keys
  itself rather than call this; its suite holds the two lists together.
  """

  @required [:orig_width, :orig_height, :observed_at_ms, :stream_epoch]

  @typedoc "The motion measurement, when a decoder or a gate took one."
  @type motion_verdict :: %{
          changed_fraction: float(),
          motion: boolean(),
          calibrating: boolean(),
          scene_cut: boolean()
        }

  @type t :: %{
          required(:orig_width) => pos_integer(),
          required(:orig_height) => pos_integer(),
          required(:observed_at_ms) => integer(),
          required(:stream_epoch) => term(),
          optional(:motion) => motion_verdict() | nil,
          optional(atom()) => term()
        }

  @spec required_keys() :: [atom()]
  def required_keys, do: @required

  @spec fetch(term()) :: {:ok, t()} | :error
  def fetch(metadata) when is_map(metadata) do
    if Enum.all?(@required, &Map.has_key?(metadata, &1)), do: {:ok, metadata}, else: :error
  end

  def fetch(_metadata), do: :error
end
