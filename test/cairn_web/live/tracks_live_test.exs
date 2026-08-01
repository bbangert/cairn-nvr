defmodule CairnWeb.TracksLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cairn.Tracks

  @filters %{"camera" => "", "label" => "", "zone" => "", "from" => "", "to" => ""}

  defp seed_track(overrides, moments \\ []) do
    started = Map.get(overrides, :started_at, DateTime.utc_now())

    attrs =
      Map.merge(
        %{
          id: Cairn.ULID.generate(),
          camera_id: "cam_a",
          started_at: started,
          ended_at: DateTime.add(started, 30),
          label: "person",
          best_score: 0.9312,
          source: :host,
          end_reason: :unseen,
          zones: []
        },
        overrides
      )

    {:ok, _} = Tracks.insert_batch([{attrs, moments}])
    attrs
  end

  defp moment(kind, at), do: %{at: at, kind: kind, bbox: [1, 2, 3, 4]}

  # Clip rows inserted directly: these tests place event windows to the second
  # around a track, which the capture pipeline's writers do not expose.
  defp clip(camera_id, started_at, ended_at) do
    %Cairn.Events.Event{}
    |> Cairn.Events.Event.changeset(%{
      id: Ecto.UUID.generate(),
      camera_id: camera_id,
      started_at: started_at,
      ended_at: ended_at,
      status: if(ended_at, do: :finalized, else: :active),
      path: "/tmp/#{System.unique_integer([:positive])}.mp4"
    })
    |> Cairn.Repo.insert!()
  end

  test "renders a track row with its label, score, camera, time and zones", %{conn: conn} do
    track = seed_track(%{camera_id: "cam_front", label: "car", zones: ["driveway"]})

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ ~s(id="tracks-list")
    assert html =~ ~s(id="track-#{track.id}")
    assert html =~ "cam_front"
    assert html =~ "car"
    # best_score is rendered to two decimals, not raw
    assert html =~ "0.93"
    refute html =~ "0.9312"
    assert html =~ "driveway"
    assert html =~ "30s"
    assert html =~ "1 track"
  end

  test "a track with no label or score reads as unknown with an em dash", %{conn: conn} do
    seed_track(%{label: nil, best_score: nil, zones: []})

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ "unknown"
    # score and zones both fall back to the em dash
    assert html =~ "—"
  end

  test "zone chips cap at two and collapse the rest", %{conn: conn} do
    track = seed_track(%{zones: ["lawn", "patio", "gate", "walkway"]})

    {:ok, view, html} = live(conn, "/tracks")

    # Scoped to the row's summary, because every zone on record is also an
    # <option> in the filter above it: counting occurrences in the page would
    # let the option stand in for the chip, and would move under any added
    # title= or aria-label.
    assert has_element?(view, ~s(#track-#{track.id} summary span), "lawn")
    assert has_element?(view, ~s(#track-#{track.id} summary span), "patio")
    refute has_element?(view, ~s(#track-#{track.id} summary span), "gate")
    refute has_element?(view, ~s(#track-#{track.id} summary span), "walkway")
    assert has_element?(view, ~s(#track-#{track.id} summary span), "+2")

    # the collapsed two are still filter options — chipped and known are
    # different things
    assert html =~ ~s(<option value="gate">)
    assert html =~ ~s(<option value="walkway">)
  end

  test "filters by camera", %{conn: conn} do
    a = seed_track(%{camera_id: "cam_a"})
    b = seed_track(%{camera_id: "cam_b"})

    {:ok, view, html} = live(conn, "/tracks")
    assert html =~ a.id
    assert html =~ b.id

    html = render_change(view, "filter", %{@filters | "camera" => "cam_a"})
    assert html =~ a.id
    refute html =~ b.id
  end

  test "filters by label", %{conn: conn} do
    person = seed_track(%{label: "person"})
    car = seed_track(%{label: "car"})

    {:ok, view, _html} = live(conn, "/tracks")

    html = render_change(view, "filter", %{@filters | "label" => "car"})
    assert html =~ car.id
    refute html =~ person.id
  end

  test "filters by zone, end to end through json_each", %{conn: conn} do
    driveway = seed_track(%{zones: ["driveway", "street"]})
    porch = seed_track(%{zones: ["porch"]})
    zoneless = seed_track(%{zones: []})

    {:ok, view, html} = live(conn, "/tracks")
    # the option comes from the distinct zones actually on record
    assert html =~ ~s(<option value="driveway")

    html = render_change(view, "filter", %{@filters | "zone" => "driveway"})
    assert html =~ driveway.id
    refute html =~ porch.id
    refute html =~ zoneless.id
    assert html =~ "1 track match"
  end

  test "filters by date range", %{conn: conn} do
    now = DateTime.utc_now()
    old = seed_track(%{started_at: DateTime.add(now, -10 * 86_400)})
    recent = seed_track(%{started_at: now})

    {:ok, view, _html} = live(conn, "/tracks")

    from = now |> DateTime.add(-86_400) |> DateTime.to_date() |> Date.to_iso8601()
    html = render_change(view, "filter", %{@filters | "from" => from})

    assert html =~ recent.id
    refute html =~ old.id
  end

  test "filters restore from the URL, so back-nav preserves them", %{conn: conn} do
    a = seed_track(%{camera_id: "cam_a"})
    b = seed_track(%{camera_id: "cam_b"})

    {:ok, _view, html} = live(conn, "/tracks?camera=cam_b")

    assert html =~ b.id
    refute html =~ a.id
    assert html =~ ~s(<option value="cam_b" selected)
  end

  test "clear-filters empties the form, the URL and the filtered-out rows", %{conn: conn} do
    kept = seed_track(%{camera_id: "cam_a", zones: ["lawn"]})
    filtered_out = seed_track(%{camera_id: "cam_b", zones: []})

    {:ok, view, html} = live(conn, "/tracks?camera=cam_a&zone=lawn")

    assert html =~ kept.id
    refute html =~ filtered_out.id
    assert html =~ "1 track match"

    html = view |> element(~s(button[phx-click="clear-filters"])) |> render_click()

    # the row the filters were hiding is back, and the count stops saying
    # "match" — a handler that returned the socket untouched fails here
    assert html =~ filtered_out.id
    assert html =~ kept.id
    assert html =~ "2 tracks"
    refute html =~ "tracks match"

    # the form no longer holds either filter
    refute html =~ ~s(<option value="cam_a" selected)
    refute html =~ ~s(<option value="lawn" selected)

    # and the browser's URL lost them too, so a reload or a back-nav does not
    # restore what the button just cleared
    assert_patch(view, "/tracks")

    # with nothing left to clear, the button that did it is gone
    refute has_element?(view, ~s(button[phx-click="clear-filters"]))
  end

  test "paginates", %{conn: conn} do
    now = DateTime.utc_now()
    for i <- 1..30, do: seed_track(%{started_at: DateTime.add(now, -i * 60)})

    {:ok, view, html} = live(conn, "/tracks")
    assert html =~ "Showing 1–25 of 30"

    html = render_click(view, "page", %{"page" => "2"})
    assert html =~ "Showing 26–30 of 30"
  end

  test "a page past the end shows an empty range, not an inverted one", %{conn: conn} do
    seed_track(%{})
    seed_track(%{})

    {:ok, _view, html} = live(conn, "/tracks?page=9")

    # 2 rows, page 9: the page is empty but total is not — the range must
    # read as empty rather than "201–200 of 2"-style nonsense
    assert html =~ "Showing 0–0 of 2"
  end

  test "an absurd ?page= is clamped, not turned into the offset it asks for", %{conn: conn} do
    seed_track(%{})

    {:ok, view, _html} = live(conn, "/tracks?page=999999999")

    # the page number is pinned at the cap, so the pagination controls step
    # from there and SQLite is never asked to walk a billion rows in
    assert has_element?(view, ~s(button[phx-value-page="9999"]))
    refute has_element?(view, ~s(button[phx-value-page="999999998"]))
  end

  test "shows the empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ "No tracks match"
    assert html =~ ">route<"
  end

  test "a linked row points at the first overlapping clip and carries ?track=", %{conn: conn} do
    t0 = DateTime.utc_now()

    track =
      seed_track(%{
        camera_id: "cam_a",
        started_at: DateTime.add(t0, -300),
        ended_at: DateTime.add(t0, -60)
      })

    # inserted late-clip-first, so the right answer is not also the insertion
    # order (the index on `events(camera_id, started_at)` sorts these rows
    # regardless, so what this catches is a reversed order_by, not a missing one)
    second = clip("cam_a", DateTime.add(t0, -150), DateTime.add(t0, -30))
    first = clip("cam_a", DateTime.add(t0, -600), DateTime.add(t0, -200))

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ ~s(href="/events/#{first.id}?track=#{track.id}")
    # the second clip overlaps too — the link must be the earliest, not merely
    # any overlapping clip
    refute html =~ second.id
    assert DateTime.compare(second.started_at, track.ended_at) == :lt

    # linked rows navigate; they do not carry the disclosure glyph
    assert html =~ "chevron_right"
    refute html =~ "expand_more"
    refute html =~ "no clip"
  end

  test "a row whose clips are all gone renders no link, but keeps its moments", %{conn: conn} do
    t0 = DateTime.utc_now()

    track =
      seed_track(
        %{
          camera_id: "cam_a",
          started_at: DateTime.add(t0, -300),
          ended_at: DateTime.add(t0, -60),
          # the clip this track was recorded into has since been pruned
          event_id: "evt_pruned",
          end_reason: :evicted
        },
        [moment(:appeared, DateTime.add(t0, -300))]
      )

    # a surviving clip on the same camera, but outside the track's window
    clip("cam_a", DateTime.add(t0, -30), t0)

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ ~s(id="track-#{track.id}")
    refute html =~ "href=\"/events/"
    assert html =~ "expand_more"
    assert html =~ "no clip"
    assert html =~ "clip expired — moments only"
    # the moments are in the markup even though there is nowhere to navigate
    assert html =~ "trip_origin"
    assert html =~ "appeared"
    # end reason is not on the row surface; it is the muted suffix on the
    # "ended" moment, with its plain-language gloss as the tooltip
    assert html =~ "· evicted"
    assert html =~ ~s(title="Dropped to cap memory use")
    assert html =~ "flag"
  end

  test "a track that never named an event says so in the expansion", %{conn: conn} do
    seed_track(%{event_id: nil})

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ "never recorded — moments only"
    refute html =~ "clip expired — moments only"
  end

  test "a live row shows elapsed time so far and a pulsing badge", %{conn: conn} do
    now = DateTime.utc_now()
    started = DateTime.add(now, -(2 * 3600 + 90))

    seed_track(
      %{started_at: started, ended_at: nil, end_reason: nil},
      [
        moment(:appeared, started),
        moment(:became_stationary, DateTime.add(now, -3630))
      ]
    )

    {:ok, _view, html} = live(conn, "/tracks")

    # elapsed-so-far in the hours form, not "—"
    assert html =~ "2h 1m"
    assert html =~ ">live"
    assert html =~ "cairn-pulse"
    # an unclosed stationary run on a live track reads as ongoing
    assert html =~ "· ongoing — 1h 0m so far"
    # a live track has not ended, so there is no "ended" moment
    refute html =~ ">ended<"
    # nor either unlinked-row verdict: both are statements about a whole life,
    # and this object may still earn a clip before it leaves
    refute html =~ "never recorded — moments only"
    refute html =~ "clip expired — moments only"
    refute html =~ "no clip"
  end

  test "a closed stationary run collapses into one row in the 'for' form", %{conn: conn} do
    t0 = DateTime.add(DateTime.utc_now(), -9000)

    seed_track(
      %{started_at: t0, ended_at: DateTime.add(t0, 8200), end_reason: :unseen},
      [
        moment(:appeared, t0),
        moment(:became_stationary, DateTime.add(t0, 60)),
        moment(:started_moving, DateTime.add(t0, 60 + 8040))
      ]
    )

    {:ok, view, html} = live(conn, "/tracks")

    assert html =~ "motion_photos_paused"
    assert html =~ "· for 2h 14m"
    # the run's closing moment is consumed by the collapse, not listed
    refute html =~ "started moving"
    refute html =~ "north_east"
    # the clock is the run's start offset, so the row seeks where it began
    assert html =~ "1:00"
    assert html =~ "· unseen"
    assert has_element?(view, ~s(span[title="Left view and wasn't seen again"]))
  end

  test "a bare started_moving with no run before it renders on its own", %{conn: conn} do
    t0 = DateTime.add(DateTime.utc_now(), -600)

    seed_track(
      %{started_at: t0, ended_at: DateTime.add(t0, 120)},
      [moment(:appeared, t0), moment(:started_moving, DateTime.add(t0, 65))]
    )

    {:ok, _view, html} = live(conn, "/tracks")

    assert html =~ "north_east"
    assert html =~ "started moving"
    assert html =~ "1:05"
  end

  test "the disconnected render takes no query and claims no count", %{conn: conn} do
    track = seed_track(%{})

    # The static frame the socket replaces milliseconds later. It costs the
    # filter options and the list query if it is allowed to, and it is not.
    html = conn |> get(~p"/tracks") |> html_response(200)

    assert html =~ ~s(id="track-filters")
    refute html =~ track.id
    # and it passes no verdict it did not earn: an ungated empty state would
    # tell the reader there are no tracks before anything counted them
    refute html =~ "No tracks match"
    refute html =~ "1 track"
  end

  test "the Tracks nav item is the active one", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/tracks")

    assert has_element?(view, ~s(a.cairn-nav--active[href="/tracks"]))
    # exactly one item is lit, so this is not merely "the class exists somewhere"
    refute has_element?(view, ~s(a.cairn-nav--active[href="/events"]))
    refute has_element?(view, ~s(a.cairn-nav--active[href="/config"]))
  end
end
