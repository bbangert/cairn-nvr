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

  Two halves, because `bin/cairn eval` never starts `:cairn` but must still
  see the board: `attach/1` puts the code on the path, loads it and records
  the board for `Cairn.Board.module/0`; `start/0` starts the board
  application. Both are idempotent.

  Each load step is explicit because a release runs embedded: nothing
  autoloads, and a module on the path but not loaded fails
  `function_exported?/3`, and with it Membrane's element check, silently.

  Trust: the directory is code the base runs with the base's full privileges,
  from a path the operator or image controls. Nothing verifies a signature;
  the contract number is a compatibility check, not a security check.
  """

  @key {__MODULE__, :board}

  @doc """
  The board for `Cairn.Board.module/0`: attached, `:none` when
  `CAIRN_BOARD_DIR` is unset or empty, else attached now. The answer is
  remembered: the variable is read once, and a failed attach is returned on
  every later call rather than retried.
  """
  @spec board() :: {:ok, module()} | :none | {:error, String.t()}
  def board do
    case :persistent_term.get(@key, nil) do
      nil -> resolve(env_dir())
      :none -> :none
      {:attached, %{board: board}} -> {:ok, board}
      {:failed, message} -> {:error, message}
    end
  end

  defp resolve(nil), do: remember(:none, :none)

  defp resolve(dir) do
    case attach(dir) do
      :ok -> board()
      {:error, message} = error -> remember({:failed, message}, error)
    end
  end

  defp remember(state, reply) do
    :persistent_term.put(@key, state)
    reply
  end

  @doc "`attach/1` on `CAIRN_BOARD_DIR`; `:ok` when it is unset or empty."
  @spec attach() :: :ok | {:error, String.t()}
  def attach do
    case env_dir() do
      nil -> :ok
      dir -> attach(dir)
    end
  end

  @spec attach(Path.t()) :: :ok | {:error, String.t()}
  def attach(dir) do
    dir = Path.expand(dir)

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
         :ok <- board_module(manifest) do
      :persistent_term.put(@key, {:attached, Map.put(manifest, :dir, dir)})
    end
  end

  @doc "Starts the attached board's application; `:ok` with none attached."
  @spec start() :: :ok | {:error, String.t()}
  def start do
    case :persistent_term.get(@key, nil) do
      {:attached, %{app: app}} ->
        case Application.ensure_all_started(app) do
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

  defp applications(dir) do
    case Path.wildcard(Path.join([dir, "lib", "*", "ebin"])) do
      [] -> {:error, "board directory #{dir} has no lib/<app>-<vsn>/ebin"}
      ebins -> Enum.reduce_while(ebins, {:ok, []}, &application/2)
    end
  end

  defp application(ebin, {:ok, apps}) do
    case app_name(ebin) do
      {:ok, app} -> {:cont, {:ok, [{app, ebin} | apps]}}
      error -> {:halt, error}
    end
  end

  defp app_name(ebin) do
    with [file] <- Path.wildcard(Path.join(ebin, "*.app")),
         {:ok, [{:application, app, _}]} <- :file.consult(String.to_charlist(file)) do
      {:ok, app}
    else
      _ -> {:error, "#{ebin} has no single readable .app file"}
    end
  end

  defp has_app(dir, apps, app) do
    if List.keymember?(apps, app, 0),
      do: :ok,
      else: {:error, "board.manifest names application #{app}, which #{dir}/lib does not hold"}
  end

  # Appended, so an application the release already ships wins over a copy
  # in the board directory.
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
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
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

  defp board_module(%{app: app, board: board}) do
    if board in Application.spec(app, :modules),
      do: :ok,
      else: {:error, "board module #{inspect(board)} is not in application #{app}"}
  end
end
