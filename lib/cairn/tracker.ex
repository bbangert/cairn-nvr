defmodule Cairn.Tracker do
  @moduledoc """
  Pure greedy-IoU object tracker: assigns stable object ids to detections
  across batches. Objects unmatched for `@max_misses` consecutive batches
  are dropped.

  Bboxes are `[x, y, w, h]` in any consistent unit (normalized or pixels).
  """

  @iou_threshold 0.1
  @max_misses 5

  defstruct next_id: 1, objects: %{}

  @type bbox :: [number()]
  @type detection :: %{
          required(:label) => String.t(),
          required(:bbox) => bbox(),
          optional(any()) => any()
        }
  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Drops every tracked object while keeping the id counter, so nothing
  matches across the cut and no id is ever handed out twice.
  """
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = tracker), do: %{tracker | objects: %{}}

  @doc "Returns `{tracker, detections_with_object_id}`."
  @spec track(t(), [detection()]) :: {t(), [map()]}
  def track(%__MODULE__{} = tracker, dets) do
    pairs =
      for {det, di} <- Enum.with_index(dets),
          {id, obj} <- tracker.objects,
          obj.label == det.label,
          iou = iou(obj.bbox, det.bbox),
          iou >= @iou_threshold do
        {iou, di, id}
      end

    {assignments, _used_dets, _used_objs} =
      pairs
      |> Enum.sort_by(fn {iou, _, _} -> -iou end)
      |> Enum.reduce({%{}, MapSet.new(), MapSet.new()}, fn {_iou, di, id},
                                                           {asg, used_d, used_o} ->
        if MapSet.member?(used_d, di) or MapSet.member?(used_o, id) do
          {asg, used_d, used_o}
        else
          {Map.put(asg, di, id), MapSet.put(used_d, di), MapSet.put(used_o, id)}
        end
      end)

    {tracker, tagged} =
      dets
      |> Enum.with_index()
      |> Enum.reduce({tracker, []}, fn {det, di}, {trk, acc} ->
        case Map.fetch(assignments, di) do
          {:ok, id} ->
            objects = Map.put(trk.objects, id, %{label: det.label, bbox: det.bbox, misses: 0})
            {%{trk | objects: objects}, [Map.put(det, :object_id, id) | acc]}

          :error ->
            id = trk.next_id
            objects = Map.put(trk.objects, id, %{label: det.label, bbox: det.bbox, misses: 0})

            {%{trk | next_id: id + 1, objects: objects}, [Map.put(det, :object_id, id) | acc]}
        end
      end)

    matched_ids = MapSet.new(Map.values(assignments))
    new_ids = tagged |> Enum.map(& &1.object_id) |> MapSet.new()

    objects =
      tracker.objects
      |> Enum.map(fn {id, obj} ->
        if MapSet.member?(matched_ids, id) or MapSet.member?(new_ids, id) do
          {id, obj}
        else
          {id, %{obj | misses: obj.misses + 1}}
        end
      end)
      |> Enum.reject(fn {_id, obj} -> obj.misses > @max_misses end)
      |> Map.new()

    {%{tracker | objects: objects}, Enum.reverse(tagged)}
  end

  @doc "Intersection-over-union of two `[x, y, w, h]` boxes."
  @spec iou(bbox(), bbox()) :: float()
  def iou([ax, ay, aw, ah], [bx, by, bw, bh]) do
    ix = max(ax, bx)
    iy = max(ay, by)
    ix2 = min(ax + aw, bx + bw)
    iy2 = min(ay + ah, by + bh)

    inter = max(ix2 - ix, 0) * max(iy2 - iy, 0)
    union = aw * ah + bw * bh - inter

    if union <= 0, do: 0.0, else: inter / union
  end
end
