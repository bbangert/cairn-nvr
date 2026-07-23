defmodule Cairn.Repo do
  use Ecto.Repo,
    otp_app: :cairn,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    if Application.get_env(:cairn, :db_in_data_dir, false) do
      data_dir = Cairn.Config.resolve_data_dir(Cairn.Config.default_path())
      db_path = Cairn.DataDir.db_path(data_dir)
      File.mkdir_p!(Path.dirname(db_path))
      {:ok, Keyword.put(config, :database, db_path)}
    else
      {:ok, config}
    end
  end
end
