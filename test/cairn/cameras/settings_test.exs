defmodule Cairn.Cameras.SettingsTest do
  # Pure translation: no socket, no repo, no config server.
  use ExUnit.Case, async: true

  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Settings

  # The round-trip row: one value in every shape the translation has to
  # survive — a credentialed URL, both tiers, a retention block, the ffmpeg
  # args the parser also accepts as a string, and verbatim JSON.
  defp rich_row do
    settings =
      Cameras.canonical(%{
        "rtsp_url" => "rtsp://admin:s3cret@cam.lan:554/main",
        "substream_url" => "rtsp://cam.lan:554/sub",
        "plugin" => "yard",
        "ingest" => "ffmpeg",
        "transcode" => true,
        "min_score" => %{"default" => 0.5, "person" => 0.6},
        "track" => %{"person" => %{"min_score" => 0.6}},
        "record" => %{"person" => %{"min_score" => 0.7}, "car" => %{"min_score" => 0.8}},
        "retention" => %{"days" => 7, "per_label" => %{"person" => 30}},
        "pre_window_seconds" => 4,
        "post_window_seconds" => 12,
        "annotation_offset_ms" => -400,
        "tracker" => "cairn",
        "max_live_tracks" => 40,
        "extra_ffmpeg_args" => "-rtsp_transport tcp",
        "motion_json" => ~s({"enabled": true})
      })

    %Camera{id: "front_door", settings: settings, zones: []}
  end

  describe "to_params/1" do
    test "never carries a password and blanks a credentialed URL" do
      params = Settings.to_params(rich_row())

      assert params["password"] == ""
      assert params["rtsp_url"] == ""
      assert params["username"] == "admin"
      refute inspect(params) =~ "s3cret"
    end

    # A hand-edited row can hold a malformed escape, and the form is the only
    # place to repair it — `URI.decode/1` raises on one.
    test "a malformed escape in the userinfo renders instead of raising" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://bad%zz:pw@h/1"}, zones: []}

      params = Settings.to_params(row)

      assert params["username"] == "bad%zz"
      assert params["rtsp_url"] == ""
    end

    # `%FF` decodes without raising, to a binary that is not valid UTF-8 and
    # would take the render down further along.
    test "an escape that decodes to invalid UTF-8 keeps the raw username" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://u%FF:pw@h/1"}, zones: []}

      params = Settings.to_params(row)

      assert params["username"] == "u%FF"
      assert params["rtsp_url"] == ""
    end

    test "prefills a URL with no credential in it" do
      params = Settings.to_params(rich_row())

      assert params["substream_url"] == "rtsp://cam.lan:554/sub"
    end

    # These are the shapes the loader skips the row for, and the form is the
    # only place the operator can repair them: every one has to arrive as an
    # empty field rather than as a `to_string/1` raise.
    test "a non-scalar cell arrives blank instead of raising" do
      row = %Camera{
        id: "gate",
        settings: %{
          "rtsp_url" => "rtsp://h/1",
          "ingest" => %{},
          "motion_json" => %{"enabled" => true},
          "tracker" => [],
          "plugin" => %{"name" => "yard"},
          "extra_ffmpeg_args" => ["-x", %{}],
          "pre_window_seconds" => %{}
        },
        zones: []
      }

      params = Settings.to_params(row)

      assert params["ingest"] == ""
      assert params["motion_json"] == ""
      assert params["tracker"] == ""
      assert params["plugin"] == ""
      assert params["extra_ffmpeg_args"] == "-x "
      assert params["pre_window_seconds"] == ""
    end

    test "renders scores as written and puts the default row first" do
      rows = rich_row() |> Settings.to_params() |> Settings.rows()

      assert Enum.map(rows, & &1["label"]) == ["default", "car", "person"]
      assert Enum.at(rows, 0)["min_score"] == "0.5"
      assert Enum.at(rows, 2)["min_score"] == "0.6"
      assert Enum.at(rows, 2)["track"] == "0.6"
      assert Enum.at(rows, 2)["record"] == "0.7"
      assert Enum.at(rows, 2)["retention_days"] == "30"
      # The car row exists only because `record` names it.
      assert Enum.at(rows, 1)["min_score"] == ""
      assert Enum.at(rows, 1)["record"] == "0.8"
    end

    test "a three-decimal threshold survives the cell it renders into" do
      row = %Camera{id: "gate", settings: %{"min_score" => %{"default" => 0.555}}, zones: []}

      params = Settings.to_params(row)

      assert params |> Settings.rows() |> Enum.at(0) |> Map.get("min_score") == "0.555"
      assert {:ok, settings} = Settings.to_settings(params, row)
      assert settings["min_score"] == %{"default" => 0.555}
    end

    test "the default row has no per-label days: they are the camera's own" do
      row = %Camera{
        id: "gate",
        settings: %{"retention" => %{"days" => 7, "per_label" => %{"default" => 3}}},
        zones: []
      }

      params = Settings.to_params(row)

      assert params["retention_days"] == "7"
      assert params |> Settings.rows() |> Enum.at(0) |> Map.get("retention_days") == ""
    end

    test "a new camera starts with one default row and nothing else" do
      params = Settings.to_params(nil)

      assert params["id"] == ""
      assert Settings.rows(params) == [Settings.blank_row("default")]
    end
  end

  describe "to_settings/2" do
    test "an untouched edit round-trips to the same canonical map (D-P5)" do
      row = rich_row()

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert Cameras.canonical(settings) == row.settings
    end

    test "blank is absent, so an empty form inherits everything" do
      {:ok, settings} =
        nil
        |> Settings.to_params()
        |> Map.put("rtsp_url", "rtsp://h/1")
        |> Settings.to_settings()

      assert settings == %{"rtsp_url" => "rtsp://h/1"}
    end

    test "a tier column with no cell filled is omitted, not emptied" do
      params =
        params_with_rows([
          %{"label" => "default", "min_score" => "0.50"},
          %{"label" => "person", "min_score" => "0.60", "record" => "0.70"}
        ])

      {:ok, settings} = Settings.to_settings(params)

      refute Map.has_key?(settings, "track")
      assert settings["record"] == %{"person" => %{"min_score" => 0.7}}
      assert settings["min_score"] == %{"default" => 0.5, "person" => 0.6}
    end

    test "a new password replaces the one in the URL and is spliced into the one without" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"username" => "ops", "password" => "new pass"})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://ops:new%20pass@cam.lan:554/main"
      assert settings["substream_url"] == "rtsp://ops:new%20pass@cam.lan:554/sub"
    end

    # The username field is prefilled off the main stream only, so applying it
    # to every URL that has userinfo rewrote a sub stream that authenticates
    # as somebody else (D-P5: an untouched save diffs to nothing).
    test "each URL keeps its own username on an untouched save" do
      row = %Camera{
        id: "gate",
        settings: %{
          "rtsp_url" => "rtsp://alice:x@cam.lan/main",
          "substream_url" => "rtsp://bob:y@cam.lan/sub"
        },
        zones: []
      }

      params = Settings.to_params(row)
      assert params["username"] == "alice"

      {:ok, settings} = Settings.to_settings(params, row)

      assert settings["rtsp_url"] == "rtsp://alice:x@cam.lan/main"
      assert settings["substream_url"] == "rtsp://bob:y@cam.lan/sub"
    end

    test "a typed password reaches both URLs and neither username moves" do
      row = %Camera{
        id: "gate",
        settings: %{
          "rtsp_url" => "rtsp://alice:x@cam.lan/main",
          "substream_url" => "rtsp://bob:y@cam.lan/sub"
        },
        zones: []
      }

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.put("password", "pw")
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://alice:pw@cam.lan/main"
      assert settings["substream_url"] == "rtsp://bob:pw@cam.lan/sub"
    end

    test "a param the form did not send reads as blank, not a crash" do
      # A hand-sent or partial submit omits keys; `to_string(nil)` is "".
      assert {:ok, settings} = Settings.to_settings(%{"rtsp_url" => "rtsp://h/1"}, nil)
      assert settings == %{"rtsp_url" => "rtsp://h/1"}
    end

    test "a ticked remove-sub-stream leaves nothing to probe on the sub row" do
      row = %Camera{
        id: "gate",
        settings: %{"rtsp_url" => "rtsp://h/1", "substream_url" => "rtsp://h/2"},
        zones: []
      }

      params = Settings.to_params(row)
      assert Settings.urls(params, row).sub == "rtsp://h/2"
      assert Settings.urls(Map.put(params, "clear_substream", "true"), row).sub == nil
    end

    test "a scalar where the retention block belongs renders blank and saves" do
      row = %Camera{
        id: "gate",
        settings: %{"rtsp_url" => "rtsp://h/1", "retention" => 5},
        zones: []
      }

      params = Settings.to_params(row)
      assert params["retention_days"] == ""
      assert {:ok, settings} = Settings.to_settings(params, row)
      refute Map.has_key?(settings, "retention")
    end

    test "a colonless userinfo is not prefilled as a username" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://SECRET@h/1"}, zones: []}
      params = Settings.to_params(row)
      assert params["username"] == ""
      assert params["rtsp_url"] == ""
      assert {:ok, %{"rtsp_url" => "rtsp://SECRET@h/1"}} = Settings.to_settings(params, row)
    end

    test "removing saved credentials strips the query form too" do
      main = "http://cam.lan/flv?stream=ch0&user=admin&password=old"
      row = %Camera{id: "gate", settings: %{"rtsp_url" => main}, zones: []}

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.put("clear_credentials", "true")
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "http://cam.lan/flv?stream=ch0"
    end

    test "an @ inside the saved password is not mistaken for the host boundary" do
      main = "rtsp://user:sec@ret@host/s"
      row = %Camera{id: "gate", settings: %{"rtsp_url" => main}, zones: []}
      params = Settings.to_params(row)

      assert params["username"] == "user"

      assert {:ok, %{"rtsp_url" => "rtsp://user:new@host/s"}} =
               Settings.to_settings(Map.put(params, "password", "new"), row)

      assert {:ok, %{"rtsp_url" => "rtsp://user:sec@ret@new/s"}} =
               Settings.to_settings(Map.put(params, "rtsp_url", "rtsp://new/s"), row)
    end

    test "a URL carrying its credential in the query is never spliced" do
      main = "http://cam.lan/flv?stream=ch0&user=admin&password=old"

      row = %Camera{
        id: "gate",
        settings: %{"rtsp_url" => main, "substream_url" => "rtsp://cam.lan/sub"},
        zones: []
      }

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"rtsp_url" => main, "username" => "admin", "password" => "pw"})
        |> Settings.to_settings(row)

      # The typed fields reach the sub stream, which has no credential at all;
      # the main stream already carries one, in the query, and stays as typed.
      assert settings["rtsp_url"] == main
      assert settings["substream_url"] == "rtsp://admin:pw@cam.lan/sub"
    end

    test "a retyped URL with no credential carries the saved query-form credential" do
      main = "http://old/flv?stream=ch0&user=admin&password=x"
      row = %Camera{id: "gate", settings: %{"rtsp_url" => main}, zones: []}

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"rtsp_url" => "http://new/flv?stream=ch1"})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "http://new/flv?stream=ch1&user=admin&password=x"
    end

    test "a retyped URL that already carries its own credential is left alone" do
      main = "http://old/flv?stream=ch0&user=admin&password=x"
      row = %Camera{id: "gate", settings: %{"rtsp_url" => main}, zones: []}
      retyped = "http://new/flv?stream=ch1&user=other&password=y"

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"rtsp_url" => retyped})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == retyped
    end

    test "credentials typed for an uncredentialed URL are spliced in, URL untouched" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://cam.lan/main"}, zones: []}

      params = Settings.to_params(row)
      # The credential rule prefills this URL: it carries no credential.
      assert params["rtsp_url"] == "rtsp://cam.lan/main"

      {:ok, settings} =
        params
        |> Map.merge(%{"username" => "ops", "password" => "pw"})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://ops:pw@cam.lan/main"
    end

    # Retyping the URL (a new host or path) used to lose the saved password:
    # the typed URL carries no userinfo of its own, so the splice read "no
    # credential yet" and dropped the saved one instead of updating around it.
    test "a retyped URL keeps the saved password when only the username changes" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://u:pw@old/1"}, zones: []}

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"rtsp_url" => "rtsp://new/1", "username" => "v", "password" => ""})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://v:pw@new/1"
    end

    test "blank credentials leave both URLs exactly as they were" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"username" => "", "password" => ""})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://admin:s3cret@cam.lan:554/main"
      assert settings["substream_url"] == "rtsp://cam.lan:554/sub"
    end

    # A blank field means "keep" everywhere else, so without the checkbox the
    # sub stream could never be removed at all.
    test "clear_substream drops the sub stream a blank field would keep" do
      row = rich_row()
      params = Settings.to_params(row)

      {:ok, kept} = params |> Map.put("substream_url", "") |> Settings.to_settings(row)
      assert kept["substream_url"] == "rtsp://cam.lan:554/sub"

      {:ok, cleared} =
        params
        |> Map.merge(%{"substream_url" => "", "clear_substream" => "true"})
        |> Settings.to_settings(row)

      refute Map.has_key?(cleared, "substream_url")
    end

    # Checked wins over a field the operator also typed into: the box is the
    # act, the field is only text.
    test "clear_substream drops a typed sub stream too" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"substream_url" => "rtsp://cam.lan/other", "clear_substream" => "true"})
        |> Settings.to_settings(row)

      refute Map.has_key?(settings, "substream_url")
    end

    # A saved credential could not otherwise be removed: a blank username or
    # password field means "keep" everywhere else, so the checkbox is the
    # only act that drops it.
    test "clear_credentials strips the saved userinfo when the fields are left blank" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"clear_credentials" => "true"})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://cam.lan:554/main"
      assert settings["substream_url"] == "rtsp://cam.lan:554/sub"
    end

    # Checked wins over a field the operator also typed into, same as
    # `clear_substream`: the box is the act, the fields are only text.
    test "clear_credentials strips userinfo from a typed clean URL too, ignoring the fields" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{
          "rtsp_url" => "rtsp://cam.lan:554/main",
          "username" => "someone",
          "password" => "else",
          "clear_credentials" => "true"
        })
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://cam.lan:554/main"
    end

    test "clear_credentials unchecked leaves the ordinary splice untouched" do
      row = rich_row()

      {:ok, settings} =
        row
        |> Settings.to_params()
        |> Map.merge(%{"username" => "ops", "password" => "newpw"})
        |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://ops:newpw@cam.lan:554/main"
    end

    # The username field is prefilled off the *main* stream, so a prefill that
    # counted as "typed" would rewrite a sub stream nobody edited (D-P5).
    test "the prefilled username alone does not splice" do
      row = rich_row()
      params = Settings.to_params(row)

      assert params["username"] == "admin"

      {:ok, settings} = Settings.to_settings(params, row)

      assert settings["substream_url"] == "rtsp://cam.lan:554/sub"
    end

    # `per_label["default"]` is a rule for a detection label spelled "default",
    # not the camera's own days — the row that key belongs to has no cell for
    # it at all, so an untouched edit must not drop it (D-P5).
    test "a saved per_label rule named default round-trips through an untouched edit" do
      row = %Camera{
        id: "gate",
        settings: %{
          "rtsp_url" => "rtsp://h/1",
          "retention" => %{"per_label" => %{"default" => 3}}
        },
        zones: []
      }

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert settings["retention"] == %{"per_label" => %{"default" => 3}}
    end

    test "a per-label days cell on the default row is not written" do
      params =
        params_with_rows([
          %{"label" => "default", "retention_days" => "3"},
          %{"label" => "person", "retention_days" => "30"}
        ])

      {:ok, settings} = Settings.to_settings(params)

      assert settings["retention"] == %{"per_label" => %{"person" => 30}}
    end

    test "a non-numeric whole-number field is an error naming the field" do
      params = Map.put(Settings.to_params(nil), "pre_window_seconds", "five")

      assert {:error, ["pre_window_seconds must be a whole number"]} =
               Settings.to_settings(params)
    end

    test "duplicate and unnamed label rows are errors" do
      duplicated =
        params_with_rows([
          %{"label" => "default"},
          %{"label" => "person", "min_score" => "0.6"},
          %{"label" => "person", "min_score" => "0.7"}
        ])

      assert {:error, [~s(duplicate label "person")]} = Settings.to_settings(duplicated)

      unnamed =
        params_with_rows([%{"label" => "default"}, %{"label" => "", "min_score" => "0.6"}])

      assert {:error, ["a label row needs a label"]} = Settings.to_settings(unnamed)
    end

    test "an entirely blank row is dropped rather than refused" do
      params = params_with_rows([%{"label" => "default"}, %{"label" => ""}])

      assert {:ok, settings} = Settings.to_settings(params)
      refute Map.has_key?(settings, "min_score")
    end

    test "a cell that is not a number is passed on for the loader to name" do
      params = params_with_rows([%{"label" => "default", "min_score" => "high"}])

      assert {:ok, %{"min_score" => %{"default" => "high"}}} = Settings.to_settings(params)
    end

    test "extra ffmpeg args are stored split, the way the importer stores them" do
      params = Map.put(Settings.to_params(nil), "extra_ffmpeg_args", "-rtsp_transport tcp")

      assert {:ok, %{"extra_ffmpeg_args" => ["-rtsp_transport", "tcp"]}} =
               Settings.to_settings(params)
    end

    # The field is one line and the split is on whitespace, so re-splitting
    # what the field only rendered would break this argument in two.
    test "an argument containing a space survives an untouched edit, an edited field splits" do
      args = ["-headers", "Authorization: Bearer x"]
      row = %Camera{id: "gate", settings: %{"extra_ffmpeg_args" => args}, zones: []}

      params = Settings.to_params(row)
      assert params["extra_ffmpeg_args"] == "-headers Authorization: Bearer x"

      {:ok, settings} = Settings.to_settings(params, row)
      assert settings["extra_ffmpeg_args"] == args

      {:ok, edited} =
        params
        |> Map.put("extra_ffmpeg_args", "-rtsp_transport tcp")
        |> Settings.to_settings(row)

      assert edited["extra_ffmpeg_args"] == ["-rtsp_transport", "tcp"]
    end

    # Neither field can supply the credential here: the password says "leave
    # blank to keep" and the username is a prefill, not an entry.
    test "a retyped URL keeps the credential the saved one carried" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://u:pw@old/1"}, zones: []}
      params = Settings.to_params(row)

      assert params["username"] == "u"

      {:ok, settings} = params |> Map.put("rtsp_url", "rtsp://new/1") |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://u:pw@new/1"

      {:ok, typed} =
        params
        |> Map.merge(%{"rtsp_url" => "rtsp://new/1", "password" => "pw2"})
        |> Settings.to_settings(row)

      assert typed["rtsp_url"] == "rtsp://u:pw2@new/1"
    end

    # Cameras that authenticate on the password alone, and on create there is
    # no saved URL to carry the credential instead.
    test "a password with no username composes password-only userinfo" do
      {:ok, settings} =
        Settings.to_settings(
          %{"rtsp_url" => "rtsp://h/1", "username" => "", "password" => "pw"},
          nil
        )

      assert settings["rtsp_url"] == "rtsp://:pw@h/1"
    end

    # The username field is not trimmed, like the password:
    # `Cairn.StreamUrl.user/1` decodes the saved userinfo verbatim, spaces
    # included, so a trim on the way back would make the splice see a typed
    # change where there was none and rewrite the URL on an untouched save.
    test "a saved username with leading/trailing spaces round-trips through an untouched edit" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://%20u:pw@h/1"}, zones: []}

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://%20u:pw@h/1"
    end

    test "a saved password-only URL round-trips through an untouched edit" do
      row = %Camera{id: "gate", settings: %{"rtsp_url" => "rtsp://:pw@h/1"}, zones: []}

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert settings["rtsp_url"] == "rtsp://:pw@h/1"
    end

    test "a saved key the form has no field for survives an edit" do
      row = %Camera{
        id: "gate",
        settings: %{"rtsp_url" => "rtsp://cam.lan/main", "future_key" => "kept"},
        zones: []
      }

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert settings["future_key"] == "kept"
    end

    # `pipeline` is modelled-and-omitted, not carried like a genuinely
    # unmodelled key (see `@modelled_keys`): the form has no field for it, so
    # an edit is the only way left to repair a row stuck on the removed
    # `"classic"` value, and it can only do that by dropping the key outright.
    test "a saved classic pipeline is dropped by an edit, unlike a real unmodelled key" do
      row = %Camera{
        id: "gate",
        settings: %{
          "rtsp_url" => "rtsp://cam.lan/main",
          "pipeline" => "classic",
          "future_key" => "kept"
        },
        zones: []
      }

      {:ok, settings} = row |> Settings.to_params() |> Settings.to_settings(row)

      refute Map.has_key?(settings, "pipeline")
      assert settings["future_key"] == "kept"
    end

    # The keys `canonical/1` drops as parse-equivalent to absent: the form
    # writes none of them, so the round trip has to land on the same map.
    test "a row imported with parser-default keys round-trips unchanged (D-P5)" do
      settings =
        Cameras.canonical(%{
          "rtsp_url" => "rtsp://cam.lan/main",
          "transcode" => false,
          "extra_ffmpeg_args" => [],
          "pipeline" => "membrane"
        })

      row = %Camera{id: "gate", settings: settings, zones: []}

      {:ok, saved} = row |> Settings.to_params() |> Settings.to_settings(row)

      assert Cameras.canonical(saved) == settings
    end
  end

  describe "sanitize_params/1" do
    # Phoenix decodes a crafted bracketed input name like `camera[id][x]=y`
    # into a nested map, and every scalar param a hand-sent or malformed
    # submit can carry has to survive that shape without raising downstream.
    test "a non-binary top-level value becomes blank" do
      params = Settings.sanitize_params(%{"id" => %{"x" => "y"}, "password" => ["a"]})

      assert params["id"] == ""
      assert params["password"] == ""
    end

    test "a binary top-level value passes through unchanged" do
      params = Settings.sanitize_params(%{"rtsp_url" => "rtsp://h/1"})

      assert params["rtsp_url"] == "rtsp://h/1"
    end

    test "labels keeps only map rows, and only their binary cells" do
      params =
        Settings.sanitize_params(%{
          "labels" => %{
            "0" => %{"label" => "default", "min_score" => %{"x" => "y"}},
            "1" => "not a row",
            "2" => %{"label" => "person", "track" => "0.5"}
          }
        })

      assert params["labels"] == %{
               "0" => %{"label" => "default"},
               "2" => %{"label" => "person", "track" => "0.5"}
             }
    end

    test "a non-map labels value becomes an empty map" do
      assert Settings.sanitize_params(%{"labels" => "not a map"})["labels"] == %{}
    end
  end

  describe "urls/2" do
    test "probes the composed URL, credential and all" do
      row = rich_row()
      params = Map.put(Settings.to_params(row), "password", "other")

      # Both streams: the probe opens what the save would write, and a typed
      # password is spliced into the sub stream too.
      assert Settings.urls(params, row) == %{
               main: "rtsp://admin:other@cam.lan:554/main",
               sub: "rtsp://admin:other@cam.lan:554/sub"
             }
    end

    # The probe has to honour the same act a save would, or it would open a
    # URL with a credential the save is about to drop.
    test "clear_credentials strips userinfo from the probed URLs too" do
      row = rich_row()
      params = Settings.to_params(row) |> Map.put("clear_credentials", "true")

      assert Settings.urls(params, row) == %{
               main: "rtsp://cam.lan:554/main",
               sub: "rtsp://cam.lan:554/sub"
             }
    end
  end

  describe "field_errors/3" do
    test "routes the loader's strings to the field or cell each names" do
      {routed, unclaimed} =
        Settings.field_errors(
          [
            "camera cam1: rtsp_url is required",
            "camera cam1: substream_url must be an rtsp:// url",
            ~s(camera cam1: ingest must be "rtsp" or "ffmpeg"),
            "camera cam1: tracker: unknown tracker \"nope\" (cairn, sparsetrack)",
            "camera cam1: annotation_offset_ms must be an integer number of ms",
            "camera cam1: extra_ffmpeg_args must be a list of strings",
            "camera cam1: motion_json: scene must be an object",
            "camera cam1: unknown plugin \"old_group\" — define it under plugins:",
            "camera cam1: max_unseen_ms must be 100..3600000"
          ],
          "cam1",
          []
        )

      assert routed["rtsp_url"] == ["rtsp_url is required"]
      assert routed["substream_url"] == [~s(substream_url must be an rtsp:// url)]
      assert routed["ingest"] == [~s(ingest must be "rtsp" or "ffmpeg")]
      assert routed["tracker"] == ["tracker: unknown tracker \"nope\" (cairn, sparsetrack)"]

      assert routed["annotation_offset_ms"] == [
               "annotation_offset_ms must be an integer number of ms"
             ]

      assert routed["extra_ffmpeg_args"] == ["extra_ffmpeg_args must be a list of strings"]
      assert routed["motion_json"] == ["motion_json: scene must be an object"]
      assert routed["plugin"] == ["unknown plugin \"old_group\" — define it under plugins:"]
      assert routed["max_unseen_ms"] == ["max_unseen_ms must be 100..3600000"]
      assert unclaimed == []
    end

    test "routes the tier strings to the cell whose label they name" do
      {routed, unclaimed} =
        Settings.field_errors(
          [
            "camera cam1: min_score values must be 0..1 (car, person)",
            "camera cam1: track values must be a number or a map of {min_score: 0..1} (person)",
            "camera cam1: track.person (0.4) must be >= min_score.person (0.5)",
            "camera cam1: record.person (0.5) must be >= track.person (0.6)"
          ],
          "cam1",
          ["car", "person"]
        )

      assert routed[{"car", "min_score"}] == ["min_score values must be 0..1 (car, person)"]
      assert routed[{"person", "min_score"}] == ["min_score values must be 0..1 (car, person)"]

      assert routed[{"person", "track"}] == [
               "track values must be a number or a map of {min_score: 0..1} (person)",
               "track.person (0.4) must be >= min_score.person (0.5)"
             ]

      assert routed[{"person", "record"}] == ["record.person (0.5) must be >= track.person (0.6)"]
      assert unclaimed == []
    end

    test "the record-covers-track message is row-level, spanning two cells" do
      message =
        "camera cam1: track.person (0.6) must be <= the effective record threshold (0.5) — " <>
          "with no record: block video falls back to min_score, so a clip could exist with no " <>
          "track row. Give person a record: rule, or lower track.person"

      {routed, []} = Settings.field_errors([message], "cam1", ["person"])

      assert [row_message] = routed[{"person", :row}]
      assert row_message =~ "effective record threshold"
    end

    # A detection label is a class name and can hold spaces, so the label in a
    # `tier.label (value)` message runs up to the value, not to the first
    # space.
    test "routes a tier string whose label has a space" do
      {routed, unclaimed} =
        Settings.field_errors(
          [
            "camera cam1: track.license plate (0.4) must be >= min_score.license plate (0.5)",
            "camera cam1: min_score values must be 0..1 (license plate)"
          ],
          "cam1",
          ["license plate"]
        )

      assert routed[{"license plate", "track"}] == [
               "track.license plate (0.4) must be >= min_score.license plate (0.5)"
             ]

      assert routed[{"license plate", "min_score"}] == [
               "min_score values must be 0..1 (license plate)"
             ]

      assert unclaimed == []
    end

    test "the record-covers-track message routes a label with a space to the row" do
      message =
        "camera cam1: track.license plate (0.6) must be <= the effective record threshold " <>
          "(0.5) — with no record: block video falls back to min_score, so a clip could " <>
          "exist with no track row. Give license plate a record: rule, or lower " <>
          "track.license plate"

      {routed, []} = Settings.field_errors([message], "cam1", ["license plate"])

      assert [row_message] = routed[{"license plate", :row}]
      assert row_message =~ "effective record threshold"
    end

    # A label with parentheses of its own ends *after* the ` (` that reads
    # like the loader's value suffix, so every one of these forms has to be
    # resolved against the known row labels rather than cut at the first ` (`.
    test "routes every form for a label that contains parentheses" do
      {routed, unclaimed} =
        Settings.field_errors(
          [
            "camera cam1: track.person (adult) (0.4) must be >= min_score.person (adult) (0.5)",
            "camera cam1: record.person (adult) (0.5) must be >= track.person (adult) (0.6)",
            "camera cam1: min_score values must be 0..1 (person (adult))",
            "camera cam1: retention_days (person (adult)) must be a whole number"
          ],
          "cam1",
          ["person (adult)"]
        )

      assert routed[{"person (adult)", "track"}] == [
               "track.person (adult) (0.4) must be >= min_score.person (adult) (0.5)"
             ]

      assert routed[{"person (adult)", "record"}] == [
               "record.person (adult) (0.5) must be >= track.person (adult) (0.6)"
             ]

      assert routed[{"person (adult)", "min_score"}] == [
               "min_score values must be 0..1 (person (adult))"
             ]

      assert routed[{"person (adult)", "retention_days"}] == [
               "retention_days (person (adult)) must be a whole number"
             ]

      assert unclaimed == []
    end

    test "the record-covers-track message routes a parenthesized label to the row" do
      message =
        "camera cam1: track.person (adult) (0.6) must be <= the effective record threshold " <>
          "(0.5) — with no record: block video falls back to min_score, so a clip could " <>
          "exist with no track row. Give person (adult) a record: rule, or lower " <>
          "track.person (adult)"

      {routed, []} = Settings.field_errors([message], "cam1", ["person (adult)"])

      assert [row_message] = routed[{"person (adult)", :row}]
      assert row_message =~ "effective record threshold"
    end

    test "fleet-level and other cameras' errors stay unclaimed" do
      {routed, unclaimed} =
        Settings.field_errors(
          [
            "duplicate camera id: cam1",
            "camera cam2: rtsp_url is required",
            "camera cam1: zones must be a list"
          ],
          "cam1",
          []
        )

      assert routed == %{}

      assert unclaimed == [
               "zones must be a list",
               "camera cam2: rtsp_url is required",
               "duplicate camera id: cam1"
             ]
    end

    # A label may itself contain ", " (a detection class literally named
    # "a, b"), so splitting the loader's joined list on ", " would invent a
    # key no row owns and the message would vanish under a nil candidate.
    # Routing instead walks the known row labels, longest first.
    test "a joined label list routes to every row it names, even one whose own label holds \", \"" do
      raw = "min_score values must be 0..1 (a, b, c)"
      message = "camera cam1: #{raw}"

      {routed, unclaimed} = Settings.field_errors([message], "cam1", ["a, b", "c"])

      assert routed[{"a, b", "min_score"}] == [raw]
      assert routed[{"c", "min_score"}] == [raw]
      assert unclaimed == []
    end

    test "a joined label the known rows cannot fully account for stays unclaimed" do
      raw = "min_score values must be 0..1 (a, b, d)"
      message = "camera cam1: #{raw}"

      {routed, unclaimed} = Settings.field_errors([message], "cam1", ["a, b", "c"])

      assert routed == %{}
      assert unclaimed == [raw]
    end
  end

  describe "excluded?/3" do
    test "a blank cell is excluded only when the column has rules and no default" do
      rows = [
        %{"label" => "default", "track" => "", "record" => "0.70"},
        %{"label" => "person", "track" => "0.60", "record" => ""},
        %{"label" => "car", "track" => "", "record" => ""}
      ]

      car = Enum.at(rows, 2)

      assert Settings.excluded?(rows, car, "track")
      # The default row carries a record rule, so a blank record inherits it.
      refute Settings.excluded?(rows, car, "record")
      assert Settings.inherited(rows, car, "record") == "0.70"
    end
  end

  describe "restart_fields/0" do
    test "covers the config server's own set and the fields it cannot see" do
      fields = Settings.restart_fields()

      assert "rtsp_url" in fields
      assert "password" in fields
      assert Settings.restart?("tracker")
      refute Settings.restart?("post_window_seconds")
    end
  end

  defp params_with_rows(rows) do
    rows = Enum.map(rows, &Map.merge(Settings.blank_row(""), &1))

    nil
    |> Settings.to_params()
    |> Map.put("labels", Settings.index_rows(rows))
  end
end
