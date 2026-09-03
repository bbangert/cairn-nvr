defmodule Cairn.Cameras.Settings do
  @moduledoc """
  The translation between a camera row's canonical `settings` map and the flat
  params of the edit form, plus the routing of the loader's error strings back
  onto the fields that caused them.

  Pure: no socket, no repo. Both directions have to agree on "blank means
  inherit" for an untouched edit to round-trip through `Cairn.Cameras.canonical/1`
  to the same map — that identity is what makes a save with no edits diff to
  nothing (plan D-P5).

  Nothing here validates thresholds, URLs or JSON: `Cairn.Config.from_map/1`
  is the one validator, so a cell this module cannot read as a number is
  passed through unchanged for the loader to name. `field_errors/3` then puts
  the loader's own string back under the field it names. The exception is a
  saved value no field can hold at all — a map where a string belongs, on a
  row the loader skipped for that very reason: it opens blank, because
  rendering it is what the operator came to undo (`scalar_param/1`).
  """

  alias Cairn.Cameras.Camera
  alias Cairn.Config
  alias Cairn.StreamUrl

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

  # Every settings key this module can write, plus `pipeline`, which it
  # deliberately can't: the form has no field for it, and `"membrane"` (the
  # only accepted value) is already a no-op `Cairn.Cameras.canonical/1`
  # drops, so a save can only ever *drop* the key, never restore it. Listing
  # it here rather than leaving it modelled-by-omission is what makes an
  # edit repair a row stuck on the removed `"classic"` value — omitted, it
  # would have ridden through `Map.drop` untouched like a real unmodelled
  # key. A saved key genuinely outside this list — one a future release adds
  # before the form does — is carried through an edit rather than dropped by
  # it, so a save the operator did not aim at that key leaves it alone. `id`
  # and `zones` are excluded because they are columns of their own, not
  # settings.
  @modelled_keys ~w(rtsp_url substream_url plugin ingest tracker motion_json transcode
                    extra_ffmpeg_args retention min_score track record id zones pipeline) ++
                   @int_fields

  # The chip's set. `Cairn.Config.Server.restart_fields/0` is what a running
  # camera cannot take in place; the five added here restart for reasons that
  # module cannot see — the resolved compares in its camera diff
  # (`pre_window_seconds`, `tracker`, `max_live_tracks`) and the credentials,
  # which are spliced into `rtsp_url`.
  @extra_restart_fields ~w(pre_window_seconds tracker max_live_tracks username password)

  @doc "The form fields whose change restarts the camera."
  @spec restart_fields() :: [String.t()]
  def restart_fields do
    Enum.map(Config.Server.restart_fields(), &to_string/1) ++ @extra_restart_fields
  end

  @spec restart?(String.t()) :: boolean()
  def restart?(field), do: field in restart_fields()

  @doc """
  Whether saving `new` over `saved` restarts the camera's tree: one of
  `restart_fields/0` — a value baked into a subprocess or a child spec at tree
  birth — moved. A camera with no saved settings is being added, not
  restarted.

  Raw settings maps, so this is a prediction and not the diff: a resolved
  input the camera does not carry itself (`sample_fps`, the tier, the rung)
  can restart a camera whose own settings did not move, and only the config
  server sees those (PR B's resolved form).
  """
  @spec would_restart?(map() | nil, map()) :: boolean()
  def would_restart?(nil, _new), do: false

  def would_restart?(saved, new) do
    fields = restart_fields()
    Map.take(saved, fields) != Map.take(new, fields)
  end

  @doc """
  A saved row rendered as form params. A saved credential is never among
  them: the password field is always empty and a URL that carries a
  credential is blank, with the readout the only place it appears.
  """
  @spec to_params(Camera.t() | nil) :: map()
  def to_params(row) do
    settings = if row, do: row.settings, else: %{}

    %{
      "id" => (row && row.id) || @blank,
      "plugin" => scalar_param(settings["plugin"]),
      "ingest" => scalar_param(settings["ingest"]),
      "transcode" => if(settings["transcode"] == true, do: "true", else: "false"),
      "tracker" => scalar_param(settings["tracker"]),
      "motion_json" => scalar_param(settings["motion_json"]),
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
      "username" => StreamUrl.user(url) || StreamUrl.user(sub) || @blank,
      "password" => @blank
    }
  end

  @doc """
  Form params reduced to the shape the rest of this module assumes.

  Params are client-controlled: Phoenix decodes any bracketed input name into
  nested maps/lists, so a crafted `camera[id][x]=y` or
  `camera[labels][0][min_score][x]=y` arrives as a map where every caller
  downstream assumes a scalar and raises. Every top-level value is forced to a
  binary except `labels`, which is walked into the row/cell shape those
  callers expect — anything that isn't already that shape is dropped rather
  than coerced, since there is no sane string to fall back to for a whole row.
  """
  @spec sanitize_params(map()) :: map()
  def sanitize_params(params) when is_map(params) do
    Map.new(params, fn
      {"labels", value} -> {"labels", sanitize_labels(value)}
      {key, value} when is_binary(value) -> {key, value}
      {key, _other} -> {key, @blank}
    end)
  end

  defp sanitize_labels(labels) when is_map(labels) do
    labels
    |> Enum.filter(fn {_index, row} -> is_map(row) end)
    |> Map.new(fn {index, row} -> {index, sanitize_row(row)} end)
  end

  defp sanitize_labels(_other), do: %{}

  defp sanitize_row(row) do
    row |> Enum.filter(fn {_cell, value} -> is_binary(value) end) |> Map.new()
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
  `clear_substream` is one way past that keep: checked, `substream_url` is
  omitted whatever the field holds. `clear_credentials` is another: checked,
  the username/password fields are ignored and userinfo comes off both URLs
  instead of being spliced in.
  """
  @spec to_settings(map(), Camera.t() | nil) :: {:ok, map()} | {:error, [String.t()]}
  def to_settings(params, saved \\ nil) do
    # Sanitized here, not only by the caller: a crafted nested value
    # (`camera[rtsp_url][x]=y`) would otherwise reach `to_string/1` and raise.
    params = sanitize_params(params)
    rows = rows(params)
    saved_settings = if saved, do: saved.settings, else: %{}

    with [] <- row_errors(rows),
         {:ok, ints} <- parse_ints(params),
         {:ok, per_label} <- row_retention(rows, saved_settings) do
      {:ok, build_settings(params, rows, ints, per_label, saved_settings)}
    else
      {:error, errors} -> {:error, errors}
      errors when is_list(errors) -> {:error, errors}
    end
  end

  @doc """
  The URLs a probe should open: the form's, composed with the credentials,
  falling back to the saved row's for a field the credential rule left blank.
  These carry the password, so they are probed and never rendered — unless
  `clear_credentials` is ticked, in which case there is no password left to
  carry.
  """
  @spec urls(map(), Camera.t() | nil) :: %{main: String.t() | nil, sub: String.t() | nil}
  def urls(params, saved) do
    params = sanitize_params(params)
    settings = if saved, do: saved.settings, else: %{}

    # The same rule a save applies: a ticked "Remove sub stream" means no sub
    # stream to probe either, and a ticked "Remove saved username and
    # password" (read inside `put_url/4` via `resolve_url/4`) means neither
    # URL probed here carries one.
    composed = %{} |> put_url("rtsp_url", params, settings) |> put_substream(params, settings)

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

  `labels` are the form's own row labels, and they are what resolves a label
  out of a message: a detection class name may hold spaces, `", "` (a class
  literally named "a, b") or parentheses (`person (adult)`), so neither the
  loader's `", "` join nor its ` (value)` suffix can be read off the text
  alone. Both are walked against the known labels, longest first; anything
  they cannot fully account for leaves the message unclaimed rather than
  routed to a wrong key.
  """
  @spec field_errors([String.t()], String.t(), [String.t()]) :: {map(), [String.t()]}
  def field_errors(errors, camera_id, labels) do
    {per_camera, fleet} = Config.partition_by_camera(errors)

    # Another camera's error is fleet-level as far as this form is concerned:
    # it can refuse the save and there is no field here to hang it on.
    others = per_camera |> Map.delete(camera_id) |> Enum.flat_map(fn {_id, msgs} -> msgs end)

    {routed, unclaimed} =
      per_camera
      |> Map.get(camera_id, [])
      |> Enum.map(&strip_prefix(&1, camera_id))
      |> Enum.reduce({%{}, []}, fn message, {routed, unclaimed} ->
        case route(message, labels) do
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
    |> put_substream(params, saved)
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
  #
  # Only a list of binaries earns that: `args_string/1` renders a non-string
  # element blank, so a malformed saved `["-x", %{}]` matches its own text and
  # would be restored verbatim from a field that looked valid — a save the
  # validator then rejects with no field to fix. Re-splitting the text is the
  # repair the operator opened the form for.
  defp put_args(acc, params, saved) do
    text = Map.get(params, "extra_ffmpeg_args") || @blank
    saved_args = saved["extra_ffmpeg_args"]

    if is_list(saved_args) and Enum.all?(saved_args, &is_binary/1) and
         text == args_string(saved_args) do
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

  # A blank URL field keeps the saved URL (the credential rule blanks it on
  # purpose), so a sub stream cannot be removed by clearing the field —
  # "Remove sub stream" is the act that drops the key, whatever the field
  # holds. Omitted, not written empty: absent is how the parser reads "no sub
  # stream".
  defp put_substream(acc, params, saved) do
    if trimmed(params, "clear_substream") in ["true", "on"],
      do: acc,
      else: put_url(acc, "substream_url", params, saved)
  end

  defp put_url(acc, key, params, saved) do
    typed = trimmed(params, key)
    base = if typed == @blank, do: saved[key], else: typed

    case base do
      url when is_binary(url) and url != @blank ->
        Map.put(acc, key, resolve_url(url, key, params, saved))

      _absent ->
        acc
    end
  end

  # "Remove saved username and password" bypasses the whole credential splice:
  # checked, the username/password fields are not read at all (there is no
  # "typed new credential" to honour in the same save that asked for the
  # saved one gone), and only the credential comes off whichever URL — typed
  # or carried from the saved row — `put_url/4` resolved as the base. Both
  # forms go, the userinfo and the query pairs the mask recognizes, through
  # the one helper that defines the key set.
  defp resolve_url(url, key, params, saved) do
    if clear_credentials?(params) do
      StreamUrl.strip_credentials(url)
    else
      credentialed(url, key, params, saved)
    end
  end

  defp clear_credentials?(params), do: trimmed(params, "clear_credentials") in ["true", "on"]

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
  # A retyped URL on the saved camera (a corrected path, still bare of its own
  # credential — `seed_userinfo/2` refuses a new host) is seeded with the
  # saved URL's userinfo *before* the fields are spliced in — not left to the
  # final fallback below — so it lands in the first branch above like any
  # other URL that already carries one: a changed username
  # replaces only the username and a blank password keeps the saved one,
  # instead of the splice reading "no userinfo yet" and dropping the saved
  # password outright. A retyped URL whose saved counterpart carried its
  # credential in the query instead (the FLV form) gets that carried the same
  # way, so it lands in the `credentialed?/1` branch below rather than
  # silently losing the credential to a save nobody meant to touch it.
  defp credentialed(url, key, params, saved) do
    # Not trimmed, like the password: `Cairn.StreamUrl.user/1` decodes the
    # saved userinfo verbatim, spaces included, and an untouched edit
    # re-derives `user` from this same field — trimming here would rewrite a
    # saved `%20user` credential's URL on a save nobody edited (D-P5).
    user = Map.get(params, "username") || @blank
    pass = password(params)
    seeded = seed_userinfo(url, saved[key])

    cond do
      StreamUrl.userinfo(seeded) != nil ->
        StreamUrl.compose(seeded, if(given_user?(user, saved), do: user, else: @blank), pass)

      # `seeded`, not `url`: the FLV form's credential can have arrived via
      # `seed_userinfo/2`'s query-pair carry rather than already being on the
      # typed URL, and only `seeded` reflects that.
      StreamUrl.credentialed?(seeded) ->
        seeded

      pass != @blank or given_user?(user, saved) ->
        StreamUrl.compose(url, user, pass)

      true ->
        url
    end
  end

  # A URL that already carries its own credential (userinfo, or the FLV query
  # form `Cairn.StreamUrl.credentialed?/1` reads) is left untouched — seeding
  # it with the saved URL's credential would either overwrite a credential the
  # operator just typed into the URL itself, or bolt a second one onto a URL
  # that already carries its own. A URL with neither takes whichever form the
  # saved URL carried: userinfo, or the recognized query pairs — the FLV form
  # has no userinfo slot to seed, so its credential rides to the retyped URL
  # as a query carry instead.
  #
  # Only onto the same endpoint. The case worth carrying for is a corrected
  # path on the camera the credential belongs to; a retyped *host* is a
  # different camera, and with no auth in front of this form, seeding there
  # would hand the saved secret to whatever host the submitter names. A new
  # host gets a bare URL and the operator types the password again.
  defp seed_userinfo(url, saved_url) do
    if StreamUrl.userinfo(url) == nil and not StreamUrl.credentialed?(url) and
         StreamUrl.same_endpoint?(url, saved_url) do
      url |> carry_userinfo(saved_url) |> carry_credential_query(saved_url)
    else
      url
    end
  end

  # Copied verbatim: what is on the saved URL is already percent-encoded, and
  # re-encoding it would change the credential.
  defp carry_userinfo(url, saved_url) do
    case StreamUrl.userinfo(saved_url) do
      nil ->
        url

      userinfo ->
        {scheme, _own, rest} = StreamUrl.split_authority(url)
        StreamUrl.join_authority(scheme, userinfo, rest)
    end
  end

  # Runs after `carry_userinfo/2`, so a saved userinfo credential has already
  # landed on `url` and made it `credentialed?/1` — this only fires for a
  # saved URL whose credential rode in the query instead, the case
  # `carry_userinfo/2` cannot carry. Same verbatim-pairs rule: the saved
  # query's `key=value` text is already encoded.
  defp carry_credential_query(url, saved_url) do
    if StreamUrl.credentialed?(url) do
      url
    else
      case StreamUrl.credential_query_pairs(saved_url) do
        [] -> url
        pairs -> append_query(url, pairs)
      end
    end
  end

  defp append_query(url, pairs) do
    {scheme, userinfo, rest} = StreamUrl.split_authority(url)
    uri = URI.parse(rest)
    added = Enum.join(pairs, "&")
    merged = if uri.query in [nil, @blank], do: added, else: uri.query <> "&" <> added

    StreamUrl.join_authority(scheme, userinfo, URI.to_string(%{uri | query: merged}))
  end

  defp given_user?(@blank, _saved), do: false

  defp given_user?(user, saved),
    do: user != (StreamUrl.user(saved["rtsp_url"]) || StreamUrl.user(saved["substream_url"]))

  # Not trimmed: a password may legitimately begin or end with a space.
  defp password(params), do: Map.get(params, "password") || @blank

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
  #
  # A saved `per_label["default"]` is nonetheless carried through untouched
  # (`carry_saved_default/2`): it is not the camera's days at all but a rule
  # for a detection label that happens to be spelled "default", which the row
  # this function reads from has no cell for and so can neither see nor
  # clear. Dropping it on every edit would quietly delete that rule the first
  # time an operator touched anything else on the camera.
  defp row_retention(rows, saved) do
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

    if errors == [],
      do: {:ok, carry_saved_default(per_label, saved)},
      else: {:error, Enum.reverse(errors)}
  end

  defp carry_saved_default(per_label, saved) do
    # Through `as_map/1` at every level: a hand-edited row can hold a scalar
    # where a block belongs, and `get_in/2` raises on it.
    case saved
         |> Map.get("retention")
         |> as_map()
         |> Map.get("per_label")
         |> as_map()
         |> Map.get("default") do
      nil -> per_label
      days -> Map.put(per_label, "default", days)
    end
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
      "retention_days" -> {"retention_days", int_string(retention(settings)["days"])}
      field -> {field, int_string(settings[field])}
    end)
  end

  defp label_rows(settings) do
    min_score = as_map(settings["min_score"])
    track = as_map(settings["track"])
    record = as_map(settings["record"])
    per_label = as_map(retention(settings)["per_label"])

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
        # `row_retention/2`.
        "retention_days" => if(label == "default", do: @blank, else: int_string(per_label[label]))
      }
    end
  end

  defp visible_url(url) when is_binary(url) do
    if StreamUrl.credentialed?(url), do: @blank, else: url
  end

  defp visible_url(_absent), do: @blank

  defp args_string(args) when is_list(args), do: Enum.map_join(args, " ", &scalar_param/1)
  defp args_string(args) when is_binary(args), do: args
  defp args_string(_absent), do: @blank

  # The rows this has to survive are exactly the rows the loader skipped: a
  # `plugin` that is a map or a `tracker` that is a list is why the row was
  # refused, and the operator can only repair it by opening the form —
  # `to_string/1` on one of those raises on the way to the input's `value=`.
  defp scalar_param(value) when is_binary(value), do: value
  defp scalar_param(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp scalar_param(_other), do: @blank

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

  # A scalar or list where the block belongs is a skipped row the operator
  # must be able to open; it reads as an empty block.
  defp retention(settings), do: settings |> Map.get("retention") |> as_map()

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

  defp route(message, labels) do
    cond do
      # The one message that indicts a pair of cells rather than either.
      match = Regex.run(~r/\Atrack\.(.+?) \(.*effective record threshold/, message) ->
        [{tier_label(message, "track", Enum.at(match, 1), labels), :row}]

      match = Regex.run(~r/\A(track|record)\.(.+?) \(/, message) ->
        cell = Enum.at(match, 1)
        [{tier_label(message, cell, Enum.at(match, 2), labels), cell}]

      # Lazy up to the *first* `(`, then everything to the last `)`: the
      # parenthesized label list is what a label with parentheses of its own
      # (`person (adult)`) would otherwise be cut in half by.
      match = Regex.run(~r/\A(min_score|track|record) values must .*?\((.*)\)\z/, message) ->
        joined_labels(Enum.at(match, 1), Enum.at(match, 2), labels)

      match = Regex.run(~r/\A(\w+) \((.+)\) must be a whole number\z/, message) ->
        field = Enum.at(match, 1)
        [{days_label(message, field, Enum.at(match, 2), labels), field}]

      String.starts_with?(message, "retention.") ->
        retention_route(message, labels)

      String.starts_with?(message, "inline plugin") or String.contains?(message, "unknown plugin") ->
        ["plugin"]

      true ->
        first_word(message)
    end
  end

  # A label is a detection class name and may hold spaces (`license plate`) or
  # parentheses (`person (adult)`), so the ` (value)` the loader always writes
  # after the label is not the *first* ` (` in the message. The known row
  # labels decide, longest first; the regex's own shortest reading stands only
  # for a label with no row, which cannot be shown in place anyway.
  defp tier_label(message, cell, fallback, labels) do
    rest = String.replace_prefix(message, cell <> ".", @blank)
    longest_label(rest, labels, " (") || fallback
  end

  # Same rule for `retention_days (label) must be a whole number`, which this
  # module writes itself: the greedy capture already spans a parenthesized
  # label, and a known label confirms where it ends.
  defp days_label(message, field, fallback, labels) do
    rest = String.replace_prefix(message, field <> " (", @blank)
    longest_label(rest, labels, ") must be a whole number") || fallback
  end

  # The loader's camera-level retention messages (`Cairn.Config.Camera`): the
  # whole block is this form's `retention_days` field, except a per-label
  # bound, which names its label the way the tier messages above do and lands
  # on that row's cell.
  defp retention_route(message, labels) do
    case Regex.run(~r/\Aretention\.per_label \((.+)\) must be /, message) do
      nil -> ["retention_days"]
      match -> [{per_label_days_label(message, Enum.at(match, 1), labels), "retention_days"}]
    end
  end

  defp per_label_days_label(message, fallback, labels) do
    rest = String.replace_prefix(message, "retention.per_label (", @blank)
    longest_label(rest, labels, ") must be ") || fallback
  end

  defp longest_label(rest, labels, following) do
    labels
    |> Enum.sort_by(&(-String.length(&1)))
    |> Enum.find(&String.starts_with?(rest, &1 <> following))
  end

  defp joined_labels(cell, joined, labels) do
    case match_labels(joined, labels) do
      {:ok, matched} -> for label <- matched, do: {label, cell}
      :error -> []
    end
  end

  # Consumes `joined` against the known row labels, longest first, so a label
  # that itself contains `", "` (a detection class literally named "a, b") is
  # matched whole before a shorter label that happens to be its prefix. Any
  # leftover the known labels cannot account for is `:error` — a partial
  # match would route half a message to a real row and silently drop the
  # rest, which is worse than leaving the whole message unclaimed.
  defp match_labels(joined, labels) do
    sorted = Enum.sort_by(labels, &(-String.length(&1)))
    consume_labels(joined, sorted, [])
  end

  defp consume_labels(@blank, _labels, acc), do: {:ok, Enum.reverse(acc)}

  defp consume_labels(rest, labels, acc) do
    case Enum.find(labels, &String.starts_with?(rest, &1)) do
      nil ->
        :error

      label ->
        case String.replace_prefix(rest, label, @blank) do
          @blank -> consume_labels(@blank, labels, [label | acc])
          ", " <> more -> consume_labels(more, labels, [label | acc])
          _other -> :error
        end
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
end
