defmodule Cairn.Artifacts.HTTP do
  @moduledoc """
  `Cairn.Artifacts.Fetcher`'s fetch function over `:httpc`: https only, at
  every hop, with the peer's certificate and hostname verified against the
  OS's trusted CAs.

  Redirects are followed here rather than by `:httpc` (at most three), so
  that each hop is checked for https and opened with these TLS options; a
  GitHub release asset answers 302 to another host.

  Bounded in bytes — the artifact's `size`, else 64 MiB — and in time: 15 s
  to connect, 5 min for the whole attempt, hops included. The body streams to
  the file as it arrives.

  Not bounded in bytes: the response headers, and the body of any answer but
  a 200, which `:httpc` buffers whole with no limit to set. The wait for the
  first response — a 200's headers, or a whole other answer — ends after
  30 s, and that is what bounds them.
  """

  @max_hops 3
  @default_max_bytes 64 * 1024 * 1024
  @connect_timeout_ms 15_000
  @attempt_timeout_ms 300_000
  @first_response_ms 30_000
  @redirects [301, 302, 303, 307, 308]

  @typedoc """
  One request: `:ok` with the body written to the path, a `Location` to follow,
  or a short error.
  """
  @type request ::
          (String.t(), Path.t(), %{max_bytes: pos_integer(), deadline: integer()} ->
             :ok | {:redirect, String.t()} | {:error, String.t()})

  @doc """
  Downloads `artifact.url` to `path`. `request` makes one request; the
  default is `:httpc`, and a suite drives the hop rules without a network
  through its own.
  """
  @spec fetch(map(), Path.t(), request()) :: :ok | {:error, String.t()}
  def fetch(artifact, path, request \\ &request/3) do
    limits = %{
      max_bytes: Map.get(artifact, :size) || @default_max_bytes,
      deadline: now() + @attempt_timeout_ms
    }

    follow(artifact.url, 0, path, request, limits)
  end

  defp follow(url, hops, path, request, limits) do
    with :ok <- https(url) do
      case request.(url, path, limits) do
        {:redirect, location} when hops < @max_hops ->
          follow(resolve(url, location), hops + 1, path, request, limits)

        {:redirect, _location} ->
          {:error, "more than #{@max_hops} redirects"}

        other ->
          other
      end
    end
  end

  # Only scheme and host in the error: a signed redirect's query is long and
  # nothing an operator needs.
  defp https(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        :ok

      {:ok, %URI{scheme: scheme, host: host}} ->
        {:error, "refusing #{scheme}://#{host}: not https"}

      {:error, _part} ->
        {:error, "refusing a malformed URL"}
    end
  end

  defp resolve(base, location) do
    base |> URI.merge(location) |> URI.to_string()
  rescue
    ArgumentError -> location
  end

  defp request(url, path, %{deadline: deadline} = limits) do
    remaining = max(deadline - now(), 1)
    first = min(deadline, now() + @first_response_ms)

    http_options = [
      timeout: remaining,
      connect_timeout: min(@connect_timeout_ms, remaining),
      autoredirect: false,
      ssl: ssl_options()
    ]

    options = [sync: false, stream: {:self, :once}]

    case :httpc.request(:get, {String.to_charlist(url), []}, http_options, options) do
      {:ok, id} -> response(id, path, limits, first)
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 4,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  # With `stream: {:self, :once}` a 200 always streams.
  defp response(id, path, %{max_bytes: max_bytes, deadline: deadline}, first) do
    receive do
      {:http, {^id, :stream_start, headers, pid}} ->
        result =
          with :ok <- declared_length(headers, max_bytes),
               do: stream(id, pid, path, max_bytes, deadline)

        cancel_unless_ok(result, id)

      {:http, {^id, {{_version, status, _reason}, headers, _body}}} when status in @redirects ->
        case header(headers, "location") do
          nil -> {:error, "HTTP #{status} without a Location"}
          location -> {:redirect, location}
        end

      {:http, {^id, {{_version, status, _reason}, _headers, _body}}} ->
        {:error, "HTTP #{status}"}

      {:http, {^id, {:error, reason}}} ->
        {:error, describe(reason)}
    after
      max(first - now(), 0) ->
        failure =
          if first < deadline,
            do: "no response in #{div(@first_response_ms, 1000)} s",
            else: "timed out"

        cancel_unless_ok({:error, failure}, id)
    end
  end

  defp declared_length(headers, max_bytes) do
    with length when is_binary(length) <- header(headers, "content-length"),
         {bytes, ""} when bytes > max_bytes <- Integer.parse(length) do
      {:error, "the response is #{bytes} bytes, more than #{max_bytes}"}
    else
      _ -> :ok
    end
  end

  defp stream(id, pid, path, max_bytes, deadline) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, file} ->
        try do
          :ok = :httpc.stream_next(pid)
          chunks(id, pid, file, 0, max_bytes, deadline)
        after
          File.close(file)
        end

      {:error, reason} ->
        {:error, "cannot open the download's file: #{:file.format_error(reason)}"}
    end
  end

  defp chunks(id, pid, file, bytes, max_bytes, deadline) do
    receive do
      {:http, {^id, :stream, chunk}} ->
        bytes = bytes + byte_size(chunk)

        with :ok <- within(bytes, max_bytes),
             :ok <- write(file, chunk) do
          :ok = :httpc.stream_next(pid)
          chunks(id, pid, file, bytes, max_bytes, deadline)
        end

      {:http, {^id, :stream_end, _headers}} ->
        :ok

      {:http, {^id, {:error, reason}}} ->
        {:error, describe(reason)}
    after
      max(deadline - now(), 0) -> {:error, "timed out"}
    end
  end

  defp within(bytes, max_bytes) when bytes > max_bytes,
    do: {:error, "the response is more than #{max_bytes} bytes"}

  defp within(_bytes, _max_bytes), do: :ok

  defp write(file, chunk) do
    case :file.write(file, chunk) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write the download: #{:file.format_error(reason)}"}
    end
  end

  defp cancel_unless_ok(:ok, _id), do: :ok

  defp cancel_unless_ok(error, id) do
    :httpc.cancel_request(id)
    error
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp describe({:failed_connect, info}) when is_list(info) do
    reason =
      Enum.find_value(info, info, fn
        {:inet, _families, reason} -> reason
        _other -> nil
      end)

    "could not connect: " <> connect_reason(reason)
  end

  defp describe(reason), do: inspect(reason, limit: 8, printable_limit: 120)

  # The alert's text is a long charlist naming an ssl source line.
  defp connect_reason({:tls_alert, {alert, _text}}) when is_atom(alert), do: "TLS alert #{alert}"
  defp connect_reason(reason), do: describe(reason)

  defp now, do: System.monotonic_time(:millisecond)
end
