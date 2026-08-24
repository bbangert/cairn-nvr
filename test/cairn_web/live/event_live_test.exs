defmodule CairnWeb.EventLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cairn.{DataDir, Event, Events, Tracks}

  defp seed(status, max_scores \\ %{"person" => 0.9}) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()
    clip = Path.join(System.tmp_dir!(), "cairn_ev_#{id}.mp4")
    snap = Path.join(System.tmp_dir!(), "cairn_ev_#{id}.jpg")
    File.write!(clip, "clip")
    File.write!(snap, "snap")

    base = %Event{
      id: id,
      camera_id: "cam_a",
      started_at: now,
      status: :active,
      labels: [],
      max_scores: max_scores,
      max_score: max_scores |> Map.values() |> Enum.max()
    }

    {:ok, _} = Events.create_active(base, clip)

    if status != :active do
      {:ok, _} = Events.finalize(%{base | status: status, ended_at: DateTime.add(now, 30)}, 100)
    end

    {:ok, _} = Events.set_snapshot(id, snap)
    on_exit(fn -> File.rm(DataDir.trackpath_for_clip(clip)) end)
    %{id: id, clip: clip, snap: snap, started_at: now}
  end

  describe "annotation offset" do
    # `cam_dual` carries -400 ms in the fixture config; `cam_a` carries none.
    defp seed_with_entries(camera_id, entries) do
      id = Ecto.UUID.generate()
      now = DateTime.utc_now()
      clip = Path.join(System.tmp_dir!(), "cairn_off_#{id}.mp4")
      File.write!(clip, "clip")

      base = %Event{
        id: id,
        camera_id: camera_id,
        started_at: now,
        status: :active,
        labels: entries,
        max_scores: %{"person" => 0.9},
        max_score: 0.9
      }

      {:ok, _} = Events.create_active(base, clip)

      {:ok, _} =
        Events.finalize(%{base | status: :finalized, ended_at: DateTime.add(now, 30)}, 100)

      # `@sidecar?` gates the overlay wrapper, and the offset attribute rides
      # on it — no sidecar, no element to assert against.
      write_sidecar(clip)

      on_exit(fn ->
        File.rm(clip)
        File.rm(DataDir.trackpath_for_clip(clip))
      end)

      id
    end

    defp entry(t), do: %{t: t, label: "person", score: 0.9, object_id: nil}

    test "a camera with no offset renders the raw times, and says so", %{conn: conn} do
      id = seed_with_entries("cam_a", [entry(3.0)])
      {:ok, view, _html} = live(conn, ~p"/events/#{id}")

      # The attribute is always present: the hook multiplies by it, so its
      # absence and a zero must not be different code paths. Selector-queried,
      # not raw HTML, per the LiveView test rules.
      assert has_element?(view, ~s([data-annotation-offset="0.0"]))
      assert has_element?(view, ~s(button[data-t="3.0"]))
      assert has_element?(view, ~s(button[data-seek="3.0"]))
    end

    test "a camera with an offset shifts marker, seek and tooltip together", %{conn: conn} do
      id = seed_with_entries("cam_dual", [entry(3.0)])
      {:ok, view, _html} = live(conn, ~p"/events/#{id}")

      assert has_element?(view, ~s([data-annotation-offset="-0.4"]))
      assert has_element?(view, ~s(button[data-t="2.6"]))
      assert has_element?(view, ~s(button[data-seek="2.6"]))
      # the tooltip is the same time, so the dot and its label cannot disagree
      assert has_element?(view, ~s(button[title*="person 0.90 at 0:03"]))
      refute has_element?(view, ~s(button[data-t="3.0"]))
    end

    # This timeline's axis is the event, so a shift that would push a marker
    # before its start parks it at the front rather than off the widget.
    test "a shift before the event's start stays signed; only the dot pins to the edge", %{
      conn: conn
    } do
      id = seed_with_entries("cam_dual", [entry(0.1)])
      {:ok, view, _html} = live(conn, ~p"/events/#{id}")

      # The clip's retained pre-roll sits before event zero, and the client
      # maps data-t through preRoll + t — flooring the value here would
      # discard a real position. The dot's visual left does clamp.
      assert has_element?(view, ~s(button[data-t="-0.3"]))
      assert has_element?(view, ~s(button[data-seek="-0.3"]))
      assert has_element?(view, ~s(button[style*="left: 0.0%"]))
    end
  end

  # `data-selected` is a JSON array of the keys the sidecar is keyed by, and
  # HEEx escapes its quotes on the way into the attribute.
  defp selected(keys) do
    ~s(data-selected=") <> String.replace(Jason.encode!(keys), ~s("), "&quot;") <> ~s(")
  end

  # The sidecar is derived from the clip path, so writing one is all it takes
  # for the page to consider the overlay available.
  defp write_sidecar(clip),
    do: File.write!(DataDir.trackpath_for_clip(clip), "not really msgpack")

  defp seed_track(overrides, moments \\ []) do
    started = Map.fetch!(overrides, :started_at)

    attrs =
      Map.merge(
        %{
          id: Cairn.ULID.generate(),
          camera_id: "cam_a",
          label: "person",
          best_score: 0.9312,
          source: :host,
          end_reason: :unseen,
          zones: []
        },
        overrides
      )

    {:ok, _} = Tracks.insert_batch([{attrs, moments}])
    Map.put(attrs, :started_at, started)
  end

  defp moment(kind, at), do: %{at: at, kind: kind, bbox: [1, 2, 3, 4]}

  # A second clip on the same camera, inserted directly: these tests place clip
  # windows to the second around a track, which the capture pipeline's writers
  # do not expose.
  defp clip_row(camera_id, started_at, ended_at) do
    %Cairn.Events.Event{}
    |> Cairn.Events.Event.changeset(%{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: started_at,
      ended_at: ended_at,
      status: :finalized,
      path: "/tmp/cairn_other_#{System.unique_integer([:positive])}.mp4"
    })
    |> Cairn.Repo.insert!()
  end

  test "delete removes the clip, snapshot, and row, then redirects", %{conn: conn} do
    %{id: id, clip: clip, snap: snap} = seed(:finalized)
    {:ok, view, _html} = live(conn, "/events/#{id}")

    assert {:error, {:live_redirect, %{to: "/events"}}} =
             view |> element("button[phx-click='delete']") |> render_click()

    refute File.exists?(clip)
    refute File.exists?(snap)
    assert Events.get(id) == nil
  end

  test "delete works on an active (still-recording) event", %{conn: conn} do
    %{id: id, clip: clip, snap: snap} = seed(:active)
    {:ok, view, _html} = live(conn, "/events/#{id}")

    assert {:error, {:live_redirect, %{to: "/events"}}} =
             view |> element("button[phx-click='delete']") |> render_click()

    refute File.exists?(clip)
    refute File.exists?(snap)
    assert Events.get(id) == nil
  end

  test "the delete confirmation names the track file", %{conn: conn} do
    %{id: id} = seed(:finalized)
    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ "clip, snapshot, track file, and index row"
  end

  test "detail page settles the recording badge after the async finalize", %{conn: conn} do
    %{id: id} = seed(:active)
    {:ok, view, html} = live(conn, "/events/#{id}")
    assert html =~ "Recording"

    # the camera tracker broadcasts :event_ended before the extractor's async
    # finalize writes the DB — the immediate re-fetch still sees an active row
    Event.broadcast(:event_ended, %Event{
      id: id,
      camera_id: "cam_a",
      started_at: DateTime.utc_now(),
      status: :finalized
    })

    assert render(view) =~ "Recording"

    # the finalize lands, then the scheduled refresh (simulated) settles it
    {:ok, _} =
      Events.finalize(
        %Event{
          id: id,
          camera_id: "cam_a",
          started_at: DateTime.utc_now(),
          status: :finalized,
          ended_at: DateTime.utc_now(),
          labels: [],
          max_scores: %{"person" => 0.9}
        },
        100
      )

    send(view.pid, {:refresh_event, id})
    refute render(view) =~ "Recording"
  end

  # -- tracked-objects panel --------------------------------------------------

  test "the panel lists tracks that overlap the clip, not only tracks that ended in it",
       %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)

    # starts inside the clip and runs long past it, and names no event at all —
    # a panel keyed on `tracks.event_id` would miss it, overlap does not
    spanning =
      seed_track(%{
        started_at: DateTime.add(t0, 5),
        ended_at: DateTime.add(t0, 4000),
        event_id: nil,
        label: "car"
      })

    # ends inside the clip
    ended_here =
      seed_track(%{started_at: DateTime.add(t0, -60), ended_at: DateTime.add(t0, 10)})

    # entirely after the clip window
    later = seed_track(%{started_at: DateTime.add(t0, 600), ended_at: DateTime.add(t0, 640)})
    # same window, other camera
    elsewhere =
      seed_track(%{
        camera_id: "cam_b",
        started_at: DateTime.add(t0, 5),
        ended_at: DateTime.add(t0, 10)
      })

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ "Tracked objects"
    assert html =~ ~s(id="track-object-#{spanning.id}")
    assert html =~ ~s(id="track-object-#{ended_here.id}")
    refute html =~ later.id
    refute html =~ elsewhere.id
    # score renders to two decimals, and the count is the panel's own
    assert html =~ "0.93"
    refute html =~ "0.9312"
  end

  test "?track= preselects one object, lights the Tracks nav, and turns the back button around",
       %{conn: conn} do
    %{id: id, clip: clip, started_at: t0} = seed(:finalized)
    write_sidecar(clip)
    a = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})
    b = seed_track(%{started_at: DateTime.add(t0, 2), ended_at: DateTime.add(t0, 11)})

    {:ok, view, html} = live(conn, "/events/#{id}?track=#{a.id}")

    assert html =~ "Back to tracks"
    refute html =~ "Back to events"
    assert has_element?(view, ~s(a.cairn-nav--active[href="/tracks"]))
    refute has_element?(view, ~s(a.cairn-nav--active[href="/events"]))

    # only the named object is selected, and only it is expanded
    assert html =~ selected([a.id])
    refute html =~ selected([b.id])
    assert has_element?(view, ~s(button[phx-value-id="#{a.id}"] span), "expand_less")
    assert has_element?(view, ~s(button[phx-value-id="#{b.id}"] span), "expand_more")

    # without the param the page is an Events page again, with everything shown
    {:ok, plain_view, plain_html} = live(conn, "/events/#{id}")
    assert plain_html =~ "Back to events"
    assert has_element?(plain_view, ~s(a.cairn-nav--active[href="/events"]))
    assert plain_html =~ a.id
    assert plain_html =~ b.id
  end

  test "toggle-track flips the row's selection, its opacity, and the overlay's data-selected",
       %{conn: conn} do
    %{id: id, clip: clip, started_at: t0} = seed(:finalized)
    write_sidecar(clip)
    track = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})

    {:ok, view, html} = live(conn, "/events/#{id}")

    assert html =~ selected([track.id])
    refute html =~ "visibility_off"

    html = view |> element(~s(button[phx-click="toggle-track"])) |> render_click()

    assert html =~ selected([])
    assert html =~ "visibility_off"
    assert html =~ "opacity: 0.55"

    html = view |> element(~s(button[phx-click="toggle-track"])) |> render_click()
    assert html =~ selected([track.id])

    # an id this page never loaded is dropped rather than added to the set
    render_click(view, "toggle-track", %{"id" => "01JNOTATRACKONTHISPAGE0000"})
    assert render(view) =~ selected([track.id])
  end

  test "toggle-moments opens and closes one object's timeline", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)

    track =
      seed_track(
        %{started_at: DateTime.add(t0, 5), ended_at: DateTime.add(t0, 20)},
        [moment(:appeared, DateTime.add(t0, 5))]
      )

    other =
      seed_track(
        %{started_at: DateTime.add(t0, 6), ended_at: DateTime.add(t0, 21), label: "car"},
        [moment(:became_stationary, DateTime.add(t0, 8))]
      )

    button = ~s(button[phx-click="toggle-moments"][phx-value-id="#{track.id}"])

    # arrived without ?track=, so nothing starts expanded and no moment row is
    # in the markup
    {:ok, view, html} = live(conn, "/events/#{id}")
    refute html =~ "trip_origin"
    refute has_element?(view, ~s(#track-moments button[data-t="5"]))
    assert has_element?(view, "#{button} span", "expand_more")

    html = view |> element(button) |> render_click()

    # the event itself put the rows there — a handler that returned the socket
    # untouched leaves this page exactly as it was
    assert html =~ "trip_origin"
    assert has_element?(view, ~s(#track-moments button[data-t="5"]))
    assert has_element?(view, "#{button} span", "expand_less")

    # only the object that was clicked opened
    refute has_element?(view, ~s(#track-moments button[data-t="8"]))
    assert has_element?(view, ~s(button[phx-value-id="#{other.id}"] span), "expand_more")

    # clicking the same button again puts it away
    html = view |> element(button) |> render_click()
    refute html =~ "trip_origin"
    refute has_element?(view, ~s(#track-moments button[data-t="5"]))
    assert has_element?(view, "#{button} span", "expand_more")

    # an id this page never loaded expands nothing
    render_click(view, "toggle-moments", %{"id" => "01JNOTATRACKONTHISPAGE0000"})
    refute render(view) =~ "trip_origin"
  end

  test "the panel caps the objects it lists, and says so", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)

    # 201 tracks overlapping one clip — the shape a day-long event on a busy
    # camera has. The cap is 200, and the panel is not allowed to drop the
    # 201st silently.
    entries =
      for i <- 1..201 do
        {%{
           id: Cairn.ULID.generate(),
           camera_id: "cam_a",
           started_at: DateTime.add(t0, i, :millisecond),
           ended_at: DateTime.add(t0, 10),
           label: "person",
           source: :host,
           end_reason: :unseen,
           zones: []
         }, []}
      end

    {:ok, _} = Tracks.insert_batch(entries)

    {:ok, view, html} = live(conn, "/events/#{id}")

    assert html =~ "Showing the first 200 objects, oldest first"
    # the oldest 200 are the ones kept: the first id in and the 200th are on
    # the page, the 201st is not
    {first, _} = hd(entries)
    {two_hundredth, _} = Enum.at(entries, 199)
    {over_cap, _} = List.last(entries)
    assert html =~ ~s(id="track-object-#{first.id}")
    assert html =~ ~s(id="track-object-#{two_hundredth.id}")
    refute html =~ over_cap.id

    # and the count next to the heading is what is listed, not what exists
    assert has_element?(view, ~s(#tracked-objects span.tnum), "200")
  end

  test "an uncapped panel says nothing about a cap", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)
    seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})

    {:ok, _view, html} = live(conn, "/events/#{id}")

    refute html =~ "Showing the first"
  end

  test "moments render as in-clip seek, cross-clip link, and inert no-clip rows",
       %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)
    other = clip_row("cam_a", DateTime.add(t0, 500), DateTime.add(t0, 560))

    track =
      seed_track(
        %{
          started_at: DateTime.add(t0, 5),
          ended_at: DateTime.add(t0, 520),
          end_reason: :unseen
        },
        [
          # inside this clip
          moment(:appeared, DateTime.add(t0, 5)),
          # in the gap between the two clips
          moment(:became_stationary, DateTime.add(t0, 200))
        ]
      )

    {:ok, view, _html} = live(conn, "/events/#{id}?track=#{track.id}")
    html = render(view)

    # 1. in this clip — a data-t button inside the hooked region
    assert html =~ ~s(id="track-moments")
    assert html =~ ~s(phx-hook="TimelineSeek")
    assert has_element?(view, ~s(#track-moments button[data-t="5"]))
    assert html =~ "trip_origin"
    assert html =~ "0:05"

    # 2. in another clip — a navigate link at its offset into that clip, in
    #    link blue with an arrow, and the tooltip naming the camera
    assert html =~ ~s(href="/events/#{other.id}?track=#{track.id}&amp;t=20")
    assert html =~ "arrow_outward"
    assert html =~ "In another clip — open cam_a at 0:20"
    assert html =~ "flag"

    # 3. recorded by nothing — inert, no button, no link, suffixed "no clip"
    assert html =~ "· for 5m 20s · no clip"
    refute has_element?(view, ~s(#track-moments button[data-t="200"]))
  end

  test "a closed stationary run collapses into one seek row", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)

    track =
      seed_track(
        %{started_at: t0, ended_at: DateTime.add(t0, 25)},
        [
          moment(:appeared, t0),
          moment(:became_stationary, DateTime.add(t0, 4)),
          moment(:started_moving, DateTime.add(t0, 18))
        ]
      )

    {:ok, view, html} = live(conn, "/events/#{id}?track=#{track.id}")

    assert html =~ "motion_photos_paused"
    assert html =~ "· for 14s"
    # the closing moment is consumed by the collapse, not listed
    refute html =~ "started moving"
    refute html =~ "north_east"
    # the row seeks the run's start, measured from the clip's start
    assert has_element?(view, ~s(#track-moments button[data-t="4"]))
  end

  test "a track with no moments says so", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)

    track =
      seed_track(%{
        started_at: DateTime.add(t0, 1),
        ended_at: nil,
        end_reason: nil
      })

    {:ok, _view, html} = live(conn, "/events/#{id}?track=#{track.id}")

    assert html =~ "No moments — it appeared and was evicted."
  end

  test "an event with no tracks shows the panel's empty state", %{conn: conn} do
    %{id: id} = seed(:finalized)

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ "No tracked objects"

    # the tier-1 lane is the third reason and the only one that is not a
    # historical accident — `Cairn.PresenceRecorder`'s clips never have tracks
    assert html =~
             "Its camera runs no tracker, this clip predates tracking, " <>
               "or its tracks have aged out."

    refute html =~ ~s(id="track-moments")
  end

  test "without a sidecar the toggles are disabled, the panel says so, and no overlay renders",
       %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)
    seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})

    {:ok, view, html} = live(conn, "/events/#{id}")

    # disabled, not hidden: the panel and its moments are still there
    assert html =~ "Tracked objects"
    assert has_element?(view, ~s(button[phx-click="toggle-track"][disabled]))
    assert html =~ "opacity: 0.4"

    # the copy is verbatim from the handoff; HEEx escapes its apostrophes
    assert html =~
             "We couldn&#39;t find this clip&#39;s track file, so there are no boxes to draw. " <>
               "Moments still seek."

    refute html =~ ~s(id="track-overlay-wrap")
  end

  test "with a sidecar the overlay hook renders over the video and carries its contract",
       %{conn: conn} do
    %{id: id, clip: clip, started_at: t0} = seed(:finalized)
    write_sidecar(clip)
    track = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})

    {:ok, view, html} = live(conn, "/events/#{id}")

    assert html =~ ~s(id="track-overlay-wrap")
    assert html =~ ~s(phx-hook="TrackOverlay")
    assert html =~ ~s(data-video-id="event-clip")
    assert html =~ ~s(data-sidecar-url="/media/events/#{id}/tracks")
    assert html =~ ~s(id="track-overlay")
    assert html =~ ~s(phx-update="ignore")
    # the hook gets each object's colour with its id — the canvas has no cascade
    assert html =~ ~s(#{track.id}&quot;:{&quot;color&quot;:&quot;#5fc0f5&quot;)
    refute has_element?(view, ~s(button[phx-click="toggle-track"][disabled]))
    refute html =~ "We couldn&#39;t find this clip&#39;s track file"
  end

  # The presence lane (`Cairn.PresenceRecorder`) writes a label-keyed sidecar
  # and no track rows at all, so the panel is empty and the overlay has nothing
  # to look its paths up by. The palette it needs is the event's own labels.
  test "an event with a sidecar but no tracks hands the overlay a label-keyed palette",
       %{conn: conn} do
    %{id: id, clip: clip} = seed(:finalized)
    write_sidecar(clip)

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ selected(["person"])
    assert html =~ ~s(person&quot;:{&quot;color&quot;:&quot;#5fc0f5&quot;)
  end

  test "a presence-born clip selects every label the event recorded, and only those",
       %{conn: conn} do
    %{id: id, clip: clip} = seed(:finalized, %{"person" => 0.9, "car" => 0.72})
    write_sidecar(clip)

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ selected(["car", "person"])
    # the palette is keyed the way the sidecar's header says its tracks are, and
    # carries the score too — the canvas chip has no panel row to read it off
    assert html =~ ~s(car&quot;:{&quot;color&quot;:&quot;#5ed08a&quot;)
    assert html =~ ~s(person&quot;:{&quot;color&quot;:&quot;#5fc0f5&quot;)
    assert html =~ ~s(&quot;score&quot;:&quot;0.72&quot;)
  end

  test "a label with a comma in it stays one key in the selection", %{conn: conn} do
    # Nothing in the detection protocol forbids it, and the joined-string
    # encoding this replaced would have split it into two keys matching no path.
    %{id: id, clip: clip} = seed(:finalized, %{"person, walking" => 0.9})
    write_sidecar(clip)

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ selected(["person, walking"])
  end

  test "an object's colour varies by its ordinal among same-label tracks", %{conn: conn} do
    %{id: id, clip: clip, started_at: t0} = seed(:finalized)
    write_sidecar(clip)
    first = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})
    # a different label sits between the two people, so a plain global
    # `with_index` would push the second person to step 2 (#9fd8f8) and a
    # per-label count keeps it at step 1 — the two are distinguishable here
    car =
      seed_track(%{started_at: DateTime.add(t0, 2), ended_at: DateTime.add(t0, 11), label: "car"})

    second = seed_track(%{started_at: DateTime.add(t0, 3), ended_at: DateTime.add(t0, 12)})

    {:ok, _view, html} = live(conn, "/events/#{id}")

    # the earlier person takes step 0, the next step 1
    assert html =~ ~s(#{first.id}&quot;:{&quot;color&quot;:&quot;#5fc0f5&quot;)
    assert html =~ ~s(#{second.id}&quot;:{&quot;color&quot;:&quot;#29ade9&quot;)
    refute html =~ ~s(#{second.id}&quot;:{&quot;color&quot;:&quot;#9fd8f8&quot;)
    # the car is the first of its own label, not the second of the panel
    assert html =~ ~s(#{car.id}&quot;:{&quot;color&quot;:&quot;#5ed08a&quot;)
    assert html =~ "background: #5fc0f5"
    assert html =~ "background: #29ade9"
  end

  test "?t= is handed to the seek hook as event-relative seconds", %{conn: conn} do
    %{id: id} = seed(:finalized)

    {:ok, _view, html} = live(conn, "/events/#{id}?track=nothing&t=20")
    assert html =~ ~s(data-initial-t="20")

    # a non-numeric ?t= is not a seek
    {:ok, _view, html} = live(conn, "/events/#{id}?t=soon")
    refute html =~ "data-initial-t"

    # nor is a negative one: the guard is `seconds >= 0`, and without it this
    # would hand the player a seek before the clip began
    {:ok, _view, html} = live(conn, "/events/#{id}?t=-5")
    refute html =~ "data-initial-t"

    # nor a number with a tail — `Integer.parse/1` splits "20abc" and the
    # match on the empty remainder is what rejects it
    {:ok, _view, html} = live(conn, "/events/#{id}?t=20abc")
    refute html =~ "data-initial-t"
  end

  test "the disconnected render skips the panel and passes no verdict on it", %{conn: conn} do
    %{id: id, started_at: t0} = seed(:finalized)
    track = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})

    html = conn |> get(~p"/events/#{id}") |> html_response(200)

    # the event row is read on both mounts — it decides the 404 — so the page
    # frame is there
    assert html =~ "Tracked objects"
    assert html =~ id
    # but nothing that cost a track query or a File.stat
    refute html =~ track.id
    # and neither notice fires: both would be statements about a panel this
    # render never loaded
    refute html =~ "No tracked objects"
    refute html =~ "We couldn&#39;t find this clip&#39;s track file"
  end

  test "a clip still recording lists the objects tracked so far", %{conn: conn} do
    # What the "still recording" note promises: a track earns its row while it
    # is running, so the panel of an open clip is not empty by construction.
    %{id: id, started_at: t0} = seed(:active)

    # started with the clip and still running: the panel's window for an open
    # clip ends at `now`, so a track cannot be seeded into its future
    live_track =
      seed_track(%{started_at: t0, ended_at: nil, end_reason: nil}, [moment(:appeared, t0)])

    {:ok, _view, html} = live(conn, "/events/#{id}")

    assert html =~ ~s(id="track-object-#{live_track.id}")
    refute html =~ "No tracked objects"
    assert html =~ "Still recording — objects tracked so far are listed."
  end

  test "the panel picks up tracks written by the async finalize", %{conn: conn} do
    %{id: id, clip: clip, started_at: t0} = seed(:active)
    {:ok, view, html} = live(conn, "/events/#{id}")

    assert html =~ "Still recording — objects tracked so far are listed."
    assert html =~ "No tracked objects"

    track = seed_track(%{started_at: DateTime.add(t0, 1), ended_at: DateTime.add(t0, 10)})
    write_sidecar(clip)

    {:ok, _} =
      Events.finalize(
        %Event{
          id: id,
          camera_id: "cam_a",
          started_at: t0,
          status: :finalized,
          ended_at: DateTime.add(t0, 30),
          labels: [],
          max_scores: %{"person" => 0.9}
        },
        100
      )

    send(view.pid, {:refresh_event, id})
    html = render(view)

    assert html =~ ~s(id="track-object-#{track.id}")
    assert html =~ selected([track.id])
    refute html =~ "Still recording — objects tracked so far are listed."
  end
end
