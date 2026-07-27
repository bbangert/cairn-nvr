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

  defp encode(bits) do
    for <<c::5 <- bits>>, into: "", do: binary_part(@alphabet, c, 1)
  end
end
