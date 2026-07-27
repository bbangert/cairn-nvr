defmodule Cairn.ULIDTest do
  use ExUnit.Case, async: true

  alias Cairn.ULID

  @crockford ~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/

  test "is 26 Crockford base32 characters" do
    for _ <- 1..100 do
      ulid = ULID.generate()
      assert byte_size(ulid) == 26
      assert ulid =~ @crockford
    end
  end

  # across milliseconds only: these are plain, not monotonic, ULIDs, so two
  # minted in the same millisecond have no defined order
  test "sorts lexicographically across timestamps" do
    ulids = for ms <- [0, 1, 1_000, 1_700_000_000_000, 281_474_976_710_655], do: ULID.generate(ms)
    assert Enum.sort(ulids) == ulids
  end

  test "a burst at one timestamp shares a time prefix and does not collide" do
    ulids = for _ <- 1..1_000, do: ULID.generate(1_700_000_000_000)

    # 80 random bits: distinctness is probabilistic, not guaranteed — a
    # collision here would mean the randomness is broken, not merely unlucky
    assert ulids |> Enum.uniq() |> length() == 1_000
    # same millisecond => identical 10-character time prefix
    assert ulids |> Enum.map(&binary_part(&1, 0, 10)) |> Enum.uniq() |> length() == 1
  end

  test "a timestamp outside 48 bits raises instead of wrapping" do
    assert byte_size(ULID.generate(0)) == 26
    assert byte_size(ULID.generate(281_474_976_710_655)) == 26

    assert_raise FunctionClauseError, fn -> ULID.generate(-1) end
    assert_raise FunctionClauseError, fn -> ULID.generate(281_474_976_710_656) end
  end
end
