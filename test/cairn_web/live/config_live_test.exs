defmodule CairnWeb.ConfigLiveTest do
  use CairnWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @fixture "test/support/fixtures/configs/valid.yml"

  test "renders globals and a link to the cameras page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/config")

    assert html =~ "config-globals"
    assert html =~ "config-cameras-link"
    assert html =~ "Open Cameras"
  end

  test "mask_url hides rtsp credentials" do
    assert CairnWeb.CameraCards.mask_url("rtsp://admin:s3cret@10.0.0.5:554/s1") ==
             "rtsp://admin:•••••@10.0.0.5:554/s1"

    assert CairnWeb.CameraCards.mask_url("rtsp://10.0.0.5:554/s1") == "rtsp://10.0.0.5:554/s1"
  end

  test "mask_url hides credential query params (http-flv style)" do
    assert CairnWeb.CameraCards.mask_url(
             "http://10.0.0.5/flv?port=1935&stream=ch0&user=admin&password=hunter2"
           ) == "http://10.0.0.5/flv?port=1935&stream=ch0&user=•••••&password=•••••"

    assert CairnWeb.CameraCards.mask_url("http://10.0.0.5/flv?Token=abc&x=1") ==
             "http://10.0.0.5/flv?Token=•••••&x=1"
  end

  test "reload with valid config shows result", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/config")

    html = render_click(view, "reload", %{})
    assert html =~ "Config reloaded — changes are live"
  end

  test "reload with invalid YAML keeps old config and shows errors", %{conn: conn} do
    original = File.read!(@fixture)
    on_exit(fn -> File.write!(@fixture, original) end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(@fixture, "cameras: [{id: broken}]\n")
    html = render_click(view, "reload", %{})

    assert html =~ "previous config is still active"
    assert html =~ "rtsp_url is required"
    # old config still rendered
    assert html =~ "config-cameras-link"

    # restore and reload back to a clean state for other tests
    File.write!(@fixture, original)
    render_click(view, "reload", %{})
  end

  # This LiveView reads through `Cairn.Cameras.server/0`, which defaults to
  # the application's own `Config.Server` when no test has pointed it
  # elsewhere — as none of these do — so the empty fleet has to be reached
  # the way an operator would: a valid reload that removes every camera,
  # then a broken one the server refuses, which keeps that empty config
  # while reporting errors.
  test "an errored load with no cameras left says so", %{conn: conn} do
    original = File.read!(@fixture)

    on_exit(fn ->
      File.write!(@fixture, original)
      Cairn.Config.Server.reload()
    end)

    {:ok, view, _html} = live(conn, "/config")

    File.write!(@fixture, "data_dir: tmp/cairn_test_data\ncameras: []\n")
    html = render_click(view, "reload", %{})
    refute html =~ "config-no-cameras"

    File.write!(@fixture, "cameras: [{id: broken}]\n")
    html = render_click(view, "reload", %{})

    assert html =~ "config-no-cameras"
    assert html =~ "No cameras are running."

    File.write!(@fixture, original)
    render_click(view, "reload", %{})
  end

  describe "busy overlay" do
    # A dead pid, not a slow one: `GenServer.call` to it exits immediately
    # with `{:noproc, _}` rather than after a real apply's timeout, which is
    # what `overlay/1`'s `catch :exit` is there for either way — the mount
    # itself must not crash while the config server is applying a save.
    test "a config server that cannot answer renders a busy line, not a crash", %{conn: conn} do
      # spawn_monitor, not spawn-then-monitor: a process that has already exited
      # is reported :noproc, and under CI load it always has.
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      previous = Application.get_env(:cairn, :config_server)
      Application.put_env(:cairn, :config_server, dead)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cairn, :config_server, previous),
          else: Application.delete_env(:cairn, :config_server)
      end)

      {:ok, view, html} = live(conn, "/config")

      assert html =~ "config-busy"
      assert html =~ "Configuration is being applied"
      refute html =~ "config-globals"

      # Reload against the same dead server: an error card, not a crash.
      html = render_click(view, "reload", %{})
      assert html =~ ~s(id="reload-result")
      assert html =~ "try again in a moment"
    end

    # The apply that made the server unanswerable ends with this message, so
    # the page leaves the busy card without the operator reloading the browser.
    test "the config change that ends the apply re-reads the page", %{conn: conn} do
      # spawn_monitor, not spawn-then-monitor: a process that has already exited
      # is reported :noproc, and under CI load it always has.
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      previous = Application.get_env(:cairn, :config_server)
      Application.put_env(:cairn, :config_server, dead)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cairn, :config_server, previous),
          else: Application.delete_env(:cairn, :config_server)
      end)

      {:ok, view, html} = live(conn, "/config")
      assert html =~ "config-busy"

      if previous,
        do: Application.put_env(:cairn, :config_server, previous),
        else: Application.delete_env(:cairn, :config_server)

      Phoenix.PubSub.broadcast(
        Cairn.PubSub,
        Cairn.Config.topic(),
        {:config_changed, %{added: [], removed: [], changed: [], refreshed: []}}
      )

      html = render(view)

      assert html =~ "config-globals"
      refute html =~ "config-busy"
    end
  end

  describe "import banner" do
    test "#config-import is absent with no marker", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/config")
      refute html =~ "config-import"
    end

    test "#config-import shows the marker's path and date", %{conn: conn} do
      Cairn.Repo.insert!(
        Cairn.Cameras.Setting.changeset(%Cairn.Cameras.Setting{}, %{
          key: "yaml_import",
          value: %{
            "path" => "/config/config.yml",
            "sha256" => String.duplicate("0", 64),
            "imported_at" => "2026-09-02T21:31:07Z"
          }
        })
      )

      on_exit(fn -> Cairn.Repo.delete_all(Cairn.Cameras.Setting) end)

      {:ok, _view, html} = live(conn, "/config")

      assert html =~ "config-import"
      assert html =~ "/config/config.yml"
      assert html =~ CairnWeb.EventsLive.fmt_time(~U[2026-09-02 21:31:07Z])
      assert html =~ ~s(<time datetime="2026-09-02T21:31:07Z">)
    end
  end

  # A private DB-backed `Config.Server` through `Cairn.Cameras.server/0`
  # (D-P7): the singleton in this test env is file-sourced, so it can never
  # produce the "changed since they were imported" warning the re-import
  # button depends on.
  describe "re-import" do
    alias Cairn.Cameras
    alias Cairn.Cameras.Camera
    alias Cairn.Cameras.Setting
    alias Cairn.Config
    alias Cairn.ConfigSource
    alias Cairn.Repo

    setup do
      dir =
        Path.join(System.tmp_dir!(), "cairn_config_live_#{System.unique_integer([:positive])}")

      Cairn.DataDir.ensure!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      path = Path.join(dir, "config.yml")

      File.write!(path, """
      data_dir: #{dir}
      retention:
        days: 7
      cameras:
        - id: cam_a
          rtsp_url: rtsp://yaml/1
        - id: cam_b
          rtsp_url: rtsp://yaml/2
      """)

      Repo.insert!(
        Camera.changeset(%Camera{}, %{
          id: "cam_a",
          position: 0,
          enabled: true,
          settings: %{"rtsp_url" => "rtsp://rows/1"}
        })
      )

      Repo.insert!(
        Camera.changeset(%Camera{}, %{
          id: "cam_z",
          position: 1,
          enabled: true,
          settings: %{"rtsp_url" => "rtsp://rows/z"}
        })
      )

      # A sha nothing in the file matches: the "changed since" warning, not
      # "still lists cameras".
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
          id: :config_live_reimport_server
        )

      Application.put_env(:cairn, :config_server, server)

      # `ConfigLive` reads `Config.default_path/0` (no server-scoped path
      # accessor exists), so the app env has to point at this test's tmp
      # file too — otherwise its reimport button would replace rows from
      # the real fixture path instead of the file this test wrote.
      previous_config_path = Application.get_env(:cairn, :config_path)
      Application.put_env(:cairn, :config_path, path)

      on_exit(fn ->
        Application.delete_env(:cairn, :config_server)

        if previous_config_path,
          do: Application.put_env(:cairn, :config_path, previous_config_path),
          else: Application.delete_env(:cairn, :config_path)
      end)

      %{path: path, server: server}
    end

    test "the button only renders when the drift warning is present", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/config")
      assert html =~ "config-reimport"
    end

    test "clicking it replaces the rows with the file's cameras", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/config")

      view |> element("#config-reimport") |> render_click()
      html = render_async(view)

      assert html =~ ~s(id="reload-result")
      assert html =~ ~s(data-ok="true")
      assert html =~ "Cameras re-imported from config.yml — changes are live"
      assert html =~ "added cam_b"
      assert html =~ "removed cam_z"
      assert html =~ "restarted cam_a"

      # Filtered rather than an exact list: this suite's sandbox is not the
      # only writer of the shared sqlite file under concurrent test runs.
      ids =
        Cameras.list() |> Enum.map(& &1.id) |> Enum.filter(&(&1 in ["cam_a", "cam_b", "cam_z"]))

      assert ids == ["cam_a", "cam_b"]
      refute html =~ "config-reimport"
    end

    # `disabled` in the markup only stops the first click's own button; a
    # stale DOM or a hand-sent event still arrives. The discriminator is the
    # task, not the render: `start_async` links its process to the LiveView,
    # so a second re-import would show as a second link. The server this test
    # installs blocks inside `apply_diff` until released, so both clicks land
    # while the first import is provably still running.
    test "a second re-import click while one is running starts no second task", %{
      conn: conn,
      path: path
    } do
      test_pid = self()

      slow =
        start_supervised!(
          {Config.Server,
           path: path,
           name: nil,
           source: {ConfigSource, :load},
           apply_diff: fn _diff, _config ->
             # Runs in the server process, so the release is sent to `slow`.
             send(test_pid, :applying)
             receive do: (:release -> :ok)
           end,
           apply_native: fn _config -> :ok end},
          id: :config_live_reimport_slow_server
        )

      Application.put_env(:cairn, :config_server, slow)

      {:ok, view, _html} = live(conn, "/config")

      links = fn -> view.pid |> Process.info(:links) |> elem(1) |> length() end
      idle = links.()

      render_click(view, "reimport")
      assert links.() == idle + 1
      assert_receive :applying, 2_000

      render_click(view, "reimport")
      assert links.() == idle + 1

      send(slow, :release)

      html = render_async(view, 2_000)
      assert html =~ "Cameras re-imported from config.yml — changes are live"
    end

    test "a file that fails to load shows the re-import failure headline, not the reload one", %{
      conn: conn,
      path: path
    } do
      {:ok, view, _html} = live(conn, "/config")

      File.write!(path, """
      data_dir: #{Path.dirname(path)}
      retention:
        days: 7
      cameras:
        - id: broken
      """)

      view |> element("#config-reimport") |> render_click()
      html = render_async(view)

      assert html =~ "We couldn&#39;t re-import the cameras"
      refute html =~ "We couldn&#39;t load the new config"
      assert html =~ "rtsp_url is required"
    end

    # `FlakyReimport` fails only the write, deterministically — driving the
    # same `handle_async(:reimport, {:exit, _}, _)` arm a real unconfirmed
    # write would, without waiting out a real 30 s timeout. The button must
    # stay disabled through it: the server may still be applying the write it
    # never answered, and a second click would queue a second destructive
    # fleet replacement behind the first one's back. Only a confirmed
    # `{:config_changed, _}` — never a page reload alone — is allowed to
    # clear it.
    test "an unconfirmed re-import keeps the button disabled until a config change confirms it",
         %{conn: conn, server: srv} do
      {:ok, view, _html} = live(conn, "/config")

      start_supervised!({Cairn.FlakyReimport, srv}, restart: :permanent)
      previous = Application.get_env(:cairn, :config_server)
      Application.put_env(:cairn, :config_server, Cairn.FlakyReimport)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:cairn, :config_server, previous),
          else: Application.delete_env(:cairn, :config_server)
      end)

      view |> element("#config-reimport") |> render_click()
      html = render_async(view)

      assert html =~ "it may still apply"
      # `get`/`last_load` still answer through the stand-in (it only fails
      # `update`), so this is the button itself, not the busy overlay.
      assert has_element?(view, "#config-reimport[disabled]")

      Phoenix.PubSub.broadcast(
        Cairn.PubSub,
        Cairn.Config.topic(),
        {:config_changed, %{added: [], removed: [], changed: [], refreshed: []}}
      )

      render(view)
      refute has_element?(view, "#config-reimport[disabled]")
    end
  end

  # `reimport_result/1` is `@doc false` public rather than private (see its
  # own doc): the reachable failure it maps — `write_fun` raising inside
  # `Cairn.ConfigSource.reimport/1`'s nested transaction — is not practical
  # to provoke deterministically through the LiveView, so the credential-
  # safety of the `{:write, reason}` branch is pinned here directly instead.
  describe "reimport_result/1" do
    test "a write error built from an Ecto exception never renders the credentialed URL" do
      changeset =
        Cairn.Cameras.Camera.changeset(%Cairn.Cameras.Camera{}, %{
          id: "bad id",
          position: 0,
          settings: %{"rtsp_url" => "rtsp://u:SECRET@h/1"}
        })

      result =
        CairnWeb.ConfigLive.reimport_result(
          {:error, {:write, %Ecto.InvalidChangesetError{changeset: changeset}}}
        )

      refute Enum.any?(result.errors, &(&1 =~ "SECRET"))
      assert result.kind == :reimport
      refute result.ok
    end

    # Another session's re-import landed first. The card is the plain error
    # one — not the unconfirmed variant — so it keeps the "your previous
    # config is still active" line, which is the whole of the news.
    test "a re-import that found no drift is a non-destructive card" do
      result = CairnWeb.ConfigLive.reimport_result({:error, {:write, :no_drift}})

      assert result.errors == ["the cameras already match config.yml — nothing to import"]
      assert result.kind == :reimport
      refute result.ok
      refute result[:unconfirmed]
    end
  end
end
