defmodule Cairn.Native.ParityAlignmentTest do
  # `align/3` is pure list arithmetic over `Cairn.Observation`s — no NIF, no
  # plugin, no clip — so unlike the rest of the harness it runs in CI.
  use ExUnit.Case, async: true

  alias Cairn.Native.Parity
  alias Cairn.Observation

  @time_base {1, 90_000}
  # 90 kHz over ~20 fps: one frame apart in the units both producers date in.
  @step 4_500
  @tolerance 1.0e-9

  describe "align/3" do
    test "the offset that agrees wins over the offset that pairs twice as much" do
      # The regression the harness was rebuilt for. The NIF run covers ten of
      # the plugin's forty frames (a `max_frames` trim), and twenty frames of
      # somewhere else entirely — so sliding the plugin's series onto that
      # second region pairs 20 against the true offset's 10, and agrees on none.
      plugin = run(900_000, marks(0..39))
      native = run(0, marks(0..9)) ++ run(200_000, marks(100..119))

      assert {offset, alignment} = Parity.align(plugin, native, @tolerance)

      assert offset == 900_000
      assert alignment == %{agreed: 10, probes: 40, margin: 10}
    end

    test "an offset one frame out agrees on nothing, so the margin is every probe" do
      plugin = run(900_000, marks(0..29))
      native = run(0, marks(0..29))

      assert {900_000, %{agreed: 30, probes: 30, margin: 30}} =
               Parity.align(plugin, native, @tolerance)
    end

    test "frames that all look alike tie several offsets, and the margin says so" do
      # Nothing distinguishes one frame from another, so the true offset and its
      # neighbours agree equally. The alignment is a coin flip and `margin` is
      # the only field that admits it.
      plugin = run(900_000, List.duplicate(0.5, 20))
      native = run(0, List.duplicate(0.5, 60))

      assert {_offset, %{agreed: 20, probes: 20, margin: 0}} =
               Parity.align(plugin, native, @tolerance)
    end

    test "two runs with nothing in common agree on nothing at any offset" do
      plugin = run(900_000, marks(0..19))
      native = run(0, marks(500..519))

      assert {_offset, %{agreed: 0, probes: 20, margin: 0}} =
               Parity.align(plugin, native, @tolerance)
    end

    test "a difference inside the tolerance is still agreement" do
      plugin = run(900_000, marks(0..9))
      native = run(0, Enum.map(marks(0..9), &(&1 + 1.0e-10)))

      assert {900_000, %{agreed: 10, margin: 10}} = Parity.align(plugin, native, @tolerance)
      assert {_offset, %{agreed: 0}} = Parity.align(plugin, native, 1.0e-12)
    end

    test "degenerate runs answer rather than pick something" do
      one = run(900_000, marks(0..0))

      assert Parity.align([], [], @tolerance) == {0, %{agreed: 0, probes: 0, margin: 0}}

      assert Parity.align([], run(0, marks(0..9)), @tolerance) ==
               {0, %{agreed: 0, probes: 0, margin: 0}}

      # no native frame is no candidate offset, and no evidence either way
      assert Parity.align(one, [], @tolerance) == {0, %{agreed: 0, probes: 1, margin: 0}}
      # one probe that agrees is one probe: an alignment with nothing to compare
      # it against reads as a full margin, which is what `probes` is next to it for
      assert Parity.align(one, run(0, marks(0..0)), @tolerance) ==
               {900_000, %{agreed: 1, probes: 1, margin: 1}}

      assert {_offset, %{agreed: 0, probes: 1, margin: 0}} =
               Parity.align(one, run(0, marks(7..7)), @tolerance)
    end
  end

  defp marks(range), do: Enum.map(range, &(&1 / 1_000))

  defp run(first_pts, marks) do
    marks
    |> Enum.with_index()
    |> Enum.map(fn {mark, index} -> frame(first_pts + index * @step, mark) end)
  end

  # The mark is the frame's identity: two frames agree only if they are the same
  # frame, which is what makes a one-frame-out offset agree on nothing.
  defp frame(pts, mark) do
    %Observation{
      camera_id: "parity",
      epoch: "01K0PARITY000000000000000",
      pts: pts,
      time_base: @time_base,
      media_ms: Observation.media_ms(pts, @time_base),
      protocol: :v1,
      time_quality: :source,
      objects: [
        %{
          label: "person",
          score: mark,
          bbox: [0.1, 0.2, 0.3, 0.4],
          track_id: nil,
          observation_kind: "detected"
        }
      ]
    }
  end
end
