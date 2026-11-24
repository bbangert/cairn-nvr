defmodule Cairn.Stage.BoardDirTest do
  use ExUnit.Case, async: true

  alias Cairn.Stage.BoardDir

  # Not ExUnit's `:tmp_dir`, which writes under this project's `tmp/`.
  setup do
    dir = Path.join(System.tmp_dir!(), "board_dir_test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{tmp_dir: dir}
  end

  # Real `defprotocol`/`defimpl` output, so the test reads the marking the
  # compiler writes rather than one written to match the code.
  setup_all do
    [proto, impl, board] =
      Enum.map(
        [
          "defprotocol Cairn.Stage.BoardDirTest.Proto do def f(x) end",
          "defimpl Cairn.Stage.BoardDirTest.Proto, for: Atom do def f(x), do: x end",
          "defmodule Cairn.Stage.BoardDirTest.Board do end"
        ],
        fn source ->
          [beam] = Code.compile_string(source)
          beam
        end
      )

    %{proto: proto, impl: impl, board: board}
  end

  defp put_app(lib, app, vsn, deps, beams, extra \\ []) do
    ebin = Path.join([lib, to_string(app), "ebin"])
    File.mkdir_p!(ebin)
    for {mod, bin} <- beams, do: File.write!(Path.join(ebin, "#{mod}.beam"), bin)

    spec =
      [vsn: ~c"#{vsn}", modules: Enum.map(beams, &elem(&1, 0)), applications: deps] ++ extra

    File.write!(
      Path.join(ebin, "#{app}.app"),
      :io_lib.format(~c"~tp.~n", [{:application, app, spec}])
    )
  end

  defp put_rel(dir, apps, erts \\ to_string(:erlang.system_info(:version))) do
    toolchain = for app <- [:kernel, :stdlib, :elixir], do: {app, Application.spec(app, :vsn)}
    apps = toolchain ++ for({app, vsn} <- apps, do: {app, ~c"#{vsn}"})
    path = Path.join(dir, "cairn.rel")
    rel = {:release, {~c"cairn", ~c"0.1.0"}, {:erts, ~c"#{erts}"}, apps}
    File.write!(path, :io_lib.format(~c"~tp.~n", [rel]))
    path
  end

  defp write(dir, rel, overrides \\ []) do
    [
      lib_dir: Path.join(dir, "lib"),
      app: :fb,
      board: __MODULE__.Board,
      contract: 1,
      rel: rel,
      out: Path.join(dir, "out")
    ]
    |> Keyword.merge(overrides)
    |> BoardDir.write()
  end

  @base [:kernel, :stdlib, :elixir]

  test "writes the board and its board-only dependencies, not the release's",
       %{tmp_dir: dir} = c do
    lib = Path.join(dir, "lib")
    put_app(lib, :fb, "0.1.0", @base ++ [:shared, :only], [c.board])
    put_app(lib, :shared, "1.0.0", @base, [])
    put_app(lib, :only, "2.0.0", @base, [])

    # Mix's own layout: the build's `priv` is a symlink into the source.
    File.mkdir_p!(Path.join(dir, "src/priv/native"))
    File.write!(Path.join(dir, "src/priv/native/lib.so"), "so")
    File.ln_s!(Path.join(dir, "src/priv"), Path.join(lib, "fb/priv"))

    File.mkdir_p!(Path.join(dir, "out/stale"))
    assert :ok = write(dir, put_rel(dir, shared: "1.0.0"))

    out = Path.join(dir, "out")

    assert {:ok, [{:app, :fb}, {:board, __MODULE__.Board}, {:contract, 1}]} =
             :file.consult(String.to_charlist(Path.join(out, "board.manifest")))

    assert File.ls!(out) |> Enum.sort() == ["board.manifest", "lib"]
    assert File.ls!(Path.join(out, "lib")) |> Enum.sort() == ["fb-0.1.0", "only-2.0.0"]
    assert File.exists?(Path.join(out, "lib/fb-0.1.0/ebin/#{__MODULE__.Board}.beam"))
    assert File.exists?(Path.join(out, "lib/only-2.0.0/ebin/only.app"))
    refute File.exists?(Path.join(out, "lib/only-2.0.0/priv"))
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(out, "lib/fb-0.1.0/priv"))
    assert File.read!(Path.join(out, "lib/fb-0.1.0/priv/native/lib.so")) == "so"
  end

  test "a shared application at another version is refused, naming both", %{tmp_dir: dir} = c do
    lib = Path.join(dir, "lib")
    put_app(lib, :fb, "0.1.0", @base ++ [:shared, :other], [c.board])
    put_app(lib, :shared, "1.1.0", @base, [])
    put_app(lib, :other, "3.0.0", @base, [])

    assert {:error, errors} = write(dir, put_rel(dir, shared: "1.0.0", other: "3.0.1"))

    assert errors == [
             "application shared is 1.1.0 in the board's build but 1.0.0 in the core release",
             "application other is 3.0.0 in the board's build but 3.0.1 in the core release"
           ]

    refute File.exists?(Path.join(dir, "out"))
  end

  test "an application found nowhere is refused unless optional", %{tmp_dir: dir} = c do
    lib = Path.join(dir, "lib")
    put_app(lib, :fb, "0.1.0", @base ++ [:only], [c.board])
    put_app(lib, :only, "1.0.0", @base ++ [:nowhere, :maybe], [], optional_applications: [:maybe])

    assert {:error, [error]} = write(dir, put_rel(dir, []))

    assert error ==
             "application nowhere, which only depends on, is neither in the core release " <>
               "nor in the build's lib directory"
  end

  test "a dependency on cairn is refused", %{tmp_dir: dir} = c do
    put_app(Path.join(dir, "lib"), :fb, "0.1.0", @base ++ [:cairn], [c.board])
    assert {:error, [error]} = write(dir, put_rel(dir, cairn: "0.1.0"))
    assert error =~ "application fb depends on cairn"
  end

  test "another ERTS is refused", %{tmp_dir: dir} = c do
    put_app(Path.join(dir, "lib"), :fb, "0.1.0", @base, [c.board])
    assert {:error, [error]} = write(dir, put_rel(dir, [], "1.0"))
    assert error =~ ~r/^the board is built on ERTS \S+; the core release runs ERTS 1\.0$/
  end

  test "the board module must be the board application's, which the release must not ship",
       %{tmp_dir: dir} = c do
    put_app(Path.join(dir, "lib"), :fb, "0.1.0", @base, [c.board])

    assert {:error, errors} = write(dir, put_rel(dir, fb: "0.1.0"), board: Other)

    assert errors == [
             "application fb is shipped by the core release; the loader refuses it",
             "board module Other is not among application fb's modules"
           ]
  end

  test "an implementation of a protocol the directory does not ship is refused",
       %{tmp_dir: dir} = c do
    lib = Path.join(dir, "lib")
    put_app(lib, :fb, "0.1.0", @base ++ [:shared], [c.board, c.impl])
    put_app(lib, :shared, "1.0.0", @base, [c.proto])

    assert {:error, [error]} = write(dir, put_rel(dir, shared: "1.0.0"))

    assert error ==
             "Cairn.Stage.BoardDirTest.Proto.Atom implements protocol " <>
               "Cairn.Stage.BoardDirTest.Proto, which the directory does not ship; the core " <>
               "release's protocols are consolidated, so it never dispatches"
  end

  test "an implementation of a protocol the directory ships is written", %{tmp_dir: dir} = c do
    lib = Path.join(dir, "lib")
    put_app(lib, :fb, "0.1.0", @base ++ [:only], [c.board, c.impl])
    put_app(lib, :only, "1.0.0", @base, [c.proto])

    assert :ok = write(dir, put_rel(dir, []))
  end
end
