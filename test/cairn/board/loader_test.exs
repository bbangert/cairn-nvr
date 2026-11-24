defmodule Cairn.Board.LoaderTest do
  # The attached board is VM-global state.
  use ExUnit.Case, async: false

  alias Cairn.Board.Generic
  alias Cairn.Board.Loader

  @moduletag :tmp_dir
  @key {Loader, :board}

  setup %{tmp_dir: tmp} do
    before_term = :persistent_term.get(@key, :unset)
    before_env = System.get_env("CAIRN_BOARD_DIR")

    on_exit(fn ->
      if before_term == :unset,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, before_term)

      if before_env,
        do: System.put_env("CAIRN_BOARD_DIR", before_env),
        else: System.delete_env("CAIRN_BOARD_DIR")

      for ebin <- Path.wildcard(Path.join(tmp, "**/ebin")) do
        for app_file <- Path.wildcard(Path.join(ebin, "*.app")) do
          app = app_file |> Path.basename(".app") |> String.to_atom()
          Application.stop(app)
          Application.unload(app)
        end

        for beam <- Path.wildcard(Path.join(ebin, "*.beam")) do
          mod = beam |> Path.basename(".beam") |> String.to_atom()
          :code.purge(mod)
          :code.delete(mod)
          :code.purge(mod)
        end

        :code.del_path(String.to_charlist(ebin))
      end
    end)

    # Erased only after the restore above is registered, so the rest of the
    # suite never sees a test board or a test failure.
    :persistent_term.erase(@key)
    :ok
  end

  describe "attach/1 and start/0" do
    test "attach loads the board without starting it; start starts it", %{tmp_dir: tmp} do
      %{dir: dir, app: app, board: board} = board_dir(tmp)

      assert :ok = Loader.attach(dir)
      assert Cairn.Board.module() == board
      assert {:file, _} = :code.is_loaded(board)

      assert :code.priv_dir(app) ==
               String.to_charlist(Path.join([dir, "lib", "#{app}-0.1.0", "priv"]))

      refute started?(app)

      assert :ok = Loader.start()
      assert started?(app)
    end

    test "both halves are idempotent; a second directory is refused", %{tmp_dir: tmp} do
      %{dir: dir} = board_dir(Path.join(tmp, "a"))
      %{dir: other} = board_dir(Path.join(tmp, "b"))

      assert :ok = Loader.attach(dir)
      assert :ok = Loader.attach(dir)
      assert :ok = Loader.start()
      assert :ok = Loader.start()
      assert {:error, "a board is already attached from " <> ^dir} = Loader.attach(other)
    end

    test "a second application in the directory is loaded too", %{tmp_dir: tmp} do
      %{dir: dir} = board_dir(tmp)
      extra = unique(:extra)
      write_app(dir, extra, [erl(:"#{extra}_mod", "-export([hi/0]).\nhi() -> hi.")])

      assert :ok = Loader.attach(dir)
      assert {:file, _} = :code.is_loaded(:"#{extra}_mod")
      assert Application.spec(extra, :vsn) == ~c"0.1.0"
    end

    test "start/0 with no board attached does nothing" do
      assert :ok = Loader.start()
    end
  end

  describe "attach/1 refuses" do
    test "a missing directory, naming it", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "nope")
      assert Loader.attach(dir) == {:error, "board directory #{dir} does not exist"}
    end

    test "a directory with no manifest", %{tmp_dir: tmp} do
      assert {:error, message} = Loader.attach(tmp)
      assert message == "board directory #{tmp} has no board.manifest"
    end

    test "a manifest that is not Erlang terms", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "board.manifest"), "{app, x")
      assert {:error, message} = Loader.attach(tmp)
      assert message =~ "board.manifest is malformed: line 1"
    end

    test "a manifest missing a key", %{tmp_dir: tmp} do
      File.write!(Path.join(tmp, "board.manifest"), "{app, x}.\n{board, y}.\n")
      assert {:error, message} = Loader.attach(tmp)
      assert message =~ "board.manifest is malformed: want {app, App}."
    end

    test "another contract, naming both numbers, before loading any code", %{tmp_dir: tmp} do
      ours = Cairn.Stage.contract()
      %{dir: dir, board: board} = board_dir(tmp, contract: ours + 1)

      assert {:error, message} = Loader.attach(dir)

      assert message ==
               "board in #{dir} was built for contract #{ours + 1}; this release has contract #{ours}"

      refute :code.is_loaded(board)
      refute Enum.any?(:code.get_path(), &List.starts_with?(&1, String.to_charlist(dir)))
    end

    test "a module whose on_load fails, naming it", %{tmp_dir: tmp} do
      %{dir: dir, app: app} = board_dir(tmp, extra_modules: [erl(:bad_nif, on_load_fails())])

      assert {:error, message} = Loader.attach(dir)
      assert message == "application #{app}: module :bad_nif failed its on_load"
    end

    test "a manifest naming an application the directory does not hold", %{tmp_dir: tmp} do
      %{dir: dir} = board_dir(tmp, manifest_app: :not_here)
      assert {:error, message} = Loader.attach(dir)

      assert message ==
               "board.manifest names application not_here, which #{dir}/lib does not hold"
    end
  end

  test "start/0 reports a board application that fails to start", %{tmp_dir: tmp} do
    %{dir: dir, app: app} = board_dir(tmp, refuse_start: true)

    assert :ok = Loader.attach(dir)
    assert {:error, message} = Loader.start()
    assert message =~ "board application #{app} did not start: "
    assert message =~ ":refused"
  end

  describe "Cairn.Board.module/0" do
    test "is the built-in board with CAIRN_BOARD_DIR unset or empty" do
      System.put_env("CAIRN_BOARD_DIR", "")
      assert Cairn.Board.module() == Application.get_env(:cairn, :board, Generic)
    end

    test "attaches from CAIRN_BOARD_DIR, as under bin/cairn eval", %{tmp_dir: tmp} do
      %{dir: dir, app: app, board: board} = board_dir(tmp)
      System.put_env("CAIRN_BOARD_DIR", dir)

      assert Cairn.Board.module() == board
      refute started?(app)
    end

    test "raises on a failed attach every time, without retrying it", %{tmp_dir: tmp} do
      dir = Path.join(tmp, "later")
      System.put_env("CAIRN_BOARD_DIR", dir)

      assert_raise RuntimeError, ~r/board directory .*later does not exist/, &Cairn.Board.module/0

      board_dir(dir)
      assert_raise RuntimeError, ~r/does not exist/, &Cairn.Board.module/0
    end
  end

  defp started?(app), do: List.keymember?(Application.started_applications(), app, 0)

  # A board whose module delegates every callback to the generic board, so a
  # process elsewhere in the VM that reads it mid-test gets generic answers.
  defp board_dir(dir, opts \\ []) do
    app = unique(:board)
    board = :"#{app}_board"

    callbacks =
      for {fun, arity} <- Generic.__info__(:functions) do
        args = Enum.map_join(1..arity//1, ",", &"A#{&1}")
        "'#{fun}'(#{args}) -> 'Elixir.Cairn.Board.Generic':'#{fun}'(#{args})."
      end

    exports =
      Enum.map_join(Generic.__info__(:functions), ",", fn {f, a} -> "'#{f}'/#{a}" end)

    {start_mod, start} =
      if opts[:refuse_start] do
        mod = :"#{app}_app"
        src = "-export([start/2, stop/1]).\nstart(_, _) -> {error, refused}.\nstop(_) -> ok."
        {[erl(mod, src)], [mod: {mod, []}]}
      else
        {[], []}
      end

    board_src = "-export([#{exports}]).\n" <> Enum.join(callbacks, "\n")
    modules = [erl(board, board_src)] ++ start_mod ++ Keyword.get(opts, :extra_modules, [])
    write_app(dir, app, modules, start)

    manifest = [
      app: Keyword.get(opts, :manifest_app, app),
      board: board,
      contract: Keyword.get(opts, :contract, Cairn.Stage.contract())
    ]

    File.write!(
      Path.join(dir, "board.manifest"),
      Enum.map(manifest, &:io_lib.format("~p.~n", [&1]))
    )

    %{dir: dir, app: app, board: board}
  end

  defp write_app(dir, app, modules, extra \\ []) do
    ebin = Path.join([dir, "lib", "#{app}-0.1.0", "ebin"])
    File.mkdir_p!(ebin)
    File.mkdir_p!(Path.join([dir, "lib", "#{app}-0.1.0", "priv"]))

    for {mod, src} <- modules do
      erl = Path.join(dir, "#{mod}.erl")
      File.write!(erl, "-module('#{mod}').\n" <> src <> "\n")
      {:ok, ^mod, bin} = :compile.file(String.to_charlist(erl), [:binary, :return_errors])
      File.write!(Path.join(ebin, "#{mod}.beam"), bin)
    end

    spec =
      [
        description: ~c"loader test",
        vsn: ~c"0.1.0",
        modules: Enum.map(modules, &elem(&1, 0)),
        registered: [],
        applications: [:kernel, :stdlib]
      ] ++ extra

    File.write!(
      Path.join(ebin, "#{app}.app"),
      :io_lib.format("~p.~n", [{:application, app, spec}])
    )
  end

  defp erl(mod, src), do: {mod, src}

  defp on_load_fails, do: "-on_load(init/0).\ninit() -> error."

  defp unique(prefix), do: :"cairn_loader_#{prefix}_#{System.unique_integer([:positive])}"
end
