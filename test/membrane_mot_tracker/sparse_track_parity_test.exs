defmodule Membrane.MOTTracker.SparseTrackParityTest do
  use ExUnit.Case, async: true

  alias Cairn.MotBench
  alias Membrane.MOTTracker.SparseTrack
  alias Mix.Tasks.Cairn.Mot.Track, as: Harness

  @fixtures "test/fixtures/sparsetrack"
  @sequence Path.join(@fixtures, "synthetic")

  # The reference's published per-dataset configs, spelled as this core's
  # options. `mot17` is the one the sweep tooling runs; `deep` cascades the
  # first stage too (the published MOT17 config leaves it at one level, which
  # is no cascade); `mot20` is the dense-crowd config, and the only one that
  # runs with the score-weighted cost switched off.
  @configs %{
    "mot17" => [],
    "deep" => [depth_levels: 4, depth_levels_low: 4, match_thresh: 0.8],
    "mot20" => [
      track_buffer: 60,
      match_thresh: 0.6,
      depth_levels_low: 8,
      confirm_thresh: 0.7,
      mot20: true
    ]
  }

  for {name, opts} <- @configs do
    test "exactly reproduces the vendored reference on the #{name} config" do
      expected = Path.join(@fixtures, "expected-#{unquote(name)}.txt")

      assert File.exists?(expected), """
      Missing #{expected}.

      Regenerate the reference outputs from the vendored Python:

          cd tools/mot-bench && ./setup.sh
          .venv/bin/python sparsetrack_parity.py

      That writes both halves of this fixture — the synthetic sequence and
      the reference's predictions over it — and echoes a checksum for each.
      """

      assert replay(unquote(opts)) == File.read!(expected)
    end
  end

  test "the fixture's three configs do not all produce the same output" do
    # A gate that three configurations pass identically is one configuration's
    # gate. This asserts the fixture is still hard enough to tell them apart —
    # a sequence with no ambiguity in it would agree everywhere and quietly
    # stop testing the cascade and the fused cost.
    outputs = for {_name, opts} <- @configs, do: replay(opts)

    assert outputs == Enum.uniq(outputs)
  end

  # The replay the parity gate compares: the same loop the MOT harness runs,
  # in the same units, with identities canonicalized to first-seen ordinals on
  # both sides — the reference's own counter is a global that survives between
  # runs, and an ordinal is a property of the output alone.
  defp replay(opts) do
    seqinfo = Harness.parse_seqinfo!(Path.join(@sequence, "seqinfo.ini"))

    detections =
      [@sequence, "det", "det.txt"]
      |> Path.join()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Harness.parse_det_line!/1)
      |> Enum.group_by(& &1.frame, &Harness.object(&1, seqinfo, :pixels))

    frames =
      for frame <- 1..seqinfo.seq_length,
          do: {frame, Harness.at_ms(frame, seqinfo.frame_rate), Map.get(detections, frame, [])}

    core = Keyword.put(opts, :frame_rate, trunc(seqinfo.frame_rate))

    {lines, _emitted, _minted} =
      MotBench.drive(frames, seqinfo, MotBench.policy([]),
        tracker: {SparseTrack, core},
        units: :pixels
      )

    IO.iodata_to_binary(lines)
  end
end
