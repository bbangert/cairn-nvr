defmodule Cairn.TranscodeTest do
  use ExUnit.Case, async: false

  alias Cairn.Config
  alias Cairn.Config.Camera
  alias Cairn.FFmpegPort

  defp camera(transcode) do
    %Camera{id: "tc", rtsp_url: "rtsp://127.0.0.1:554/x", transcode: transcode}
  end

  describe "build_argv/3 transcode variant" do
    test "replaces copy with h264_v4l2m2m + GOP on the output" do
      argv = FFmpegPort.build_argv(camera(true), "-timeout", gop: 30)

      assert Enum.count(argv, &(&1 == "h264_v4l2m2m")) == 1
      refute "copy" in argv
      assert Enum.count(argv, &(&1 == "-g")) == 1
      assert "30" in argv
      assert Enum.count(argv, &(&1 == "-bf")) == 1
    end

    test "copy variant is unchanged by gop option" do
      argv = FFmpegPort.build_argv(camera(false), "-timeout", gop: 30)
      assert Enum.count(argv, &(&1 == "copy")) == 1
      refute "-g" in argv
    end
  end

  test "transcode without the hw encoder refuses with a clear status (no fallback)" do
    id = "tc_#{System.unique_integer([:positive])}"
    cam = %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x", transcode: true}
    config = %Config{data_dir: "tmp/tc_test"}
    test_pid = self()

    start_supervised!({Cairn.RingBuffer, camera_id: id, pre_window_seconds: 5})

    pid =
      start_supervised!(
        {FFmpegPort,
         camera: cam,
         config: config,
         transcode_available: false,
         status_fun: fn cam_id, status -> send(test_pid, {:status, cam_id, status}) end}
      )

    assert_receive {:status, ^id, :transcode_unavailable}, 2_000
    # no ffmpeg spawned, no backoff loop
    refute_receive {:status, ^id, :connecting}, 300
    assert :sys.get_state(pid).port == nil
  end

  test "transcode with the hw encoder available proceeds to spawn" do
    id = "tc_#{System.unique_integer([:positive])}"
    cam = %Camera{id: id, rtsp_url: "rtsp://127.0.0.1:554/x", transcode: true}
    config = %Config{data_dir: "tmp/tc_test"}
    test_pid = self()

    start_supervised!({Cairn.RingBuffer, camera_id: id, pre_window_seconds: 5})

    start_supervised!({
      FFmpegPort,
      # fake command so we don't need a real encoder
      camera: cam,
      config: config,
      index: 0,
      transcode_available: true,
      command: "sleep 30",
      status_fun: fn cam_id, status -> send(test_pid, {:status, cam_id, status}) end
    })

    assert_receive {:status, ^id, :connecting}, 2_000
  end
end
