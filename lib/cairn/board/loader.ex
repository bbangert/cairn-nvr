defmodule Cairn.Board.Loader do
  @moduledoc """
  Attaches a board shipped beside the release rather than inside it.

  A board directory holds `board.manifest` and `lib/<app>-<vsn>/{ebin,priv}`
  for the board application and any application the release does not ship.
  The manifest is `:file.consult/1` terms, each key exactly once:

      {app, cairn_rockchip}.
      {board, 'Elixir.Cairn.Rockchip.Board'}.
      {contract, 1}.

  The board application's version is its `.app` `vsn`, not a manifest key.
  No application in the directory may depend on `:cairn`: the board
  application starts inside `:cairn`'s own start, before its tree, so it
  builds on `cairn_stage` alone and cannot use `:cairn`'s processes.

  Two halves, because `bin/cairn eval` loads `:cairn` without starting it but
  must still see the board: `attach/1` puts the code on the path, loads it,
  checks the board module (`Cairn.Stage.Conformance`) and records it for
  `Cairn.Board.module/0`; `start/0` starts the board application. Both are
  idempotent.

  Each load step is explicit because `bin/cairn start` runs embedded: nothing
  autoloads, and a module on the path but not loaded fails
  `function_exported?/3`, and with it Membrane's element check, silently.
  `bin/cairn eval` runs interactive, where the same steps make a board NIF's
  `on_load` fail at attach rather than at its first call.

  Trust: the directory is code the base runs with the base's full privileges,
  from a path the operator or image controls. Every application under `lib/`
  is loaded and every module's `on_load` runs, not only the board's. An eval
  VM with `CAIRN_BOARD_DIR` set does the same on its first
  `Cairn.Board.module/0`, so tools run board code too. Consulting the
  manifest and every `.app` creates their atoms. Whoever can write the
  directory runs code as the service, so outside the image keep it
  unwritable by the service's user; in the image the service runs as root,
  which can write the release itself as well. Nothing verifies a signature; the contract
  number is a compatibility check, not a security check.
  """

  alias Cairn.Pipeline.DetectChain
  alias Cairn.Stage.Conformance

  @key {__MODULE__, :board}

  @doc """
  The board for `Cairn.Board.module/0`: attached, `:none` when
  `CAIRN_BOARD_DIR` is unset or empty, else attached now. This answer is
  remembered: `board/0` reads the variable once, and returns a failed attach
  on every later call rather than retrying it. `attach/1` remembers only a
  success.
  """
  @spec board() :: {:ok, module()} | :none | {:error, String.t()}
  def board do
    case :persistent_term.get(@key, nil) do
      nil -> serialised(fn -> first_board() end)
      state -> reply(state)
    end
  end

  # Re-read under the lock: a concurrent first caller may have resolved it.
  defp first_board do
    case :persistent_term.get(@key, nil) do
      nil -> resolve(env_dir())
      state -> reply(state)
    end
  end

  defp reply(:none), do: :none
  defp reply({:attached, %{board: board}}), do: {:ok, board}
  defp reply({:failed, message}), do: {:error, message}

  defp resolve(nil), do: remember(:none)

  defp resolve(dir) do
    case attach_once(Path.expand(dir)) do
      :ok -> reply(:persistent_term.get(@key))
      {:error, message} -> remember({:failed, message})
    end
  end

  defp remember(state) do
    :persistent_term.put(@key, state)
    reply(state)
  end

  @doc """
  `attach/1` on `CAIRN_BOARD_DIR`; `:ok` when it is unset or empty, which it
  records, so that after a boot `board/0` never resolves, or locks, inside a
  child's `init/1`.
  """
  @spec attach() :: :ok | {:error, String.t()}
  def attach do
    case env_dir() do
      nil -> serialised(&no_board/0)
      dir -> attach(dir)
    end
  end

  defp no_board do
    if :persistent_term.get(@key, nil) == nil, do: :persistent_term.put(@key, :none)
    :ok
  end

  @spec attach(Path.t()) :: :ok | {:error, String.t()}
  def attach(dir) do
    dir = Path.expand(dir)
    serialised(fn -> attach_once(dir) end)
  end

  # Two first callers of `board/0` in an eval VM would otherwise both attach;
  # the code server runs a successful `on_load` once, but a failed one again
  # for the second caller. `:global` needs no process of ours, which an eval
  # VM has not started, only kernel's `global_name_server` (absent under
  # `start_distribution: false`). Taken by the public entry points only,
  # never nested.
  defp serialised(fun), do: :global.trans({@key, self()}, fun, [node()])

  defp attach_once(dir) do
    case :persistent_term.get(@key, nil) do
      {:attached, %{dir: ^dir}} -> :ok
      {:attached, %{dir: other}} -> {:error, "a board is already attached from #{other}"}
      _ -> do_attach(dir)
    end
  end

  # The contract is checked before any board code is on the path: a
  # mismatched board's `on_load` must not run.
  defp do_attach(dir) do
    with :ok <- directory(dir),
         {:ok, manifest} <- manifest(dir),
         :ok <- contract(dir, manifest),
         {:ok, apps} <- applications(dir),
         :ok <- has_app(dir, apps, manifest.app),
         :ok <- load_apps(apps),
         :ok <- from_dir(dir, manifest.app),
         :ok <- board_module(manifest),
         :ok <- conforms(dir, manifest) do
      :persistent_term.put(@key, {:attached, Map.put(manifest, :dir, dir)})
    end
  end

  @doc """
  Starts the attached board's application; `:ok` with none attached.

  `:permanent` so that a board application that later exits takes the node
  down, rather than leaving one that detects nothing. A permanent
  application that fails to start stops the node as well, which is why a
  test passes `:temporary`.
  """
  @spec start(Application.restart_type()) :: :ok | {:error, String.t()}
  def start(type \\ :permanent) do
    case :persistent_term.get(@key, nil) do
      {:attached, %{app: app}} ->
        case Application.ensure_all_started(app, type: type) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            {:error, "board application #{app} did not start: #{inspect(reason)}"}
        end

      {:failed, message} ->
        {:error, message}

      _ ->
        :ok
    end
  end

  # Empty counts as unset so a derived image can switch the board off.
  defp env_dir do
    case System.get_env("CAIRN_BOARD_DIR") do
      "" -> nil
      dir -> dir
    end
  end

  defp directory(dir) do
    if File.dir?(dir), do: :ok, else: {:error, "board directory #{dir} does not exist"}
  end

  defp manifest(dir) do
    path = Path.join(dir, "board.manifest")

    case :file.consult(String.to_charlist(path)) do
      {:ok, terms} ->
        manifest_terms(path, terms)

      {:error, :enoent} ->
        {:error, "board directory #{dir} has no board.manifest"}

      {:error, {line, mod, reason}} ->
        {:error, "#{path} is malformed: line #{line}: #{mod.format_error(reason)}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp manifest_terms(path, terms) do
    case Enum.sort(terms) do
      [{:app, app}, {:board, board}, {:contract, n}]
      when is_atom(app) and is_atom(board) and is_integer(n) ->
        {:ok, %{app: app, board: board, contract: n}}

      _ ->
        {:error,
         "#{path} is malformed: want {app, App}. {board, Module}. {contract, N}. " <>
           "each once, got #{inspect(terms)}"}
    end
  end

  defp contract(dir, %{contract: theirs}) do
    case Cairn.Stage.contract() do
      ^theirs ->
        :ok

      ours ->
        {:error,
         "board in #{dir} was built for contract #{theirs}; this release has contract #{ours}"}
    end
  end

  # `File.ls/1` rather than `Path.wildcard/1`, which would read `[`, `{`, `*`
  # or `?` in the operator's directory as a pattern.
  defp applications(dir) do
    lib = Path.join(dir, "lib")

    ebins =
      for entry <- ls(lib), ebin = Path.join([lib, entry, "ebin"]), File.dir?(ebin), do: ebin

    case ebins do
      [] -> {:error, "board directory #{dir} has no lib/<app>-<vsn>/ebin"}
      ebins -> Enum.reduce_while(ebins, {:ok, []}, &application/2)
    end
  end

  defp application(ebin, {:ok, apps}) do
    with {:ok, app, spec} <- app_spec(ebin),
         :ok <- not_on_cairn(ebin, app, spec) do
      {:cont, {:ok, [{app, ebin} | apps]}}
    else
      error -> {:halt, error}
    end
  end

  defp app_spec(ebin) do
    with [file] <- ebin |> ls() |> Enum.filter(&String.ends_with?(&1, ".app")),
         path = String.to_charlist(Path.join(ebin, file)),
         {:ok, [{:application, app, spec}]} when is_list(spec) <- :file.consult(path) do
      {:ok, app, spec}
    else
      _ -> {:error, "#{ebin} has no single readable .app file"}
    end
  end

  # Started from inside `:cairn`'s start, a dependency on `:cairn` is parked
  # behind the start in progress, and boot hangs without a word.
  defp not_on_cairn(ebin, app, spec) do
    deps = Keyword.get(spec, :applications, []) ++ Keyword.get(spec, :included_applications, [])

    if :cairn in deps,
      do:
        {:error,
         "application #{app} in #{ebin} depends on cairn; a board starts inside cairn's " <>
           "start and depends on cairn_stage, not on the base"},
      else: :ok
  end

  defp ls(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
  end

  defp has_app(dir, apps, app) do
    if List.keymember?(apps, app, 0),
      do: :ok,
      else: {:error, "board.manifest names application #{app}, which #{dir}/lib does not hold"}
  end

  # Appended, so for an application the release also ships, the release's
  # copy wins: already loaded under `bin/cairn start` and `bin/cairn eval`,
  # earlier on the path otherwise. `from_dir/2` refuses that for the board's
  # own application; for any other the release's copy is what the board runs
  # against, without a word.
  defp load_apps(apps) do
    Enum.each(apps, fn {_app, ebin} -> :code.add_pathz(String.to_charlist(ebin)) end)

    Enum.reduce_while(apps, :ok, fn {app, _ebin}, :ok ->
      with :ok <- load_app(app),
           :ok <- load_modules(app) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp load_app(app) do
    case Application.ensure_loaded(app) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot load application #{app}: #{inspect(reason)}"}
    end
  end

  # `Code.ensure_loaded/1` answers `{:error, :embedded}` in a release. This
  # also runs each `-on_load`, so a board NIF has loaded or failed before
  # anything calls it.
  defp load_modules(app) do
    case :code.ensure_modules_loaded(Application.spec(app, :modules)) do
      :ok ->
        :ok

      {:error, failures} ->
        {:error, "application #{app}: " <> Enum.map_join(failures, "; ", &module_failure/1)}
    end
  end

  defp module_failure({mod, :on_load_failure}), do: "module #{inspect(mod)} failed its on_load"
  defp module_failure({mod, reason}), do: "module #{inspect(mod)} did not load: #{reason}"

  # The manifest's contract vouches for the directory's copy, so a release's
  # copy running in its place is refused.
  defp from_dir(dir, app) do
    case :code.lib_dir(app) do
      lib_dir when is_list(lib_dir) ->
        lib_dir = to_string(lib_dir)

        if String.starts_with?(lib_dir, dir <> "/"),
          do: :ok,
          else:
            {:error,
             "application #{app} in #{dir} is already shipped by this release, from #{lib_dir}"}

      {:error, reason} ->
        {:error, "application #{app} has no lib directory: #{inspect(reason)}"}
    end
  end

  defp board_module(%{app: app, board: board}) do
    if board in Application.spec(app, :modules),
      do: :ok,
      else: {:error, "board module #{inspect(board)} is not in application #{app}"}
  end

  # Every config load checks each profile's backend against the board, and
  # the base's own `generic-ort.yml` and the `backend:` default are `ort`; a
  # profile with no `decoder:` opens `auto`.
  @doc false
  def requires, do: %{backends: ["ort"], decoders: ["auto"]}

  # After the load, so it judges the code the node would run; before the
  # board is recorded, so no reader ever sees one that fails it.
  defp conforms(dir, %{board: board, contract: contract}) do
    opts = [
      contract: contract,
      generic: DetectChain.base_steps("conformance"),
      requires: requires(),
      base: Cairn.Board.base()
    ]

    case Conformance.check(board, opts) do
      :ok ->
        :ok

      {:error, violations} ->
        {:error,
         "board #{inspect(board)} in #{dir} does not conform: " <> Enum.join(violations, "; ")}
    end
  end
end
