defmodule CairnWeb.EventsLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cairn.Events

  defp seed(camera_id, minutes_ago, labels) do
    id = Ecto.UUID.generate()
    started = DateTime.add(DateTime.utc_now(), -minutes_ago * 60)

    event = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: started,
      ended_at: DateTime.add(started, 30),
      status: :finalized,
      max_scores: Map.new(labels, &{&1, 0.8})
    }

    {:ok, _} = Events.create_active(event, "/tmp/#{id}.mp4")
    {:ok, row} = Events.finalize(%{event | status: :finalized}, 100)
    row
  end

  defp insert_active(camera_id, labels) do
    id = Ecto.UUID.generate()

    ev = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: DateTime.utc_now(),
      status: :active,
      labels: [],
      max_scores: Map.new(labels, &{&1, 0.8})
    }

    {:ok, _} = Events.create_active(ev, "/tmp/#{id}.mp4")
    ev
  end

  # What `Cairn.PresenceRecorder` writes: one row per camera, entries and
  # trigger with no `object_id` (there is no tracker to mint one), and no track
  # rows anywhere.
  defp insert_presence_born(camera_id, labels) do
    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    ev = %Cairn.Event{
      id: id,
      camera_id: camera_id,
      started_at: now,
      status: :active,
      labels: for(l <- labels, do: %{t: 0.0, label: l, score: 0.8, object_id: nil}),
      max_scores: Map.new(labels, &{&1, 0.8}),
      max_score: 0.8,
      trigger: %{
        t: 1.2,
        label: hd(labels),
        score: 0.8,
        bbox: [0.1, 0.2, 0.3, 0.4],
        object_id: nil
      }
    }

    {:ok, _} = Events.create_active(ev, "/tmp/#{id}.mp4")
    ev
  end

  test "a new event appears live on the latest view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")
    ev = insert_active("cam_a", ["person"])

    Cairn.Event.broadcast(:event_started, ev)

    assert render(view) =~ ev.id
  end

  # D-E1's whole point: this page renders the *persisted* row it re-fetches by
  # id, never the broadcast struct, so a presence-born event is only visible
  # here because the lane writes a real row.
  test "a presence-born event renders from its re-fetched row", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")
    ev = insert_presence_born("cam_a", ["person", "car"])

    Cairn.Event.broadcast(:event_started, ev)

    html = render(view)
    assert html =~ ev.id
    # chips come from the row's "max_scores" map; the broadcast's `labels` is a
    # list of entries and renders nothing here
    assert html =~ "person"
    assert html =~ "car"
    assert html =~ "0.80"
  end

  test "a presence-born event that is still recording is listed while it records",
       %{conn: conn} do
    # The extractor inserts the `active` row at open, so a segment is on the page
    # from its first broadcast — it does not wait for the close to become real.
    ev = insert_presence_born("cam_a", ["person"])

    {:ok, _view, html} = live(conn, "/events")
    assert html =~ ev.id
  end

  test "an event whose :event_started outran its row insert lands on the next broadcast",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")

    id = Ecto.UUID.generate()

    ev = %Cairn.Event{
      id: id,
      camera_id: "cam_a",
      started_at: DateTime.utc_now(),
      status: :active,
      max_scores: %{"person" => 0.8}
    }

    # The real ordering on both lanes: the broadcast leaves the owner as soon as
    # the extractor process exists, and the row is written by that extractor's
    # own handle_continue — so the lookup here finds nothing.
    Cairn.Event.broadcast(:event_started, ev)
    refute render(view) =~ id

    {:ok, _} = Events.create_active(ev, "/tmp/#{id}.mp4")
    Cairn.Event.broadcast(:event_updated, ev)

    assert render(view) =~ id
  end

  test "a live event that fails the active filter is not inserted", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events?camera=cam_a")
    ev = insert_active("cam_b", ["car"])

    Cairn.Event.broadcast(:event_started, ev)

    refute render(view) =~ ev.id
  end

  test "a repeated broadcast does not duplicate the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")
    ev = insert_active("cam_a", ["person"])

    Cairn.Event.broadcast(:event_started, ev)
    Cairn.Event.broadcast(:event_started, ev)

    # the stream row's dom id must appear exactly once
    dom_id = "events-#{ev.id}"
    count = render(view) |> String.split(dom_id) |> length() |> Kernel.-(1)
    assert count == 1
  end

  test "live inserts are capped to the page size", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")
    # one more than a page (25); the oldest live row must fall out of the stream
    evs = for _ <- 1..26, do: insert_active("cam_a", ["person"])
    for ev <- evs, do: Cairn.Event.broadcast(:event_started, ev)

    html = render(view)
    refute html =~ "events-#{List.first(evs).id}"
    assert html =~ "events-#{List.last(evs).id}"
  end

  test "lists events and filters by camera", %{conn: conn} do
    a = seed("cam_a", 10, ["person"])
    b = seed("cam_b", 5, ["car"])

    {:ok, view, html} = live(conn, "/events")
    assert html =~ a.id
    assert html =~ b.id

    html =
      render_change(view, "filter", %{
        "camera" => "cam_a",
        "label" => "",
        "from" => "",
        "to" => ""
      })

    assert html =~ a.id
    refute html =~ b.id
  end

  test "filters by label via json_extract", %{conn: conn} do
    a = seed("cam_a", 10, ["person"])
    b = seed("cam_a", 5, ["car"])

    {:ok, view, _html} = live(conn, "/events?label=person")
    html = render(view)
    assert html =~ a.id
    refute html =~ b.id
  end

  test "paginates", %{conn: conn} do
    for i <- 1..30, do: seed("cam_a", i, ["person"])

    {:ok, view, html} = live(conn, "/events")
    assert html =~ "Showing 1–25 of 30"

    html = render_click(view, "page", %{"page" => "2"})
    assert html =~ "Showing 26–30 of 30"
  end

  test "shows empty state", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/events")
    assert html =~ "No events match"
  end

  test "event detail renders clip, timeline and metadata", %{conn: conn} do
    row = seed("cam_a", 10, ["person"])

    {:ok, _view, html} = live(conn, "/events/#{row.id}")
    assert html =~ "/media/events/#{row.id}"
    assert html =~ "labels-timeline"
    assert html =~ row.id
  end

  test "unknown event redirects to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/events"}}} =
             live(conn, "/events/#{Ecto.UUID.generate()}")
  end
end
