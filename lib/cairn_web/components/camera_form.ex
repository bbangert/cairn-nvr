defmodule CairnWeb.CameraForm do
  @moduledoc """
  The camera editor: the translation between a row's canonical `settings` map
  and the flat form params, plus the markup `CairnWeb.CamerasLive` renders for
  `:new` and `:edit`.

  The translation lives here rather than in the LiveView because it is the
  half that is testable without a socket, and because both directions have to
  agree on "blank means inherit" for an untouched edit to round-trip through
  `Cairn.Cameras.canonical/1` to the same map — that identity is what makes a
  save with no edits diff to nothing (plan D-P5).

  Nothing here validates thresholds, URLs or JSON: `Cairn.Config.from_map/1`
  is the one validator, so a cell this module cannot read as a number is
  passed through unchanged for the loader to name. `field_errors/2` then puts
  the loader's own string back under the field it names.
  """

  use CairnWeb, :html

  alias Cairn.Cameras.Camera
  alias Cairn.Config
  alias CairnWeb.CameraCards

  # Every params value is a string; a blank one is the operator saying nothing.
  @blank ""

  @int_fields ~w(pre_window_seconds post_window_seconds max_event_seconds
                 annotation_offset_ms max_live_tracks max_unseen_ms stationary_after_ms)

  # `retention_days` is a form field but not a settings key: it is the
  # `days` of the `retention` block, which also holds the rows' per-label
  # days.
  @all_int_fields ["retention_days" | @int_fields]

  @cells ~w(min_score track record retention_days)

  @text_fields ~w(rtsp_url substream_url plugin ingest tracker motion_json extra_ffmpeg_args)

  # Every settings key this module can write. A saved key outside it — the
  # vestigial `pipeline`, or one a future release adds before the form does —
  # is carried through an edit rather than dropped by it, so a save the
  # operator did not aim at that key leaves it alone. `id` and `zones` are
  # excluded because they are columns of their own, not settings.
  @modelled_keys ~w(rtsp_url substream_url plugin ingest tracker motion_json transcode
                    extra_ffmpeg_args retention min_score track record id zones) ++ @int_fields

  # The chip's set. `Cairn.Config.Server.restart_fields/0` is what a running
  # camera cannot take in place; the five added here restart for reasons that
  # module cannot see — the resolved compares in its camera diff
  # (`pre_window_seconds`, `tracker`, `max_live_tracks`) and the credentials,
  # which are spliced into `rtsp_url`.
  @extra_restart_fields ~w(pre_window_seconds tracker max_live_tracks username password)

  @doc false
  @spec restart_fields() :: [String.t()]
  def restart_fields do
    Enum.map(Config.Server.restart_fields(), &to_string/1) ++ @extra_restart_fields
  end

  @spec restart?(String.t()) :: boolean()
  def restart?(field), do: field in restart_fields()

  @doc """
  A saved row rendered as form params. A saved credential is never among
  them: the password field is always empty and a URL that carries a
  credential is blank, with the readout the only place it appears.
  """
  @spec to_params(Camera.t() | nil) :: map()
  def to_params(row) do
    settings = if row, do: row.settings, else: %{}

    %{
      "id" => (row && row.id) || "",
      "plugin" => settings["plugin"] || @blank,
      "ingest" => to_string(settings["ingest"] || @blank),
      "transcode" => if(settings["transcode"] == true, do: "true", else: "false"),
      "tracker" => settings["tracker"] || @blank,
      "motion_json" => settings["motion_json"] || @blank,
      "extra_ffmpeg_args" => args_string(settings["extra_ffmpeg_args"]),
      "labels" => index_rows(label_rows(settings))
    }
    |> Map.merge(int_params(settings))
    |> Map.merge(url_params(settings))
  end

  # The credential rule in one place: a URL that carries a credential is not
  # rendered, the username is, and the password never is.
  defp url_params(settings) do
    url = settings["rtsp_url"]
    sub = settings["substream_url"]

    %{
      "rtsp_url" => visible_url(url),
      "substream_url" => visible_url(sub),
      "username" => url_user(url) || url_user(sub) || @blank,
      "password" => @blank
    }
  end

  @doc "The label rows of `params`, in index order — the socket's own copy."
  @spec rows(map()) :: [map()]
  def rows(params) do
    case Map.get(params, "labels") do
      map when is_map(map) ->
        map
        |> Enum.sort_by(fn {index, _row} -> to_int(index) end)
        |> Enum.map(fn {_index, row} -> normalize_row(row) end)
        |> ensure_default_row()

      list when is_list(list) ->
        list |> Enum.map(&normalize_row/1) |> ensure_default_row()

      _absent ->
        [blank_row("default")]
    end
  end

  @spec blank_row(String.t()) :: map()
  def blank_row(label) do
    Map.new(["label" | @cells], fn
      "label" -> {"label", label}
      cell -> {cell, @blank}
    end)
  end

  @spec index_rows([map()]) :: map()
  def index_rows(rows) do
    rows |> Enum.with_index() |> Map.new(fn {row, n} -> {to_string(n), row} end)
  end

  @doc """
  Form params as a YAML-camera-shaped settings map, or the errors that stop
  it becoming one. Blank is absent everywhere: an omitted key inherits, which
  is what the parser's `nil` already means.

  `saved` is the row being edited: a blank URL field keeps its URL (the
  credential rule leaves it blank on purpose), and a typed password is
  spliced into that saved URL whether or not it already carries userinfo.
  Its keys that no field here models are carried through untouched.
  """
  @spec to_settings(map(), Camera.t() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def to_settings(params, saved \\ nil) do
    rows = rows(params)
    saved_settings = if saved, do: saved.settings, else: %{}

    with [] <- row_errors(rows),
         {:ok, ints} <- parse_ints(params),
         {:ok, per_label} <- row_retention(rows) do
      {:ok, build_settings(params, rows, ints, per_label, saved_settings)}
    else
      {:error, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  @doc """
  The URLs a probe should open: the form's, composed with the credentials,
  falling back to the saved row's for a field the credential rule left blank.
  These carry the password, so they are probed and never rendered.
  """
  @spec urls(map(), Camera.t() | nil) :: %{main: String.t() | nil, sub: String.t() | nil}
  def urls(params, saved) do
    settings = if saved, do: saved.settings, else: %{}

    composed =
      %{} |> put_url("rtsp_url", params, settings) |> put_url("substream_url", params, settings)

    %{main: composed["rtsp_url"], sub: composed["substream_url"]}
  end

  @doc """
  The loader's strings for `camera_id`, routed to the field each names, plus
  the ones no field claims (fleet-level messages included) for
  `#camera-form-errors`.

  A tier message names the *resolved* label, which may be a row whose cell is
  blank and only ghosts an inherited number — that is the intended landing
  place (the ghost is the number the message quotes). A label with no row at
  all cannot be shown in place, so it stays unclaimed.
  """
  @spec field_errors([String.t()], String.t()) :: {map(), [String.t()]}
  def field_errors(errors, camera_id) do
    {per_camera, fleet} = Config.partition_by_camera(errors)

    # Another camera's error is fleet-level as far as this form is concerned:
    # it can refuse the save and there is no field here to hang it on.
    others = per_camera |> Map.delete(camera_id) |> Enum.flat_map(fn {_id, msgs} -> msgs end)

    {routed, unclaimed} =
      per_camera
      |> Map.get(camera_id, [])
      |> Enum.map(&strip_prefix(&1, camera_id))
      |> Enum.reduce({%{}, []}, fn message, {routed, unclaimed} ->
        case route(message) do
          [] -> {routed, [message | unclaimed]}
          keys -> {Enum.reduce(keys, routed, &append(&2, &1, message)), unclaimed}
        end
      end)

    {routed, Enum.reverse(unclaimed) ++ others ++ fleet}
  end

  @doc "Errors on one field, or on one row's cell (`{label, cell}`)."
  @spec errors_for(map(), term()) :: [String.t()]
  def errors_for(field_errors, key), do: Map.get(field_errors, key, [])

  @doc """
  Whether a blank tier cell means "this label gets nothing" rather than
  "inherits": the column has rules for other labels and no `default` rule, so
  the parser excludes the label from the tier (decision 5).
  """
  @spec excluded?([map()], map(), String.t()) :: boolean()
  def excluded?(rows, row, cell) when cell in ["track", "record"] do
    blank?(row[cell]) and row["label"] != "default" and
      blank?(cell_of(rows, "default", cell)) and
      Enum.any?(rows, fn other -> other["label"] != "default" and not blank?(other[cell]) end)
  end

  # `min_score` always resolves: the parser invents a `default` floor, so no
  # label is ever excluded from it.
  def excluded?(_rows, _row, _cell), do: false

  @doc "The number a blank cell inherits, for the ghost, or `nil`."
  @spec inherited([map()], map(), String.t()) :: String.t() | nil
  def inherited(rows, row, cell) do
    cond do
      not blank?(row[cell]) -> nil
      row["label"] == "default" and cell == "min_score" -> "0.50"
      row["label"] == "default" -> nil
      not blank?(cell_of(rows, "default", cell)) -> cell_of(rows, "default", cell)
      cell == "min_score" -> "0.50"
      # A tier with no rule anywhere resolves to the wire floor for every
      # label; only a *present* tier excludes.
      cell in ["track", "record"] -> "= Detect"
      true -> nil
    end
  end

  # -- params -> settings -----------------------------------------------------

  defp build_settings(params, rows, ints, per_label, saved) do
    saved
    |> Map.drop(@modelled_keys)
    |> put_url("rtsp_url", params, saved)
    |> put_url("substream_url", params, saved)
    |> put_present("plugin", params)
    |> put_present("ingest", params)
    |> put_present("tracker", params)
    |> put_present("motion_json", params)
    |> put_transcode(params)
    |> put_args(params, saved)
    |> put_ints(ints)
    |> put_retention(ints, per_label)
    |> put_min_score(rows)
    |> put_tier("track", rows)
    |> put_tier("record", rows)
  end

  # Only `true` is written: `transcode: false` is the parser's default, and a
  # key the operator never set must not appear in the row and make an
  # untouched save look like a change.
  defp put_transcode(acc, params) do
    if trimmed(params, "transcode") in ["true", "on"],
      do: Map.put(acc, "transcode", true),
      else: acc
  end

  defp put_present(acc, key, params) do
    case trimmed(params, key) do
      @blank -> acc
      value -> Map.put(acc, key, value)
    end
  end

  # The row holds the split list even though the parser accepts the string
  # too: the importer stores a list, so the form has to as well or the two
  # would render different maps for the same fleet.
  #
  # The field is one line of text and the split is on whitespace, so an
  # element containing a space cannot survive a round trip through it. Text
  # still equal to what `args_string/1` rendered is therefore not re-split at
  # all: the saved list rides out as it went in, and only an edit splits
  # (D-P5).
  defp put_args(acc, params, saved) do
    text = Map.get(params, "extra_ffmpeg_args") || @blank
    saved_args = saved["extra_ffmpeg_args"]

    if is_list(saved_args) and text == args_string(saved_args) do
      if saved_args == [], do: acc, else: Map.put(acc, "extra_ffmpeg_args", saved_args)
    else
      case String.split(text) do
        [] -> acc
        args -> Map.put(acc, "extra_ffmpeg_args", args)
      end
    end
  end

  defp put_ints(acc, ints) do
    Enum.reduce(@int_fields, acc, fn field, acc ->
      case Map.get(ints, field) do
        nil -> acc
        value -> Map.put(acc, field, value)
      end
    end)
  end

  defp put_retention(acc, ints, per_label) do
    retention =
      %{}
      |> then(fn map ->
        case Map.get(ints, "retention_days") do
          nil -> map
          days -> Map.put(map, "days", days)
        end
      end)
      |> then(fn map ->
        if per_label == %{}, do: map, else: Map.put(map, "per_label", per_label)
      end)

    if retention == %{}, do: acc, else: Map.put(acc, "retention", retention)
  end

  defp put_min_score(acc, rows) do
    scores =
      rows
      |> Enum.reject(&blank?(&1["min_score"]))
      |> Map.new(fn row -> {row["label"], number(row["min_score"])} end)

    if scores == %{}, do: acc, else: Map.put(acc, "min_score", scores)
  end

  # An empty tier map is not the same as an absent one — it excludes every
  # label (see `Cairn.Config.Camera`'s moduledoc) — so a column with no cell
  # filled drops the key entirely.
  defp put_tier(acc, key, rows) do
    tier =
      rows
      |> Enum.reject(&blank?(&1[key]))
      |> Map.new(fn row -> {row["label"], %{"min_score" => number(row[key])}} end)

    if tier == %{}, do: acc, else: Map.put(acc, key, tier)
  end

  defp put_url(acc, key, params, saved) do
    typed = trimmed(params, key)
    base = if typed == @blank, do: saved[key], else: typed

    case base do
      url when is_binary(url) and url != @blank ->
        Map.put(acc, key, credentialed(url, key, params, saved))

      _absent ->
        acc
    end
  end

  # A URL that already carries userinfo keeps its own username unless the
  # operator changed the field, and keeps its own password unless one was
  # typed: the username is prefilled off the *main* stream, so overwriting
  # with it would rewrite a sub stream that authenticates as somebody else on
  # a save nobody edited. A URL with none takes the fields as a
  # splice, whether or not its own text was edited — adding credentials to a
  # camera that never had any is the ordinary reason to type them. A URL
  # whose credential rides in the query (`?user=…&password=…`, the FLV form)
  # is left alone either way: the fields describe the userinfo form, and
  # adding a second credential to a URL that already carries one would
  # change a stream the operator did not touch.
  #
  # What counts as "given" is where the trap is: treating a prefill as typed
  # would break the untouched-edit round trip (D-P5) either way. Only a
  # password, or a username the operator changed, rewrites a URL that has no
  # userinfo.
  #
  # Last: a URL retyped for a stream whose saved URL carried the credential
  # keeps it. Neither field can supply one here — the password field says
  # "leave blank to keep" and the username is a prefill, not an entry — so
  # without the carry, moving a camera to a new host or path would quietly
  # save the stream without its credential.
  defp credentialed(url, key, params, saved) do
    user = trimmed(params, "username")
    pass = password(params)

    cond do
      URI.parse(url).userinfo != nil ->
        compose_url(url, if(given_user?(user, saved), do: user, else: @blank), pass)

      CameraCards.credentialed?(url) ->
        url

      pass != @blank or given_user?(user, saved) ->
        compose_url(url, user, pass)

      true ->
        carry_userinfo(url, saved[key])
    end
  end

  # Copied verbatim: what is on the saved URL is already percent-encoded, and
  # re-encoding it would change the credential.
  defp carry_userinfo(url, saved_url) when is_binary(saved_url) do
    case URI.parse(saved_url).userinfo do
      nil -> url
      userinfo -> URI.to_string(%{URI.parse(url) | userinfo: userinfo})
    end
  end

  defp carry_userinfo(url, _absent), do: url

  defp given_user?(@blank, _saved), do: false

  defp given_user?(user, saved),
    do: user != (url_user(saved["rtsp_url"]) || url_user(saved["substream_url"]))

  # Not trimmed: a password may legitimately begin or end with a space.
  defp password(params), do: Map.get(params, "password") || @blank

  defp compose_url(url, @blank, @blank), do: url

  defp compose_url(url, user, pass) do
    uri = URI.parse(url)
    {current_user, current_pass} = split_userinfo(uri.userinfo)
    user = if user == @blank, do: current_user, else: encode(user)
    pass = if pass == @blank, do: current_pass, else: encode(pass)

    URI.to_string(%{uri | userinfo: userinfo(user, pass)})
  end

  defp userinfo(nil, _pass), do: nil
  defp userinfo(user, nil), do: user
  defp userinfo(user, pass), do: user <> ":" <> pass

  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, nil}
    end
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp parse_ints(params) do
    {ints, errors} =
      Enum.reduce(@all_int_fields, {%{}, []}, fn field, acc ->
        put_int(acc, field, trimmed(params, field), "#{field} must be a whole number")
      end)

    if errors == [], do: {:ok, ints}, else: {:error, Enum.reverse(errors)}
  end

  defp put_int(acc, _key, @blank, _message), do: acc

  defp put_int({ints, errors}, key, value, message) do
    case Integer.parse(value) do
      {int, ""} -> {Map.put(ints, key, int), errors}
      _other -> {ints, [message | errors]}
    end
  end

  # The `default` row has no days cell and cannot contribute one:
  # `retention.per_label["default"]` is a rule for a detection label literally
  # named `default` (`Cairn.Config.retention_days/3` looks the label up by
  # name), never the camera's own days — those are `retention.days`, which the
  # "Keep clips (days)" field writes. A stray one would also drag
  # `Cairn.Retention`'s sweep floor down, since that takes the minimum over
  # every per-label value.
  defp row_retention(rows) do
    {per_label, errors} =
      rows
      |> Enum.reject(&(&1["label"] == "default"))
      |> Enum.reduce({%{}, []}, fn row, acc ->
        put_int(
          acc,
          row["label"],
          String.trim(row["retention_days"]),
          "retention_days (#{row["label"]}) must be a whole number"
        )
      end)

    if errors == [], do: {:ok, per_label}, else: {:error, Enum.reverse(errors)}
  end

  # A row with nothing in it at all is dropped rather than refused: the
  # operator added a row and changed their mind, and there is nothing to save.
  defp row_errors(rows) do
    named = Enum.reject(rows, &empty_row?/1)

    blank =
      if Enum.any?(named, &blank?(&1["label"])),
        do: ["a label row needs a label"],
        else: []

    duplicates =
      named
      |> Enum.map(& &1["label"])
      |> Enum.frequencies()
      |> Enum.filter(fn {label, count} -> count > 1 and label != @blank end)
      |> Enum.map(fn {label, _count} -> ~s(duplicate label "#{label}") end)
      |> Enum.sort()

    blank ++ duplicates
  end

  defp empty_row?(row), do: Enum.all?(["label" | @cells], &blank?(row[&1]))

  # Passed through when it is not a number so the loader names it: parsing
  # here would have to invent an error message the loader already has.
  defp number(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _other -> String.trim(value)
    end
  end

  # -- settings -> params -----------------------------------------------------

  defp int_params(settings) do
    Map.new(@all_int_fields, fn
      "retention_days" -> {"retention_days", int_string(get_in(settings, ["retention", "days"]))}
      field -> {field, int_string(settings[field])}
    end)
  end

  defp label_rows(settings) do
    min_score = as_map(settings["min_score"])
    track = as_map(settings["track"])
    record = as_map(settings["record"])
    per_label = as_map(get_in(settings, ["retention", "per_label"]))

    labels =
      [min_score, track, record, per_label]
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Kernel.--(["default"])
      |> Enum.sort()

    for label <- ["default" | labels] do
      %{
        "label" => label,
        "min_score" => score_string(min_score[label]),
        "track" => rule_string(track[label]),
        "record" => rule_string(record[label]),
        # Blank on `default` to match the cell the row no longer renders — see
        # `row_retention/1`.
        "retention_days" => if(label == "default", do: @blank, else: int_string(per_label[label]))
      }
    end
  end

  defp visible_url(url) when is_binary(url) do
    if CameraCards.credentialed?(url), do: @blank, else: url
  end

  defp visible_url(_absent), do: @blank

  defp url_user(url) when is_binary(url) do
    case url |> URI.parse() |> Map.get(:userinfo) do
      nil -> nil
      userinfo -> userinfo |> split_userinfo() |> elem(0) |> URI.decode()
    end
  end

  defp url_user(_absent), do: nil

  defp args_string(args) when is_list(args), do: Enum.join(args, " ")
  defp args_string(args) when is_binary(args), do: args
  defp args_string(_absent), do: @blank

  # `:short`, not two decimals: the cell is the value that gets saved back, so
  # rounding it would rewrite a 3-decimal threshold on an untouched save
  # (D-P5). Two decimals survive only as the inherited ghost.
  defp score_string(value) when is_float(value), do: :erlang.float_to_binary(value, [:short])
  defp score_string(value) when is_integer(value), do: score_string(value / 1)
  defp score_string(value) when is_binary(value), do: value
  defp score_string(_absent), do: @blank

  defp rule_string(%{"min_score" => score}), do: score_string(score)
  defp rule_string(value) when is_number(value), do: score_string(value)
  defp rule_string(_absent), do: @blank

  defp int_string(value) when is_integer(value), do: Integer.to_string(value)
  defp int_string(value) when is_binary(value), do: value
  defp int_string(_absent), do: @blank

  defp as_map(value) when is_map(value), do: value
  defp as_map(_other), do: %{}

  defp normalize_row(row) do
    Map.new(["label" | @cells], fn key -> {key, to_string(Map.get(row, key) || @blank)} end)
  end

  # The first row is the `default` block, whatever arrived: it is not
  # removable and its label is not editable, so nothing else can produce it.
  defp ensure_default_row([]), do: [blank_row("default")]
  defp ensure_default_row([first | rest]), do: [%{first | "label" => "default"} | rest]

  defp cell_of(rows, label, cell) do
    case Enum.find(rows, &(&1["label"] == label)) do
      nil -> @blank
      row -> row[cell]
    end
  end

  defp blank?(value), do: value in [nil, @blank]

  defp to_int(index) when is_integer(index), do: index

  defp to_int(index) do
    case Integer.parse(to_string(index)) do
      {int, _rest} -> int
      :error -> 0
    end
  end

  defp trimmed(params, key), do: params |> Map.get(key) |> to_string() |> String.trim()

  # -- error routing ----------------------------------------------------------

  defp strip_prefix(message, camera_id) do
    case message do
      "camera " <> rest -> String.replace_prefix(rest, "#{camera_id}: ", @blank)
      other -> other
    end
  end

  defp append(routed, key, message),
    do: Map.update(routed, key, [message], &(&1 ++ [message]))

  # A label is a detection class name and may hold spaces (`license plate`),
  # so the two `tier.label` forms capture up to the ` (value)` the loader
  # always writes after the label rather than up to the first space.
  defp route(message) do
    cond do
      # The one message that indicts a pair of cells rather than either.
      match = Regex.run(~r/\Atrack\.(.+?) \(.*effective record threshold/, message) ->
        [{Enum.at(match, 1), :row}]

      match = Regex.run(~r/\A(track|record)\.(.+?) \(/, message) ->
        [{Enum.at(match, 2), Enum.at(match, 1)}]

      match = Regex.run(~r/\A(min_score|track|record) values must .*\(([^)]*)\)\z/, message) ->
        for label <- String.split(Enum.at(match, 2), ", "), do: {label, Enum.at(match, 1)}

      match = Regex.run(~r/\A(\w+) \(([^)]+)\) must be a whole number\z/, message) ->
        [{Enum.at(match, 2), Enum.at(match, 1)}]

      String.starts_with?(message, "inline plugin") or String.contains?(message, "unknown plugin") ->
        ["plugin"]

      true ->
        first_word(message)
    end
  end

  defp first_word(message) do
    word = message |> String.split([" ", ":"], parts: 2) |> hd()

    # `id` is not a settings key, so no loader message starts with it — the
    # form's own "id has already been taken" does, and that is the field it
    # belongs under.
    if word in @text_fields or word in @all_int_fields or word in ["min_score", "id"],
      do: [word],
      else: []
  end

  # -- markup -----------------------------------------------------------------

  # Scaffold styling in the index page's voice; phase 7 replaces it wholesale.
  # Functions, not module attributes: `@name` inside a HEEx template reads an
  # assign, so an attribute could not be referenced from the markup at all.
  defp field_style, do: "display: flex; flex-direction: column; gap: 5px;"

  defp label_style,
    do: "display: flex; align-items: center; gap: 7px; font-size: 12px; color: var(--hs-fg-2);"

  defp input_style,
    do:
      "padding: 7px 9px; border-radius: 7px; border: 1px solid var(--hs-border); background: var(--hs-bg-sunken); color: var(--hs-fg-1); font-size: 13px; width: 100%; box-sizing: border-box;"

  defp group_style, do: "padding: 16px; display: flex; flex-direction: column; gap: 14px;"

  defp error_style,
    do: "font-size: 12px; color: var(--hs-danger); font-family: var(--hs-font-mono);"

  defp help_style, do: "font-size: 12px; color: var(--hs-fg-3);"

  defp heading_style, do: "margin: 0; font-size: 14px; font-weight: 600; color: var(--hs-fg-1);"

  attr :form, :any, required: true
  attr :rows, :list, required: true
  attr :mode, :string, required: true
  attr :field_errors, :map, required: true
  attr :form_errors, :list, required: true
  attr :plugins, :list, required: true
  attr :trackers, :list, required: true
  attr :known_labels, :list, required: true
  attr :probe, :map, required: true
  attr :saving, :boolean, required: true
  attr :restart_predicted, :boolean, required: true
  attr :camera_id, :string, required: true
  attr :password_gen, :integer, required: true

  def camera_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="camera-form"
      data-mode={@mode}
      phx-change="validate"
      phx-submit="save"
      style="display: flex; flex-direction: column; gap: 16px;"
    >
      <fieldset disabled={@saving} style="border: 0; margin: 0; padding: 0; min-width: 0;">
        <div style="display: flex; flex-direction: column; gap: 16px;">
          <.stream_fields
            form={@form}
            mode={@mode}
            field_errors={@field_errors}
            plugins={@plugins}
            password_gen={@password_gen}
          />
          <.tier_rows rows={@rows} field_errors={@field_errors} known_labels={@known_labels} />
          <.windows_fields form={@form} field_errors={@field_errors} />
          <.advanced form={@form} field_errors={@field_errors} trackers={@trackers} />
          <.probe_section probe={@probe} />
        </div>
      </fieldset>

      <div :if={@form_errors != []} id="camera-form-errors" class="hs-card" style={group_style()}>
        <div :for={error <- @form_errors} style={error_style()}>{error}</div>
      </div>

      <div style="display: flex; align-items: center; gap: 12px; flex-wrap: wrap;">
        <button
          id="camera-save"
          type="submit"
          class="hs-btn hs-btn--primary"
          phx-disable-with="Saving…"
          disabled={@saving}
        >
          {if @mode == "new", do: "Add camera", else: "Save camera"}
        </button>
        <span :if={@restart_predicted} style="font-size: 12px; color: var(--hs-warning);">
          Saving may restart {@camera_id} and clear its presence in Home Assistant
        </span>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :mode, :string, required: true
  attr :field_errors, :map, required: true
  attr :plugins, :list, required: true
  attr :password_gen, :integer, required: true

  defp stream_fields(assigns) do
    ~H"""
    <section class="hs-card" style={group_style()}>
      <h2 style={heading_style()}>Stream</h2>

      <div class="hs-field" style={field_style()}>
        <label for="camera-id" style={label_style()}>Camera id</label>
        <input
          id="camera-id"
          name="camera[id]"
          value={@form.params["id"]}
          readonly={@mode == "edit"}
          phx-debounce="300"
          style={input_style()}
        />
        <span style={help_style()}>
          lowercase letters, digits, <code>_</code>
          and <code>-</code>; it names this camera everywhere and cannot change later
        </span>
        <div :for={error <- errors_for(@field_errors, "id")} style={error_style()}>{error}</div>
      </div>

      <.text_field
        form={@form}
        field="rtsp_url"
        label="Main stream URL"
        field_errors={@field_errors}
        help={
          if @mode == "edit",
            do: "leave blank to keep the saved URL",
            else: "rtsp:// or any URL ffmpeg can open"
        }
      />
      <.text_field
        form={@form}
        field="substream_url"
        label="Sub stream URL"
        field_errors={@field_errors}
        help="optional; must be rtsp://"
      />
      <.text_field
        form={@form}
        field="username"
        label="Username"
        field_errors={@field_errors}
        help="composed into the stream URLs"
        rest={%{"autocomplete" => "off"}}
      />

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for={"camera-password-#{@password_gen}"} style={label_style()}>
          Password<.restart_chip />
        </label>
        <%!-- Never a value=: a saved credential is not rendered anywhere but
              the masked readout (the credential rule). `phx-update="ignore"`
              follows from that: with no value attribute to restore, the next
              patch (any keystroke elsewhere re-renders the form) would clear
              what the operator typed here before Save, and the camera would
              be saved without its password. The board walk caught exactly
              that. Ignored, the DOM keeps the typed value and the submit still
              carries it.

              Which is also why the id carries a generation: an ignored node is
              never patched, so without a new id the typed password would
              outlive the save that consumed it and ride along on the next,
              unrelated one. `CairnWeb.CamerasLive` bumps the generation
              wherever the form is re-initialized from a fresh row. --%>
        <input
          id={"camera-password-#{@password_gen}"}
          name="camera[password]"
          type="password"
          autocomplete="new-password"
          phx-update="ignore"
          phx-debounce="300"
          style={input_style()}
        />
        <span style={help_style()}>leave blank to keep</span>
      </div>

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for="camera-plugin" style={label_style()}>Detection plugin group<.restart_chip /></label>
        <select id="camera-plugin" name="camera[plugin]" style={input_style()}>
          <option value="" selected={@form.params["plugin"] in [nil, ""]}>no detection</option>
          <%!-- The saved group is an option whatever `@plugins` holds: a config
                server busy applying answers with `[]`, and a select with no
                option for the current value posts "" — an unrelated save would
                silently turn detection off. --%>
          <option
            :for={name <- plugin_options(@plugins, @form.params["plugin"])}
            value={name}
            selected={@form.params["plugin"] == name}
          >
            {name}
          </option>
        </select>
        <div :for={error <- errors_for(@field_errors, "plugin")} style={error_style()}>{error}</div>
      </div>

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for="camera-ingest" style={label_style()}>Ingest<.restart_chip /></label>
        <select id="camera-ingest" name="camera[ingest]" style={input_style()}>
          <option value="" selected={@form.params["ingest"] in [nil, ""]}>ffmpeg (default)</option>
          <option
            :for={value <- ~w(ffmpeg rtsp)}
            value={value}
            selected={@form.params["ingest"] == value}
          >
            {value}
          </option>
        </select>
        <span style={help_style()}>
          rtsp needs an rtsp:// URL and no transcode
        </span>
        <div :for={error <- errors_for(@field_errors, "ingest")} style={error_style()}>{error}</div>
      </div>

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for="camera-transcode" style={label_style()}>
          <%!-- The unchecked box sends nothing, so the hidden field is what
                turns transcode back off. --%>
          <input type="hidden" name="camera[transcode]" value="false" />
          <input
            id="camera-transcode"
            type="checkbox"
            class="hs-tog"
            name="camera[transcode]"
            value="true"
            checked={@form.params["transcode"] in ["true", "on", true]}
          /> Transcode to H.264<.restart_chip />
        </label>
      </div>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :field_errors, :map, required: true
  attr :known_labels, :list, required: true

  defp tier_rows(assigns) do
    ~H"""
    <section class="hs-card" style={group_style()}>
      <h2 style={heading_style()}>
        Detection thresholds
      </h2>
      <div style="display: grid; grid-template-columns: 1.4fr 1fr 1fr 1fr 0.8fr auto; gap: 8px; align-items: center; font-size: 12px; color: var(--hs-fg-3);">
        <span>Label</span>
        <span data-restart="true">Detect ≥<.restart_chip /></span>
        <span>Track ≥</span>
        <span>Record ≥</span>
        <span>Keep (days)</span>
        <span></span>
      </div>

      <fieldset
        id="camera-labels"
        style="border: 0; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px;"
      >
        <div
          :for={{row, n} <- Enum.with_index(@rows)}
          id={"label-row-#{n}"}
          data-label={row["label"]}
          data-error={row_error?(@field_errors, row) && "true"}
          style="display: flex; flex-direction: column; gap: 4px;"
        >
          <div style="display: grid; grid-template-columns: 1.4fr 1fr 1fr 1fr 0.8fr auto; gap: 8px; align-items: center;">
            <input
              aria-label={"detection label #{n}"}
              name={"camera[labels][#{n}][label]"}
              value={row["label"]}
              list="known-labels"
              readonly={n == 0}
              phx-debounce="300"
              style={input_style()}
            />
            <.cell rows={@rows} row={row} n={n} cell="min_score" field_errors={@field_errors} />
            <.cell rows={@rows} row={row} n={n} cell="track" field_errors={@field_errors} />
            <.cell rows={@rows} row={row} n={n} cell="record" field_errors={@field_errors} />
            <%!-- No days cell on the `default` row: the camera's own days are
                  the "Keep clips (days)" field below, and a per-label rule
                  named `default` would match no detection label at all. --%>
            <input
              :if={n > 0}
              aria-label={"#{row["label"]} keep days"}
              name={"camera[labels][#{n}][retention_days]"}
              value={row["retention_days"]}
              inputmode="numeric"
              phx-debounce="300"
              style={input_style()}
            />
            <span :if={n == 0} style={help_style()}>—</span>
            <button
              :if={n > 0}
              type="button"
              class="hs-btn hs-btn--sm"
              phx-click="remove-label-row"
              phx-value-index={n}
            >
              Remove
            </button>
            <span :if={n == 0}></span>
          </div>
          <div :for={error <- row_errors_of(@field_errors, row)} style={error_style()}>{error}</div>
        </div>

        <datalist id="known-labels">
          <option :for={label <- @known_labels} value={label}></option>
        </datalist>
        <div>
          <button type="button" class="hs-btn hs-btn--sm" phx-click="add-label-row">Add label</button>
        </div>
      </fieldset>
    </section>
    """
  end

  attr :rows, :list, required: true
  attr :row, :map, required: true
  attr :n, :integer, required: true
  attr :cell, :string, required: true
  attr :field_errors, :map, required: true

  defp cell(assigns) do
    assigns =
      assign(assigns,
        excluded: excluded?(assigns.rows, assigns.row, assigns.cell),
        ghost: inherited(assigns.rows, assigns.row, assigns.cell),
        errors: errors_for(assigns.field_errors, {assigns.row["label"], assigns.cell})
      )

    ~H"""
    <div style="display: flex; flex-direction: column; gap: 3px;">
      <%!-- The column heading is a symbol in a grid with no per-cell label, so
            the accessible name has to carry both the row and the column. --%>
      <input
        aria-label={"#{@row["label"]} #{column_name(@cell)} threshold"}
        name={"camera[labels][#{@n}][#{@cell}]"}
        value={@row[@cell]}
        inputmode="decimal"
        placeholder={@ghost}
        phx-debounce="300"
        style={input_style()}
      />
      <span
        :if={@excluded}
        class="hs-badge hs-badge--warning"
        title={"no #{@cell}: rule and no default — this label gets no #{if @cell == "track", do: "rows", else: "video"}"}
      >
        excluded
      </span>
      <span :for={error <- @errors} style={error_style()}>{error}</span>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field_errors, :map, required: true

  defp windows_fields(assigns) do
    ~H"""
    <section class="hs-card" style={group_style()}>
      <h2 style={heading_style()}>
        Windows &amp; retention
      </h2>
      <span style={help_style()}>blank inherits the global value</span>
      <.text_field
        form={@form}
        field="pre_window_seconds"
        label="Pre-event seconds"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="post_window_seconds"
        label="Post-event seconds"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="max_event_seconds"
        label="Max event seconds"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="retention_days"
        label="Keep clips (days)"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="annotation_offset_ms"
        label="Annotation offset (ms)"
        field_errors={@field_errors}
        help="±30000 ms"
      />
    </section>
    """
  end

  attr :form, :any, required: true
  attr :field_errors, :map, required: true
  attr :trackers, :list, required: true

  defp advanced(assigns) do
    ~H"""
    <%!-- The section's `open` is client-only state; `KeepOpen`
          (assets/js/hooks/keep_open.js) carries it across the patch every
          keystroke in this form causes. --%>
    <details id="camera-advanced" phx-hook="KeepOpen" class="hs-card" style={group_style()}>
      <summary style="font-size: 14px; font-weight: 600; color: var(--hs-fg-1); cursor: pointer;">
        Advanced
      </summary>

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for="camera-tracker" style={label_style()}>Tracker<.restart_chip /></label>
        <select id="camera-tracker" name="camera[tracker]" style={input_style()}>
          <option value="" selected={@form.params["tracker"] in [nil, ""]}>profile default</option>
          <option :for={name <- @trackers} value={name} selected={@form.params["tracker"] == name}>
            {name}
          </option>
        </select>
        <div :for={error <- errors_for(@field_errors, "tracker")} style={error_style()}>{error}</div>
      </div>

      <.text_field
        form={@form}
        field="max_live_tracks"
        label="Max live tracks"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="max_unseen_ms"
        label="Max unseen (ms)"
        field_errors={@field_errors}
      />
      <.text_field
        form={@form}
        field="stationary_after_ms"
        label="Stationary after (ms)"
        field_errors={@field_errors}
      />

      <div class="hs-field" data-restart="true" style={field_style()}>
        <label for="camera-motion_json" style={label_style()}>Motion gate (JSON)<.restart_chip /></label>
        <textarea
          id="camera-motion_json"
          name="camera[motion_json]"
          rows="4"
          phx-debounce="300"
          style={input_style() <> " font-family: var(--hs-font-mono);"}
        >{@form.params["motion_json"]}</textarea>
        <span style={help_style()}>
          Scene config for the motion gate, passed through as written. Restarts the camera.
        </span>
        <div :for={error <- errors_for(@field_errors, "motion_json")} style={error_style()}>
          {error}
        </div>
      </div>

      <.text_field
        form={@form}
        field="extra_ffmpeg_args"
        label="Extra ffmpeg arguments"
        field_errors={@field_errors}
        help="split on spaces — quotes are not honoured; restarts the camera"
      />
    </details>
    """
  end

  attr :probe, :map, required: true

  defp probe_section(assigns) do
    ~H"""
    <section class="hs-card" style={group_style()}>
      <div style="display: flex; align-items: center; gap: 12px;">
        <button id="camera-probe" type="button" class="hs-btn hs-btn--sm" phx-click="probe">
          Test stream
        </button>
        <span style={help_style()}>
          ffprobe opens the stream — up to 15 s
        </span>
      </div>
      <section id="probe-result" style="display: flex; flex-direction: column; gap: 8px;">
        <.probe_row id="probe-main" label="Main" result={@probe.main} />
        <.probe_row :if={@probe.sub.state != :absent} id="probe-sub" label="Sub" result={@probe.sub} />
      </section>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :result, :map, required: true

  defp probe_row(assigns) do
    ~H"""
    <div
      id={@id}
      data-state={@result.state}
      style="display: flex; align-items: center; gap: 8px; flex-wrap: wrap;"
    >
      <span style="font-size: 12px; color: var(--hs-fg-3); width: 40px;">{@label}</span>
      <span :if={@result.state == :idle} style={help_style()}>
        not probed yet
      </span>
      <span :if={@result.state == :running} style="font-size: 12px; color: var(--hs-fg-2);">
        Probing… up to 15 s
      </span>
      <span
        :for={chip <- @result.chips}
        class="tnum"
        style="padding: 3px 9px; border-radius: 6px; font-size: 12px; background: var(--hs-bg-sunken); color: var(--hs-fg-2); font-family: var(--hs-font-mono);"
      >
        {chip}
      </span>
      <span
        :if={@result.warning}
        class="hs-badge hs-badge--warning"
        title="Switch the camera to H.264 or enable transcode"
      >
        <span class="hs-dot"></span>not H.264
      </span>
      <span :if={@result.error} class="hs-badge hs-badge--danger">
        <span class="hs-dot"></span>Probe failed — {@result.error}
      </span>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :field, :string, required: true
  attr :label, :string, required: true
  attr :field_errors, :map, required: true
  attr :help, :string, default: nil
  attr :rest, :map, default: %{}

  defp text_field(assigns) do
    assigns = assign(assigns, restart: restart?(assigns.field))

    ~H"""
    <div class="hs-field" data-restart={@restart && "true"} style={field_style()}>
      <label for={"camera-#{@field}"} style={label_style()}>{@label}<.restart_chip :if={@restart} /></label>
      <input
        id={"camera-#{@field}"}
        name={"camera[#{@field}]"}
        value={@form.params[@field]}
        phx-debounce="300"
        style={input_style()}
        {@rest}
      />
      <span :if={@help} style={help_style()}>{@help}</span>
      <div :for={error <- errors_for(@field_errors, @field)} style={error_style()}>{error}</div>
    </div>
    """
  end

  defp restart_chip(assigns) do
    ~H"""
    <span class="hs-badge hs-badge--accent" style="font-size: 10px;">restarts camera</span>
    """
  end

  # The column's name in the operator's words, not the settings key's: the
  # heading over `min_score` reads "Detect ≥".
  defp column_name("min_score"), do: "detect"
  defp column_name(cell), do: cell

  defp plugin_options(plugins, current) when current in [nil, ""], do: plugins
  defp plugin_options(plugins, current), do: Enum.uniq(plugins ++ [current])

  # `data-error` marks the row when anything in it is wrong, cells included —
  # a cell error is rendered in its cell, but the row is what the operator
  # scans for.
  defp row_error?(field_errors, row) do
    Enum.any?([:row | @cells], &(errors_for(field_errors, {row["label"], &1}) != []))
  end

  # Row-level messages only: a cell's own error renders in the cell.
  defp row_errors_of(field_errors, row), do: errors_for(field_errors, {row["label"], :row})
end
