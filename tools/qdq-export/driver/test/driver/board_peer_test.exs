defmodule Driver.BoardPeerTest do
  # Real distribution semantics against a local :peer node — the peer IS
  # named vagus@127.0.0.1 so the shape-pinned enable parse holds end to
  # end. async: false: one peer name, and the suite owns the VM cookie.
  use ExUnit.Case, async: false

  alias Driver.Board

  @cookie String.duplicate("c0ffee01", 8)
  @host "127.0.0.1"
  @moduletag timeout: 120_000
  @moduletag :tmp_dir

  defmodule FakeSsh do
    @behaviour Driver.Board.Ssh

    # The enable step is the one thing tests must not shell out for; the
    # canned output keeps the channel's \r\n so the real parse runs.
    @impl true
    def enable(_host), do: {:ok, Application.fetch_env!(:driver, :fake_enable_output)}
  end

  setup_all do
    :erlang.set_cookie(node(), :erlang.binary_to_atom(@cookie))
    :ok
  end

  setup %{tmp_dir: tmp_dir} do
    boot_path = Path.join(tmp_dir, "boot_id")
    File.write!(boot_path, "boot-A\n")
    Application.put_env(:driver, :boot_id_path, boot_path)

    Application.put_env(:driver, :fake_enable_output, enable_output(@cookie))

    on_exit(fn ->
      Application.delete_env(:driver, :boot_id_path)
      Application.delete_env(:driver, :fake_enable_output)
    end)

    {:ok, boot_path: boot_path}
  end

  defp enable_output(cookie) do
    ~s({:ok, %{cookie: "#{cookie}", node: :"vagus@#{@host}", ports: 9100..9105}}\r\n)
  end

  defp start_peer(attempts \\ 3) do
    code_paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    opts = %{
      name: :vagus,
      host: ~c"#{@host}",
      longnames: true,
      args: [~c"-setcookie", ~c"#{@cookie}" | code_paths]
    }

    case :peer.start(opts) do
      {:ok, pid, node} ->
        {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])
        pid

      # The previous test's peer name can linger in epmd for a beat.
      {:error, _} when attempts > 1 ->
        Process.sleep(300)
        start_peer(attempts - 1)
    end
  end

  defp connect! do
    {:ok, session} = Board.connect(@host, ssh: FakeSsh)
    session
  end

  test "connect mints a session from the parsed enable output" do
    peer = start_peer()
    session = connect!()

    assert session.node == :"vagus@#{@host}"
    assert session.boot_id == "boot-A"
    assert session.qnn_sessions == 0

    :peer.stop(peer)
  end

  test "cmd returns the real exit status, pipes included" do
    peer = start_peer()
    session = connect!()

    assert Board.cmd(session, "printf hi; exit 3") == {"hi", 3}
    assert {"2\n", 0} = Board.cmd(session, "printf 'a\\nb\\n' | wc -l")

    :peer.stop(peer)
  end

  test "read! is whole-or-error", %{tmp_dir: tmp_dir} do
    peer = start_peer()
    session = connect!()

    path = Path.join(tmp_dir, "evidence.txt")
    File.write!(path, "all of it")
    assert Board.read!(session, path) == "all of it"

    assert_raise ErlangError, fn ->
      Board.read!(session, Path.join(tmp_dir, "missing"))
    end

    :peer.stop(peer)
  end

  test "write! pushes chunked and sha-verifies", %{tmp_dir: tmp_dir} do
    peer = start_peer()
    session = connect!()

    # Odd size crossing the 4MB chunk boundary: 2 chunks + remainder.
    content = :crypto.strong_rand_bytes(9_000_001)
    local = Path.join(tmp_dir, "artifact.bin")
    remote = Path.join(tmp_dir, "pushed/artifact.bin")
    File.write!(local, content)

    assert Board.write!(session, local, remote) == :ok
    assert File.read!(remote) == content

    :peer.stop(peer)
  end

  test "cmd timeout raises on the caller without wedging the node" do
    peer = start_peer()
    session = connect!()

    assert {:erpc, :timeout} = catch_error(Board.cmd(session, "sleep 5", timeout: 200))
    assert {_, 0} = Board.cmd(session, "true")

    :peer.stop(peer)
  end

  test "ensure_session keeps the CDSP counter across a same-boot reconnect" do
    peer = start_peer()
    session = %{connect!() | qnn_sessions: 5}

    assert {:ok, ^session} = Board.ensure_session(session)

    :peer.stop(peer)
    peer2 = start_peer()

    assert {:ok, fresh} = Board.ensure_session(session)
    assert fresh.qnn_sessions == 5
    assert fresh.boot_id == session.boot_id

    :peer.stop(peer2)
  end

  test "reboot: nodedown, changed boot id, fresh session with counter reset",
       %{boot_path: boot_path} do
    peer = start_peer()
    session = %{connect!() | qnn_sessions: 7}

    task =
      Task.async(fn ->
        Board.reboot(session,
          reboot_cmd: "true",
          nodedown_timeout: 10_000,
          deadline: 30_000,
          interval: 200
        )
      end)

    # Let the task subscribe and cast before the "board" goes down.
    Process.sleep(500)
    File.write!(boot_path, "boot-B\n")
    :peer.stop(peer)
    peer2 = start_peer()

    assert {:ok, fresh} = Task.await(task, 60_000)
    assert fresh.boot_id == "boot-B"
    assert fresh.qnn_sessions == 0

    :peer.stop(peer2)
  end

  test "reboot refuses a dist bounce that kept the boot id" do
    peer = start_peer()
    session = connect!()

    task =
      Task.async(fn ->
        Board.reboot(session,
          reboot_cmd: "true",
          nodedown_timeout: 10_000,
          deadline: 30_000,
          interval: 200
        )
      end)

    Process.sleep(500)
    :peer.stop(peer)
    peer2 = start_peer()

    assert {:error, :boot_id_unchanged} = Task.await(task, 60_000)

    :peer.stop(peer2)
  end

  test "a reboot that never took the board down is reported, not faked" do
    peer = start_peer()
    session = connect!()

    assert {:error, :reboot_not_observed} =
             Board.reboot(session, reboot_cmd: "true", nodedown_timeout: 500)

    :peer.stop(peer)
  end
end
