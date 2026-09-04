defmodule CairnWeb.Api.CameraController do
  @moduledoc """
  Camera inventory for the Home Assistant integration.

  Merges configured cameras (`Cairn.Config.Server`) with live runtime status
  (`Cairn.CameraStatus`). The `id` is stable and used as the HA device
  identifier. Credentials (`rtsp_url`, `substream_url`) are never emitted.

  Zones are listed as `{id, name}` alone: the id is what the `presence_*`
  frames key on and the name is what a client shows, while the outline is
  the editor's business and no consumer's.
  """

  use CairnWeb, :controller

  alias Cairn.CameraControl
  alias Cairn.CameraStatus
  alias Cairn.Config
  alias Cairn.Config.Server

  def index(conn, _params) do
    config = Server.get()
    statuses = CameraStatus.all()

    cameras =
      Enum.map(
        config.cameras,
        &shape(&1, config, Map.get(statuses, &1.id, %{}), CameraControl.get(&1.id))
      )

    json(conn, %{cameras: cameras})
  end

  @doc """
  Runtime control: `POST /api/cameras/:id/control` with any of
  `detection_enabled`, `recording_enabled` (booleans), `min_score` (0..1 or
  null to clear the override). Returns the resulting control state.
  """
  def control(conn, %{"id" => camera_id} = params) do
    with {:ok, _cam} <- camera(camera_id),
         {:ok, attrs} <- validate(params),
         {:ok, control} <- set(camera_id, attrs) do
      json(conn, %{id: camera_id, control: control})
    else
      :unknown_camera -> conn |> put_status(404) |> json(%{error: "unknown camera"})
      {:invalid, field} -> conn |> put_status(422) |> json(%{error: "invalid #{field}"})
    end
  end

  @doc false
  def shape(cam, config, status, control) do
    windows = Config.windows(config, cam)

    %{
      id: cam.id,
      detection: cam.plugin != nil,
      transcode: cam.transcode,
      min_score: cam.min_score,
      windows: %{
        pre_seconds: windows.pre,
        post_seconds: windows.post,
        max_seconds: windows.max
      },
      zones: for(z <- cam.zones, do: %{id: z.id, name: z.name}),
      status: Map.get(status, :status, :unknown),
      probe: safe_probe(Map.get(status, :probe)),
      plugin_status: Map.get(status, :plugin_status),
      control: control
    }
  end

  # CameraStatus probe may be `{:error, term}` (camera in backoff/error) — a
  # tuple Jason can't encode, which would 500 the whole list. Sanitize like the
  # SSE feed does.
  defp safe_probe(probe) when is_map(probe), do: probe
  defp safe_probe({:error, reason}), do: %{error: inspect(reason)}
  defp safe_probe(_), do: nil

  # The fast path: it answers 404 without a call, but it runs in this request's
  # process, ordered against nothing. A delete applied between it and the write
  # is caught by the owner, which checks the published config in the same
  # mailbox the prune runs in — both refusals are the same 404. The owner's
  # `known?/1` is the authority and counts `dormant` rows as known; this
  # pre-check reads only `config.cameras`, so it is narrower and can 404 a
  # disabled camera the owner would otherwise accept.
  defp camera(camera_id) do
    case Server.camera(camera_id) do
      {:ok, cam} -> {:ok, cam}
      :error -> :unknown_camera
    end
  end

  defp set(camera_id, attrs) do
    case CameraControl.set(camera_id, attrs) do
      {:error, :unknown_camera} -> :unknown_camera
      control -> {:ok, control}
    end
  end

  # Collect only the present, valid fields into an atom-keyed attrs map.
  defp validate(params) do
    Enum.reduce_while([:detection_enabled, :recording_enabled, :min_score], {:ok, %{}}, fn
      field, {:ok, acc} ->
        case validate_field(field, Map.fetch(params, Atom.to_string(field))) do
          :absent -> {:cont, {:ok, acc}}
          {:ok, value} -> {:cont, {:ok, Map.put(acc, field, value)}}
          :error -> {:halt, {:invalid, field}}
        end
    end)
  end

  defp validate_field(_field, :error), do: :absent
  defp validate_field(:min_score, {:ok, nil}), do: {:ok, nil}

  defp validate_field(:min_score, {:ok, v}) when is_number(v) and v >= 0 and v <= 1,
    do: {:ok, v / 1}

  defp validate_field(field, {:ok, v})
       when field in [:detection_enabled, :recording_enabled] and
              is_boolean(v),
       do: {:ok, v}

  defp validate_field(_field, {:ok, _v}), do: :error
end
