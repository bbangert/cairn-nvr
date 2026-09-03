defmodule CairnWeb.CameraCardsTest do
  # Pure readouts: no socket, no repo.
  use ExUnit.Case, async: true

  alias Cairn.Cameras.Camera
  alias CairnWeb.CameraCards

  describe "an @ inside the credential" do
    test "is consumed through the last @ of the authority" do
      assert CameraCards.mask_url("rtsp://user:sec@ret@host/s") == "rtsp://user:•••••@host/s"
      assert CameraCards.mask_url("rtsp://SEC@RET@host/s") == "rtsp://•••••@host/s"

      assert CameraCards.mask_url("rtsp://u:p@host/path@x?password=p") ==
               "rtsp://u:•••••@host/path@x?password=•••••"
    end
  end

  describe "access_token" do
    test "is a credential the mask and the prefill rule both see" do
      url = "http://cam.lan/flv?stream=ch0&access_token=SECRET"
      assert CameraCards.mask_url(url) == "http://cam.lan/flv?stream=ch0&access_token=•••••"
      assert CameraCards.credentialed?(url)
    end
  end

  describe "describe_exit/1" do
    test "names the exception and never what it was holding" do
      changeset =
        Cairn.Cameras.Camera.changeset(%Cairn.Cameras.Camera{}, %{
          id: "Bad Id",
          position: 0,
          settings: %{"rtsp_url" => "rtsp://u:SECRET@h/1"}
        })

      line = CameraCards.describe_exit({%Ecto.InvalidChangesetError{changeset: changeset}, []})
      assert line =~ "Ecto.InvalidChangesetError"
      assert line =~ "id"
      refute line =~ "SECRET"

      assert CameraCards.describe_exit({:timeout, []}) == ":timeout"
      assert CameraCards.describe_exit(:killed) == ":killed"
      assert CameraCards.describe_exit({:shutdown, {:secret, "SECRET"}}) == ":shutdown"
      refute CameraCards.describe_exit({1, 2, "SECRET"}) =~ "SECRET"
    end
  end

  describe "probe_chips/1" do
    test "is empty for nil, a failed probe map, a bare error tuple, or garbage" do
      assert CameraCards.probe_chips(nil) == []
      assert CameraCards.probe_chips(%{error: :timeout}) == []
      # `Cairn.CameraStatus.set_probe/2` accepts a bare `{:error, reason}`,
      # not only a `%{error: _}` map — this is the shape `Cairn.Probe`'s own
      # callers store on a probe that never returned a result.
      assert CameraCards.probe_chips({:error, :timeout}) == []
      assert CameraCards.probe_chips("not a probe") == []
    end

    test "renders codec, resolution, fps and profile" do
      probe = %{codec: "h264", width: 1920, height: 1080, fps: 15, profile: "high"}

      assert CameraCards.probe_chips(probe) == ["h264", "1920×1080", "15 fps", "high"]
    end
  end

  describe "mask_url/1" do
    test "hides rtsp credentials" do
      assert CameraCards.mask_url("rtsp://admin:s3cret@10.0.0.5:554/s1") ==
               "rtsp://admin:•••••@10.0.0.5:554/s1"

      assert CameraCards.mask_url("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
    end

    # Cameras that authenticate on the password alone: the userinfo is there,
    # with nothing before the colon.
    test "hides a password whose username is empty" do
      assert CameraCards.mask_url("rtsp://:secret@host/s") == "rtsp://:•••••@host/s"
    end

    # A colonless userinfo is `credentialed?/1`-true, so the form refuses to
    # prefill it; rendering it verbatim in the row would hand back what the
    # form withheld. Which half of `user:pass` it is cannot be known, so all
    # of it goes.
    test "hides a colonless userinfo whole" do
      assert CameraCards.mask_url("rtsp://SECRET@host/s") == "rtsp://•••••@host/s"
      refute CameraCards.mask_url("rtsp://SECRET@host/s") =~ "SECRET"
      assert CameraCards.credentialed?("rtsp://SECRET@host/s")
    end

    test "hides credential query params (http-flv style)" do
      assert CameraCards.mask_url(
               "http://10.0.0.5/flv?port=1935&stream=ch0&user=admin&password=hunter2"
             ) == "http://10.0.0.5/flv?port=1935&stream=ch0&user=•••••&password=•••••"

      assert CameraCards.mask_url("http://10.0.0.5/flv?Token=abc&x=1") ==
               "http://10.0.0.5/flv?Token=•••••&x=1"
    end

    # The camera reads `?pass%77ord=` as `password`, so the raw spelling is
    # not what decides: an escape in the key would otherwise be a way to get a
    # credential rendered in the clear.
    test "hides a percent-encoded key" do
      assert CameraCards.mask_url("http://10.0.0.5/live?pass%77ord=hunter2") ==
               "http://10.0.0.5/live?pass%77ord=•••••"

      assert CameraCards.credentialed?("http://10.0.0.5/live?pass%77ord=hunter2")
    end

    # `%FF` is a well-formed escape whose decoding is not valid UTF-8, which
    # `String.downcase/1` may refuse: the key is then judged raw, and the
    # credential beside it is still masked.
    test "an escape that decodes to invalid UTF-8 is judged on the raw key" do
      assert CameraCards.mask_url("http://10.0.0.5/live?pass%FFword=1&password=hunter2") ==
               "http://10.0.0.5/live?pass%FFword=1&password=•••••"

      assert CameraCards.credentialed?("http://10.0.0.5/live?pass%FFword=1&password=hunter2")
      refute CameraCards.credentialed?("http://10.0.0.5/live?pass%FFword=1")
    end

    test "a malformed escape is judged on the raw key" do
      assert CameraCards.mask_url("http://10.0.0.5/live?%zz=1&password=hunter2") ==
               "http://10.0.0.5/live?%zz=1&password=•••••"

      refute CameraCards.credentialed?("http://10.0.0.5/live?%zz=1")
    end

    test "hides the vendor spellings of the same secret" do
      for key <- ~w(psw passwd auth key apikey api_key session) do
        assert CameraCards.mask_url("http://10.0.0.5/live?#{key}=hunter2&channel=1") ==
                 "http://10.0.0.5/live?#{key}=•••••&channel=1"
      end
    end
  end

  describe "mask_url/1 and credentialed?/1 on a non-string" do
    # A row's `rtsp_url` is whatever its settings column holds: a hand-edited
    # or migrated row can carry a number, which the loader skips — and the
    # edit page still has to render, so it can be fixed.
    test "read as nothing to show rather than raising" do
      assert CameraCards.mask_url(123) == ""
      assert CameraCards.mask_url(nil) == ""
      refute CameraCards.credentialed?(123)
      refute CameraCards.credentialed?(nil)
    end
  end

  describe "credentialed?/1" do
    test "userinfo and credential query params count, a plain URL does not" do
      assert CameraCards.credentialed?("rtsp://admin:s3cret@10.0.0.5:554/s1")
      assert CameraCards.credentialed?("http://10.0.0.5/live?psw=hunter2")
      refute CameraCards.credentialed?("rtsp://10.0.0.5:554/s1")
      refute CameraCards.credentialed?("http://10.0.0.5/live?channel=1&subtype=0")
    end

    test "an empty username still leaves userinfo to hide" do
      assert CameraCards.credentialed?("rtsp://:secret@host/s")
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

    test "a re-import another session already did says nothing was left to import" do
      assert CameraCards.describe_write_error(:no_drift) ==
               "the cameras already match config.yml — nothing to import"
    end
  end

  describe "save_result/1" do
    test "a rejected write says the previous config is still active" do
      html = card(%{ok: false, diff: nil, warnings: [], errors: ["nope"], phase: :done})

      assert html =~ "We couldn't save that change"
      assert html =~ "Your previous config is still active"
    end

    # An exit that never confirmed may still be committing and applying, so
    # the card must not tell the operator that nothing changed.
    test "an unconfirmed write does not" do
      html =
        card(%{
          ok: false,
          diff: nil,
          warnings: [],
          errors: ["the save did not get a confirmed answer"],
          phase: :done,
          unconfirmed: true
        })

      assert html =~ "the save did not get a confirmed answer"
      refute html =~ "Your previous config is still active"
    end

    defp card(result) do
      Phoenix.LiveViewTest.rendered_to_string(CameraCards.save_result(%{result: result}))
    end
  end
end
