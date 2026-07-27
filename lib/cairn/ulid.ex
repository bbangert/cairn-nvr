defmodule Cairn.ULID do
  @moduledoc """
  Crockford-base32 ULIDs: 48 bits of millisecond timestamp followed by 80
  random bits, rendered as 26 uppercase characters.

  Used for stream epochs (`Cairn.StreamEpochs`). These are plain (not
  monotonic) ULIDs, so the textual form sorts lexicographically by mint
  *millisecond*: two ULIDs minted in the same millisecond sort in random
  order relative to each other. Uniqueness is probabilistic — 80 random
  bits make a collision within one millisecond improbable, not impossible.
  """

  # Crockford base32: no I, L, O or U (unambiguous when read out of a log).
  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  # 48 bits of milliseconds
  @max_time_ms 281_474_976_710_655
  # 48 timestamp bits at 5 bits per character
  @time_chars 10

  @type t :: <<_::208>>

  @spec generate() :: t()
  def generate, do: generate(System.system_time(:millisecond))

  @doc """
  Generates a ULID for a fixed millisecond timestamp.

  Raises for a timestamp outside 0..#{@max_time_ms}: silently truncating it
  to 48 bits would yield a valid-looking ULID that sorts wrongly.
  """
  @spec generate(non_neg_integer()) :: t()
  def generate(time_ms) when is_integer(time_ms) and time_ms >= 0 and time_ms <= @max_time_ms do
    # 48 timestamp bits are left-padded to 50 so both halves land on a 5-bit
    # boundary: 10 characters of time, 16 of randomness.
    encode(<<0::2, time_ms::48>>) <> encode(:crypto.strong_rand_bytes(10))
  end

  @doc """
  Whether `candidate` names an *earlier millisecond* than `held`.

  This is how every stream-epoch consumer decides to ignore an announcement:
  an older epoch delivered after a newer one (a port's spawn-time ETS pull
  racing a queued broadcast, or `Cairn.StreamEpochs`' degraded caller-side
  broadcast, which has no ordering relation to the server's) would otherwise
  put the consumer back on a stream that no longer exists.

  Only the timestamp half is compared, deliberately. Two ULIDs minted in the
  same millisecond sort by their random halves, so a full string compare
  would call one of them "older" at random — and *rejecting a legitimate
  announcement is the failure this guard exists to prevent*, not a lesser
  version of it. Same-millisecond mints are treated as the same instant and
  applied; two mints for one camera are separated by an ffmpeg respawn and
  its backoff, so a genuine rollback is always milliseconds wide.

  Total on any binary: a value shorter than the timestamp prefix compares
  whole (test fixtures and hand-written epochs are not ULIDs).
  """
  @spec superseded?(String.t() | nil, String.t()) :: boolean()
  def superseded?(nil, _candidate), do: false

  def superseded?(held, candidate) when is_binary(held) and is_binary(candidate),
    do: time_part(candidate) < time_part(held)

  defp time_part(ulid) when byte_size(ulid) >= @time_chars,
    do: binary_part(ulid, 0, @time_chars)

  defp time_part(ulid), do: ulid

  defp encode(bits) do
    for <<c::5 <- bits>>, into: "", do: binary_part(@alphabet, c, 1)
  end
end
