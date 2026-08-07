defmodule Mix.Tasks.Cairn.Mot.NdjsonTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Cairn.Mot.Ndjson

  @moduletag :tmp_dir

  @epoch "01K0TESTEPOCH00000000000000"

  defp v1_line(pts, objects) do
    Jason.encode!(%{
      "spec" => "cairn.plugin",
      "version" => 1,
      "type" => "frame.objects",
      "camera_id" => "test",
      "stream_epoch" => @epoch,
      "sequence" => pts,
      "frame" => %{"pts" => pts, "observed_at" => "2026-07-26T12:00:00.000Z"},
      "objects" => objects
    })
  end

  defp person(bbox, extra \\ %{}) do
    Map.merge(%{"label" => "person", "score" => 0.9, "bbox" => bbox}, extra)
  end

  setup %{tmp_dir: tmp_dir} do
    seq_dir = Path.join(tmp_dir, "SYN-E2E")
    File.mkdir_p!(seq_dir)

    File.write!(Path.join(seq_dir, "seqinfo.ini"), """
    name=SYN-E2E
    frameRate=10
    seqLength=5
    imWidth=100
    imHeight=100
    """)

    embedding = Base.encode64(<<127::signed-8, 0, 0, 0>>)

    capture =
      [
        ~s({"spec":"cairn.plugin","version":1,"type":"plugin.hello","hello":{"name":"t","version":"0","supported_versions":[1],"capabilities":{"object_tracking":false}}}),
        # pts 0 -> frame 1; carries an embedding
        v1_line(0, [person([0.1, 0.1, 0.4, 0.4], %{"embedding" => embedding})]),
        "not json at all",
        # pts 9000 -> 100ms -> frame 2
        v1_line(9_000, [person([0.12, 0.1, 0.4, 0.4])]),
        # a second sample landing on frame 2's slot: deduped
        v1_line(11_000, [person([0.13, 0.1, 0.4, 0.4])]),
        # an empty liveness line at pts 18000 -> frame 3
        v1_line(18_000, []),
        ~s({"spec":"cairn.plugin","version":1,"type":"plugin.status","status":{"state":"ready"}})
      ]
      |> Enum.join("\n")

    ndjson = Path.join(tmp_dir, "run.ndjson")
    File.write!(ndjson, capture)

    %{seq_dir: seq_dir, ndjson: ndjson}
  end

  test "replays a capture through the protocol onto the gt frame grid",
       %{seq_dir: seq_dir, ndjson: ndjson, tmp_dir: tmp_dir} do
    out = Path.join(tmp_dir, "preds/SYN-E2E.txt")

    capture_io(fn ->
      Ndjson.run([ndjson, "--seq", seq_dir, "--out", out, "--reid"])
    end)

    assert File.read!(out) == """
           1,1,10.00,10.00,40.00,40.00,1,-1,-1,-1
           2,1,12.00,10.00,40.00,40.00,1,-1,-1,-1
           """

    config = Jason.decode!(File.read!(Path.join(tmp_dir, "preds/SYN-E2E.config.json")))
    assert config["task"] == "cairn.mot.ndjson"
    assert config["lines_total"] == 7
    assert config["lines_objects"] == 4
    assert config["lines_invalid"] == 1
    assert config["objects_invalid"] == 0
    assert config["frames_deduped"] == 1
    assert config["frames_past_grid"] == 0
    assert config["objects_embedded"] == 1
    assert config["policy"]["reid"] == true
    assert config["tracks_minted"] == 1
  end

  test "a deduped frame's embeddings are not counted as consumed",
       %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
    embedding = Base.encode64(<<127::signed-8, 0, 0, 0>>)

    capture =
      [
        v1_line(0, [person([0.1, 0.1, 0.4, 0.4])]),
        # same frame slot as pts 0, embedded — dropped, and its embedding
        # must not inflate objects_embedded
        v1_line(2_000, [person([0.1, 0.1, 0.4, 0.4], %{"embedding" => embedding})])
      ]
      |> Enum.join("\n")

    ndjson = Path.join(tmp_dir, "dedupe.ndjson")
    File.write!(ndjson, capture)
    out = Path.join(tmp_dir, "dedupe.txt")
    capture_io(fn -> Ndjson.run([ndjson, "--seq", seq_dir, "--out", out]) end)

    config = Jason.decode!(File.read!(Path.join(tmp_dir, "dedupe.config.json")))
    assert config["frames_deduped"] == 1
    assert config["objects_embedded"] == 0
  end

  test "a capture of only garbage and per-object drops is counted, not crashed",
       %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
    capture =
      [
        "garbage line one",
        v1_line(0, [%{"label" => "person", "score" => 5.0, "bbox" => [0, 0, 1, 1]}]),
        "garbage line two"
      ]
      |> Enum.join("\n")

    ndjson = Path.join(tmp_dir, "invalid.ndjson")
    File.write!(ndjson, capture)
    out = Path.join(tmp_dir, "invalid.txt")
    capture_io(fn -> Ndjson.run([ndjson, "--seq", seq_dir, "--out", out]) end)

    assert File.read!(out) == ""
    config = Jason.decode!(File.read!(Path.join(tmp_dir, "invalid.config.json")))
    assert config["lines_invalid"] == 2
    assert config["objects_invalid"] == 1
    assert config["lines_objects"] == 1
    assert config["tracks_minted"] == 0
  end

  test "two replays of one capture are byte-identical",
       %{seq_dir: seq_dir, ndjson: ndjson, tmp_dir: tmp_dir} do
    out_a = Path.join(tmp_dir, "a.txt")
    out_b = Path.join(tmp_dir, "b.txt")
    capture_io(fn -> Ndjson.run([ndjson, "--seq", seq_dir, "--out", out_a]) end)
    capture_io(fn -> Ndjson.run([ndjson, "--seq", seq_dir, "--out", out_b]) end)

    assert File.read!(out_a) == File.read!(out_b)
  end
end
