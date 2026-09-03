defmodule Cairn.DataDirTest do
  use ExUnit.Case, async: true

  import Bitwise

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

  describe "secure_db/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "cairn_data_dir_test_#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "chmods cairn.db and its wal/shm siblings to 0600", %{dir: dir} do
      db = DataDir.db_path(dir)

      for path <- [db, db <> "-wal", db <> "-shm"] do
        File.write!(path, "")
        File.chmod!(path, 0o644)
      end

      assert :ok == DataDir.secure_db(dir)

      for path <- [db, db <> "-wal", db <> "-shm"] do
        assert (File.stat!(path).mode &&& 0o777) == 0o600
      end
    end

    test "is a no-op when no db files exist", %{dir: dir} do
      assert :ok == DataDir.secure_db(dir)
      refute File.exists?(DataDir.db_path(dir))
    end

    # A chmod failure (EPERM on a restored backup's ownership) is not
    # simulated here: `File.chmod/2` fails on permission or a missing path,
    # and a file this test just wrote is owned by the test process, so
    # there is no way to make the call fail without root or an
    # already-covered missing-file case. `:ok` on both real branches (a
    # tightened file, an absent one) is what the spec promises regardless
    # of what `File.chmod/2` itself reports — the warn-and-continue behaviour
    # for a failure is read off the source, not exercised here.
    test "leaves an already-0600 db alone and logs nothing", %{dir: dir} do
      db = DataDir.db_path(dir)
      File.write!(db, "")
      File.chmod!(db, 0o600)

      log = ExUnit.CaptureLog.capture_log(fn -> assert DataDir.secure_db(dir) == :ok end)

      assert (File.stat!(db).mode &&& 0o777) == 0o600
      assert log == ""
    end

    test "ensure!/1 tightens an existing cairn.db", %{dir: dir} do
      db = DataDir.db_path(dir)
      File.write!(db, "")
      File.chmod!(db, 0o644)

      assert :ok == DataDir.ensure!(dir)

      assert (File.stat!(db).mode &&& 0o777) == 0o600
    end

    test "ensure!/1 creates a fresh data dir at 0700" do
      dir =
        Path.join(
          System.tmp_dir!(),
          "cairn_data_dir_fresh_#{System.unique_integer([:positive])}"
        )

      refute File.exists?(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      assert :ok == DataDir.ensure!(dir)

      assert (File.stat!(dir).mode &&& 0o777) == 0o700
    end
  end

  describe "phoenix filter_parameters" do
    test "redacts camera URL params the same way as password/token" do
      # Phoenix compiles the configured list into an internal matcher on
      # boot (Phoenix.Logger.compile_filter/1), so this exercises the
      # actual redaction path rather than inspecting the compiled term.
      filtered =
        Phoenix.Logger.filter_values(%{
          "rtsp_url" => "rtsp://user:pass@host/stream",
          "substream_url" => "rtsp://user:pass@host/sub",
          "camera_id" => "driveway"
        })

      assert filtered["rtsp_url"] == "[FILTERED]"
      assert filtered["substream_url"] == "[FILTERED]"
      assert filtered["camera_id"] == "driveway"
    end
  end
end
