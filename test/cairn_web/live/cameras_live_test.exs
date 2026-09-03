defmodule CairnWeb.CamerasLiveTest do
  # async: false — a private Config.Server the LiveView reads through app env,
  # and the shared sandbox the LiveView process needs to see these rows.
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Cairn.Cameras
  alias Cairn.Cameras.Camera
  alias Cairn.Cameras.Setting
  alias Cairn.Config
  alias Cairn.ConfigSource
  alias Cairn.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "cairn_cams_live_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    path = Path.join(dir, "config.yml")
    File.write!(path, "data_dir: #{dir}\n")

    # The marker keeps the loader from importing the YAML's (absent) cameras
    # and warning about drift; the rows under test are the whole fleet.
    Repo.insert!(
      Setting.changeset(%Setting{}, %{
        key: "yaml_import",
        value: %{
          "path" => path,
          "sha256" => String.duplicate("0", 64),
          "imported_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      })
    )

    server =
      start_supervised!(
        {Config.Server,
         path: path,
         name: nil,
         source: {ConfigSource, :load},
         apply_diff: fn _diff, _config -> :ok end,
         apply_native: fn _config -> :ok end},
        id: :cameras_live_server
      )

    # D-P7: the LiveView addresses the server through `Cairn.Cameras.server/0`,
    # which reads this env — the test singleton keeps the YAML file source.
    Application.put_env(:cairn, :config_server, server)
    on_exit(fn -> Application.delete_env(:cairn, :config_server) end)

    %{dir: dir, server: server}
  end

  defp create!(id, settings \\ %{"rtsp_url" => "rtsp://h/1"}, attrs \\ %{}) do
    {:ok, _diff, _warnings} =
      Cameras.create(Map.merge(%{"id" => id, "settings" => settings}, attrs))
  end

  test "lists rows with their loaded state, zones and links", %{conn: conn} do
    create!("cam1", %{"rtsp_url" => "rtsp://h/1"}, %{
      "zones" => [
        %{"id" => "yard", "name" => "Yard", "points" => [[0.1, 0.1], [0.9, 0.1], [0.9, 0.9]]}
      ]
    })

    {:ok, _view, html} = live(conn, "/cameras")

    assert html =~ ~s(id="cameras-list")
    assert html =~ ~s(id="camera-row-cam1")
    assert html =~ ~s(data-loaded="loaded")
    assert html =~ ~s(data-zones="1")
    assert html =~ "1 zone"
    assert html =~ "no detection"
    assert html =~ ~s(href="/cameras/cam1/edit")
    # Phase 4 adds the zones route; until then the button is disabled, not a 404.
    refute html =~ "/cameras/cam1/zones"
    assert html =~ ~r/<button[^>]*disabled[^>]*>\s*Zones/
    assert html =~ ~s(id="cameras-add")
  end

  test "renders the empty state when there are no rows", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/cameras")

    assert html =~ ~s(id="cameras-empty")
    assert html =~ "No cameras yet"
    refute html =~ ~s(id="cameras-list")
  end

  test "a disabled row reads as disabled with its switch off", %{conn: conn} do
    create!("cam1")
    {:ok, _diff, _warnings} = Cameras.set_enabled("cam1", false)

    {:ok, _view, html} = live(conn, "/cameras")

    assert html =~ ~s(data-loaded="disabled")
    # A disabled camera has no runtime to report, so no badge rather than "Unknown".
    refute html =~ ~s(id="camera-status-)
    assert html =~ ~s(aria-checked="false")
  end

  test "a skipped row shows the loader's errors and no status badge", %{conn: conn, server: srv} do
    create!("cam1")

    # Behind the context's back on purpose: a row only becomes skipped when the
    # loader refuses what a validated save would never have written.
    "cam1" |> Cameras.get() |> Camera.update_changeset(%{settings: %{}}) |> Repo.update!()
    {:ok, _diff, _warnings} = Config.Server.reload(srv)

    {:ok, _view, html} = live(conn, "/cameras")

    assert html =~ ~s(data-loaded="skipped")
    assert html =~ "rtsp_url is required"
    refute html =~ ~s(id="camera-status-cam1")
  end

  test "the enable toggle disables and re-enables the camera", %{conn: conn} do
    create!("cam1")

    {:ok, view, _html} = live(conn, "/cameras")

    render_click(view, "toggle-enabled", %{"id" => "cam1"})
    html = render_async(view)

    assert html =~ ~s(id="save-result")
    assert html =~ ~s(data-ok="true")
    assert html =~ "removed cam1"
    assert html =~ ~s(aria-checked="false")
    refute Cameras.get("cam1").enabled

    render_click(view, "toggle-enabled", %{"id" => "cam1"})
    html = render_async(view)

    assert html =~ "added cam1"
    assert html =~ ~s(aria-checked="true")
    assert Cameras.get("cam1").enabled
  end

  test "delete removes the row", %{conn: conn} do
    create!("cam1")

    {:ok, view, _html} = live(conn, "/cameras")

    render_click(view, "delete", %{"id" => "cam1"})
    html = render_async(view)

    assert html =~ ~s(data-ok="true")
    assert html =~ "removed cam1"
    refute html =~ ~s(id="camera-row-cam1")
    assert Cameras.get("cam1") == nil
  end

  # The deterministic refusal used here is a write failure: the row is deleted
  # behind the view's back, so the toggle's own write cannot find it.
  test "a refused flip renders the error", %{conn: conn} do
    create!("cam1")

    {:ok, view, _html} = live(conn, "/cameras")

    Repo.delete!(Cameras.get("cam1"))

    render_click(view, "toggle-enabled", %{"id" => "cam1"})
    html = render_async(view)

    assert html =~ ~s(data-ok="false")
    assert html =~ "the save could not be written: the camera no longer exists"
    assert html =~ "Your previous config is still active — nothing changed."
  end

  test "a config change from another session brings the new row in", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cameras")

    # The broadcast reaches this process and the view in one send each; the
    # render call queues behind the view's copy, so no polling is needed.
    Cairn.Config.Server.subscribe()
    create!("cam2")
    assert_receive {:config_changed, %{added: ["cam2"]}}

    assert render(view) =~ ~s(id="camera-row-cam2")
  end

  test "a failed load banners its errors and the rows read unloaded", %{conn: conn} = ctx do
    # Inserted behind the context: the reload that would have brought this row
    # into the running config is the one that fails.
    Repo.insert!(
      Camera.changeset(%Camera{}, %{
        id: "cam1",
        position: 0,
        settings: %{"rtsp_url" => "rtsp://h/1"}
      })
    )

    File.write!(Path.join(ctx.dir, "config.yml"), "data_dir: #{ctx.dir}\nretention:\n  days: 0\n")
    {:error, _errors} = Config.Server.reload(ctx.server)

    {:ok, _view, html} = live(conn, "/cameras")

    assert html =~ ~s(id="cameras-load-errors")
    assert html =~ "retention.days must be &gt;= 1"
    assert html =~ ~s(data-loaded="unloaded")
    refute html =~ ~s(id="camera-status-cam1")
  end

  test "editing an unknown camera redirects to the list", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/cameras", flash: flash}}} =
             live(conn, "/cameras/nope/edit")

    assert flash["error"] == "Unknown camera"
  end

  test "the nav marks Cameras active and /config still renders", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/cameras")

    assert view |> element("a.cairn-nav--active") |> render() =~ "Cameras"

    assert {:ok, _config_view, html} = live(conn, "/config")
    assert html =~ "config-globals"
  end

  describe "password field" do
    test "is write-only and survives re-renders", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cameras/new?tab=manual")
      [input] = Regex.scan(~r/<input[^>]*id="camera-password"[^>]*>/, html) |> List.flatten()

      assert input =~ ~s(type="password")
      assert input =~ ~s(autocomplete="new-password")
      # Without this, LiveView's next patch clears the typed password: the
      # input has no value attribute to restore it from (the credential rule).
      assert input =~ ~s(phx-update="ignore")
      refute input =~ "value="
    end
  end

  describe "the camera form" do
    test "the add page renders the form, the tabs and no password value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cameras/new")

      assert html =~ ~s(id="camera-form")
      assert html =~ ~s(data-mode="new")
      assert html =~ ~s(id="camera-new-tabs")
      assert html =~ ~s(id="tab-scan")
      assert html =~ ~s(id="tab-manual")
      assert html =~ ~s(id="camera-labels")
      assert html =~ ~s(id="label-row-0")
      # write-only: the field exists and can never carry a value
      assert html =~ ~s(name="camera[password]")
      refute html =~ ~s(name="camera[password]" type="password" value)
    end

    test "the scan tab is a placeholder until discovery lands", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/cameras/new?tab=scan")

      assert html =~ ~s(id="onvif-scan")
      assert html =~ "ONVIF discovery arrives in a later release"
      refute html =~ ~s(id="camera-form")
    end

    test "validate marks the offending row and banners what no field claims", %{conn: conn} do
      create!("cam1")
      # Behind the context's back: a fleet-level fault this form cannot fix.
      create!("cam2")
      "cam2" |> Cameras.get() |> Camera.update_changeset(%{settings: %{}}) |> Repo.update!()

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      render_click(view, "add-label-row")

      html =
        view
        |> form("#camera-form",
          camera: %{
            "labels" => %{
              "0" => %{"label" => "default", "min_score" => "0.5"},
              "1" => %{"label" => "person", "min_score" => "0.5", "track" => "0.4"}
            }
          }
        )
        |> render_change()

      assert html =~ ~s(id="label-row-1")
      assert html =~ ~s(data-error="true")
      assert html =~ "track.person (0.4) must be &gt;= min_score.person (0.5)"

      assert html =~ ~s(id="camera-form-errors")
      assert html =~ "camera cam2: rtsp_url is required"
    end

    test "a blank id is refused under the field before any write", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/cameras/new?tab=manual")

      html =
        render_change(view, "validate", %{"camera" => %{"id" => "", "rtsp_url" => "rtsp://h/x"}})

      assert html =~ "id is required"

      render_submit(view, "save", %{"camera" => %{"id" => "", "rtsp_url" => "rtsp://h/x"}})
      assert Cairn.Cameras.list() == []
    end

    test "a duplicate id is refused under the field with no credential on the page",
         %{conn: conn} do
      create!("cam1", %{"rtsp_url" => "rtsp://u:SECRET@h/1"})

      {:ok, view, _html} = live(conn, "/cameras/new")

      html =
        view
        |> form("#camera-form",
          camera: %{"id" => "cam1", "rtsp_url" => "rtsp://h/2", "password" => "SECRET2"}
        )
        |> render_submit()

      assert html =~ "id has already been taken"
      # Neither the saved password nor the typed one: the write is never
      # attempted, so no changeset can carry them onto the page.
      refute html =~ "SECRET"
      assert Cameras.get("cam1").settings == %{"rtsp_url" => "rtsp://u:SECRET@h/1"}
    end

    test "a disabled camera is not in the fleet its own edit validates", %{conn: conn} do
      create!("cam1")

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      html = view |> form("#camera-form", camera: %{"max_unseen_ms" => "50"}) |> render_change()

      assert html =~ "max_unseen_ms must be 100..3600000"

      {:ok, _diff, _warnings} = Cameras.set_enabled("cam1", false)

      {:ok, disabled_view, _html} = live(conn, "/cameras/cam1/edit")

      html =
        disabled_view
        |> form("#camera-form", camera: %{"max_unseen_ms" => "50"})
        |> render_change()

      refute html =~ "max_unseen_ms must be"
    end

    test "removing a label row re-validates what is left", %{conn: conn} do
      create!("cam1")

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      render_click(view, "add-label-row")

      html =
        view
        |> form("#camera-form",
          camera: %{
            "labels" => %{
              "0" => %{"label" => "default"},
              "1" => %{"label" => "default", "min_score" => "0.5"}
            }
          }
        )
        |> render_change()

      assert html =~ "duplicate label"

      refute render_click(view, "remove-label-row", %{"index" => "1"}) =~ "duplicate label"
    end

    test "save creates the row and lands on the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/cameras/new")

      view
      |> form("#camera-form", camera: %{"id" => "porch", "rtsp_url" => "rtsp://h/porch"})
      |> render_submit()

      assert flash = assert_redirect(view, "/cameras")
      assert flash["info"] == "added porch"
      assert Cameras.get("porch").settings == %{"rtsp_url" => "rtsp://h/porch"}
    end

    test "the edit page prefills, masks and never renders the saved password", %{conn: conn} do
      create!("cam1", %{
        "rtsp_url" => "rtsp://admin:s3cret@h/1",
        "post_window_seconds" => 12,
        "min_score" => %{"default" => 0.5, "person" => 0.6}
      })

      {:ok, _view, html} = live(conn, "/cameras/cam1/edit")

      refute html =~ "s3cret"
      assert html =~ ~s(data-mode="edit")
      assert html =~ ~s(id="camera-url-readout")
      assert html =~ "rtsp://admin:•••••@h/1"
      # the credential rule: a credentialed URL is not prefilled
      assert html =~ ~s(name="camera[rtsp_url]" value="" )
      assert html =~ ~s(value="admin")
      assert html =~ ~s(value="12")
      assert html =~ ~s(value="0.6")
      assert html =~ ~s(id="camera-zones-summary")
      assert html =~ ~s(data-zones="0")
      assert html =~ ~s(id="camera-remove")
      assert html =~ ~s(id="camera-remove-confirm")
    end

    test "an untouched save diffs to nothing (D-P5)", %{conn: conn} do
      create!("cam1", %{
        "rtsp_url" => "rtsp://h/1",
        "min_score" => %{"default" => 0.5, "person" => 0.6},
        "track" => %{"person" => %{"min_score" => 0.7}},
        "record" => %{"person" => %{"min_score" => 0.8}},
        "retention" => %{"days" => 7, "per_label" => %{"person" => 30}},
        "extra_ffmpeg_args" => ["-rtsp_transport", "tcp"],
        "motion_json" => ~s({"enabled":true})
      })

      settings = Cameras.get("cam1").settings

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      view |> form("#camera-form") |> render_submit()
      html = render_async(view)

      assert html =~ ~s(id="save-result")
      assert html =~ ~s(data-ok="true")
      assert html =~ ~s(data-phase="done")
      refute html =~ "restarted cam1"
      refute html =~ "updated cam1"
      refute html =~ "added cam1"
      assert Cameras.get("cam1").settings == settings
    end

    test "changing the stream URL restarts the camera", %{conn: conn} do
      create!("cam1")

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      view
      |> form("#camera-form", camera: %{"rtsp_url" => "rtsp://h/2"})
      |> render_submit()

      html = render_async(view)

      assert html =~ ~s(data-ok="true")
      assert html =~ "restarted cam1"
      assert Cameras.get("cam1").settings["rtsp_url"] == "rtsp://h/2"
    end

    test "remove deletes the row and returns to the list", %{conn: conn} do
      create!("cam1")

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      render_submit(view, "remove", %{"id" => "cam1"})

      assert flash = assert_redirect(view, "/cameras")
      assert flash["info"] == "removed cam1"
      assert Cameras.get("cam1") == nil
    end

    test "a probe that cannot connect reaches the error state", %{conn: conn} do
      Application.put_env(:cairn, :probe_timeout_ms, 500)
      on_exit(fn -> Application.delete_env(:cairn, :probe_timeout_ms) end)

      create!("cam1", %{"rtsp_url" => "rtsp://127.0.0.1:1/x"})

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      render_click(view, "probe")
      html = render_async(view, 5_000)

      assert html =~ ~s(id="probe-main")
      assert html =~ ~s(data-state="error")
      assert html =~ "Probe failed"
    end

    # The singleton keeps the YAML file source in the test env (D-P7), so a
    # save through it is refused rather than written. That refusal is the
    # closest a test can come to the `@tag :integration` save the plan asks
    # for: the private server is the only DB-backed one in the suite.
    test "a save through a file-backed server is refused on the card", %{conn: conn} do
      create!("cam1")

      {:ok, view, _html} = live(conn, "/cameras/cam1/edit")

      Application.delete_env(:cairn, :config_server)

      view
      |> form("#camera-form", camera: %{"rtsp_url" => "rtsp://h/2"})
      |> render_submit()

      html = render_async(view)

      assert html =~ ~s(data-ok="false")
      assert html =~ "update needs a DB-backed config source"
      assert html =~ "Your previous config is still active — nothing changed."
    end
  end
end
