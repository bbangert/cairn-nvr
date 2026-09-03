defmodule CairnWeb.CameraCardsTest do
  # Pure readouts: no socket, no repo.
  use ExUnit.Case, async: true

  alias Cairn.Cameras.Camera
  alias CairnWeb.CameraCards

  describe "mask_url/1" do
    test "hides rtsp credentials" do
      assert CameraCards.mask_url("rtsp://admin:s3cret@10.0.0.5:554/s1") ==
               "rtsp://admin:•••••@10.0.0.5:554/s1"

      assert CameraCards.mask_url("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
    end

    test "hides credential query params (http-flv style)" do
      assert CameraCards.mask_url(
               "http://10.0.0.5/flv?port=1935&stream=ch0&user=admin&password=hunter2"
             ) == "http://10.0.0.5/flv?port=1935&stream=ch0&user=•••••&password=•••••"

      assert CameraCards.mask_url("http://10.0.0.5/flv?Token=abc&x=1") ==
               "http://10.0.0.5/flv?Token=•••••&x=1"
    end

    test "hides the vendor spellings of the same secret" do
      for key <- ~w(psw passwd auth key apikey api_key session) do
        assert CameraCards.mask_url("http://10.0.0.5/live?#{key}=hunter2&channel=1") ==
                 "http://10.0.0.5/live?#{key}=•••••&channel=1"
      end
    end
  end

  describe "credentialed?/1" do
    test "userinfo and credential query params count, a plain URL does not" do
      assert CameraCards.credentialed?("rtsp://admin:s3cret@10.0.0.5:554/s1")
      assert CameraCards.credentialed?("http://10.0.0.5/live?psw=hunter2")
      refute CameraCards.credentialed?("rtsp://10.0.0.5:554/s1")
      refute CameraCards.credentialed?("http://10.0.0.5/live?channel=1&subtype=0")
    end
  end

  describe "describe_probe_error/1" do
    test "names the reasons a probe can fail with" do
      assert CameraCards.describe_probe_error(:timeout) == "timed out"
      assert CameraCards.describe_probe_error({:ffprobe_exit, 1}) == "ffprobe exited 1"
      assert CameraCards.describe_probe_error(:no_video_stream) == "no video stream"
    end

    test "a decode error and an exit reason never carry what they were holding" do
      {:error, decode_error} = Jason.decode("ffprobe: rtsp://u:SECRET@h/1: no such stream")

      message = CameraCards.describe_probe_error(decode_error)

      assert message == "ffprobe returned no readable stream info"
      refute message =~ "SECRET"

      assert CameraCards.describe_probe_error({%RuntimeError{message: "rtsp://u:SECRET@h/1"}, []}) ==
               "the probe did not finish — see the log"
    end
  end

  describe "describe_write_error/1" do
    test "a rejected changeset names its fields and never its settings" do
      changeset =
        Camera.changeset(%Camera{}, %{
          id: "Front Door",
          position: 0,
          settings: %{"rtsp_url" => "rtsp://u:SECRET@h/1"}
        })

      message = CameraCards.describe_write_error(changeset)

      assert message =~ "id must be lowercase"
      refute message =~ "SECRET"
      refute message =~ "rtsp"
    end

    test "the shapes a write can fail with, and one it cannot" do
      assert CameraCards.describe_write_error(:not_found) == "the camera no longer exists"

      assert CameraCards.describe_write_error(%Exqlite.Error{message: "database is locked"}) ==
               "database is locked"

      assert CameraCards.describe_write_error({:nonsense, %{"rtsp_url" => "rtsp://u:SECRET@h/1"}}) ==
               "an unexpected error — see the log"
    end
  end
end
