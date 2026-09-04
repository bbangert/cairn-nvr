defmodule Cairn.Zones do
  @moduledoc """
  Polygon zones over a camera's frame: validation, containment, and the
  draft state for the zone editor (phase 4 — nothing in `lib/` drives
  `Draft` yet; `Cairn.Cameras.put_zones/3` is how zones change today). Pure
  — no process, no store.

  A zone's `points` are normalized 0..1 frame coordinates with the origin at
  the top left, and the outline closes implicitly (last → first). Normalized
  because the frame they were drawn on and the frame detection runs on are
  not the same size (`substream_url`), and because a camera can come back at
  a different resolution without the operator's polygons meaning anything
  else.
  """

  alias Cairn.Config

  @typedoc """
  A validated zone. `id` is the stable slug presence is keyed on and never
  changes; `name` is the operator's label and is free to.
  """
  @type zone :: %{id: String.t(), name: String.t(), points: [[float()]]}

  # The inferred defaults D-P6 owns (spike §4.1), not measured numbers: the
  # spacing is ≈ 10 px across a 1080p frame — closer than a finger can aim —
  # and the vertex cap bounds both the config diff and the per-box ray-cast.
  @min_spacing 0.005
  @min_area 1.0e-4
  @max_points 64
  @max_id 32
  @max_name 64

  # A zone id is the camera id's slug space, from the one definition of it —
  # they differ in scope (unique per camera, not per fleet), not in shape.
  @id_regex Regex.compile!("\\A#{Config.Camera.id_class()}\\z")

  @doc """
  Validates one zone (from the config file, a row, or the editor to come)
  against the ids already taken on its camera, returning the atom-keyed
  zone.

  Accepts string- or atom-keyed input (the stored shape is string-keyed).
  Every failing rule is reported, so an operator fixes one outline once —
  except the four geometry rules, which are skipped when the points are not
  `[x, y]` pairs at all: each destructures a pair and would raise, so the
  guard is load-bearing, not tidiness.
  """
  @spec validate(term(), [String.t()]) :: {:ok, zone()} | {:error, [String.t()]}
  def validate(raw, existing_ids) when is_map(raw) do
    id = fetch(raw, :id)
    name = fetch(raw, :name)
    points = fetch(raw, :points)

    case id_errors(id, existing_ids) ++ name_errors(name) ++ point_errors(points) do
      [] -> {:ok, %{id: id, name: String.trim(name), points: floats(points)}}
      errors -> {:error, errors}
    end
  end

  def validate(_raw, _existing_ids), do: {:error, ["a zone must be a mapping"]}

  # No `String.to_existing_atom` on the key: the atom form is what a caller
  # inside the VM passes, the string form is what storage and the wire carry.
  defp fetch(raw, key) do
    case Map.fetch(raw, key) do
      {:ok, value} -> value
      :error -> Map.get(raw, Atom.to_string(key))
    end
  end

  defp id_errors(id, existing_ids) do
    cond do
      not (is_binary(id) and id =~ @id_regex and String.length(id) <= @max_id) ->
        ["use lowercase letters, digits, - and _"]

      id in existing_ids ->
        ["already used on this camera"]

      true ->
        []
    end
  end

  defp name_errors(name) when is_binary(name) do
    trimmed = String.trim(name)

    cond do
      trimmed == "" -> ["give the zone a name"]
      String.length(trimmed) > @max_name -> ["name is too long (#{@max_name} max)"]
      true -> []
    end
  end

  defp name_errors(_name), do: ["give the zone a name"]

  defp point_errors(points) do
    if pairs?(points) do
      in_frame_errors(points) ++
        count_errors(points) ++
        spacing_errors(points) ++ area_errors(points) ++ shape_errors(points)
    else
      ["points must be a list of [x, y] pairs"]
    end
  end

  defp pairs?(points) when is_list(points) do
    Enum.all?(points, fn
      [x, y] -> is_number(x) and is_number(y)
      _other -> false
    end)
  end

  defp pairs?(_points), do: false

  defp in_frame_errors(points) do
    if Enum.all?(points, fn [x, y] -> in_frame?(x) and in_frame?(y) end),
      do: [],
      else: ["a point is outside the frame"]
  end

  defp in_frame?(v), do: v >= 0 and v <= 1

  # Counted after collapsing the duplicates: three vertices two of which are
  # the same point is a line, and the spacing rule below reports the pair.
  defp count_errors(points) do
    too_few = if length(dedupe(points)) < 3, do: ["a zone needs at least 3 points"], else: []

    too_many =
      if length(points) > @max_points, do: ["too many points (#{@max_points} max)"], else: []

    too_few ++ too_many
  end

  # Deliberately not silent: the operator's points are the operator's, so a
  # doubled vertex is refused rather than quietly dropped from what is saved.
  defp spacing_errors(points) do
    if Enum.any?(edges(points), fn {a, b} -> too_close?(a, b) end),
      do: ["two points are on top of each other"],
      else: []
  end

  defp area_errors(points) do
    if shoelace_area(points) < @min_area, do: ["the zone has no area"], else: []
  end

  defp shape_errors(points) do
    if self_intersecting?(points), do: ["the outline crosses itself"], else: []
  end

  defp dedupe([]), do: []

  defp dedupe(points) do
    kept = points |> Enum.reduce([], &drop_repeat/2) |> Enum.reverse()

    # The closing edge duplicates like any other: a polygon whose last point
    # sits on its first has one vertex fewer than it looks.
    case kept do
      [first | [_ | _]] ->
        if too_close?(List.last(kept), first), do: Enum.drop(kept, -1), else: kept

      _single_or_empty ->
        kept
    end
  end

  defp drop_repeat(point, []), do: [point]

  defp drop_repeat(point, [last | _rest] = kept) do
    if too_close?(point, last), do: kept, else: [point | kept]
  end

  @doc """
  Whether two points are too close to be distinct vertices — the spacing
  floor `validate/2` enforces, and the double-tap guard `Draft.add_point/2`
  applies for the editor.
  """
  @spec too_close?([number()], [number()]) :: boolean()
  def too_close?([ax, ay], [bx, by]) do
    :math.sqrt((ax - bx) * (ax - bx) + (ay - by) * (ay - by)) < @min_spacing
  end

  defp shoelace_area(points) do
    points
    |> edges()
    |> Enum.reduce(0.0, fn {[ax, ay], [bx, by]}, sum -> sum + (ax * by - bx * ay) end)
    |> abs()
    |> Kernel./(2)
  end

  @doc """
  Whether the outline crosses itself. A bow-tie is rejected at Close (D-P6)
  because the even-odd ray-cast below reads it as two lobes with the crossing
  excluded — a shape nobody drew.
  """
  @spec self_intersecting?([[number()]]) :: boolean()
  def self_intersecting?(points) when length(points) < 4, do: false

  def self_intersecting?(points) do
    last = length(points) - 1
    edges = points |> edges() |> Enum.with_index()

    Enum.any?(edges, fn {{a, b}, i} ->
      Enum.any?(edges, fn {{c, d}, j} ->
        # Adjacent edges share a vertex, so their touching is not a crossing;
        # the first and last edge are adjacent through the closing point.
        j > i + 1 and not (i == 0 and j == last) and segments_cross?(a, b, c, d)
      end)
    end)
  end

  defp segments_cross?(a, b, c, d) do
    o1 = orient(a, b, c)
    o2 = orient(a, b, d)
    o3 = orient(c, d, a)
    o4 = orient(c, d, b)

    (o1 * o2 < 0 and o3 * o4 < 0) or touches?(a, b, c, o1) or touches?(a, b, d, o2) or
      touches?(c, d, a, o3) or touches?(c, d, b, o4)
  end

  # A collinear endpoint is a crossing only when it lies on the other segment
  # rather than on its extension.
  defp touches?(a, b, p, 0), do: on_segment?(a, b, p)
  defp touches?(_a, _b, _p, _orientation), do: false

  # Sign of the cross product (b - a) × (c - a): 1 left turn, -1 right, 0
  # collinear. The epsilon keeps a float rounding error off the collinear arm,
  # where it would report a touch that is not one.
  defp orient([ax, ay], [bx, by], [cx, cy]) do
    v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)

    cond do
      v > 1.0e-12 -> 1
      v < -1.0e-12 -> -1
      true -> 0
    end
  end

  # Only ever asked about a point already known collinear with the segment,
  # so the bounding box is the whole test.
  defp on_segment?([ax, ay], [bx, by], [px, py]) do
    px >= min(ax, bx) and px <= max(ax, bx) and py >= min(ay, by) and py <= max(ay, by)
  end

  @doc """
  The presence keys `old` could mint that `new` cannot: the ids whose outline
  moved or that are gone, with the whole-frame key `nil` standing in for a
  zoneless list.

  A rename clears nothing — the id is the key presence is held under, and
  `docs/ha-api.md` promises it survives one. A reshape must clear: a state
  announced under the old outline can sit outside the new one, and on a still
  scene no later batch would ever be evidence against it.
  """
  @spec removed([zone()], [zone()]) :: [String.t() | nil]
  def removed([], []), do: []
  def removed([], _new), do: [nil]
  def removed(old, []), do: Enum.map(old, & &1.id)

  def removed(old, new) do
    outlines = Map.new(new, &{&1.id, &1.points})

    for zone <- old, Map.get(outlines, zone.id) != zone.points, do: zone.id
  end

  @doc """
  The ids of every zone containing `bbox`, in the order the zones were given.

  The test point is the box's bottom centre `{x + w/2, y + h}` clamped into
  the frame — where the object meets the ground, so a person's zone is the
  one they are standing in rather than every zone their head reaches into.
  A box the frame clips at the bottom counts in the zone its foot lands in.
  Overlapping and nested zones are legal (D-P6), so a box can count in
  several at once.

  A point exactly on an edge is deterministic: the ray runs +x and a crossing
  counts only when `px < x_intersect`, so the point belongs to the zone lying
  to its **right** and never to both sides of a shared edge. Zones reaching
  here are validated (`Cairn.Config` parses them at load), so no shape is
  defended against.
  """
  @spec hits([zone()], [number()]) :: [String.t()]
  def hits(zones, [x, y, w, h]) do
    px = clamp01(x + w / 2)
    py = clamp01(y + h)

    for zone <- zones, contains?(zone.points, px, py), do: zone.id
  end

  defp contains?(points, px, py) do
    points
    |> edges()
    |> Enum.reduce(false, fn edge, inside ->
      if crosses_ray?(edge, px, py), do: not inside, else: inside
    end)
  end

  # Half-open in y: an edge counts where it starts above the ray and not where
  # it ends there, so a vertex on the ray is one crossing rather than two.
  defp crosses_ray?({[xi, yi], [xj, yj]}, px, py) do
    above_i = yi > py
    above_j = yj > py

    above_i != above_j and px < (xj - xi) * (py - yi) / (yj - yi) + xi
  end

  # Every edge including the closing one, as {from, to} pairs. An empty
  # outline has none — `validate/2` reaches here with `[]` on its way to
  # the count error, and `hd/1` would turn that report into a crash.
  defp edges([]), do: []
  defp edges(points), do: Enum.zip(points, tl(points) ++ [hd(points)])

  defp floats(points), do: Enum.map(points, fn [x, y] -> [x / 1, y / 1] end)

  # Clamped just INSIDE the frame, not onto its far edge: the crossing rule
  # counts an edge at its lower-y endpoint, so a foot at exactly y = 1.0 is
  # outside a zone drawn down to the bottom of the frame — and y = 1.0 is
  # exactly where the foot of a box clipped by the bottom of the frame lands,
  # which is every person walking out of shot.
  @inside_frame 1.0 - 1.0e-9

  defp clamp01(v), do: v |> max(0) |> min(@inside_frame) |> Kernel./(1)

  defmodule Draft do
    @moduledoc """
    The outline being drawn, as LiveView assigns: what the phase-4 editor's
    `zone-*` events will fold over (no caller in `lib/` yet). State only —
    the rubber band and the drag preview belong to the browser hook and
    never come here.
    """

    alias Cairn.Zones

    @typedoc """
    `editing` carries the id of the saved zone this draft replaces, `nil`
    while drawing a new one — the editor is to disable the id field on it.
    """
    @type t :: %{points: [[float()]], closed?: boolean(), editing: nil | String.t()}

    @spec new() :: t()
    def new, do: %{points: [], closed?: false, editing: nil}

    @spec add_point(t(), [number()]) :: t()
    def add_point(%{closed?: true} = draft, _point), do: draft

    def add_point(%{points: points} = draft, point) do
      point = clamp(point)

      case points do
        [_ | _] ->
          if Zones.too_close?(point, List.last(points)), do: draft, else: append(draft, point)

        [] ->
          append(draft, point)
      end
    end

    defp append(%{points: points} = draft, point), do: %{draft | points: points ++ [point]}

    @spec move_point(t(), integer(), [number()]) :: t()
    def move_point(%{points: points} = draft, index, point)
        when is_integer(index) and index >= 0 do
      if index < length(points),
        do: %{draft | points: List.replace_at(points, index, clamp(point))},
        else: draft
    end

    def move_point(draft, _index, _point), do: draft

    @doc """
    Undoes the last act, which on a closed draft is the close itself — so it
    reopens rather than dropping a vertex the operator can still see.
    """
    @spec undo(t()) :: t()
    def undo(%{closed?: true} = draft), do: %{draft | closed?: false}
    def undo(%{points: []} = draft), do: draft
    def undo(%{points: points} = draft), do: %{draft | points: Enum.drop(points, -1)}

    @spec close(t()) :: {:ok, t()} | {:error, String.t()}
    def close(%{points: points}) when length(points) < 3,
      do: {:error, "a zone needs at least 3 points"}

    def close(%{points: points} = draft) do
      if Zones.self_intersecting?(points),
        do: {:error, "the outline crosses itself"},
        else: {:ok, %{draft | closed?: true}}
    end

    # The surface can report a pointer just outside itself (a drag released
    # off the frame); the frame is what a zone is in.
    defp clamp([x, y]), do: [clamp01(x), clamp01(y)]

    defp clamp01(v), do: v |> max(0) |> min(1) |> Kernel./(1)
  end
end
