defmodule CairnWeb.TrackMomentsTest do
  # No database: these are the formatting contracts the two callers rely on,
  # asked of the function directly rather than through a rendered page.
  use ExUnit.Case, async: true

  alias CairnWeb.TrackMoments

  describe "fmt_clock/2" do
    test "prints the offset between two instants, in the m:ss and h:mm:ss forms" do
      from = ~U[2026-08-01 12:00:00Z]

      assert TrackMoments.fmt_clock(from, DateTime.add(from, 5)) == "0:05"
      assert TrackMoments.fmt_clock(from, DateTime.add(from, 65)) == "1:05"
      assert TrackMoments.fmt_clock(from, DateTime.add(from, 3600 + 125)) == "1:02:05"
    end

    test "an instant before the origin clamps to zero rather than printing a negative clock" do
      # The clamp the docstring promises, pinned on the function itself: no
      # page fixture can reach it (`EventLive` only formats a moment against a
      # clip that contains it), so a rendered assertion would pass with the
      # clamp deleted.
      from = ~U[2026-08-01 12:00:00Z]

      assert TrackMoments.fmt_clock(from, DateTime.add(from, -1)) == "0:00"
      assert TrackMoments.fmt_clock(from, DateTime.add(from, -3600)) == "0:00"
      assert TrackMoments.fmt_clock(-1) == "0:00"
      assert TrackMoments.fmt_clock(-7200) == "0:00"
    end
  end

  test "reason_gloss/1 answers nil for a reason it has no wording for" do
    assert TrackMoments.reason_gloss(:evicted) == "Dropped to cap memory use"
    assert TrackMoments.reason_gloss(:not_a_reason) == nil
  end
end
