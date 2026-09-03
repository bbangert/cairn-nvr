defmodule Cairn.Cameras.CandidateTest do
  use ExUnit.Case, async: true

  alias Cairn.Cameras.Candidate
  alias Cairn.Config

  @valid_fixture "test/support/fixtures/configs/valid.yml"

  # The non-camera half of the file, which is what the form validates a
  # candidate fleet against (PR C caches it).
  defp globals do
    {:ok, raw} = Config.raw_map(@valid_fixture)
    Map.delete(raw, "cameras")
  end

  defp row(id, settings \\ %{}) do
    Map.merge(%{"id" => id, "rtsp_url" => "rtsp://h/#{id}"}, settings)
  end

  # The two argv profiles ask for different models, which is the cross-camera
  # rule a candidate can trip without any row of its own being wrong.
  defp model_globals do
    Map.merge(globals(), %{
      "profile_dirs" => ["test/support/fixtures/profiles/argv"],
      "plugins" => %{"full" => %{"profile" => "full"}, "partial" => %{"profile" => "partial"}}
    })
  end

  describe "validate/4" do
    test "a clean candidate has no errors" do
      result = Candidate.validate(row("cam1"), [row("cam1"), row("cam2")], globals(), mode: :edit)

      assert result.errors == []
      assert result.own == []
      assert result.others == %{}
      assert result.fleet == []
    end

    test "the candidate's own fault is blamed on it" do
      candidate = row("cam1", %{"rtsp_url" => nil})

      result = Candidate.validate(candidate, [row("cam1"), row("cam2")], globals(), mode: :edit)

      assert result.own == ["camera cam1: rtsp_url is required"]
      assert result.others == %{}
      assert result.fleet == []
      assert result.errors == result.own
    end

    test "another row's fault is filed under that row, not the candidate" do
      rows = [row("cam1"), row("cam2", %{"rtsp_url" => nil})]

      result = Candidate.validate(row("cam1"), rows, globals(), mode: :edit)

      assert result.own == []
      assert result.others == %{"cam2" => ["camera cam2: rtsp_url is required"]}
      assert result.fleet == []
    end

    test "an edit replaces the row with its id rather than joining it" do
      rows = [row("cam1", %{"rtsp_url" => nil}), row("cam2")]

      result = Candidate.validate(row("cam1"), rows, globals(), mode: :edit)

      assert result.errors == []
    end

    # `duplicate camera id: …` names no camera, so `partition_by_camera/1`
    # files it fleet-level — the form shows it above the fields, not on one.
    test "a create with a taken id reports the duplicate id, fleet-level" do
      rows = [row("cam1"), row("cam2")]

      result = Candidate.validate(row("cam1"), rows, globals(), mode: :create)

      assert result.fleet == ["duplicate camera id: cam1"]
      assert result.own == []
      assert result.preexisting_fleet == []
    end

    # `Config.Camera.parse/3` can only index-prefix a row with no valid id
    # of its own (`camera #N: id is required …`), and `partition_by_camera/1`
    # has no id to key that on — it lands fleet-level unless this module
    # reclaims it for the candidate that actually caused it.
    test "a create with a missing id files the id error under own, not fleet" do
      rows = [row("cam1")]
      candidate = Map.put(row("cam1"), "id", "")

      result = Candidate.validate(candidate, rows, globals(), mode: :create)

      assert result.own == ["camera : id is required ([a-z0-9_-], lowercase)"]
      assert result.fleet == []

      {routed, unclaimed} = Cairn.Cameras.Settings.field_errors(result.own, "", [])
      assert routed["id"] == ["id is required ([a-z0-9_-], lowercase)"]
      assert unclaimed == []
    end

    # An edit's candidate always occupies a real slot (its own row, or an
    # append for the disabled case) — it cannot come back index-prefixed, so
    # there is nothing here for `:edit` to reclaim.
    test "an edit with a missing id is unaffected by the create-only reclaim" do
      candidate = Map.put(row("cam1"), "id", "")

      result = Candidate.validate(candidate, [row("cam1")], globals(), mode: :edit)

      assert result.own == []
      assert result.fleet == ["camera #1: id is required ([a-z0-9_-], lowercase)"]
    end

    test "a mode is required" do
      assert_raise ArgumentError, ~r/mode: :create \| :edit/, fn ->
        Candidate.validate(row("cam1"), [row("cam1")], globals(), [])
      end
    end

    test "a disabled candidate — no row of its own in the fleet — is validated too" do
      candidate = row("cam_off", %{"rtsp_url" => nil})

      result = Candidate.validate(candidate, [row("cam1")], globals(), mode: :edit)

      assert result.own == ["camera cam_off: rtsp_url is required"]
    end

    test "a fleet-level rule the candidate introduces is not pre-existing" do
      rows = [row("cam1", %{"plugin" => "full"})]
      candidate = row("cam2", %{"plugin" => "partial"})

      result = Candidate.validate(candidate, rows, model_globals(), mode: :edit)

      assert result.own == []
      assert [message] = result.fleet
      assert message =~ "different models (full, partial)"
      assert result.preexisting_fleet == []
    end

    # The saved row stays in the baseline unchanged, so a conflict it was
    # already party to is not something this edit introduced. Validating the
    # baseline with the row removed instead took the other half of the
    # conflict away with it and reported a fault nobody just made.
    test "an unchanged edit of a row already in a fleet conflict reports it pre-existing" do
      rows = [row("cam1", %{"plugin" => "full"}), row("cam2", %{"plugin" => "partial"})]

      result =
        Candidate.validate(row("cam1", %{"plugin" => "full"}), rows, model_globals(), mode: :edit)

      assert result.own == []
      assert [message] = result.fleet
      assert message =~ "different models (full, partial)"
      assert result.preexisting_fleet == result.fleet
    end

    test "a fleet-level fault in the globals is pre-existing, not the candidate's" do
      globals = Map.put(globals(), "retention", %{"days" => -1})

      result = Candidate.validate(row("cam1"), [row("cam1")], globals, mode: :edit)

      assert result.fleet == ["retention.days must be >= 1 and <= 10000"]
      assert result.preexisting_fleet == result.fleet
    end

    test "warnings come back from a candidate with no errors" do
      globals = Map.put(globals(), "nonsense", true)

      result = Candidate.validate(row("cam1"), [row("cam1")], globals, mode: :edit)

      assert result.errors == []
      assert Enum.any?(result.warnings, &(&1 =~ ~s(unknown key "nonsense")))
    end
  end

  describe "render_row/1" do
    test "keeps the parser's keys, drops the rest, and carries id and zones" do
      zones = [%{"name" => "drive", "points" => [[0, 0], [1, 0], [1, 1]]}]

      assert Candidate.render_row(%{
               id: "cam1",
               settings: %{"rtsp_url" => "rtsp://h/1", "nope" => 1},
               zones: zones
             }) == %{"id" => "cam1", "rtsp_url" => "rtsp://h/1", "zones" => zones}
    end
  end
end
