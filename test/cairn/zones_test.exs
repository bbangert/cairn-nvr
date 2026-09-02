defmodule Cairn.ZonesTest do
  use ExUnit.Case, async: true

  alias Cairn.Zones
  alias Cairn.Zones.Draft

  @triangle [[0, 0], [1, 0], [1, 1]]
  @square [[0, 0], [1, 0], [1, 1], [0, 1]]
  # Crossing edges with a non-zero shoelace sum, so the shape rule is the only
  # one it breaks.
  @bowtie [[0, 0], [1, 1], [1, 0], [0, 0.6]]

  defp zone(overrides) do
    Map.merge(%{"id" => "drive", "name" => "Driveway", "points" => @triangle}, overrides)
  end

  defp errors(overrides, existing \\ []) do
    {:error, errors} = Zones.validate(zone(overrides), existing)
    errors
  end

  describe "removed/2" do
    defp z(id, points), do: %{id: id, name: "Z", points: points}

    test "a zone that vanished is removed, one that only got a new name is not" do
      assert Zones.removed([z("drive", @square)], []) == ["drive"]
      assert Zones.removed([z("drive", @square)], [%{z("drive", @square) | name: "Yard"}]) == []
    end

    test "a reshaped outline is removed under its own id" do
      assert Zones.removed([z("drive", @square)], [z("drive", @triangle)]) == ["drive"]
    end

    test "the zoneless list stands for the whole-frame key" do
      assert Zones.removed([], [z("drive", @square)]) == [nil]
      assert Zones.removed([], []) == []
    end

    test "a zone added beside an untouched one clears nothing" do
      old = [z("drive", @square)]
      assert Zones.removed(old, old ++ [z("porch", @triangle)]) == []
    end
  end

  describe "validate/2" do
    test "a well-formed zone comes back atom-keyed with float points" do
      assert {:ok, parsed} = Zones.validate(zone(%{}), [])

      assert parsed == %{
               id: "drive",
               name: "Driveway",
               points: [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0]]
             }
    end

    test "atom keys parse too, and the name is stored trimmed" do
      assert {:ok, parsed} =
               Zones.validate(%{id: "drive", name: "  Driveway  ", points: @triangle}, [])

      assert parsed.name == "Driveway"
    end

    test "an id outside the slug space is refused" do
      for bad <- ["Bad Id", "-lead", "", "drive\n", String.duplicate("a", 33), nil, :drive] do
        assert errors(%{"id" => bad}) == ["use lowercase letters, digits, - and _"]
      end

      assert {:ok, _zone} = Zones.validate(zone(%{"id" => String.duplicate("a", 32)}), [])
    end

    test "an id already on this camera is refused" do
      assert errors(%{}, ["walk", "drive"]) == ["already used on this camera"]
      assert {:ok, _zone} = Zones.validate(zone(%{}), ["walk"])
    end

    test "a missing or blank name is refused, an over-long one says so" do
      for bad <- ["", "   ", nil, 7] do
        assert errors(%{"name" => bad}) == ["give the zone a name"]
      end

      assert errors(%{"name" => String.duplicate("n", 65)}) == ["name is too long (64 max)"]
      assert {:ok, _zone} = Zones.validate(zone(%{"name" => String.duplicate("n", 64)}), [])
    end

    test "points that are not [x, y] pairs report the shape and nothing else" do
      for bad <- ["nope", nil, [[0, 0], [1]], [[0, 0], [1, "y"]], [%{"x" => 0}]] do
        assert errors(%{"points" => bad}) == ["points must be a list of [x, y] pairs"]
      end
    end

    test "a point outside the frame is refused" do
      assert "a point is outside the frame" in errors(%{"points" => [[0, 0], [1.5, 0], [1, 1]]})
      assert "a point is outside the frame" in errors(%{"points" => [[0, -0.1], [1, 0], [1, 1]]})
    end

    test "fewer than three points is refused, counted after the duplicates collapse" do
      assert "a zone needs at least 3 points" in errors(%{"points" => [[0, 0], [1, 0]]})

      # Three vertices, two of them the same point: a line with a spare.
      assert "a zone needs at least 3 points" in errors(%{
               "points" => [[0, 0], [0, 0.001], [1, 0]]
             })
    end

    test "more than 64 points is refused" do
      circle =
        for i <- 0..64 do
          a = 2 * :math.pi() * i / 65
          [0.5 + 0.4 * :math.cos(a), 0.5 + 0.4 * :math.sin(a)]
        end

      assert length(circle) == 65
      assert errors(%{"points" => circle}) == ["too many points (64 max)"]
    end

    test "two points on top of each other are refused rather than silently dropped" do
      assert errors(%{"points" => [[0, 0], [0.002, 0], [1, 0.5], [0, 1]]}) ==
               ["two points are on top of each other"]

      # The closing edge counts: a last point back on the first is the same fault.
      assert "two points are on top of each other" in errors(%{
               "points" => [[0, 0], [1, 0], [1, 1], [0.001, 0]]
             })
    end

    test "a shape with no area is refused" do
      assert errors(%{"points" => [[0, 0], [1, 0], [0.5, 0.00015]]}) == ["the zone has no area"]
    end

    test "an outline that crosses itself is refused" do
      assert errors(%{"points" => @bowtie}) == ["the outline crosses itself"]
    end

    test "a concave outline is fine — only crossings are not" do
      l_shape = [[0, 0], [0.6, 0], [0.6, 0.3], [0.3, 0.3], [0.3, 0.6], [0, 0.6]]

      assert {:ok, parsed} = Zones.validate(zone(%{"points" => l_shape}), [])
      assert length(parsed.points) == 6
    end

    test "every broken rule is reported, in the order the operator reads them" do
      assert errors(%{"id" => "Bad Id", "name" => "", "points" => [[0, 0], [1, 0]]}) == [
               "use lowercase letters, digits, - and _",
               "give the zone a name",
               "a zone needs at least 3 points",
               "the zone has no area"
             ]
    end

    test "a zone that is not a mapping is refused" do
      assert Zones.validate("drive", []) == {:error, ["a zone must be a mapping"]}
    end

    # A key absent and a key set to nil reach `pairs?/1` the same way, so the
    # zone an operator simply forgot to draw fails as a shape, not as a crash.
    test "a zone with no points key at all is refused like a malformed one" do
      assert Zones.validate(%{"id" => "drive", "name" => "x"}, []) ==
               {:error, ["points must be a list of [x, y] pairs"]}
    end
  end

  describe "self_intersecting?/1" do
    test "simple outlines are not" do
      refute Zones.self_intersecting?(@triangle)
      refute Zones.self_intersecting?(@square)
      refute Zones.self_intersecting?([[0, 0], [1, 0]])
    end

    test "a bow-tie is" do
      assert Zones.self_intersecting?(@bowtie)
      assert Zones.self_intersecting?([[0, 0], [1, 1], [1, 0], [0, 1]])
    end
  end

  describe "hits/2" do
    defp zones(list),
      do: Enum.map(list, fn {id, points} -> %{id: id, name: id, points: points} end)

    @outer {"outer", [[0, 0], [1, 0], [1, 1], [0, 1]]}
    @inner {"inner", [[0.4, 0.4], [0.6, 0.4], [0.6, 0.6], [0.4, 0.6]]}

    test "a box's foot inside nested zones counts in both, in the zones' order" do
      # foot = {0.5, 0.5}
      assert Zones.hits(zones([@outer, @inner]), [0.45, 0.4, 0.1, 0.1]) == ["outer", "inner"]
      assert Zones.hits(zones([@inner, @outer]), [0.45, 0.4, 0.1, 0.1]) == ["inner", "outer"]
    end

    test "a box whose foot is in no zone counts nowhere" do
      assert Zones.hits(zones([@inner]), [0.05, 0.0, 0.1, 0.1]) == []
    end

    test "the head does not count — only the foot" do
      # The box spans the inner zone but its foot lands below it.
      assert Zones.hits(zones([@inner]), [0.45, 0.3, 0.1, 0.45]) == []
    end

    test "a foot exactly on a shared edge counts in exactly one zone — the right-hand one" do
      left = {"left", [[0, 0], [0.5, 0], [0.5, 1], [0, 1]]}
      right = {"right", [[0.5, 0], [1, 0], [1, 1], [0.5, 1]]}

      # foot = {0.5, 0.5}, the edge both zones share
      assert Zones.hits(zones([left, right]), [0.45, 0.4, 0.1, 0.1]) == ["right"]
      assert Zones.hits(zones([right, left]), [0.45, 0.4, 0.1, 0.1]) == ["right"]
    end

    test "a box hanging off the bottom of the frame still counts in the bottom zone" do
      bottom = {"bottom", [[0, 0.5], [1, 0.5], [1, 1], [0, 1]]}

      # foot y = 1.2, clamped into the frame
      assert Zones.hits(zones([bottom]), [0.4, 0.9, 0.2, 0.3]) == ["bottom"]
    end

    test "no zones means no hits — the caller reads that as the whole frame" do
      assert Zones.hits([], [0.4, 0.4, 0.2, 0.2]) == []
    end
  end

  describe "Draft" do
    test "points accumulate, clamped into the frame" do
      draft = Draft.new() |> Draft.add_point([0.1, 0.2]) |> Draft.add_point([1.4, -0.3])

      assert draft.points == [[0.1, 0.2], [1.0, 0.0]]
      assert draft.closed? == false
    end

    test "a double-tap on the last point is ignored" do
      draft = Draft.new() |> Draft.add_point([0.1, 0.2]) |> Draft.add_point([0.101, 0.2])

      assert draft.points == [[0.1, 0.2]]
    end

    test "a closed draft takes no more points" do
      {:ok, closed} = Draft.new() |> add_all(@triangle) |> Draft.close()

      assert Draft.add_point(closed, [0.5, 0.5]) == closed
    end

    test "move_point replaces a vertex and ignores an index that is not there" do
      draft = Draft.new() |> add_all(@triangle)

      assert Draft.move_point(draft, 1, [0.5, 0.5]).points == [[0.0, 0.0], [0.5, 0.5], [1.0, 1.0]]
      assert Draft.move_point(draft, 9, [0.5, 0.5]) == draft
      assert Draft.move_point(draft, -1, [0.5, 0.5]) == draft
    end

    test "undo reopens a closed draft before it drops anything" do
      {:ok, closed} = Draft.new() |> add_all(@triangle) |> Draft.close()

      reopened = Draft.undo(closed)
      assert reopened.closed? == false
      assert length(reopened.points) == 3

      assert length(Draft.undo(reopened).points) == 2
      assert Draft.undo(Draft.new()) == Draft.new()
    end

    test "close needs three points" do
      draft = Draft.new() |> Draft.add_point([0, 0]) |> Draft.add_point([1, 0])

      assert Draft.close(draft) == {:error, "a zone needs at least 3 points"}
    end

    test "close refuses an outline that crosses itself" do
      draft = add_all(Draft.new(), @bowtie)

      assert Draft.close(draft) == {:error, "the outline crosses itself"}
      assert {:ok, closed} = Draft.close(add_all(Draft.new(), @square))
      assert closed.closed?
    end

    defp add_all(draft, points), do: Enum.reduce(points, draft, &Draft.add_point(&2, &1))
  end
end
