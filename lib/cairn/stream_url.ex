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
  query is left alone. A URL with no `//` has no authority to split.

  Two shapes this cannot resolve, both of which report no userinfo here and so
  would be rendered in full: a raw `/` inside a userinfo (it ends the authority
  before any `@` is seen) and a URL with no `//` at all (there is no authority
  to look in). Both are *ambiguous* rather than bare — see `ambiguous?/1`,
  which the display and splice paths consult and this function does not.
  """
  @spec split_authority(String.t()) :: {String.t(), String.t() | nil, String.t()}
  def split_authority(url) when is_binary(url) do
    case String.split(url, "//", parts: 2) do
      [prefix, authority_onward] ->
        {authority, tail} = split_at_path(authority_onward)

        case last_at(authority) do
          nil -> {prefix <> "//", nil, authority_onward}
          {userinfo, host} -> {prefix <> "//", userinfo, host <> tail}
        end

      [_no_authority] ->
        {"", nil, url}
    end
  end

  @doc "The inverse of `split_authority/1`."
  @spec join_authority(String.t(), String.t() | nil, String.t()) :: String.t()
  def join_authority(scheme, nil, rest), do: scheme <> rest
  def join_authority(scheme, userinfo, rest), do: scheme <> userinfo <> "@" <> rest

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
  at all: past the authority's first `/` with no `@` in the authority itself
  (`rtsp://u:pa/ss@cam.lan/main`), or anywhere before a `?`/`#` in a URL with
  no `//` to open an authority (`rtsp:/user:secret@host/live`, a malformed
  stored value). Both are `@`s with a credential plausibly in front of them and
  no boundary this module can trust, so both fail closed.

  A hand-typed or imported password really does contain a raw slash sometimes,
  and there is no way to tell that URL from a bare one whose *path* holds an
  `@`. Either guess is wrong half the time and a wrong guess renders half a
  password, so both readings are refused: everything from `//` through the
  last such `@` is treated as credential — masked whole, never spliced into,
  stripped entire. The cost is a bare URL with an `@` in its path opening
  blank in the form, which the operator repairs by retyping it; the same
  repair path a row this module cannot read already takes.

  A raw `?` or `#` in a password is out of reach: past one, an `@` is a query
  or fragment character, and `?x=me@h` is ordinary. Those are left to the
  query masker, which hides the value of a credential-named key and nothing
  else.
  """
  @spec ambiguous?(term()) :: boolean()
  def ambiguous?(url) when is_binary(url), do: ambiguous_split(url) != nil
  def ambiguous?(_other), do: false

  # `{scheme, everything after the last ambiguous @}`, or `nil` when the URL
  # reads unambiguously.
  defp ambiguous_split(url) do
    case String.split(url, "//", parts: 2) do
      [prefix, onward] ->
        {authority, _tail} = split_at_path(onward)
        if last_at(authority) == nil, do: last_at_before_query(prefix <> "//", onward)

      # No `//`, so `split_authority/1` finds no userinfo and every reader
      # would treat the whole string as bare. An `@` in it is a credential
      # boundary as good as any other, and the scheme is not worth preserving
      # in a URL already malformed enough to reach here.
      [_no_authority] ->
        last_at_before_query(@blank, url)
    end
  end

  defp last_at_before_query(scheme, onward) do
    head =
      case :binary.match(onward, ["?", "#"]) do
        {at, _len} -> binary_part(onward, 0, at)
        :nomatch -> onward
      end

    case head |> :binary.matches("@") |> List.last() do
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
    # The username (up to the first colon) stays; with no colon the whole
    # userinfo is a credential (`rtsp://SECRET@host` — a password to some
    # cameras, and `credentialed?/1` calls it one) and goes entirely. An
    # empty username (`rtsp://:secret@host`) masks like any other. An
    # ambiguous URL shows none of what precedes its `@`.
    masked =
      case {ambiguous_split(url), split_authority(url)} do
        {{scheme, rest}, _split} ->
          scheme <> "•••••@" <> rest

        {nil, {_scheme, nil, _rest}} ->
          url

        {nil, {scheme, userinfo, rest}} ->
          join_authority(scheme, mask_userinfo(userinfo), rest)
      end

    # The fragment comes off before the query is masked: a `#` after the last
    # pair would otherwise ride inside that pair's value and vanish with it.
    {before_fragment, fragment} = split_fragment(masked)

    case String.split(before_fragment, "?", parts: 2) do
      [base, query] -> base <> "?" <> mask_query(query) <> fragment
      [base] -> base <> fragment
    end
  end

  # A row's `rtsp_url` is whatever the column holds: a hand-edited or migrated
  # row can carry a number, which the loader skips and the page still has to
  # render. Nothing to mask reads as nothing to show — like `credentialed?/1`,
  # which calls the same value clean.
  def mask(_other), do: @blank

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
  `mask/1` masks, or an `@` `ambiguous?/1` refuses to read. The form's prefill
  rule reads it: a credentialed URL is left blank rather than rendered (the
  credential rule).
  """
  @spec credentialed?(term()) :: boolean()
  def credentialed?(url) when is_binary(url) do
    {_scheme, userinfo, rest} = split_authority(url)

    userinfo != nil or ambiguous?(url) or
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

  @doc "The URL's userinfo, or `nil`."
  @spec userinfo(term()) :: String.t() | nil
  def userinfo(url) when is_binary(url), do: url |> split_authority() |> elem(1)
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

  An ambiguous URL (`ambiguous?/1`) is returned unchanged: its `@` may be
  inside a password or inside a path, and splicing on the wrong reading
  rewrites the host.
  """
  @spec compose(String.t(), String.t(), String.t()) :: String.t()
  def compose(url, @blank, @blank), do: url

  def compose(url, user, pass) do
    case ambiguous_split(url) do
      {_scheme, _rest} -> url
      nil -> splice(url, user, pass)
    end
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
  """
  @spec same_endpoint?(term(), term()) :: boolean()
  def same_endpoint?(a, b) when is_binary(a) and is_binary(b), do: endpoint(a) == endpoint(b)
  def same_endpoint?(_a, _b), do: false

  defp endpoint(url) do
    {scheme, _userinfo, rest} = split_authority(url)
    {scheme, rest |> split_at_path() |> elem(0)}
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
