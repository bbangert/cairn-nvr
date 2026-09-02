defmodule Cairn.Cameras.CameraTest do
  use Cairn.DataCase, async: true

  alias Cairn.Cameras.Camera

  test "accepts a valid slug" do
    changeset = Camera.changeset(%Camera{}, %{id: "front-door_1", position: 0})
    assert changeset.valid?
  end

  test "refuses an uppercase id" do
    changeset = Camera.changeset(%Camera{}, %{id: "Cam_A", position: 0})

    assert "must be lowercase [a-z0-9_-] starting with a letter or digit" in errors_on(changeset).id
  end

  test "refuses an id starting with a dash" do
    changeset = Camera.changeset(%Camera{}, %{id: "-x", position: 0})

    assert "must be lowercase [a-z0-9_-] starting with a letter or digit" in errors_on(changeset).id
  end

  test "refuses a trailing newline (pins the anchors)" do
    changeset = Camera.changeset(%Camera{}, %{id: "cam_a\n", position: 0})

    assert "must be lowercase [a-z0-9_-] starting with a letter or digit" in errors_on(changeset).id
  end

  test "enabled defaults true when omitted" do
    changeset = Camera.changeset(%Camera{}, %{id: "cam1", position: 0})
    assert {:ok, camera} = Repo.insert(changeset)
    assert camera.enabled
  end

  test "position must be >= 0" do
    changeset = Camera.changeset(%Camera{}, %{id: "cam1", position: -1})
    refute changeset.valid?
    assert "must be greater than or equal to 0" in errors_on(changeset).position
  end

  test "inserting the same id twice yields the unique error on :id" do
    assert {:ok, _} =
             %Camera{} |> Camera.changeset(%{id: "dup", position: 0}) |> Repo.insert()

    assert {:error, changeset} =
             %Camera{} |> Camera.changeset(%{id: "dup", position: 1}) |> Repo.insert()

    assert "has already been taken" in errors_on(changeset).id
  end

  test "update_changeset/2 ignores an id change" do
    {:ok, camera} =
      %Camera{} |> Camera.changeset(%{id: "cam1", position: 0}) |> Repo.insert()

    changeset = Camera.update_changeset(camera, %{id: "cam2", position: 1})
    assert {:ok, updated} = Repo.update(changeset)
    assert updated.id == "cam1"
    assert updated.position == 1
  end
end
