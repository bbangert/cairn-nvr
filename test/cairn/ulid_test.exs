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

  describe "superseded?/2" do
    test "an earlier millisecond is superseded by a later one" do
      older = ULID.generate(1_700_000_000_000)
      newer = ULID.generate(1_700_000_000_001)

      assert ULID.superseded?(newer, older)
      refute ULID.superseded?(older, newer)
    end

    test "nothing held supersedes nothing" do
      refute ULID.superseded?(nil, ULID.generate())
    end

    # deliberate: the random halves order two same-millisecond mints at
    # random, and calling one "older" would discard a legitimate epoch
    # announcement — the exact failure the guard exists to prevent
    test "same-millisecond mints never supersede each other" do
      held = ULID.generate(1_700_000_000_000)

      for _ <- 1..200 do
        refute ULID.superseded?(held, ULID.generate(1_700_000_000_000))
      end
    end

    test "is total on binaries that are not ULIDs" do
      refute ULID.superseded?("epoch_one", "epoch_two")
      assert ULID.superseded?("epoch_two", "epoch_one")
      refute ULID.superseded?("a", "b")
    end
  end

  test "a timestamp outside 48 bits raises instead of wrapping" do
    assert byte_size(ULID.generate(0)) == 26
    assert byte_size(ULID.generate(281_474_976_710_655)) == 26

    assert_raise FunctionClauseError, fn -> ULID.generate(-1) end
    assert_raise FunctionClauseError, fn -> ULID.generate(281_474_976_710_656) end
  end
end
