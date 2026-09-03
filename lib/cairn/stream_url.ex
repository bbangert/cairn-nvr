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
  Masks `rtsp://user:secret@host/…`, `rtsp://secret@host/…` and
  `…?password=x&user=y` forms.
  """
  @spec mask(term()) :: String.t()
  def mask(url) when is_binary(url) do
    # The username (up to the first colon) stays; with no colon the whole
    # userinfo is a credential (`rtsp://SECRET@host` — a password to some
    # cameras, and `credentialed?/1` calls it one) and goes entirely. An
    # empty username (`rtsp://:secret@host`) masks like any other.
    masked =
      case split_authority(url) do
        {_scheme, nil, _rest} ->
          url

        {scheme, userinfo, rest} ->
          join_authority(scheme, mask_userinfo(userinfo), rest)
      end

    case String.split(masked, "?", parts: 2) do
      [base, query] -> base <> "?" <> mask_query(query)
      [base] -> base
    end
  end

  # A row's `rtsp_url` is whatever the column holds: a hand-edited or migrated
  # row can carry a number, which the loader skips and the page still has to
  # render. Nothing to mask reads as nothing to show — like `credentialed?/1`,
  # which calls the same value clean.
  def mask(_other), do: @blank

  defp mask_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, _password] -> user <> ":•••••"
      [_password_only] -> "•••••"
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
  Whether the URL carries a credential — userinfo, or one of the query
  parameters `mask/1` masks. The form's prefill rule reads it: a credentialed
  URL is left blank rather than rendered (the credential rule).
  """
  @spec credentialed?(term()) :: boolean()
  def credentialed?(url) when is_binary(url) do
    {_scheme, userinfo, rest} = split_authority(url)

    userinfo != nil or
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
      userinfo -> userinfo |> split_userinfo() |> colon_user() |> decode_user()
    end
  end

  def user(_absent), do: nil

  defp colon_user({user, nil}) when is_binary(user), do: nil
  defp colon_user({user, _password}), do: user

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
  """
  @spec compose(String.t(), String.t(), String.t()) :: String.t()
  def compose(url, @blank, @blank), do: url

  def compose(url, user, pass) do
    {scheme, current, rest} = split_authority(url)
    {current_user, current_pass} = split_userinfo(current)
    user = if user == @blank, do: current_user, else: encode(user)
    pass = if pass == @blank, do: current_pass, else: encode(pass)

    join_authority(scheme, compose_userinfo(user, pass), rest)
  end

  defp compose_userinfo(nil, nil), do: nil
  # `rtsp://:pass@host` is what a camera that authenticates on the password
  # alone wants, and on create there is no saved URL to carry the credential
  # instead — dropping the userinfo here silently discarded the typed
  # password. Both `mask/1` and `credentialed?/1` already read this form.
  defp compose_userinfo(nil, pass), do: ":" <> pass
  defp compose_userinfo(user, nil), do: user
  defp compose_userinfo(user, pass), do: user <> ":" <> pass

  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> {user, pass}
      [user] -> {user, nil}
    end
  end

  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)
end
