defmodule Cairn.ProbeTest do
  use ExUnit.Case, async: true

  alias Cairn.Probe

  defp ffprobe_json(codec, opts \\ []) do
    Jason.encode!(%{
      "streams" => [
        %{"codec_type" => "audio", "codec_name" => "aac"},
        %{
          "codec_type" => "video",
          "codec_name" => codec,
          "width" => Keyword.get(opts, :width, 2560),
          "height" => Keyword.get(opts, :height, 1920),
          "avg_frame_rate" => Keyword.get(opts, :fps, "20/1"),
          "profile" => Keyword.get(opts, :profile, "High")
        }
      ],
      "format" => %{"format_name" => "rtsp"}
    })
  end

  describe "parse/1" do
    test "h264 camera" do
      assert {:ok, probe} = Probe.parse(ffprobe_json("h264"))

      assert probe == %{
               codec: "h264",
               width: 2560,
               height: 1920,
               fps: 20.0,
               profile: "High"
             }
    end

    test "hevc and mjpeg cameras parse too" do
      assert {:ok, %{codec: "hevc"}} = Probe.parse(ffprobe_json("hevc"))
      assert {:ok, %{codec: "mjpeg"}} = Probe.parse(ffprobe_json("mjpeg"))
    end

    test "fractional and degenerate frame rates" do
      assert {:ok, %{fps: 29.97}} = Probe.parse(ffprobe_json("h264", fps: "30000/1001"))
      assert {:ok, %{fps: nil}} = Probe.parse(ffprobe_json("h264", fps: "0/0"))
    end

    test "no video stream" do
      json = Jason.encode!(%{"streams" => [%{"codec_type" => "audio"}]})
      assert {:error, :no_video_stream} = Probe.parse(json)
    end

    test "garbage output" do
      assert {:error, _} = Probe.parse("not json")
      assert {:error, :unexpected_output} = Probe.parse(~s({"no": "streams"}))
    end
  end

  describe "run/2" do
    @tag :tmp_dir
    test "probes a local file end-to-end (real ffprobe)" do
      assert {:ok, probe} = Probe.run("test/support/fixtures/media/testsrc.fmp4")
      assert probe.codec == "h264"
      assert probe.width == 320
      assert probe.fps == 10.0
    end

    test "hard timeout kills a hung probe" do
      # a URL ffprobe will hang on: unroutable TEST-NET address
      assert {:error, reason} = Probe.run("rtsp://192.0.2.1:554/x", 500)
      assert reason in [:timeout, {:ffprobe_exit, 1}]
    end
  end
end
