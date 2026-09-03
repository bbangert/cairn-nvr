defmodule Cairn.Repo do
  use Ecto.Repo,
    otp_app: :cairn,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    if Application.get_env(:cairn, :db_in_data_dir, false) do
      data_dir = Cairn.Config.resolve_data_dir(Cairn.Config.default_path())
      # Not `mkdir_p!`: this is the first thing on the boot to create the data
      # dir, and a dir made under the default umask stays group/world-readable
      # until something tightens it — with SQLite creating `cairn.db`, which
      # holds RTSP userinfo, inside it in between. `ensure!/1` creates it 0700.
      Cairn.DataDir.ensure!(data_dir)
      {:ok, Keyword.put(config, :database, Cairn.DataDir.db_path(data_dir))}
    else
      {:ok, config}
    end
  end
end
