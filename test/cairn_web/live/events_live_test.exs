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

  test "a new event appears live on the latest view", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/events")
    ev = insert_active("cam_a", ["person"])

    Cairn.Event.broadcast(:event_started, ev)

    assert render(view) =~ ev.id
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
