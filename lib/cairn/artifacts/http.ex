defmodule Cairn.Artifacts.HTTP do
  @moduledoc """
  `Cairn.Artifacts.Fetcher`'s fetch function over Req: https only, at every
  hop, with the peer's certificate and hostname verified against the OS's
  trusted CAs.

  Redirects are followed here rather than by Req (at most three), so that each
  hop is checked for https; a GitHub release asset answers 302 to another host.
  Req retries, decompresses and decodes nothing.

  Bounded in bytes: a 200's body to the artifact's `size`, else 64 MiB,
  refused on a larger `content-length` and cut off once more has arrived. It
  streams to the file as it arrives. Any other answer's body is dropped at its
  first chunk, so at most one socket read of it is held. The status line and
  the header section stop at Mint's 256 KiB each.

  Bounded in time: 15 s for the TCP connect (DNS included) and 15 s more for
  the TLS handshake, 30 s for any one read, and 5 min for the whole attempt,
  hops included. A hop's reads get what is left of the five minutes once a
  worst-case connect and one last stalled read are paid for, so the attempt
  ends within them. Not counted against them: a blocked write to the file, the
  send of the request, and a wait of up to Finch's 5 s for a pooled connection.
  """

  @max_hops 3
  @default_max_bytes 64 * 1024 * 1024
  @connect_timeout_ms 15_000
  @attempt_timeout_ms 300_000
  @stall_ms 30_000
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
  default is Req, and a suite drives the hop rules without a network
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

  # Finch's `request_timeout` counts only the time spent in socket reads, and
  # may overrun by one read; `:ssl.connect/4` gives the TCP connect and the TLS
  # handshake the connect timeout each. Both are paid for up front.
  defp request(url, path, %{max_bytes: max_bytes, deadline: deadline}) do
    left = deadline - now() - 2 * @connect_timeout_ms
    stall = min(@stall_ms, left)

    with :ok <- if(left > 0, do: :ok, else: {:error, "timed out"}),
         {:ok, file} <- open(path) do
      try do
        [
          url: url,
          into: into(file, max_bytes, deadline),
          redirect: false,
          retry: false,
          raw: true,
          connect_options: connect_options(),
          receive_timeout: stall,
          request_timeout: left - stall
        ]
        |> Req.request()
        |> answer()
      after
        File.close(file)
      end
    end
  end

  # Req starts a Finch pool per distinct `connect_options` term and never
  # stops one, so the term must not vary: no per-request timeout in it.
  # `:public_key.cacerts_get/0` caches the OS store after its first load.
  # Mint adds SNI, the hostname check and a depth of 4 to these.
  defp connect_options do
    [
      timeout: @connect_timeout_ms,
      transport_opts: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
    ]
  end

  defp open(path) do
    case File.open(path, [:write, :binary, :raw]) do
      {:ok, file} ->
        {:ok, file}

      {:error, reason} ->
        {:error, "cannot open the download's file: #{:file.format_error(reason)}"}
    end
  end

  @doc false
  # Req calls this in the calling process for every chunk of every status,
  # after the status and headers are set. A halt closes the connection and Req
  # still answers `{:ok, response}`, so a 200 cut short carries its error.
  def into(file, max_bytes, deadline) do
    fn {:data, chunk}, {request, response} ->
      received = Req.Response.get_private(response, :received, 0)
      bytes = received + byte_size(chunk)

      case take(response, chunk, received, bytes, {file, max_bytes, deadline}) do
        :ok -> {:cont, {request, Req.Response.put_private(response, :received, bytes)}}
        failure -> {:halt, {request, Req.Response.put_private(response, :failure, failure)}}
      end
    end
  end

  defp take(response, chunk, received, bytes, {file, max_bytes, deadline}) do
    with :ok <- if(response.status == 200, do: :ok, else: :drop),
         :ok <- if(received == 0, do: declared_length(response, max_bytes), else: :ok),
         :ok <- within(bytes, max_bytes),
         :ok <- if(now() > deadline, do: {:error, "timed out"}, else: :ok),
         do: write(file, chunk)
  end

  defp answer({:ok, %Req.Response{status: 200} = response}),
    do: Req.Response.get_private(response, :failure, :ok)

  defp answer({:ok, %Req.Response{status: status} = response}) when status in @redirects do
    case Req.Response.get_header(response, "location") do
      [location | _] -> {:redirect, location}
      [] -> {:error, "HTTP #{status} without a Location"}
    end
  end

  defp answer({:ok, %Req.Response{status: status}}), do: {:error, "HTTP #{status}"}
  defp answer({:error, exception}), do: {:error, describe(exception)}

  defp declared_length(response, max_bytes) do
    with [length | _] <- Req.Response.get_header(response, "content-length"),
         {bytes, ""} when bytes > max_bytes <- Integer.parse(length) do
      {:error, "the response is #{bytes} bytes, more than #{max_bytes}"}
    else
      _ -> :ok
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

  defp describe(%Req.TransportError{reason: :timeout}), do: "timed out"

  # The alert's text is a long charlist naming an ssl source line.
  defp describe(%Req.TransportError{reason: {:tls_alert, {alert, _text}}}) when is_atom(alert),
    do: "TLS alert #{alert}"

  defp describe(%Req.TransportError{reason: reason} = error) when is_atom(reason),
    do: Exception.message(error)

  # Mint's own text names the bytes read so far, which differ between tries.
  defp describe(%Req.HTTPError{reason: {too_long, _size, max}})
       when too_long in [:response_line_too_long, :max_header_list_size_exceeded],
       do: "the response's status line or headers are more than #{max} bytes"

  defp describe(%{reason: reason}), do: inspect(reason, limit: 8, printable_limit: 120)
  defp describe(other), do: inspect(other, limit: 8, printable_limit: 120)

  defp now, do: System.monotonic_time(:millisecond)
end
