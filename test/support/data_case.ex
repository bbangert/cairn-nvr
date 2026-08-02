defmodule Cairn.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Cairn.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Cairn.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Cairn.DataCase
    end
  end

  setup tags do
    Cairn.DataCase.setup_sandbox(tags)
    Cairn.DataCase.reset_checkpoints()
    :ok
  end

  @doc """
  Empties `Cairn.EventCheckpoint`'s table around the test.

  That table is a public named ETS table owned by an application process, so
  it outlives the test that wrote to it — and `Cairn.CameraTracker.init/1`
  reads its own camera's row from it and consults the event index for that
  row. A row one test leaves behind is therefore restored by a tracker some
  later test starts for the same camera id, in that test's sandbox.

  Call it from any test that starts a `Cairn.CameraTracker` or writes a
  checkpoint, even one that does not `use Cairn.DataCase`.
  """
  @spec reset_checkpoints() :: :ok
  def reset_checkpoints do
    Cairn.EventCheckpoint.clear()
    on_exit(&Cairn.EventCheckpoint.clear/0)
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Cairn.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
