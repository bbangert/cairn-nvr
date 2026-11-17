defmodule Cairn.Rockchip.ElementsTest do
  use ExUnit.Case, async: true

  alias Cairn.Rockchip.{DecodeScale, Download}
  alias Cairn.Stage.{DmaFrame, FrameMeta}
  alias Membrane.Buffer

  @moduletag :capture_log

  # Host and NIF in one. The decoder handle is the test pid and a lease is
  # `{pid, pts}`, so every call reports to the test without shared state.
  defmodule Stub do
    def open_decoder(_camera_id, params, _source),
      do: {:ok, %{ref: params.test, module: Map.get(params, :module, __MODULE__), sample_fps: 30}}

    def report_decoder_refusal(_camera_id, _message), do: :ok

    def decode_au(pid, _au, pts, _sample) do
      frame = %{
        lease: {pid, pts},
        pool: 7,
        width: 4,
        height: 2,
        orig_width: 640,
        orig_height: 480,
        pts: pts,
        observed_at_ms: 0,
        scale_x: 0.5,
        scale_y: 0.5,
        pad_w: 0,
        pad_h: 2,
        motion: nil
      }

      {:ok, {true, frame}}
    end

    def close_decoder(pid) do
      send(pid, {:closed, __MODULE__})
      {:ok, true}
    end

    def download({pid, pts}) do
      send(pid, {:download, pts})
      if pts < 0, do: {:error, {:decode, "sync"}}, else: {:ok, :binary.copy(<<pts>>, 24)}
    end

    def release({pid, pts}) do
      send(pid, {:release, pts})
      :ok
    end
  end

  defmodule Foreign do
    def close_decoder(pid) do
      send(pid, {:closed, __MODULE__})
      {:ok, true}
    end
  end

  defp decode_scale(params \\ %{}) do
    {[], core} =
      DecodeScale.handle_init(%{}, %DecodeScale{
        camera_id: "cam",
        host: Stub,
        stream_params: Map.put(params, :test, self()),
        native: Stub
      })

    {:ok, guard} = Membrane.ResourceGuard.start_link()
    format = %Membrane.H264{alignment: :au, width: 640, height: 480}
    {[], core} = DecodeScale.handle_stream_format(:input, format, %{resource_guard: guard}, core)
    {core, guard}
  end

  defp feed(core, guard, pts) do
    buffer = %Buffer{payload: <<1>>, pts: pts, metadata: %{stream_epoch: :e}}
    # No output demand is open, so the AU's only action is the next one's demand.
    {[demand: {:input, 1}], core} =
      DecodeScale.handle_buffer(:input, buffer, %{resource_guard: guard}, core)

    core
  end

  defp download(buffer) do
    {[], state} = Download.handle_init(%{}, %Download{native: Stub})
    Download.handle_buffer(:input, buffer, %{}, state)
  end

  test "a replaced lease is released undownloaded; an output one reaches Download" do
    {core, guard} = decode_scale()
    core = core |> feed(guard, 1) |> feed(guard, 2)
    assert_received {:release, 1}

    {[stream_format: {:output, format}, buffer: {:output, buffer}], _core} =
      DecodeScale.handle_demand(:output, 1, :buffers, %{}, core)

    assert format == %DmaFrame{width: 4, height: 2, format: :RGB, owner: 7}
    assert buffer.payload == <<>> and buffer.metadata.lease == {self(), 2}
    refute_received {:release, 2}

    {[buffer: {:output, out}], state} = download(buffer)
    assert_received {:download, 2}
    assert_received {:release, 2}
    refute_received {:download, 1}

    assert out.payload == :binary.copy(<<2>>, 24) and out.pts == 2
    refute Map.has_key?(out.metadata, :lease)
    assert {:ok, %{stream_epoch: :e, orig_width: 640}} = FrameMeta.fetch(out.metadata)
    assert state.frames == 1
  end

  test "a failed download is counted, released, and demands again" do
    {[demand: {:input, more}], state} =
      download(%Buffer{payload: <<>>, pts: -1, metadata: %{lease: {self(), -1}}})

    # Membrane takes the arriving buffer off the input demand first, so an
    # open output demand of 3 left 2, and the retry restores 3.
    assert {[demand: {:input, 3}], _} = Download.handle_demand(:output, 3, :buffers, %{}, state)
    assert more.(2) == 3
    assert_received {:release, -1}

    assert {[notify_parent: {:stats, %{frames: 0, failed: 1}}], _} =
             Download.handle_parent_notification(:stats, %{}, state)
  end

  test "Download turns the pool's format into RGB of the same size" do
    {[], state} = Download.handle_init(%{}, %Download{native: Stub})
    format = %DmaFrame{width: 4, height: 2, format: :RGB, owner: 7}

    assert {[
              stream_format:
                {:output, %Membrane.RawVideo{width: 4, height: 2, pixel_format: :RGB}}
            ], _} = Download.handle_stream_format(:input, format, %{}, state)
  end

  test "a decoder opened through another library is closed and refused" do
    arg = %{host: Stub, camera_id: "cam", native: Stub, params: %{test: self(), module: Foreign}}

    assert {:error, {:config, message}} = DecodeScale.open_decoder(arg, {640, 480})
    assert message =~ "Foreign decoder"
    assert_received {:closed, Foreign}
  end
end
