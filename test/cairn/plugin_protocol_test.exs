defmodule Cairn.PluginProtocolTest do
  use ExUnit.Case, async: true

  alias Cairn.PluginProtocol

  @base %{"label" => "person", "score" => 0.9, "bbox" => [0, 0, 1, 1]}

  defp det(fields), do: Map.merge(@base, fields)

  @valid [
    {"floats throughout", %{"score" => 0.87, "bbox" => [0.12, 0.4, 0.2, 0.5]}},
    {"integer score 0", %{"score" => 0}},
    {"integer score 1", %{"score" => 1}},
    {"integer bbox at the bounds", %{"bbox" => [0, 0, 1, 1]}},
    {"single-byte label", %{"label" => "a"}},
    {"64-byte label", %{"label" => String.duplicate("a", 64)}},
    {"multibyte label under 64 bytes", %{"label" => String.duplicate("é", 32)}}
  ]

  @invalid [
    {"empty label", %{"label" => ""}},
    {"label over 64 bytes", %{"label" => String.duplicate("a", 65)}},
    {"multibyte label over 64 bytes", %{"label" => String.duplicate("é", 33)}},
    {"non-binary label", %{"label" => 12}},
    {"nil label", %{"label" => nil}},
    {"label with a NUL byte", %{"label" => "per\0son"}},
    {"label with an ANSI escape", %{"label" => "\e[2Jperson"}},
    {"label with a newline", %{"label" => "person\nfake log line"}},
    {"string score", %{"score" => "0.9"}},
    {"score above 1", %{"score" => 5.0}},
    {"negative score", %{"score" => -0.1}},
    {"nil score", %{"score" => nil}},
    {"3-element bbox", %{"bbox" => [0, 0, 1]}},
    {"5-element bbox", %{"bbox" => [0, 0, 1, 1, 1]}},
    {"empty bbox", %{"bbox" => []}},
    {"non-list bbox", %{"bbox" => "0,0,1,1"}},
    {"non-numeric bbox member", %{"bbox" => [0, 0, "1", 1]}},
    {"negative bbox origin", %{"bbox" => [-0.1, 0, 0.5, 0.5]}},
    {"bbox origin above 1", %{"bbox" => [1.5, 0, 0.5, 0.5]}},
    {"bbox size above 1", %{"bbox" => [0, 0, 1.5, 0.5]}},
    {"integer bbox out of range", %{"bbox" => [0, 0, 2, 2]}},
    {"zero width", %{"bbox" => [0, 0, 0, 0.5]}},
    {"zero height", %{"bbox" => [0, 0, 0.5, 0]}},
    {"negative height", %{"bbox" => [0, 0, 0.5, -0.5]}}
  ]

  for {name, fields} <- @valid do
    test "valid: #{name}" do
      assert {:ok, det} = PluginProtocol.validate_det(det(unquote(Macro.escape(fields))))
      assert is_float(det.score)
      assert [_, _, _, _] = det.bbox
    end
  end

  for {name, fields} <- @invalid do
    test "invalid: #{name}" do
      assert PluginProtocol.validate_det(det(unquote(Macro.escape(fields)))) == :error
    end
  end

  test "keys missing entirely are invalid" do
    assert PluginProtocol.validate_det(%{"label" => "person", "score" => 0.9}) == :error
    assert PluginProtocol.validate_det(%{"score" => 0.9, "bbox" => [0, 0, 1, 1]}) == :error
    assert PluginProtocol.validate_det(%{}) == :error
  end

  test "non-map dets are invalid" do
    assert PluginProtocol.validate_det("person") == :error
    assert PluginProtocol.validate_det(nil) == :error
    assert PluginProtocol.validate_det([0, 0, 1, 1]) == :error
  end

  test "extra keys are ignored and dropped from the normalized det" do
    assert {:ok, det} = PluginProtocol.validate_det(det(%{"track_id" => 7}))
    assert det == %{label: "person", score: 0.9, bbox: [0, 0, 1, 1]}
  end

  test "validate_dets keeps the valid dets in order and counts the rest" do
    dets = [
      det(%{"label" => "a"}),
      det(%{"bbox" => [0, 0, 1]}),
      det(%{"label" => "b"}),
      det(%{"score" => "high"}),
      "garbage"
    ]

    assert {[%{label: "a"}, %{label: "b"}], 3} = PluginProtocol.validate_dets(dets)
  end

  test "validate_dets on an empty list" do
    assert PluginProtocol.validate_dets([]) == {[], 0}
  end

  test "validate_dets keeps a list at the 64-det cap" do
    dets = List.duplicate(@base, 64)
    assert {kept, 0} = PluginProtocol.validate_dets(dets)
    assert length(kept) == 64
  end

  test "validate_dets rejects an over-cap list whole, counting every entry" do
    dets = List.duplicate(@base, 65)
    assert PluginProtocol.validate_dets(dets) == {[], 65}
  end

  test "validate_dets is total on a non-list" do
    assert PluginProtocol.validate_dets(%{"label" => "person"}) == {[], 1}
    assert PluginProtocol.validate_dets("dets") == {[], 1}
    assert PluginProtocol.validate_dets(nil) == {[], 1}
  end

  describe "decode_line/2, protocol v1" do
    @observed "2026-07-26T12:00:00.500Z"

    defp v1(fields \\ %{}) do
      %{
        "spec" => "cairn.plugin",
        "version" => 1,
        "type" => "frame.objects",
        "camera_id" => "front_door",
        "stream_epoch" => "01J0000000000000000000000",
        "sequence" => 7,
        "frame" => %{"pts" => 90_000, "observed_at" => @observed},
        "objects" => [@base]
      }
      |> Map.merge(fields)
      |> Jason.encode!()
    end

    defp frame(fields) do
      v1(%{"frame" => Map.merge(%{"pts" => 90_000, "observed_at" => @observed}, fields)})
    end

    test "a full envelope decodes into an observation" do
      assert {:objects, obs} = PluginProtocol.decode_line(v1(), :group)

      assert obs.camera_id == "front_door"
      assert obs.epoch == "01J0000000000000000000000"
      assert obs.sequence == 7
      assert obs.pts == 90_000
      assert obs.time_base == {1, 90_000}
      assert obs.media_ms == 1_000.0
      assert obs.observed_at == ~U[2026-07-26 12:00:00.500Z]
      assert obs.time_quality == :source
      assert obs.protocol == :v1
      assert obs.ended_tracks == []
      assert obs.invalid_objects == 0

      assert [%{label: "person", score: 0.9, track_id: nil, observation_kind: "detected"}] =
               obs.objects
    end

    test "time_base scales media_ms" do
      assert {:objects, obs} =
               PluginProtocol.decode_line(
                 frame(%{"pts" => 120, "time_base" => [1, 60]}),
                 :camera
               )

      assert obs.time_base == {1, 60}
      assert obs.media_ms == 2_000.0
    end

    test "objects carry track_id and observation_kind" do
      line =
        v1(%{
          "objects" => [
            Map.merge(@base, %{"track_id" => "t-1", "observation_kind" => "tracked"})
          ],
          "ended_tracks" => ["t-0"]
        })

      assert {:objects, obs} = PluginProtocol.decode_line(line, :group)
      assert [%{track_id: "t-1", observation_kind: "tracked"}] = obs.objects
      assert obs.ended_tracks == ["t-0"]
    end

    test "an empty objects list is a valid observation" do
      assert {:objects, %{objects: []}} =
               PluginProtocol.decode_line(v1(%{"objects" => []}), :group)
    end

    test "an invalid object is dropped and counted, the line survives" do
      line = v1(%{"objects" => [det(%{"bbox" => [0, 0, 1]}), @base]})

      assert {:objects, obs} = PluginProtocol.decode_line(line, :group)
      assert [%{label: "person"}] = obs.objects
      assert obs.invalid_objects == 1
    end

    test "unknown top-level fields are ignored" do
      line = v1(%{"emitted_at" => @observed, "model" => %{"name" => "yolo"}, "future" => [1, 2]})
      assert {:objects, %{sequence: 7}} = PluginProtocol.decode_line(line, :group)
    end

    test "unknown types are ignored, unknown specs are an error" do
      assert PluginProtocol.decode_line(v1(%{"type" => "frame.audio"}), :group) ==
               {:ignore, :unknown_type}

      assert PluginProtocol.decode_line(~s({"spec": "other.plugin"}), :group) ==
               {:error, :unknown_spec}
    end

    test "an envelope without version or type is an error" do
      assert PluginProtocol.decode_line(~s({"spec": "cairn.plugin"}), :group) ==
               {:error, :invalid_envelope}

      assert PluginProtocol.decode_line(~s({"spec": "cairn.plugin", "version": 1}), :group) ==
               {:error, :invalid_envelope}
    end

    test "group mode requires camera_id, per-camera mode does not" do
      line = v1(%{"camera_id" => nil}) |> String.replace(~s("camera_id":null,), "")

      assert PluginProtocol.decode_line(line, :group) == {:error, :missing_camera_id}
      assert {:objects, %{camera_id: nil}} = PluginProtocol.decode_line(line, :camera)
    end

    @invalid_envelopes [
      {:unsupported_version, %{"version" => 2}},
      {:unsupported_version, %{"version" => "1"}},
      {:invalid_envelope, %{"type" => 42}},
      {:invalid_stream_epoch, %{"stream_epoch" => 1}},
      {:invalid_stream_epoch, %{"stream_epoch" => ""}},
      {:invalid_sequence, %{"sequence" => -1}},
      {:invalid_sequence, %{"sequence" => 1.5}},
      {:invalid_sequence, %{"sequence" => "7"}},
      {:invalid_frame, %{"frame" => "now"}},
      {:invalid_objects, %{"objects" => %{}}},
      {:invalid_ended_tracks, %{"ended_tracks" => [1]}},
      {:invalid_ended_tracks, %{"ended_tracks" => "t-0"}}
    ]

    for {reason, fields} <- @invalid_envelopes do
      test "invalid envelope: #{inspect(fields)} -> #{reason}" do
        line = v1(unquote(Macro.escape(fields)))
        assert PluginProtocol.decode_line(line, :group) == {:error, unquote(reason)}
      end
    end

    @invalid_frames [
      {:invalid_pts, %{"pts" => "90000"}},
      {:invalid_time_base, %{"time_base" => [0, 90_000]}},
      {:invalid_time_base, %{"time_base" => [1, -90_000]}},
      {:invalid_time_base, %{"time_base" => [1.0, 90_000.0]}},
      {:invalid_time_base, %{"time_base" => [1]}},
      {:invalid_observed_at, %{"observed_at" => "yesterday"}},
      {:invalid_observed_at, %{"observed_at" => 1_753_531_200}}
    ]

    for {reason, fields} <- @invalid_frames do
      test "invalid frame: #{inspect(fields)} -> #{reason}" do
        line = frame(unquote(Macro.escape(fields)))
        assert PluginProtocol.decode_line(line, :group) == {:error, unquote(reason)}
      end
    end

    test "a missing frame field is an error" do
      assert PluginProtocol.decode_line(v1(%{"frame" => %{"pts" => 1}}), :group) ==
               {:error, :invalid_observed_at}

      assert PluginProtocol.decode_line(v1(%{"frame" => %{"observed_at" => @observed}}), :group) ==
               {:error, :invalid_pts}
    end

    test "at most 64 objects per line" do
      assert {:objects, obs} =
               PluginProtocol.decode_line(v1(%{"objects" => List.duplicate(@base, 64)}), :group)

      assert length(obs.objects) == 64

      assert PluginProtocol.decode_line(v1(%{"objects" => List.duplicate(@base, 65)}), :group) ==
               {:error, :too_many_objects}
    end

    test "track ids are bounded" do
      long = String.duplicate("t", 65)
      line = v1(%{"objects" => [Map.put(@base, "track_id", long)]})

      assert {:objects, %{objects: [], invalid_objects: 1}} =
               PluginProtocol.decode_line(line, :group)
    end

    # Jason decodes JSON integer tokens at arbitrary precision. Unbounded,
    # `Observation.media_ms/2` (pts / den * num * 1000) raises ArithmeticError
    # on a value no float can hold — which killed the port, and the plugin
    # replays the line after every respawn.
    @huge String.to_integer(String.duplicate("9", 400))

    test "a bignum pts is a contract violation, not an exception" do
      assert PluginProtocol.decode_line(frame(%{"pts" => @huge}), :group) ==
               {:error, :invalid_pts}

      assert PluginProtocol.decode_line(frame(%{"pts" => -@huge}), :group) ==
               {:error, :invalid_pts}
    end

    test "a bignum time_base component is a contract violation" do
      assert PluginProtocol.decode_line(frame(%{"time_base" => [@huge, 1]}), :group) ==
               {:error, :invalid_time_base}

      assert PluginProtocol.decode_line(frame(%{"time_base" => [1, @huge]}), :group) ==
               {:error, :invalid_time_base}
    end

    test "a bignum sequence is a contract violation" do
      assert PluginProtocol.decode_line(v1(%{"sequence" => @huge}), :group) ==
               {:error, :invalid_sequence}
    end

    test "media_ms stays finite at the accepted bounds" do
      max_pts = 4_611_686_018_427_387_904

      assert {:objects, obs} =
               PluginProtocol.decode_line(
                 frame(%{"pts" => max_pts, "time_base" => [1_000_000_000, 1]}),
                 :group
               )

      assert is_float(obs.media_ms)
      assert obs.media_ms < 1.0e40
    end

    test "an unknown observation_kind invalidates the object" do
      line = v1(%{"objects" => [Map.put(@base, "observation_kind", "guessed")]})

      assert {:objects, %{objects: [], invalid_objects: 1}} =
               PluginProtocol.decode_line(line, :group)
    end
  end

  describe "decode_line/2, hello and status" do
    defp message(type, fields) do
      %{"spec" => "cairn.plugin", "version" => 1, "type" => type}
      |> Map.merge(fields)
      |> Jason.encode!()
    end

    test "hello passes the nested body through" do
      hello = %{
        "name" => "cairn-detect",
        "version" => "0.3.1",
        "supported_versions" => [1],
        "capabilities" => %{"object_tracking" => true}
      }

      assert PluginProtocol.decode_line(message("plugin.hello", %{"hello" => hello}), :camera) ==
               {:hello, hello}
    end

    test "a flat hello keeps its own fields and loses the envelope" do
      line = message("plugin.hello", %{"name" => "mock", "supported_versions" => [1]})

      assert {:hello, hello} = PluginProtocol.decode_line(line, :camera)
      assert hello == %{"name" => "mock", "supported_versions" => [1]}
    end

    test "status requires a state string and keeps camera_id" do
      line =
        message("plugin.status", %{
          "camera_id" => "front_door",
          "status" => %{"state" => "degraded", "detail" => "decoder fallback"}
        })

      assert {:status, status} = PluginProtocol.decode_line(line, :group)
      assert status["state"] == "degraded"
      assert status["detail"] == "decoder fallback"
      assert status["camera_id"] == "front_door"

      assert PluginProtocol.decode_line(message("plugin.status", %{}), :group) ==
               {:error, :invalid_status}

      assert PluginProtocol.decode_line(
               message("plugin.status", %{"status" => %{"state" => 1}}),
               :group
             ) == {:error, :invalid_status}
    end

    test "a status without camera_id carries none" do
      line = message("plugin.status", %{"status" => %{"state" => "ready"}})
      assert {:status, status} = PluginProtocol.decode_line(line, :camera)
      refute Map.has_key?(status, "camera_id")
    end

    # The status is retained per camera in ETS and broadcast to every
    # dashboard and SSE client on every line, so it is a whitelist: what a
    # plugin can park there and amplify is fixed here, not by the plugin.
    test "status keeps only the contract keys, bounded" do
      line =
        message("plugin.status", %{
          "status" => %{
            "state" => "ready",
            "detail" => "model loaded",
            "fps" => 19.5,
            "blob" => String.duplicate("x", 10_000),
            "nested" => %{"deep" => [1, 2, 3]}
          }
        })

      assert {:status, status} = PluginProtocol.decode_line(line, :camera)
      assert status == %{"state" => "ready", "detail" => "model loaded", "fps" => 19.5}
    end

    test "an out-of-bounds status field is dropped, not the line" do
      status = fn fields ->
        line = message("plugin.status", %{"status" => Map.merge(%{"state" => "ready"}, fields)})
        {:status, shaped} = PluginProtocol.decode_line(line, :camera)
        shaped
      end

      refute Map.has_key?(status.(%{"detail" => String.duplicate("d", 257)}), "detail")
      refute Map.has_key?(status.(%{"detail" => "line\nbreak"}), "detail")
      refute Map.has_key?(status.(%{"detail" => 42}), "detail")
      refute Map.has_key?(status.(%{"fps" => 10_001}), "fps")
      refute Map.has_key?(status.(%{"fps" => -1}), "fps")
      refute Map.has_key?(status.(%{"fps" => "fast"}), "fps")
    end

    test "an unusable state drops the line" do
      invalid = [
        %{"state" => String.duplicate("s", 33)},
        %{"state" => ""},
        %{"state" => "\e[2Jready"},
        %{"state" => "ready\nfake log line"},
        %{"state" => 1},
        %{"detail" => "no state at all"}
      ]

      for body <- invalid do
        line = message("plugin.status", %{"status" => body})
        assert PluginProtocol.decode_line(line, :group) == {:error, :invalid_status}
      end
    end

    test "a payload camera_id cannot address another member" do
      line =
        message("plugin.status", %{
          "status" => %{"state" => "ready", "camera_id" => "someone_else"}
        })

      assert {:status, status} = PluginProtocol.decode_line(line, :group)
      refute Map.has_key?(status, "camera_id")
    end

    # `hello` is held in port state and interpolated into logs; a map where a
    # string belongs used to raise Protocol.UndefinedError and kill the port.
    test "hello fields that do not match the contract are dropped, not the line" do
      hello = %{
        "name" => %{"not" => "a string"},
        "version" => String.duplicate("v", 65),
        "supported_versions" => "one",
        "capabilities" => ["object_tracking"],
        "extra" => String.duplicate("x", 10_000)
      }

      assert PluginProtocol.decode_line(message("plugin.hello", %{"hello" => hello}), :camera) ==
               {:hello, %{}}
    end

    test "hello lists and maps are filtered and capped" do
      hello = %{
        "name" => "cairn-detect",
        "supported_versions" => [1, "2", 3.0, -1, 10_000] ++ Enum.to_list(1..20),
        "capabilities" =>
          %{"object_tracking" => true, "audio" => "yes", String.duplicate("k", 33) => true}
          |> Map.merge(Map.new(1..40, &{"cap_#{&1}", true}))
      }

      assert {:hello, shaped} =
               PluginProtocol.decode_line(message("plugin.hello", %{"hello" => hello}), :camera)

      assert shaped["name"] == "cairn-detect"
      # non-integers and out-of-range versions go, and the list is capped
      assert length(shaped["supported_versions"]) <= 16
      assert Enum.all?(shaped["supported_versions"], &(is_integer(&1) and &1 in 0..1_000))
      # only boolean values with short printable keys survive, capped at 32
      assert map_size(shaped["capabilities"]) == 32
      refute Map.has_key?(shaped["capabilities"], "audio")
      refute Enum.any?(Map.keys(shaped["capabilities"]), &(byte_size(&1) > 32))
      assert Enum.all?(Map.values(shaped["capabilities"]), &is_boolean/1)
    end

    test "a hello with no usable body is an empty map, never a crash" do
      assert PluginProtocol.decode_line(message("plugin.hello", %{"hello" => 42}), :camera) ==
               {:hello, %{}}

      assert PluginProtocol.decode_line(message("plugin.hello", %{}), :camera) == {:hello, %{}}
    end
  end

  describe "decode_line/2, protocol v0" do
    test "a line without spec falls through to v0" do
      line = ~s({"pts": 90000, "dets": [{"label": "person", "score": 0.9, "bbox": [0,0,1,1]}]})

      assert {:objects, obs} = PluginProtocol.decode_line(line, :camera)
      assert obs.protocol == :v0
      assert obs.pts == 90_000
      assert obs.media_ms == 1_000.0
      assert obs.time_quality == :arrival
      # the port fills these in: the wire carries neither
      assert obs.epoch == nil
      assert obs.observed_at == nil
      assert obs.sequence == nil
      assert [%{label: "person", track_id: nil, observation_kind: "detected"}] = obs.objects
    end

    test "v0 still validates and counts per detection" do
      line =
        ~s({"camera_id": "front_door", "pts": 1, "dets": [) <>
          ~s({"label": "person", "score": 0.9, "bbox": [0,0,1]},) <>
          ~s({"label": "cat", "score": 0.8, "bbox": [0,0,1,1]}]})

      assert {:objects, obs} = PluginProtocol.decode_line(line, :group)
      assert [%{label: "cat"}] = obs.objects
      assert obs.invalid_objects == 1
      assert obs.camera_id == "front_door"
    end

    test "v0 errors" do
      assert PluginProtocol.decode_line(~s({"pts": "1", "dets": []}), :camera) ==
               {:error, :missing_pts_or_dets}

      assert PluginProtocol.decode_line(~s({"pts": 1}), :camera) ==
               {:error, :missing_pts_or_dets}

      assert PluginProtocol.decode_line(~s({"pts": 1, "dets": []}), :group) ==
               {:error, :missing_camera_id}

      assert PluginProtocol.decode_line("garbage", :camera) == {:error, :malformed_json}
      assert PluginProtocol.decode_line("[1, 2]", :camera) == {:error, :not_an_object}
    end
  end
end
