defmodule CairnWeb.CameraCards do
  @moduledoc """
  Readouts shared by every page that shows a camera: credential masking, the
  credential test the form's prefill rule reads, `Cairn.CameraStatus` probe
  chips, the status badge vocabulary and the `#save-result` card.

  `CairnWeb.CamerasLive` and `CairnWeb.CameraForm` render all of it; the
  config page's re-import card borrows `describe_write_error/1` and nothing
  else. Masking and the prefill rule are one decision rather than two that
  look alike: a URL `credentialed?/1` calls clean is rendered into a form
  field, so the two read the same `@credential_params`.
  """

  use CairnWeb, :html

  # Vendor spellings, not a taxonomy: a key here is masked in the readout and
  # keeps the URL out of the form's `value=`. Guessing wide is the cheap
  # direction — a misjudged non-secret is merely hidden.
  @credential_params ~w(password pass pwd passwd psw token access_token secret auth key
                        apikey api_key session user username)

  # Label and colour only. The dashboard tile keeps its own richer map: it
  # renders the full-area outage message and the pulse over live video, which
  # a list row deliberately does not.
  @status_meta %{
    connecting: %{label: "Connecting", color: "var(--hs-warning)"},
    running: %{label: "Running", color: "var(--hs-success)"},
    backoff: %{label: "Unreachable", color: "var(--hs-danger)"},
    stalled: %{label: "Stalled", color: "var(--hs-state-on)"},
    transcode_unavailable: %{label: "Transcode unavailable", color: "var(--hs-danger)"},
    unknown: %{label: "Unknown", color: "var(--hs-fg-3)"}
  }

  @doc """
  Masks `rtsp://user:secret@host/…`, `rtsp://secret@host/…` and
  `…?password=x&user=y` forms.
  """
  @spec mask_url(term()) :: String.t()
  def mask_url(url) when is_binary(url) do
    # The username may be empty (`rtsp://:secret@host`, which cameras that
    # authenticate on the password alone do accept), so `*` — requiring a
    # character there rendered the password in the clear.
    masked =
      url
      |> String.replace(~r/(\/\/[^:\/@]*:)[^@\/]+@/, "\\1•••••@")
      # `rtsp://SECRET@host` — userinfo with no colon is a password to some
      # cameras as readily as a username, and `credentialed?/1` already calls
      # it a credential; the whole of it goes. Never matches what the pass
      # above wrote: that leaves a colon in the userinfo.
      |> String.replace(~r/\/\/[^:\/@]+@/, "//•••••@")

    case String.split(masked, "?", parts: 2) do
      [base, query] -> base <> "?" <> mask_query(query)
      [base] -> base
    end
  end

  # A row's `rtsp_url` is whatever the column holds: a hand-edited or migrated
  # row can carry a number, which the loader skips and the page still has to
  # render. Nothing to mask reads as nothing to show — like `credentialed?/1`,
  # which calls the same value clean.
  def mask_url(_other), do: ""

  defp mask_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &mask_query_pair/1)
  end

  defp mask_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if credential_key?(key), do: "#{key}=•••••", else: pair

      _ ->
        pair
    end
  end

  # `?pass%77ord=` is the same key as `?password=` to the camera that reads
  # it, so the raw spelling is not what to compare: an escape anywhere in the
  # key would otherwise walk a credential past both the mask and the prefill
  # rule. A malformed escape has no decoding, and the raw key is then all
  # there is to judge — as is a well-formed one that decodes to invalid UTF-8
  # (`?pass%FFword=`), which `String.downcase/1` is free to refuse.
  defp credential_key?(key), do: normalize_key(key) in @credential_params

  defp normalize_key(key) do
    decoded = URI.decode_www_form(key)
    if String.valid?(decoded), do: String.downcase(decoded), else: downcase_raw(key)
  rescue
    ArgumentError -> downcase_raw(key)
  end

  # The raw key came out of a URI, so it is ASCII and this is total — the
  # rescue is the belt for a value that reached here some other way.
  defp downcase_raw(key) do
    String.downcase(key)
  rescue
    ArgumentError -> key
  end

  @doc """
  Whether the URL carries a credential — userinfo, or one of the query
  parameters `mask_url/1` masks. The form's prefill rule reads it: a
  credentialed URL is left blank rather than rendered (the credential rule).
  """
  @spec credentialed?(term()) :: boolean()
  def credentialed?(url) when is_binary(url) do
    uri = URI.parse(url)

    uri.userinfo != nil or
      Enum.any?(String.split(uri.query || "", "&"), fn pair ->
        pair |> String.split("=", parts: 2) |> hd() |> credential_key?()
      end)
  end

  def credentialed?(_other), do: false

  @doc """
  A rejected write's reason as one line an operator may see. Never
  `inspect/1`: a rejected changeset's `:changes` and an Ecto exception's
  message both carry the settings map, and with it the camera's password.
  Only the shapes named here say what went wrong; everything else is
  reported as unexpected and left to the log.
  """
  @spec describe_write_error(term()) :: String.t()
  def describe_write_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  def describe_write_error(%Ecto.InvalidChangesetError{changeset: changeset}),
    do: describe_write_error(changeset)

  def describe_write_error(%Ecto.ConstraintError{constraint: name}),
    do: "constraint #{name} failed"

  def describe_write_error(%DBConnection.ConnectionError{message: message}), do: message
  def describe_write_error(%Exqlite.Error{message: message}), do: message
  def describe_write_error(:not_found), do: "the camera no longer exists"
  def describe_write_error(:incomplete), do: "the fleet changed underneath the save"
  def describe_write_error(:no_cameras), do: "config.yml lists no cameras to import"

  def describe_write_error(:no_drift),
    do: "the cameras already match config.yml — nothing to import"

  def describe_write_error(:no_marker),
    do: "nothing was ever imported from config.yml, so there is nothing to replace"

  def describe_write_error({:bad_return, _other}), do: "the write returned an unexpected value"
  def describe_write_error(_other), do: "an unexpected error — see the log"

  @doc """
  A failed probe's reason as one line — `Cairn.Probe.run/2`'s four, plus the
  decode error its `parse/1` passes back. Never `inspect/1` either: a
  `Jason.DecodeError` holds ffprobe's own output, which quotes the
  credentialed URL it was given, and an exit reason holds whatever the raise
  was holding.
  """
  @spec describe_probe_error(term()) :: String.t()
  def describe_probe_error(:timeout), do: "timed out"
  def describe_probe_error({:ffprobe_exit, status}), do: "ffprobe exited #{status}"
  def describe_probe_error(:no_video_stream), do: "no video stream"
  def describe_probe_error(:unexpected_output), do: "ffprobe returned no readable stream info"
  def describe_probe_error(%Jason.DecodeError{}), do: "ffprobe returned no readable stream info"
  def describe_probe_error(_other), do: "the probe did not finish — see the log"

  @doc """
  A task's exit reason as one line for the log. An exit from a raise carries
  the exception and its stacktrace — and an Ecto exception carries the
  changeset, so the settings map — so only the exception's module and its
  safe description are logged; anything else is named by shape.
  """
  @spec describe_exit(term()) :: String.t()
  def describe_exit({%{__exception__: true} = e, _stacktrace}),
    do: "#{inspect(e.__struct__)}: #{describe_write_error(e)}"

  def describe_exit({reason, _stacktrace}) when is_atom(reason), do: inspect(reason)
  def describe_exit(reason) when is_atom(reason), do: inspect(reason)
  def describe_exit(_other), do: "an unexpected exit"

  @doc "The last probe result for a camera, or `nil` when it was never probed."
  @spec probe(map(), String.t()) :: map() | nil
  def probe(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:probe)
  end

  @doc "Codec / resolution / fps / profile chips; empty for a failed or absent probe."
  @spec probe_chips(map() | nil | {:error, term()}) :: [String.t()]
  def probe_chips(nil), do: []
  def probe_chips(%{error: _}), do: []
  # `Cairn.CameraStatus.set_probe/2` accepts a bare `{:error, reason}`, not
  # only an `%{error: _}` map — without this clause `probe[:codec]` below
  # raises `Protocol.UndefinedError` (tuples have no `Access` impl) and takes
  # `/cameras` down.
  def probe_chips({:error, _reason}), do: []

  def probe_chips(probe) when is_map(probe) do
    [
      probe[:codec],
      probe[:width] && probe[:height] && "#{probe.width}×#{probe.height}",
      probe[:fps] && "#{probe.fps} fps",
      probe[:profile]
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  # Belt-and-suspenders with the `{:error, _}` clause above: `probe[:codec]`
  # needs the `Access` protocol, which nothing else stored here implements.
  def probe_chips(_other), do: []

  @doc """
  Whether the camera streams something other than H.264 with no transcode to
  fix it — the pairing is what makes it a warning, since a transcoded camera
  is free to send anything.
  """
  @spec not_h264?(map(), String.t(), boolean()) :: boolean()
  def not_h264?(statuses, camera_id, transcode?) do
    case probe(statuses, camera_id) do
      %{codec: codec} when is_binary(codec) and codec != "h264" -> not transcode?
      _ -> false
    end
  end

  @spec transcode_unavailable?(map(), String.t()) :: boolean()
  def transcode_unavailable?(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status) == :transcode_unavailable
  end

  @spec status(map(), String.t()) :: atom()
  def status(statuses, camera_id) do
    statuses |> Map.get(camera_id, %{}) |> Map.get(:status) || :unknown
  end

  @doc "Label and colour for one of the six status values."
  @spec status_meta(atom()) :: %{label: String.t(), color: String.t()}
  def status_meta(status), do: Map.get(@status_meta, status, @status_meta.unknown)

  @doc """
  The `#save-result` card, shared by the list and the form so the two cannot
  drift: the four badge words come from the applied diff, never from what the
  form predicted. `phase` is `:applying` while the write is in flight and
  absent on the list, which has no in-flight card. `unconfirmed` marks a
  write that timed out rather than one that was rejected — the server may
  still be applying it, so the card withholds the reassurance below.
  """
  attr :result, :map, required: true

  def save_result(assigns) do
    ~H"""
    <section
      id="save-result"
      data-ok={to_string(@result.ok)}
      data-phase={@result[:phase]}
      class="hs-card"
      style={[
        "padding: 14px 16px; display: flex; flex-direction: column; gap: 10px; border-color: ",
        if(@result.ok, do: "var(--hs-success);", else: "var(--hs-danger);")
      ]}
    >
      <div
        :if={@result[:phase] == :applying}
        style="display: flex; align-items: center; gap: 8px; font-size: 14px; color: var(--hs-fg-2);"
      >
        <span class="ms" style="font-size: 19px;">hourglass_top</span>
        Applying — this can take up to 30 s while the camera restarts
      </div>
      <div
        :if={@result.ok and @result[:phase] != :applying}
        style="display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 600; color: var(--hs-success);"
      >
        <span class="ms" style="font-size: 19px;">check_circle</span>Saved — changes are live
      </div>
      <div :if={@result.diff} style="display: flex; gap: 6px; flex-wrap: wrap;">
        <span :for={id <- @result.diff.added} class="hs-badge hs-badge--success">
          <span class="hs-dot"></span>added {id}
        </span>
        <span :for={id <- @result.diff.removed} class="hs-badge hs-badge--danger">
          <span class="hs-dot"></span>removed {id}
        </span>
        <span :for={id <- @result.diff.changed} class="hs-badge hs-badge--accent">
          <span class="hs-dot"></span>restarted {id}
        </span>
        <%!-- "updated", not "restarted": a refreshed camera keeps its stream
              and its live tracks, which is what the operator sees. --%>
        <span :for={id <- @result.diff.refreshed} class="hs-badge">
          <span class="hs-dot"></span>updated {id}
        </span>
      </div>
      <div
        :if={@result.warnings != []}
        style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-warning);"
      >
        <div :for={w <- @result.warnings} style="display: flex; gap: 7px;">
          <span class="ms" style="font-size: 16px; flex: none; margin-top: 1px;">warning</span>{w}
        </div>
      </div>
      <div
        :if={!@result.ok}
        style="display: flex; align-items: center; gap: 8px; font-size: 14px; font-weight: 600; color: var(--hs-danger);"
      >
        <span class="ms" style="font-size: 19px;">error</span>We couldn't save that change
      </div>
      <div
        :if={@result.errors != []}
        style="display: flex; flex-direction: column; gap: 4px; font-size: 13px; color: var(--hs-danger); font-family: var(--hs-font-mono);"
      >
        <div :for={e <- @result.errors}>{e}</div>
      </div>
      <div
        :if={!@result.ok and !@result[:unconfirmed]}
        style="font-size: 13px; color: var(--hs-fg-2);"
      >
        Your previous config is still active — nothing changed.
      </div>
    </section>
    """
  end
end
