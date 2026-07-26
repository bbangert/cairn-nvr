defmodule Cairn.ULID do
  @moduledoc """
  Crockford-base32 ULIDs: 48 bits of millisecond timestamp followed by 80
  random bits, rendered as 26 uppercase characters.

  Used for stream epochs (`Cairn.StreamEpochs`), where the useful property
  is that the textual form sorts lexicographically by mint time while
  staying collision-free within a millisecond.
  """

  # Crockford base32: no I, L, O or U (unambiguous when read out of a log).
  @alphabet "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

  @type t :: <<_::208>>

  @spec generate() :: t()
  def generate, do: generate(System.system_time(:millisecond))

  @doc "Generates a ULID for a fixed millisecond timestamp."
  @spec generate(integer()) :: t()
  def generate(time_ms) when is_integer(time_ms) do
    # 48 timestamp bits are left-padded to 50 so both halves land on a 5-bit
    # boundary: 10 characters of time, 16 of randomness.
    encode(<<0::2, time_ms::48>>) <> encode(:crypto.strong_rand_bytes(10))
  end

  defp encode(bits) do
    for <<c::5 <- bits>>, into: "", do: binary_part(@alphabet, c, 1)
  end
end
