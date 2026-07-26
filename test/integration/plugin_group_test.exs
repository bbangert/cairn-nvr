defmodule Cairn.PluginGroupIntegrationTest do
  @moduledoc """
  The multiplexed plugin contract end to end: one mock plugin process in
  `--cameras-json` mode serving two cameras, launched from a parsed config
  through `Cairn.PluginGroupSupervisor`, routing by `camera_id` into the
  global aggregator while real camera trees stream the fixture.

  Excluded by default (`test_helper.exs`); run with
  `mix test --include integration`.
  """

  use Cairn.DataCase, async: false

  @moduletag :integration
  @moduletag timeout: 120_000

  alias Cairn.{CameraSupervisor, Config, Event, PluginGroupSupervisor}

  @fixture Path.absname("test/support/fixtures/media/testsrc_long.fmp4")
  @mock Path.absname("priv/plugins/mock/mock_plugin.exs")

  @cam_a "grp_cam_a"
  @cam_b "grp_cam_b"

  setup do
    # Extractors write into the ACTIVE config's data dir, not this test's, and
    # the sandbox rolls back the rows that point at those files. Left behind,
    # they crash the next run's boot reconciliation.
    on_exit(fn ->
      active = Config.Server.get().data_dir

      for id <- [@cam_a, @cam_b], sub <- ~w(events snapshots) do
        File.rm_rf!(Path.join([active, sub, id]))
      end
    end)

    # on_exit runs LIFO: the data dir must outlive the processes logging into it
    dir = Path.join(System.tmp_dir!(), "cairn_group_e2e_#{System.unique_integer([:positive])}")
    Cairn.DataDir.ensure!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    Application.put_env(:cairn, :start_cameras, true)
    on_exit(fn -> Application.put_env(:cairn, :start_cameras, false) end)

    on_exit(fn ->
      Enum.each(Cairn.Registry.ids_for_role(:plugin_group), &PluginGroupSupervisor.stop_group/1)
      Enum.each(Cairn.Registry.ids_for_role(:camera), &CameraSupervisor.stop_camera/1)
    end)

    timeline = Path.join(dir, "timeline.json")

    File.write!(
      timeline,
      Jason.encode!([
        %{
          camera_id: @cam_a,
          at_ms: 8_000,
          pts: 90_000,
          dets: [%{label: "person", score: 0.6, bbox: [0.1, 0.1, 0.2, 0.4]}]
        },
        # below cam_b's 0.8 floor: proves the group applies each member's own
        # min_score, and that this line was not routed to cam_a
        %{
          camera_id: @cam_b,
          at_ms: 8_500,
          pts: 90_000,
          dets: [%{label: "person", score: 0.6, bbox: [0.1, 0.1, 0.2, 0.4]}]
        },
        %{
          camera_id: @cam_b,
          at_ms: 9_500,
          pts: 180_000,
          dets: [%{label: "car", score: 0.95, bbox: [0.15, 0.1, 0.2, 0.4]}]
        }
      ])
    )

    {:ok, config, []} =
      Config.from_map(%{
        "data_dir" => dir,
        "udp" => %{"base_port" => 19_560, "range" => 12},
        "events" => %{
          "pre_window_seconds" => 4,
          "post_window_seconds" => 3,
          "max_event_seconds" => 60
        },
        "plugins" => %{
          "detect" => %{
            "command" => ["elixir", @mock, "--timeline", timeline, "--hold"]
          }
        },
        "cameras" => [
          %{
            "id" => @cam_a,
            "rtsp_url" => "file://" <> @fixture,
            "plugin" => "detect",
            "min_score" => %{"default" => 0.5}
          },
          %{
            "id" => @cam_b,
            "rtsp_url" => "file://" <> @fixture,
            "plugin" => "detect",
            "min_score" => %{"default" => 0.8}
          }
        ]
      })

    %{config: config, dir: dir}
  end

  test "one group process serves two cameras and survives a member restart", %{config: config} do
    Event.subscribe()

    :ok = PluginGroupSupervisor.sync(config)
    :ok = CameraSupervisor.sync(config)

    group = Cairn.Registry.whereis("detect", :plugin_group)
    assert is_pid(group)
    # neither member owns a plugin port: the group process is the only one
    refute Cairn.Registry.whereis(@cam_a, :plugin)
    refute Cairn.Registry.whereis(@cam_b, :plugin)

    os_pid = :sys.get_state(group).os_pid
    assert is_integer(os_pid)

    # routed by camera_id, each with that camera's own config
    assert_receive {:event_started, %Event{camera_id: @cam_a} = event_a}, 30_000
    assert [%{label: "person"}] = event_a.labels

    # cam_b's 0.6 person is filtered by its 0.8 floor; only the 0.95 car opens
    assert_receive {:event_started, %Event{camera_id: @cam_b} = event_b}, 30_000
    assert [%{label: "car"}] = event_b.labels

    # a member camera restart is invisible to the group: it just sees RTP
    # silence on that member's port
    :ok = CameraSupervisor.stop_camera(@cam_b)
    # the registry unregisters on the child's DOWN, a moment after terminate
    assert wait_for(fn -> is_nil(Cairn.Registry.whereis(@cam_b, :camera)) end)

    {:ok, _pid} = CameraSupervisor.start_camera(config, Enum.at(config.cameras, 1), 1)
    assert wait_for(fn -> Cairn.Registry.whereis(@cam_b, :ffmpeg) end)

    assert Cairn.Registry.whereis("detect", :plugin_group) == group
    assert :sys.get_state(group).os_pid == os_pid

    # the untouched member's event still finalizes through the normal path
    assert_receive {:event_ended, %Event{camera_id: @cam_a, status: :finalized}}, 30_000
  end

  defp wait_for(fun, attempts \\ 100) do
    cond do
      value = fun.() ->
        value

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(50)
        wait_for(fun, attempts - 1)
    end
  end
end
