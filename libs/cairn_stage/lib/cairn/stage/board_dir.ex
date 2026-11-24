defmodule Cairn.Stage.BoardDir do
  @moduledoc """
  Writes a board directory, the layout the base's loader attaches at boot:
  `board.manifest` and `lib/<app>-<vsn>/{ebin,priv}` for the board
  application and every application in its dependency closure that the core
  release does not ship.

  An application the core release's `.rel` lists is not written: the
  release's copy is the one that runs, so the board must be built against
  that version. Versions are compared, never bytes, because the same version
  builds differently from one checkout to another (macros embed the deps
  path; optional dependencies change what compiles). An application the
  build lacks is taken from the toolchain (OTP, Elixir), and shipped from
  there unless the `.rel` lists it. Also refused: an application in none of
  these, unless optional; a dependency on `:cairn`; another ERTS; a
  `defimpl` of a protocol the directory does not ship; an `out` that exists
  and is neither empty nor a board directory.

  Reads `.app` files and beam attributes only; no module is loaded, so a
  board NIF's `on_load` never runs here.
  """

  @type opts :: [
          lib_dir: Path.t(),
          app: atom(),
          board: module(),
          contract: pos_integer(),
          rel: Path.t(),
          out: Path.t()
        ]

  @doc """
  Writes the directory at `out`, replacing an empty directory or a previous
  board directory, or writes nothing and returns every problem found.
  `lib_dir` is the board build's `lib`, holding `<app>/ebin/<app>.app` for
  the board application and its dependencies;
  `rel` is the core release's `releases/<vsn>/<name>.rel`.
  """
  @spec write(opts()) :: :ok | {:error, [String.t()]}
  def write(opts) do
    lib_dir = Keyword.fetch!(opts, :lib_dir)
    app = Keyword.fetch!(opts, :app)

    with {:ok, erts, rel_apps} <- read_rel(Keyword.fetch!(opts, :rel)),
         {:ok, board_app} <- built(lib_dir, app) do
      {shipped, closure_errors} = walk([board_app], rel_apps, lib_dir, MapSet.new([app]), [], [])

      errors =
        Enum.uniq(
          erts_errors(erts) ++
            board_errors(board_app, Keyword.fetch!(opts, :board), rel_apps) ++
            closure_errors ++
            protocol_errors(shipped) ++ out_errors(Keyword.fetch!(opts, :out))
        )

      if errors == [], do: emit(shipped, opts), else: {:error, errors}
    else
      {:error, message} -> {:error, [message]}
    end
  end

  defp read_rel(path) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:release, {_name, _vsn}, {:erts, erts}, apps}]} ->
        {:ok, to_string(erts), Map.new(apps, &{elem(&1, 0), to_string(elem(&1, 1))})}

      {:ok, terms} ->
        {:error, "#{path} is not a release file: #{inspect(terms, limit: 5)}"}

      {:error, reason} ->
        {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  # The VM running this is the toolchain the board's beams were built by.
  defp erts_errors(rel_erts) do
    case to_string(:erlang.system_info(:version)) do
      ^rel_erts -> []
      ours -> ["the board is built on ERTS #{ours}; the core release runs ERTS #{rel_erts}"]
    end
  end

  defp board_errors(%{name: app, modules: modules}, board, rel_apps) do
    shipped_by_core =
      if Map.has_key?(rel_apps, app),
        do: ["application #{app} is shipped by the core release; the loader refuses it"],
        else: []

    in_app =
      if board in modules,
        do: [],
        else: ["board module #{inspect(board)} is not among application #{app}'s modules"]

    shipped_by_core ++ in_app
  end

  defp out_errors(out) do
    if replaceable?(out),
      do: [],
      else: ["#{out} exists and is not a board directory; refusing to replace it"]
  end

  defp replaceable?(out) do
    not File.exists?(out) or
      (File.dir?(out) and
         (File.ls(out) == {:ok, []} or File.regular?(Path.join(out, "board.manifest"))))
  end

  # Breadth first from the board application. A `.rel`-listed application
  # ends its branch: the release carries its dependencies. An optional one
  # found nowhere is skipped, as a release skips it. Every edge is judged,
  # so an application optional for one parent and required by another is
  # still reported; `seen` only keeps one from being shipped twice.
  defp walk([], _rel_apps, _lib_dir, _seen, shipped, errors),
    do: {Enum.reverse(shipped), Enum.reverse(errors)}

  defp walk([app | rest], rel_apps, lib_dir, seen, shipped, errors) do
    {queue, seen, errors} =
      app.deps
      |> Enum.uniq()
      |> Enum.reduce({rest, seen, errors}, fn dep, {queue, seen, errors} ->
        case dependency(dep, app, rel_apps, lib_dir) do
          {:ship, dep_app} -> enqueue(dep_app, queue, seen, errors)
          :skip -> {queue, seen, errors}
          {:error, message} -> {queue, seen, [message | errors]}
        end
      end)

    walk(queue, rel_apps, lib_dir, seen, [app | shipped], errors)
  end

  defp enqueue(%{name: name} = app, queue, seen, errors) do
    if MapSet.member?(seen, name),
      do: {queue, seen, errors},
      else: {queue ++ [app], MapSet.put(seen, name), errors}
  end

  # The loader refuses the same at boot, which is too late to find out.
  defp dependency(:cairn, parent, _rel_apps, _lib_dir),
    do:
      {:error,
       "application #{parent.name} depends on cairn; a board starts inside cairn's start " <>
         "and depends on cairn_stage, not on the base, and the loader refuses it"}

  defp dependency(dep, parent, rel_apps, lib_dir) do
    case {Map.fetch(rel_apps, dep), find(lib_dir, dep)} do
      {{:ok, rel_vsn}, {:ok, %{vsn: vsn}}} ->
        same_version(dep, vsn, rel_vsn)

      {{:ok, _}, {:error, _}} ->
        {:error, "application #{dep} is in the core release but not in this build"}

      {:error, {:ok, dep_app}} ->
        {:ship, dep_app}

      {:error, {:error, _}} ->
        if dep in parent.optional,
          do: :skip,
          else:
            {:error,
             "application #{dep}, which #{parent.name} depends on, is in neither the core " <>
               "release, the build's lib directory nor the toolchain"}
    end
  end

  defp same_version(_app, vsn, vsn), do: :skip

  defp same_version(app, built, rel),
    do:
      {:error,
       "application #{app} is #{built} in the board's build but #{rel} in the core release"}

  # OTP's and Elixir's own applications are not in a Mix build's lib. Mix
  # prunes the code path to the applications the project lists, so one only
  # a dependency needs can be off it: the Elixir and OTP installs are
  # searched too. Nothing is loaded.
  defp find(lib_dir, app) do
    with {:error, _} = missing <- built(lib_dir, app) do
      case toolchain_dir(app) do
        nil -> missing
        dir -> descriptor(Path.join(dir, "ebin"), app)
      end
    end
  end

  defp toolchain_dir(app) do
    case :code.lib_dir(app) do
      dir when is_list(dir) ->
        to_string(dir)

      _ ->
        elixir = Path.join([:code.lib_dir(:elixir), "..", to_string(app)])

        if File.dir?(elixir),
          do: Path.expand(elixir),
          else: Path.wildcard(Path.join([:code.root_dir(), "lib", "#{app}-*"])) |> List.last()
    end
  end

  defp built(lib_dir, app), do: descriptor(Path.join([lib_dir, to_string(app), "ebin"]), app)

  defp descriptor(ebin, app) do
    with {:ok, spec} <- app_file(ebin, app) do
      {:ok,
       %{
         name: app,
         vsn: to_string(Keyword.fetch!(spec, :vsn)),
         deps:
           Keyword.get(spec, :applications, []) ++ Keyword.get(spec, :included_applications, []),
         optional: Keyword.get(spec, :optional_applications, []),
         modules: Keyword.get(spec, :modules, []),
         dir: Path.dirname(ebin)
       }}
    end
  end

  defp app_file(ebin, app) do
    path = Path.join(ebin, "#{app}.app")

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, ^app, spec}]} when is_list(spec) -> {:ok, spec}
      _ -> {:error, "#{path} is not a readable .app file for #{app}"}
    end
  end

  # The core release consolidates its protocols, so an implementation of
  # one the directory does not carry itself never dispatches.
  defp protocol_errors(shipped) do
    modules = MapSet.new(Enum.flat_map(shipped, & &1.modules))

    for app <- shipped, module <- app.modules, error <- impl_error(app, module, modules) do
      error
    end
  end

  # `defimpl` marks its module with `__impl__: [protocol: P, for: T]`.
  defp impl_error(app, module, modules) do
    path = Path.join([app.dir, "ebin", "#{module}.beam"])

    case :beam_lib.chunks(String.to_charlist(path), [:attributes]) do
      {:ok, {^module, [attributes: attributes]}} ->
        protocol = attributes |> Keyword.get(:__impl__, []) |> Keyword.get(:protocol)

        if protocol == nil or MapSet.member?(modules, protocol),
          do: [],
          else: [
            "#{inspect(module)} implements protocol #{inspect(protocol)}, which the " <>
              "directory does not ship; the core release's protocols are consolidated, " <>
              "so it never dispatches"
          ]

      _ ->
        ["cannot read the attributes of #{path}"]
    end
  end

  # Mix symlinks `priv` into the build; the directory must hold real files.
  defp emit(shipped, opts) do
    out = Keyword.fetch!(opts, :out)
    File.rm_rf!(out)

    for app <- shipped,
        dir <- ~w(ebin priv),
        source = Path.join(app.dir, dir),
        File.dir?(source) do
      target = Path.join([out, "lib", "#{app.name}-#{app.vsn}", dir])
      File.mkdir_p!(Path.dirname(target))
      File.cp_r!(source, target, dereference_symlinks: true)
    end

    manifest = [
      app: Keyword.fetch!(opts, :app),
      board: Keyword.fetch!(opts, :board),
      contract: Keyword.fetch!(opts, :contract)
    ]

    File.write!(
      Path.join(out, "board.manifest"),
      for({key, value} <- manifest, do: :io_lib.format(~c"{~tp, ~tp}.~n", [key, value]))
    )
  end
end
