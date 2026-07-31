defmodule Cairn.DataDirTest do
  use ExUnit.Case, async: true

  alias Cairn.DataDir

  describe "trackpath_for_clip/1" do
    test "replaces a clip's .mp4 with .tracks, in place" do
      # A literal, not a derivation: the browser overlay fetches this path
      # through a route that derives it the same way, so the rule has to be
      # pinned somewhere that does not compute it.
      assert DataDir.trackpath_for_clip("/data/events/driveway/ev1_driveway_1700000000.mp4") ==
               "/data/events/driveway/ev1_driveway_1700000000.tracks"
    end

    test "appends to anything that is not .mp4" do
      # `Path.rootname/2` leaves a path it does not recognise alone, so a
      # `.mkv` becomes `foo.mkv.tracks` rather than `foo.tracks`. Intended:
      # every clip this system writes is `.mp4` (`event_clip_path/4`) and
      # `Cairn.Reconciler` only ever adopts `*.mp4`, so the extension is not a
      # variable — and appending keeps the result a sibling of the original
      # under every input, which is what the path-traversal argument rests on.
      assert DataDir.trackpath_for_clip("/data/events/driveway/foo.mkv") ==
               "/data/events/driveway/foo.mkv.tracks"

      assert DataDir.trackpath_for_clip("/data/events/driveway/foo") ==
               "/data/events/driveway/foo.tracks"
    end
  end
end
