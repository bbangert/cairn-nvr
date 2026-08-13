defmodule Mix.Tasks.Cairn.Mot.TrackTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.Cairn.Mot.Track

  @moduletag :tmp_dir

  describe "parse_seqinfo!/1" do
    test "reads the fields the harness needs", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "seqinfo.ini")

      File.write!(path, """
      [Sequence]
      name=MOT17-04-SDP
      imDir=img1
      frameRate=30
      seqLength=1050
      imWidth=1920
      imHeight=1080
      imExt=.jpg
      """)

      assert Track.parse_seqinfo!(path) == %{
               name: "MOT17-04-SDP",
               frame_rate: 30.0,
               seq_length: 1050,
               im_width: 1920,
               im_height: 1080
             }
    end
  end

  describe "parse_seqinfo!/1 error paths" do
    test "raises a Mix error naming the missing key", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "seqinfo.ini")

      File.write!(path, """
      [Sequence]
      name=BROKEN
      frameRate=30
      seqLength=10
      imHeight=1080
      """)

      assert_raise Mix.Error, ~r/missing imWidth/, fn -> Track.parse_seqinfo!(path) end
    end

    test "raises a Mix error on a non-numeric field", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "seqinfo.ini")

      File.write!(path, """
      name=BROKEN
      frameRate=fast
      seqLength=10
      imWidth=100
      imHeight=100
      """)

      assert_raise Mix.Error, ~r/not a number/, fn -> Track.parse_seqinfo!(path) end
    end
  end

  describe "at_ms/2" do
    test "maps 1-indexed frames onto the fps clock, frame 1 at t=0" do
      assert Track.at_ms(1, 30.0) == 0
      assert Track.at_ms(2, 30.0) == 33
      assert Track.at_ms(31, 30.0) == 1000
      assert Track.at_ms(2, 0.1) == 10_000
      assert Track.at_ms(3, 5.0) == 400
    end
  end

  describe "parse_det_line!/1" do
    test "parses integer and float fields, ignoring the trailing world coords" do
      assert Track.parse_det_line!("1,-1,1359.1,413.27,120.26,362.77,2.3092,-1,-1,-1") ==
               %{frame: 1, x: 1359.1, y: 413.27, w: 120.26, h: 362.77, conf: 2.3092}

      assert Track.parse_det_line!("7,-1,10,20,30,40,1") ==
               %{frame: 7, x: 10.0, y: 20.0, w: 30.0, h: 40.0, conf: 1.0}
    end

    test "raises a Mix error on too few fields" do
      assert_raise Mix.Error, ~r/malformed det.txt line/, fn ->
        Track.parse_det_line!("1,-1,10,20")
      end
    end

    test "raises a Mix error on a non-numeric field" do
      assert_raise Mix.Error, ~r/not a number/, fn ->
        Track.parse_det_line!("1,-1,ten,20,30,40,0.9")
      end
    end
  end

  describe "object/3" do
    @seqinfo %{im_width: 100, im_height: 100}

    test "normalizes to 0..1 ltwh and clamps overhang to the frame" do
      det = %{frame: 1, x: -5.0, y: -5.0, w: 20.0, h: 20.0, conf: 0.9}

      assert %{bbox: [+0.0, +0.0, w, h], label: "person", observation_kind: "detected"} =
               Track.object(det, @seqinfo, :normalized)

      assert_in_delta w, 0.15, 1.0e-9
      assert_in_delta h, 0.15, 1.0e-9
    end

    test "clamps confidence into 0..1" do
      det = %{frame: 1, x: 10.0, y: 10.0, w: 20.0, h: 20.0, conf: 2.31}
      assert %{score: 1.0} = Track.object(det, @seqinfo, :normalized)
    end

    test "clamps high-side overhang back to the frame edge" do
      det = %{frame: 1, x: 90.0, y: 85.0, w: 20.0, h: 20.0, conf: 0.9}

      assert %{bbox: [x, y, w, h]} = Track.object(det, @seqinfo, :normalized)
      assert_in_delta x, 0.9, 1.0e-9
      assert_in_delta y, 0.85, 1.0e-9
      assert_in_delta w, 0.1, 1.0e-9
      assert_in_delta h, 0.15, 1.0e-9
    end

    test "drops a box entirely outside the frame" do
      det = %{frame: 1, x: 150.0, y: 150.0, w: 20.0, h: 20.0, conf: 0.9}
      assert Track.object(det, @seqinfo, :normalized) == nil
    end

    test "drops a box that clamps to exactly zero width or height" do
      grazing_right = %{frame: 1, x: 100.0, y: 40.0, w: 20.0, h: 20.0, conf: 0.9}
      assert Track.object(grazing_right, @seqinfo, :normalized) == nil

      grazing_bottom = %{frame: 1, x: 40.0, y: 100.0, w: 20.0, h: 20.0, conf: 0.9}
      assert Track.object(grazing_bottom, @seqinfo, :normalized) == nil
    end

    test "pixel mode keeps the box where the detector put it, overhang and all" do
      det = %{frame: 1, x: -5.0, y: 85.0, w: 20.0, h: 40.0, conf: 0.9}

      assert %{bbox: [-5.0, 85.0, 20.0, 40.0], score: 0.9} =
               Track.object(det, @seqinfo, :pixels)
    end

    test "pixel mode still clamps confidence into 0..1" do
      det = %{frame: 1, x: 10.0, y: 10.0, w: 20.0, h: 20.0, conf: 2.31}

      assert %{score: 1.0} = Track.object(det, @seqinfo, :pixels)
    end
  end

  describe "run/1" do
    setup %{tmp_dir: tmp_dir} do
      seq_dir = Path.join(tmp_dir, "SYN-01")
      File.mkdir_p!(Path.join(seq_dir, "det"))

      File.write!(Path.join(seq_dir, "seqinfo.ini"), """
      [Sequence]
      name=SYN-01
      frameRate=10
      seqLength=3
      imWidth=100
      imHeight=100
      """)

      File.write!(Path.join([seq_dir, "det", "det.txt"]), """
      1,-1,10,10,40,40,0.9
      2,-1,12,10,40,40,0.9
      2,-1,60,60,30,30,0.8
      3,-1,14,10,40,40,0.9
      3,-1,60,60,30,30,0.8
      """)

      %{seq_dir: seq_dir}
    end

    test "tracks a sequence into MOT lines with stable first-seen ordinals",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "preds/SYN-01.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out]) end)

      assert File.read!(out) == """
             1,1,10.00,10.00,40.00,40.00,1,-1,-1,-1
             2,1,12.00,10.00,40.00,40.00,1,-1,-1,-1
             2,2,60.00,60.00,30.00,30.00,1,-1,-1,-1
             3,1,14.00,10.00,40.00,40.00,1,-1,-1,-1
             3,2,60.00,60.00,30.00,30.00,1,-1,-1,-1
             """
    end

    test "two runs over the same input are byte-identical",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out_a = Path.join(tmp_dir, "a.txt")
      out_b = Path.join(tmp_dir, "b.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out_a]) end)
      capture_io(fn -> Track.run([seq_dir, "--out", out_b]) end)

      assert File.read!(out_a) == File.read!(out_b)
    end

    test "--det-min drops detections before the tracker sees them",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "filtered.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out, "--det-min", "0.85"]) end)

      refute File.read!(out) =~ "60.00"

      config = Jason.decode!(File.read!(Path.join(tmp_dir, "filtered.config.json")))
      assert config["det_min"] == 0.85
      assert config["detections_total"] == 5
      assert config["detections_below_det_min"] == 2
      assert config["detections_clamped_out"] == 0
      assert config["detections_kept"] == 3
    end

    test "--det-min keeps a detection exactly at the threshold",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "boundary.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out, "--det-min", "0.8"]) end)

      config = Jason.decode!(File.read!(Path.join(tmp_dir, "boundary.config.json")))
      assert config["detections_below_det_min"] == 0
      assert config["detections_kept"] == 5
    end

    test "--fps overrides seqinfo frameRate for the run",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "slow.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out, "--fps", "0.1"]) end)

      config = Jason.decode!(File.read!(Path.join(tmp_dir, "slow.config.json")))
      assert config["fps"] == 0.1
    end

    test "rejects a non-positive --fps", %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "bad.txt")

      assert_raise Mix.Error, ~r/fps must be > 0/, fn ->
        Track.run([seq_dir, "--out", out, "--fps", "0.0"])
      end
    end

    test "reports a non-positive sparsetrack level count instead of raising through the core",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "levels.txt")

      for {flag, value} <- [{"--depth-levels", "0"}, {"--depth-levels-low", "-2"}] do
        assert_raise Mix.Error, ~r/#{flag} must be > 0/, fn ->
          Track.run([seq_dir, "--out", out, "--tracker", "sparsetrack", flag, value])
        end
      end
    end

    test "policy scalar and stage flags reach the sidecar echo",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "flags.txt")

      capture_io(fn ->
        Track.run([
          seq_dir,
          "--out",
          out,
          "--oru",
          "--no-twin-mint",
          "--max-unseen-ms",
          "1234",
          "--max-live-tracks",
          "7",
          "--stationary-after-ms",
          "5678"
        ])
      end)

      config = Jason.decode!(File.read!(Path.join(tmp_dir, "flags.config.json")))
      policy = config["policy"]
      assert policy["oru"] == true
      assert policy["twin_mint"] == false
      assert policy["max_unseen_ms"] == 1234
      assert policy["max_live_tracks"] == 7
      assert policy["stationary_after_ms"] == 5678
    end

    test "raises on unknown options, missing seq dir, and missing --out",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "x.txt")

      assert_raise Mix.Error, ~r/invalid options/, fn ->
        Track.run([seq_dir, "--out", out, "--bogus"])
      end

      assert_raise Mix.Error, ~r/usage:/, fn -> Track.run(["--out", out]) end
      assert_raise Mix.Error, ~r/--out is required/, fn -> Track.run([seq_dir]) end
    end

    test "raises when seqinfo.ini or det.txt is missing", %{tmp_dir: tmp_dir} do
      empty_dir = Path.join(tmp_dir, "empty-seq")
      File.mkdir_p!(empty_dir)
      out = Path.join(tmp_dir, "x.txt")

      assert_raise Mix.Error, ~r/cannot read seqinfo.ini/, fn ->
        Track.run([empty_dir, "--out", out])
      end

      File.write!(Path.join(empty_dir, "seqinfo.ini"), """
      name=EMPTY
      frameRate=10
      seqLength=1
      imWidth=100
      imHeight=100
      """)

      assert_raise Mix.Error, ~r/cannot read det\/det.txt/, fn ->
        Track.run([empty_dir, "--out", out])
      end
    end

    test "writes a config sidecar that echoes the policy",
         %{seq_dir: seq_dir, tmp_dir: tmp_dir} do
      out = Path.join(tmp_dir, "SYN-01.txt")
      capture_io(fn -> Track.run([seq_dir, "--out", out, "--bbd", "--min-score", "0.25"]) end)

      config = Jason.decode!(File.read!(Path.join(tmp_dir, "SYN-01.config.json")))

      assert config["seq"] == "SYN-01"
      assert config["seq_dir"] == seq_dir
      assert config["fps"] == 10.0
      assert config["seq_length"] == 3
      assert config["image_size"] == [100, 100]
      assert config["detections_total"] == 5
      assert config["policy"]["bbd"] == true
      assert config["policy"]["oru"] == false
      assert config["policy"]["min_score"] == 0.25
      assert config["lines_emitted"] == 5
      assert config["tracks_minted"] == 2
      assert is_binary(config["git_sha"])
    end
  end
end
