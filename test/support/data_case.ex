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
  Empties both active-event checkpoint tables around the test.

  They are public named ETS tables owned by application processes, so they
  outlive the test that wrote to them — and both lanes read their own camera's
  row in `init/1` and consult the event index for it
  (`Cairn.CameraTracker.init/1`, `Cairn.PresenceRecorder.init/1`). A row one
  test leaves behind is therefore restored by a process some later test starts
  for the same camera id, in that test's sandbox.

  Call it from any test that starts either of those, or writes a checkpoint,
  even one that does not `use Cairn.DataCase`.
  """
  @spec reset_checkpoints() :: :ok
  def reset_checkpoints do
    clear_checkpoints()
    on_exit(&Cairn.DataCase.clear_checkpoints/0)
  end

  @doc false
  @spec clear_checkpoints() :: :ok
  def clear_checkpoints do
    Cairn.EventCheckpoint.clear()
    Cairn.PresenceCheckpoint.clear()
    :ok
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
