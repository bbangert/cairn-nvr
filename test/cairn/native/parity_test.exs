defmodule Cairn.Native.ParityTest do
  # The parity harness itself, on the smallest run that still proves something:
  # one clip, a few dozen frames, both producers.
  #
  # `:native_parity` is excluded in `test/test_helper.exs`, and has to be —
  # CI's Elixir job builds no Rust, and this needs the NIF *and* the plugin
  # binary *and* ffmpeg *and* python3. Run it with:
  #
  #     mix test --only native_parity
  #
  # A missing NIF or model raises here rather than skipping: the tag is already
  # how a run says it does not want this, so anything that got past it asked for
  # the comparison, and a green suite that never ran it is the worse answer.
  use ExUnit.Case, async: false

  alias Cairn.Native
  alias Cairn.Native.Parity

  @moduletag :native_parity
  @moduletag timeout: 300_000

  @model "plugins/cairn-detect/yolox_nano.onnx"
  @labels "plugins/cairn-detect/coco.names"
  @plugin "plugins/cairn-detect/target/release/cairn-detect"
  @clips "data/events/reolink_main"

  setup_all do
    unless Native.available?() do
      raise "cairn-native is not loaded (#{inspect(Native.load_error())}); " <>
              "cargo build --release in plugins/cairn-native, then copy " <>
              "target/release/libcairn_native.so to priv/native/"
    end

    for path <- [@model, @labels, @plugin] do
      unless File.exists?(path), do: raise("#{path} is missing")
    end

    case Path.wildcard(@clips <> "/*.mp4") do
      [] -> raise "no clips under #{@clips}"
      clips -> {:ok, clip: Enum.min(clips)}
    end
  end

  @tag :tmp_dir
  test "the same clip yields the same detections through both producers", %{
    clip: clip,
    tmp_dir: tmp_dir
  } do
    report =
      Parity.compare(clip,
        model: @model,
        labels: @labels,
        plugin: @plugin,
        work_dir: tmp_dir,
        # A short feed rather than a short clip: the plugin is fed over RTP in
        # real time, so the run costs what it plays. The NIF side is trimmed to
        # match, and `expected_frames` follows the trim.
        max_frames: 100,
        feed_duration: 8
      )

    assert report.mismatches == [], Enum.map_join(report.mismatches, "\n", &inspect/1)
    assert report.matched >= 25
    assert report.objects > 0

    # `:parity` rather than the clean diff above, which on its own means nothing
    # if the two runs were lined up by luck: the verdict is also where a margin
    # of 0 — several offsets fitting the evidence equally well — is refused as
    # `:ambiguous_alignment`.
    assert report.verdict == :parity,
           "#{report.verdict}, alignment #{inspect(report.alignment)}"

    # Task 2.4's deliberate omissions, asserted as the *only* differences: every
    # other field is compared above and any disagreement would be a mismatch.
    %{
      frames: frames,
      plugin_sequence_present: sequences,
      native_sequence_nil: nils,
      plugin_instance_nil_both: instances
    } = report.expected_differences

    assert frames == report.matched
    assert sequences == frames, "the plugin path stopped numbering its lines"
    assert nils == frames, "the NIF path grew a sequence"
    assert instances == frames
  end

  @tag :tmp_dir
  test "a clip splits into one access unit per packet, with the container's pts", %{
    clip: clip,
    tmp_dir: tmp_dir
  } do
    %{aus: aus, time_base: {num, den}} = Parity.read_clip(clip, tmp_dir)

    assert num > 0 and den > 0
    assert length(aus) > 10

    # Annex-B, which is what the H.264 parser will hand the detect branch: every
    # unit starts on a start code, and the first is a keyframe carrying its
    # parameter sets in band.
    assert Enum.all?(aus, fn {au, _pts} -> match?(<<0, 0, 0, 1, _rest::binary>>, au) end)
    {first, _pts} = hd(aus)
    assert <<0, 0, 0, 1, header, _rest::binary>> = first
    assert Bitwise.band(header, 0x1F) in [7, 9], "the first access unit carries no SPS/AUD"

    # One pts per access unit and no two alike: the pts is the join key the
    # comparison runs on, so a repeated one would pair two pictures.
    pts = Enum.map(aus, &elem(&1, 1))
    assert length(Enum.uniq(pts)) == length(pts)
  end
end
