defmodule Cairn.Tracker.StageTest do
  @moduledoc """
  `Cairn.Tracker.Stage.validate_lists/1` — the constraint checks that move
  into config load when profiles supply the lists. The dummy modules below
  exist because the real stages can only demonstrate *valid* lists; every
  rejection needs a module shaped wrong on purpose.
  """

  use ExUnit.Case, async: true

  alias Cairn.Tracker.Stage

  defmodule BatchOnly do
    def call(batch, _params), do: batch
  end

  defmodule PerObjectOnly do
    def per_object(tracked, _object, _detected?, _context, _params), do: tracked
  end

  defmodule Adjacent do
    def call(batch, _params), do: batch
    def constraints, do: %{adjacent_after: :iou_association}
  end

  defmodule Paired do
    def call(batch, _params), do: batch
    def constraints, do: %{paired_across_association: true}
  end

  defmodule NoCallbacks do
  end

  defp lists(overrides) do
    Map.merge(%{association_one: [], association_two: [], per_object: []}, Map.new(overrides))
  end

  test "the real transitional lists validate" do
    bbd = [{Stage.Bbd, %{}}]

    assert :ok =
             Stage.validate_lists(
               lists(
                 association_one: bbd,
                 association_two: bbd,
                 per_object: [{Stage.Oru, %{}}]
               )
             )
  end

  test "empty lists validate — the no-flags path" do
    assert :ok = Stage.validate_lists(lists([]))
  end

  test "a per-object stage in a batch position is rejected by kind" do
    assert {:error, message} =
             Stage.validate_lists(lists(association_one: [{PerObjectOnly, %{}}]))

    assert message =~ "call/2"
    assert message =~ "PerObjectOnly"
  end

  test "a batch stage in the per-object list is rejected by kind" do
    assert {:error, message} = Stage.validate_lists(lists(per_object: [{BatchOnly, %{}}]))
    assert message =~ "per_object/5"
  end

  test "a module exporting neither callback is rejected in either position" do
    assert {:error, one} = Stage.validate_lists(lists(association_one: [{NoCallbacks, %{}}]))
    assert one =~ "call/2"

    assert {:error, two} = Stage.validate_lists(lists(per_object: [{NoCallbacks, %{}}]))
    assert two =~ "per_object/5"
  end

  test "malformed shapes come back as errors, never raises" do
    # The function's destiny is config-load validation, so config-derived
    # garbage must surface through {:error, _}, not a KeyError.
    assert {:error, message} = Stage.validate_lists(%{association_one: []})
    assert message =~ "must be a map with"

    assert {:error, message} = Stage.validate_lists(lists(per_object: [Stage.Oru]))
    assert message =~ "not a `{module, params}` tuple"

    assert {:error, _message} = Stage.validate_lists(lists(association_one: [{"bbd", %{}}]))
  end

  test "a module that cannot be loaded names that mistake, not a kind mismatch" do
    assert {:error, message} =
             Stage.validate_lists(lists(association_one: [{Cairn.Tracker.Stage.Typo, %{}}]))

    assert message =~ "cannot be loaded"
    refute message =~ "does not export"
  end

  test "an adjacent_after stage anywhere but the head of its point is rejected" do
    ok = [{Adjacent, %{}}, {BatchOnly, %{}}]
    displaced = [{BatchOnly, %{}}, {Adjacent, %{}}]

    assert :ok = Stage.validate_lists(lists(association_one: ok))
    assert {:error, message} = Stage.validate_lists(lists(association_two: displaced))
    assert message =~ "adjacent_after"
  end

  test "a paired stage at one association point only is rejected" do
    one_sided = [{Paired, %{}}]

    assert {:error, message} = Stage.validate_lists(lists(association_one: one_sided))
    assert message =~ "both association points or neither"

    assert :ok =
             Stage.validate_lists(lists(association_one: one_sided, association_two: one_sided))
  end
end
