defmodule Cairn.StreamUrl do
  @moduledoc """
  A camera's stream URL as a string: where its credential begins and ends,
  how to hide it, strip it, read it back and splice a new one in.

  One module rather than one per caller because masking, stripping and the
  form's credential splice have to agree about where a credential ends — a
  disagreement renders half a password, or rewrites the host.
  """

  # Vendor spellings, not a taxonomy: a key here is masked in the readout and
  # keeps the URL out of the form's `value=`. Guessing wide is the cheap
  # direction — a misjudged non-secret is merely hidden.
  @credential_params ~w(password pass pwd passwd psw token access_token secret auth key
                        apikey api_key session user username)

  @blank ""

  @doc """
  A URL split into everything up to and including `//`, its userinfo, and the
  host onward — the one place the userinfo boundary is decided, so masking,
  stripping and the form's credential splice cannot disagree about where a
  credential ends.

  The boundary is the **last** `@` before the first `/`, `?` or `#`, not the
  first: a hand-edited or imported password can itself contain a raw `@`
  (`rtsp://user:sec@ret@host/s`), and `URI.parse/1` splits at the first one —
  which masks half a password, strips half a password, and rewrites the host
  as `ret@host`. Anything past that boundary is `rest`, so an `@` in a path or
  query is left alone. A URL whose `//` opens no authority (`open_authority/1`)
  has none to split.

  Two shapes this cannot resolve, both of which report no userinfo here and so
  would be rendered in full: a raw `/` inside a userinfo (it ends the authority
  before any `@` is seen) and a URL with no authority opener (there is no
  authority to look in). Both are *ambiguous* rather than bare — see
  `ambiguous?/1` and the wider `display_ambiguous?/1`, which the readout,
  prefill and splice paths consult and this function does not.
  """
  @spec split_authority(String.t()) :: {String.t(), String.t() | nil, String.t()}
  def split_authority(url) when is_binary(url) do
    case open_authority(url) do
      {scheme, authority_onward} ->
        {authority, tail} = split_at_path(authority_onward)

        case last_at(authority) do
          nil -> {scheme, nil, authority_onward}
          {userinfo, host} -> {scheme, userinfo, host <> tail}
        end

      :none ->
        {@blank, nil, url}
    end
  end

  @doc "The inverse of `split_authority/1`."
  @spec join_authority(String.t(), String.t() | nil, String.t()) :: String.t()
  def join_authority(scheme, nil, rest), do: scheme <> rest
  def join_authority(scheme, userinfo, rest), do: scheme <> userinfo <> "@" <> rest

  # `{everything up to and including the `//`, the rest}`, or `:none` when no
  # `//` in the URL opens an authority.
  #
  # Only a `//` reached with nothing but a scheme in front of it opens one: a
  # path or a query has to have not started, so anything before it holding a
  # `/`, `?` or `#` disqualifies it. Splitting on the first `//` alone read
  # `rtsp:/broken?next=http://cam/live&password=x` as authority
  # `cam/live&password=x` — which put the real query out of every reader's
  # reach, so `credentialed?/1` called the row clean and the form rendered the
  # secret. A URL with no opener has no authority at all and takes the
  # fail-closed path: display-ambiguous on any `@` it holds, and its query —
  # the whole string, since none of it was eaten by a false authority — masked
  # by the ordinary pair rule.
  #
  # The prefix must be nothing or a scheme (`rtsp:`), not merely free of those
  # three characters: `rtsp:user:SECRET@//host/live` would otherwise open an
  # authority at `host` with the credential sitting outside every reader.
  defp open_authority(url) do
    case String.split(url, "//", parts: 2) do
      [prefix, onward] ->
        if prefix == @blank or Regex.match?(~r/^[A-Za-z][A-Za-z0-9+.-]*:$/, prefix),
          do: {prefix <> "//", onward},
          else: :none

      [_no_authority] ->
        :none
    end
  end

  defp split_at_path(authority_onward) do
    case :binary.match(authority_onward, ["/", "?", "#"]) do
      {at, _len} -> String.split_at(authority_onward, at)
      :nomatch -> {authority_onward, ""}
    end
  end

  defp last_at(authority) do
    case authority |> :binary.matches("@") |> List.last() do
      nil ->
        nil

      {at, _len} ->
        {binary_part(authority, 0, at),
         binary_part(authority, at + 1, byte_size(authority) - at - 1)}
    end
  end

  @doc """
  Whether the URL holds an `@` that `split_authority/1` reads as no credential
  at all, or that it reads as an ordinary userinfo boundary but that a
  password containing both a raw `@` and a raw `/` would produce the same way.

  Three shapes fail closed, all on the same reasoning: an `@` past the
  authority's first `/` is indistinguishable from a userinfo's password
  running on past that `/` and ending at a *later* `@` instead —

    * no `@` in the authority itself (`rtsp://u:pa/ss@cam.lan/main`) — the
      apparent authority has no credential at all, but a password holding a
      raw `/` reads exactly this way;
    * an `@` in the authority AND another `@` after its first `/`
      (`rtsp://u:sec@ret/part@host/live`) — this reads as ordinary userinfo
      `u:sec` at host `ret`, but a password `sec@ret/part` produces the
      identical bytes;
    * anywhere before a `?`/`#` in a URL where no `//` opens an authority
      (`rtsp:/user:secret@host/live`, a malformed stored value).

  A hand-typed or imported password really does contain a raw slash
  sometimes, and there is no way to tell that URL from an ordinary one whose
  *path* holds an `@` — bare, or already read as userinfo@host. Either guess
  is wrong half the time and a wrong guess renders half a password or points
  a stripped/composed URL at the wrong authority, so every such reading is
  refused: everything from `//` through the LAST such `@` is treated as
  credential — masked whole, never spliced into, stripped entire. The cost is
  wider now than the first two shapes alone: a bare URL with an `@` in its
  path, or a *normal* userinfo URL whose path independently holds an `@`,
  both now open blank in the form and get retyped — the same repair path a
  row this module cannot read already takes. Guessing wide is the cheap
  direction (see `@credential_params`'s note): a wrongly-blanked ordinary URL
  costs a retype, a wrongly-read password costs a leaked or truncated secret.

  This is the *structural* rule, and it stops at a `?` or `#`: past one an
  `@` really is a query or fragment character, `?x=me@h` is ordinary text, and
  `strip_credentials/1` — the one caller that rewrites the URL — must not cut
  a stored URL apart at somebody's email address. The readout, the prefill and
  the splice run on the wider `display_ambiguous?/1` instead.
  """
  @spec ambiguous?(term()) :: boolean()
  def ambiguous?(url) when is_binary(url), do: ambiguous_split(url) != nil
  def ambiguous?(_other), do: false

  @doc """
  Whether the URL holds an `@` that could be terminating a userinfo, read as
  widely as a display decision can afford: any `@` after `//` and beyond the
  readable authority counts, a `?` or `#` in between included.

  A raw `?` or `#` inside a password puts the *readable* authority's end
  there — `rtsp://u:pa?ss@cam.lan/main` (password `pa?ss`) reads as authority
  `u:pa` holding no `@` at all — so the structural rule of `ambiguous?/1`
  calls that URL bare, which renders the password in the readout and prefills
  it into the form. Under this rule everything such an `@` could be hiding
  goes: `mask/1` covers `//` through the URL's LAST `@`, `credentialed?/1` is
  true, `user/1` and `userinfo/1` offer nothing, and `compose/3` refuses to
  splice.

  Display fails closed wider than mutation on purpose. The cost is a
  legitimate `@` in a query value (`?x=me@h`) over-masked, so that row opens
  blank and gets retyped — guessing wide is the cheap direction (see
  `@credential_params`'s note) where the cost is a retype. In a rewrite it
  would be data loss instead, which is why `strip_credentials/1` keeps the
  structural rule and leaves that query value alone.
  """
  @spec display_ambiguous?(term()) :: boolean()
  def display_ambiguous?(url) when is_binary(url), do: display_split(url) != nil
  def display_ambiguous?(_other), do: false

  # `{scheme, everything after the URL's last @}`, or `nil` when no `@` sits
  # beyond the readable authority.
  defp display_split(url) do
    case open_authority(url) do
      {scheme, onward} ->
        {_authority, tail} = split_at_path(onward)

        if :binary.match(tail, "@") != :nomatch, do: last_at_anywhere(scheme, onward)

      # Nothing opened an authority, so every `@` in the string is beyond one.
      :none ->
        last_at_anywhere(@blank, url)
    end
  end

  # `{scheme, everything after the last ambiguous @}`, or `nil` when the URL
  # reads unambiguously.
  defp ambiguous_split(url) do
    case open_authority(url) do
      {scheme, onward} ->
        {authority, tail} = split_at_path(onward)

        if last_at(authority) == nil or at_past_slash?(tail) do
          last_at_before_query(scheme, onward)
        end

      # No authority, so `split_authority/1` finds no userinfo and every reader
      # would treat the whole string as bare. An `@` in it is a credential
      # boundary as good as any other, and the scheme is not worth preserving
      # in a URL already malformed enough to reach here.
      :none ->
        last_at_before_query(@blank, url)
    end
  end

  # Whether `tail` — everything from the authority's first `/` onward — holds
  # an `@` before any `?`/`#`. True here is ambiguous regardless of whether
  # the authority in front of `tail` already parsed as an ordinary
  # userinfo@host: that reading and a password holding a raw `@` *and* a raw
  # `/` produce the same bytes, and this module cannot tell them apart.
  defp at_past_slash?(tail) do
    String.starts_with?(tail, "/") and
      case :binary.match(tail, ["?", "#"]) do
        {at, _len} -> :binary.match(binary_part(tail, 0, at), "@") != :nomatch
        :nomatch -> :binary.match(tail, "@") != :nomatch
      end
  end

  defp last_at_before_query(scheme, onward) do
    head =
      case :binary.match(onward, ["?", "#"]) do
        {at, _len} -> binary_part(onward, 0, at)
        :nomatch -> onward
      end

    after_last_at(scheme, onward, head)
  end

  defp last_at_anywhere(scheme, onward), do: after_last_at(scheme, onward, onward)

  # `search` is a prefix of `onward`: the `@` is looked for in it, and the tail
  # handed back is everything past that `@` in the whole string.
  defp after_last_at(scheme, onward, search) do
    case search |> :binary.matches("@") |> List.last() do
      nil -> nil
      {at, _len} -> {scheme, binary_part(onward, at + 1, byte_size(onward) - at - 1)}
    end
  end

  @doc """
  Masks `rtsp://user:secret@host/…`, `rtsp://secret@host/…` and
  `…?password=x&user=y` forms.
  """
  @spec mask(term()) :: String.t()
  def mask(url) when is_binary(url) do
    # The `@` collapse runs first, on the URL as given: masking query pairs
    # first can erase the very `@` the display rule reads, and for a password
    # holding a raw `?` (`rtsp://u:pa?password=x@cam/main`) the pair
    # replacement swallowed the URL's only `@` and left `u:pa` on the page.
    # What survives the collapse is then swept for pairs without requiring a
    # `?` — the collapse usually eats that — so a credential pair after a
    # query `@` (`?user=a@b&password=x`) is still masked.
    #
    # An unambiguous URL keeps the username (up to the first colon); with no
    # colon the whole userinfo is a credential (`rtsp://SECRET@host` — a
    # password to some cameras, and `credentialed?/1` calls it one) and goes
    # entirely. An empty username (`rtsp://:secret@host`) masks like any other.
    case display_split(url) do
      {scheme, rest} ->
        scheme <> "•••••@" <> mask_pairs(rest)

      nil ->
        case split_authority(url) do
          {_scheme, nil, _rest} ->
            mask_query_of(url)

          {scheme, userinfo, rest} ->
            mask_query_of(join_authority(scheme, mask_userinfo(userinfo), rest))
        end
    end
  end

  # A row's `rtsp_url` is whatever the column holds: a hand-edited or migrated
  # row can carry a number, which the loader skips and the page still has to
  # render. Nothing to mask reads as nothing to show — like `credentialed?/1`,
  # which calls the same value clean.
  def mask(_other), do: @blank

  # The fragment comes off before the query is masked: a `#` after the last
  # pair would otherwise ride inside that pair's value and vanish with it.
  defp mask_query_of(url) do
    {before_fragment, fragment} = split_fragment(url)

    case String.split(before_fragment, "?", parts: 2) do
      [base, query] -> base <> "?" <> mask_query(query) <> fragment
      [base] -> base <> fragment
    end
  end

  defp split_fragment(url) do
    case String.split(url, "#", parts: 2) do
      [before, fragment] -> {before, "#" <> fragment}
      [before] -> {before, ""}
    end
  end

  defp mask_userinfo(userinfo) do
    case split_userinfo(userinfo) do
      {nil, _password_only} -> "•••••"
      {user, _password} -> user <> ":•••••"
    end
  end

  defp mask_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", &mask_query_pair/1)
  end

  # What is left of a URL after the display collapse cut it at an `@`: any
  # `?` that opened its query may be on the other side of that cut, so a pair
  # is anything between two of `?`, `&` and `#` (or an end of the string)
  # rather than something a surviving `?` introduces.
  defp mask_pairs(rest) do
    rest
    |> String.split(~r/[?&#]/, include_captures: true)
    |> Enum.map_join(&mask_query_pair/1)
  end

  defp mask_query_pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [key, _value] ->
        if credential_key?(key), do: "#{key}=•••••", else: pair

      _ ->
        pair
    end
  end

  @doc """
  Whether a query key names a credential.

  `?pass%77ord=` is the same key as `?password=` to the camera that reads it,
  so the raw spelling is not what to compare: an escape anywhere in the key
  would otherwise walk a credential past both the mask and the form's prefill
  rule. A malformed escape has no decoding, and the raw key is then all there
  is to judge — as is a well-formed one that decodes to invalid UTF-8
  (`?pass%FFword=`), which `String.downcase/1` is free to refuse.
  """
  @spec credential_key?(String.t()) :: boolean()
  def credential_key?(key), do: normalize_key(key) in @credential_params

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
  Whether the URL carries a credential — userinfo, one of the query parameters
  `mask/1` masks, or an `@` `display_ambiguous?/1` refuses to read. The form's
  prefill rule reads it: a credentialed URL is left blank rather than rendered
  (the credential rule).
  """
  @spec credentialed?(term()) :: boolean()
  def credentialed?(url) when is_binary(url) do
    {_scheme, userinfo, rest} = split_authority(url)

    userinfo != nil or display_ambiguous?(url) or
      Enum.any?(String.split(URI.parse(rest).query || @blank, "&"), fn pair ->
        pair |> String.split("=", parts: 2) |> hd() |> credential_key?()
      end)
  end

  def credentialed?(_other), do: false

  @doc """
  The URL's credential query pairs verbatim — the `key=value` strings whose
  key `credentialed?/1` recognizes — so a form retyping the URL by hand can
  carry the saved camera's FLV-form credential (`?user=…&password=…`) onto
  the new one the same way a userinfo credential is carried.
  """
  @spec credential_query_pairs(term()) :: [String.t()]
  def credential_query_pairs(url) when is_binary(url) do
    url
    |> split_authority()
    |> elem(2)
    |> URI.parse()
    |> Map.get(:query)
    |> case do
      nil ->
        []

      query ->
        Enum.filter(String.split(query, "&"), fn pair ->
          pair |> String.split("=", parts: 2) |> hd() |> credential_key?()
        end)
    end
  end

  def credential_query_pairs(_other), do: []

  @doc """
  The URL with every credential removed — the userinfo and the query pairs
  `credentialed?/1` recognizes — so the form's "remove saved username and
  password" strips the FLV form as well as the RTSP one, with the one key set.

  The structural `ambiguous?/1` rule, not the display one: a `?x=me@h` query
  value is ordinary text to a rewrite, and cutting the URL there would delete
  a path and a host the operator never asked to lose. Display fails closed
  wider than mutation, so a URL this leaves intact can still be one `mask/1`
  hides whole.
  """
  @spec strip_credentials(String.t()) :: String.t()
  def strip_credentials(url) when is_binary(url) do
    case ambiguous_split(url) do
      # Cutting at the last ambiguous `@` leaves nothing ambiguous behind, so
      # the recursion is one deep and finishes on the query form.
      {scheme, rest} -> strip_credentials(scheme <> rest)
      nil -> strip_unambiguous(url)
    end
  end

  defp strip_unambiguous(url) do
    {scheme, _userinfo, rest} = split_authority(url)
    uri = URI.parse(rest)

    query =
      case uri.query do
        nil ->
          nil

        query ->
          kept =
            query
            |> String.split("&")
            |> Enum.reject(fn pair ->
              pair |> String.split("=", parts: 2) |> hd() |> credential_key?()
            end)

          if kept == [], do: nil, else: Enum.join(kept, "&")
      end

    join_authority(scheme, nil, URI.to_string(%{uri | query: query}))
  end

  @doc """
  The URL's userinfo, or `nil`.

  Checked against `display_ambiguous?/1` rather than reading
  `split_authority/1` alone: such a URL can still parse an ordinary userinfo
  out of its apparent authority (`rtsp://u:p@h/live@1` reads as `u:p`@`h`
  before the ambiguity rule sees the later `@`), and handing that back would
  publish half of what might be a password holding a raw `@`.
  """
  @spec userinfo(term()) :: String.t() | nil
  def userinfo(url) when is_binary(url) do
    if display_ambiguous?(url), do: nil, else: url |> split_authority() |> elem(1)
  end

  def userinfo(_absent), do: nil

  @doc """
  The URL's username, decoded, or `nil`.

  A colonless userinfo (`rtsp://SECRET@host`) is a password to some cameras
  and `mask/1` treats the whole of it as one, so it is not a username to
  prefill: rendering it would expose in the form what the readout hides.
  """
  @spec user(term()) :: String.t() | nil
  def user(url) when is_binary(url) do
    case userinfo(url) do
      nil -> nil
      userinfo -> userinfo |> split_userinfo() |> elem(0) |> decode_user()
    end
  end

  def user(_absent), do: nil

  # A hand-edited or migrated row can hold a malformed escape (`bad%zz`),
  # which `URI.decode/1` raises on — and the form has to render the row the
  # operator opened it to repair. The raw text is then all there is to show.
  # A well-formed escape can decode to invalid UTF-8 (`u%FF`) without raising
  # at all, and that binary would take the render down further along, so it
  # is kept raw for the same reason.
  defp decode_user(nil), do: nil

  defp decode_user(user) do
    decoded = URI.decode(user)
    if String.valid?(decoded), do: decoded, else: user
  rescue
    ArgumentError -> user
  end

  @doc """
  The URL with `user` and `pass` spliced into its userinfo, each encoded. A
  blank one keeps whatever the URL already carried, which is how "leave blank
  to keep" reaches the URL.

  A colonless userinfo is the password, as `mask/1` and `user/1` read it: a
  typed password replaces it (and keeps the colonless shape the camera was
  given), a typed username moves it into the password slot rather than
  deleting it. Reading it as a username instead published the old password as
  the form's `value=`. A username typed onto a URL with no userinfo at all
  therefore gets an explicit empty password slot (`user:@host`) rather than the
  colonless `user@host` this module would read back as a password.

  A display-ambiguous URL (`display_ambiguous?/1`) is returned unchanged: its
  `@` may be inside a password, a path or a query, and splicing on the wrong
  reading rewrites the host. That is the same refusal the readout makes, so a
  URL whose `@` is a legitimate query value takes neither a splice nor a
  render until that `@` is written `%40`.
  """
  @spec compose(String.t(), String.t(), String.t()) :: String.t()
  def compose(url, @blank, @blank), do: url

  def compose(url, user, pass) do
    # A URL with no authority to splice into (`rtsp:/cam/main`, or an empty
    # host) is returned as typed: prepending `user:pass@` to it would build
    # `ops:pw@rtsp:/cam/main`, which a non-empty-URL check lets through.
    if display_ambiguous?(url) or unambiguous_endpoint(url) == nil,
      do: url,
      else: splice(url, user, pass)
  end

  defp splice(url, user, pass) do
    {scheme, current, rest} = split_authority(url)
    {current_user, current_pass} = split_userinfo(current)
    user = if user == @blank, do: current_user, else: encode(user)
    pass = if pass == @blank, do: current_pass, else: encode(pass)

    join_authority(scheme, compose_userinfo(user, pass, colonless?(current)), rest)
  end

  defp colonless?(current), do: is_binary(current) and not String.contains?(current, ":")

  defp compose_userinfo(nil, nil, _colonless), do: nil
  # A URL that arrived colonless keeps that shape when its password is
  # replaced: the camera was reached with `secret@host` and a new password is
  # the same credential, not a new form of one.
  defp compose_userinfo(nil, pass, true), do: pass
  # `rtsp://:pass@host` is what a camera that authenticates on the password
  # alone wants, and on create there is no saved URL to carry the credential
  # instead — dropping the userinfo here silently discarded the typed
  # password. Both `mask/1` and `credentialed?/1` already read this form.
  defp compose_userinfo(nil, pass, false), do: ":" <> pass
  # The colon is kept even with nothing after it: a bare `user@host` is a
  # colonless userinfo, which this module reads as a password-only credential
  # everywhere else — `user/1` would then return `nil` for the name just typed
  # and `mask/1` would hide it. Only a URL that had no userinfo at all reaches
  # here, so there is no saved password the empty slot could be shadowing.
  defp compose_userinfo(user, nil, _colonless), do: user <> ":"
  defp compose_userinfo(user, pass, _colonless), do: user <> ":" <> pass

  # The module's one reading of a userinfo: no colon means no username, so the
  # whole of it is the password (`mask/1`, `user/1` and `compose/3` all rest
  # on this — a disagreement is what leaked one).
  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [password_only] -> {nil, password_only}
    end
  end

  @doc """
  Whether two URLs name the same endpoint: identical scheme and identical
  host[:port], whatever their paths, queries or credentials.

  Carrying a saved credential onto a retyped URL is only "the same camera, a
  corrected path" while this holds. Compared byte for byte rather than
  normalized — a URL that differs only in case is retyped rarely, and the
  wrong answer here sends a saved secret to a host the operator never gave it
  to.

  A URL that names no host at all — no `//` opening an authority, or nothing
  before the first `/`, `?` or `#` after it — is never the same endpoint as anything, itself
  included. Two of them reduce to the same empty authority and would
  otherwise compare equal, which is a saved credential carried onto `rtsp:`.
  """
  @spec same_endpoint?(term(), term()) :: boolean()
  def same_endpoint?(a, b) when is_binary(a) and is_binary(b) do
    case {endpoint(a), endpoint(b)} do
      {nil, _b} -> false
      {_a, nil} -> false
      {endpoint_a, endpoint_b} -> endpoint_a == endpoint_b
    end
  end

  def same_endpoint?(_a, _b), do: false

  # `nil` for a URL with no authority: `split_authority/1` reports a blank
  # scheme when no `//` opens one, and a blank host when there is nothing
  # between it and the path.
  # An ambiguous URL has no readable host: its `@` may sit inside a password
  # or a path, and the authority `split_authority/1` returns for it can be
  # the credential itself. Comparing that would seed a saved secret onto
  # whatever host follows the `@`.
  # `display_ambiguous?/1`, not the narrower structural rule: a URL that only
  # *displays* ambiguous (`http://attacker.lan?x@camera.lan/…`) still parses
  # an apparent authority here, and comparing that would let
  # `Settings.seed_userinfo/2` carry a saved credential onto a host chosen by
  # whatever precedes that later `@` — exactly the forgery `mask/1` and
  # `userinfo/1` already refuse to render for the same URL.
  defp endpoint(url) do
    if display_ambiguous?(url), do: nil, else: unambiguous_endpoint(url)
  end

  defp unambiguous_endpoint(url) do
    case split_authority(url) do
      {@blank, _userinfo, _rest} ->
        nil

      {scheme, _userinfo, rest} ->
        case split_at_path(rest) do
          {@blank, _tail} -> nil
          {host, _tail} -> {scheme, host}
        end
    end
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
