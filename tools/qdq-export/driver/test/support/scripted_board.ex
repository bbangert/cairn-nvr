defmodule Driver.ScriptedBoard do
  @moduledoc """
  A scripted stand-in for `Driver.Board` behind the `cfg.board` seam:
  stage logic runs for real (loops, budget, guard rc handling, local
  evidence writes) while every board interaction returns what the test
  scripted and is recorded for assertion. Board mechanics themselves are
  covered by the `:peer` suite; the composition is P3-T1's board slice.
  """

  @doc "Start the (named) recorder with a `%{fun_name => fun}` script."
  def start_link(script) do
    Agent.start_link(fn -> %{script: script, calls: []} end, name: __MODULE__)
  end

  def child_spec(script) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [script]}}
  end

  @doc "All recorded `{fun_name, args}` in call order."
  def calls, do: Agent.get(__MODULE__, & &1.calls) |> Enum.reverse()

  def calls(name), do: Enum.filter(calls(), fn {n, _} -> n == name end)

  # -- the Board surface Campaign/CLI use ---------------------------------

  def connect(host, opts \\ []), do: dispatch(:connect, [host, opts])
  def ensure_session(board), do: dispatch(:ensure_session, [board])
  def cmd(board, sh, opts \\ []), do: dispatch(:cmd, [board, sh, opts])
  def read!(board, path, timeout \\ 30_000), do: dispatch(:read!, [board, path, timeout])
  def write!(board, local, remote), do: dispatch(:write!, [board, local, remote])
  def eval!(board, code, binding \\ []), do: dispatch(:eval!, [board, code, binding])
  def boot_id(board), do: dispatch(:boot_id, [board])
  def engine_stop(board, container), do: dispatch(:engine_stop, [board, container])
  def engine_start(board, container), do: dispatch(:engine_start, [board, container])
  def pin_governor(board), do: dispatch(:pin_governor, [board])
  def restore_governor(board), do: dispatch(:restore_governor, [board])
  def reboot(board, opts \\ []), do: dispatch(:reboot, [board, opts])
  def final_reboot(board, opts \\ []), do: dispatch(:final_reboot, [board, opts])

  defp dispatch(name, args) do
    script =
      Agent.get_and_update(__MODULE__, fn state ->
        {state.script, %{state | calls: [{name, args} | state.calls]}}
      end)

    case Map.fetch(script, name) do
      {:ok, fun} -> apply(fun, args)
      :error -> default(name, args)
    end
  end

  # Benign defaults keep happy-path scripts terse.
  defp default(:connect, [host, _]), do: {:ok, session(host)}
  defp default(:ensure_session, [board]), do: {:ok, board}
  defp default(:cmd, _), do: {"", 0}
  defp default(:read!, _), do: ""
  defp default(:write!, _), do: :ok
  defp default(:eval!, _), do: []
  defp default(:boot_id, [board]), do: board.boot_id
  defp default(:engine_stop, _), do: :ok
  defp default(:engine_start, _), do: :ok
  defp default(:pin_governor, _), do: {:ok, "schedutil"}
  defp default(:restore_governor, _), do: {:ok, :nothing_to_restore}
  defp default(:reboot, [board, _]), do: {:ok, %{board | qnn_sessions: 0}}
  defp default(:final_reboot, _), do: :ok

  @doc "A session struct for tests; no distribution involved."
  def session(host \\ "scripted") do
    %Driver.Board{host: host, node: :vagus@scripted, cookie: :scripted, boot_id: "boot-A"}
  end
end
