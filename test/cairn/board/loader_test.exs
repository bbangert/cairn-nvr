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

      # `File.ls!/1` below it: an ebin path can hold glob characters.
      for ebin <- Path.wildcard(Path.join(tmp, "**/ebin")) do
        files = File.ls!(ebin)

        for file <- files, Path.extname(file) == ".app" do
          app = file |> Path.basename(".app") |> String.to_atom()
          Application.stop(app)
          Application.unload(app)
        end

        for file <- files, Path.extname(file) == ".beam" do
          mod = file |> Path.basename(".beam") |> String.to_atom()
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
      # `:application.info/0` is the one place the restart type shows.
      assert {app, :permanent} in :application.info()[:started]
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

    test "a directory whose name holds glob characters", %{tmp_dir: tmp} do
      %{dir: dir, board: board} = board_dir(Path.join(tmp, "b[1]{x}"))

      assert :ok = Loader.attach(dir)
      assert Cairn.Board.module() == board
    end
  end

  describe "attach/0" do
    test "records no board with CAIRN_BOARD_DIR unset or empty", %{tmp_dir: tmp} do
      for set <- [&System.delete_env/1, &System.put_env(&1, "")] do
        :persistent_term.erase(@key)
        set.("CAIRN_BOARD_DIR")
        assert :ok = Loader.attach()
        assert :persistent_term.get(@key, nil) == :none
      end

      # A recorded "none" is not a refusal: a later attach/1 still attaches.
      %{dir: dir, board: board} = board_dir(tmp)
      assert :ok = Loader.attach(dir)
      assert :ok = Loader.attach()
      assert Cairn.Board.module() == board
    end

    test "attaches CAIRN_BOARD_DIR", %{tmp_dir: tmp} do
      %{dir: dir, board: board} = board_dir(tmp)
      System.put_env("CAIRN_BOARD_DIR", dir)

      assert :ok = Loader.attach()
      assert Cairn.Board.module() == board
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

    test "an application that depends on cairn, before loading any code", %{tmp_dir: tmp} do
      %{dir: dir, app: app, board: board} = board_dir(tmp, applications: [:cairn])

      assert {:error, message} = Loader.attach(dir)
      ebin = Path.join([dir, "lib", "#{app}-0.1.0", "ebin"])

      assert message ==
               "application #{app} in #{ebin} depends on cairn; a board starts inside cairn's " <>
                 "start and depends on cairn_stage, not on the base"

      refute :code.is_loaded(board)
    end

    test "another application in the directory that includes cairn", %{tmp_dir: tmp} do
      %{dir: dir} = board_dir(tmp)
      extra = unique(:extra)
      write_app(dir, extra, [], included_applications: [:cairn])

      assert {:error, message} = Loader.attach(dir)
      assert message =~ "application #{extra} in "
      assert message =~ " depends on cairn; "
    end

    test "a board application the release already ships", %{tmp_dir: tmp} do
      app = unique(:board)
      shipped = Path.join(tmp, "release")
      write_app(shipped, app, [erl(:"#{app}_board", "")])
      :code.add_pathz(String.to_charlist(Path.join([shipped, "lib", "#{app}-0.1.0", "ebin"])))
      :ok = Application.load(app)

      %{dir: dir} = board_dir(Path.join(tmp, "board"), app: app)

      assert {:error, message} = Loader.attach(dir)

      assert message ==
               "application #{app} in #{dir} is already shipped by this release, " <>
                 "from #{shipped}/lib/#{app}-0.1.0"
    end

    test "a board that does not conform, naming each violation", %{tmp_dir: tmp} do
      overrides = %{name: "'name'() -> 42.", profiles_dir: "'profiles_dir'() -> <<\"/nope\">>."}
      %{dir: dir, board: board} = board_dir(tmp, overrides: overrides)

      assert {:error, message} = Loader.attach(dir)

      assert message ==
               "board #{inspect(board)} in #{dir} does not conform: " <>
                 "#{inspect(board)}.name/0 is 42, not a non-empty string; " <>
                 "#{inspect(board)}.profiles_dir/0 /nope is no directory"

      assert :persistent_term.get(@key, nil) == nil
    end

    test "a board without the decoder the base requires", %{tmp_dir: tmp} do
      overrides = %{decoders: "'decoders'() -> [<<\"sw\">>]."}
      %{dir: dir, board: board} = board_dir(tmp, overrides: overrides)

      assert {:error, message} = Loader.attach(dir)
      assert message =~ ~s(#{inspect(board)}.decoders/0 offers no "auto"; this base requires)
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
    # Permanent, a failed start would stop the test VM.
    assert {:error, message} = Loader.start(:temporary)
    assert message =~ "board application #{app} did not start: "
    assert message =~ ":refused"
  end

  test "Cairn.Application.start_board/0 tags a failed attach as the board's", %{tmp_dir: tmp} do
    dir = Path.join(tmp, "nope")
    System.put_env("CAIRN_BOARD_DIR", dir)

    assert Cairn.Application.start_board() ==
             {:error, {:board, "board directory #{dir} does not exist"}}
  end

  describe "Cairn.Board.module/0" do
    test "is the built-in board with CAIRN_BOARD_DIR unset or empty" do
      built_in = Application.get_env(:cairn, :board, Generic)

      System.delete_env("CAIRN_BOARD_DIR")
      assert Cairn.Board.module() == built_in

      :persistent_term.erase(@key)
      System.put_env("CAIRN_BOARD_DIR", "")
      assert Cairn.Board.module() == built_in
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

  # A board whose module delegates every callback not in `:overrides` to the
  # generic board, so a process elsewhere in the VM that reads it mid-test
  # gets generic answers.
  defp board_dir(dir, opts \\ []) do
    app = Keyword.get_lazy(opts, :app, fn -> unique(:board) end)
    board = :"#{app}_board"

    overrides = Keyword.get(opts, :overrides, %{})

    callbacks =
      for {fun, arity} <- Generic.__info__(:functions) do
        args = Enum.map_join(1..arity//1, ",", &"A#{&1}")

        Map.get_lazy(overrides, fun, fn ->
          "'#{fun}'(#{args}) -> 'Elixir.Cairn.Board.Generic':'#{fun}'(#{args})."
        end)
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

    start = start ++ Keyword.take(opts, [:applications])

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

    {deps, extra} = Keyword.pop(extra, :applications, [])

    spec =
      [
        description: ~c"loader test",
        vsn: ~c"0.1.0",
        modules: Enum.map(modules, &elem(&1, 0)),
        registered: [],
        applications: [:kernel, :stdlib | deps]
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
