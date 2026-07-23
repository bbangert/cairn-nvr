defmodule CairnWeb.EventLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cairn.{Event, Events}

  defp seed(status) do
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
      max_scores: %{"person" => 0.9},
      max_score: 0.9
    }

    {:ok, _} = Events.create_active(base, clip)

    if status != :active do
      {:ok, _} = Events.finalize(%{base | status: status, ended_at: DateTime.add(now, 30)}, 100)
    end

    {:ok, _} = Events.set_snapshot(id, snap)
    %{id: id, clip: clip, snap: snap}
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

  test "detail page settles the recording badge after the async finalize", %{conn: conn} do
    %{id: id} = seed(:active)
    {:ok, view, html} = live(conn, "/events/#{id}")
    assert html =~ "Recording"

    # the aggregator broadcasts :event_ended before the extractor's async
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
end
