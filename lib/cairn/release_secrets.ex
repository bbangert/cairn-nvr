defmodule Cairn.ReleaseSecrets do
  @moduledoc """
  Release-boot secret management. Cairn is LAN-trusted with no accounts,
  so the endpoint's `secret_key_base` (cookie/LiveView signing only) is
  auto-generated once and persisted under the data dir when the operator
  doesn't provide `SECRET_KEY_BASE`.
  """

  @doc "Returns SECRET_KEY_BASE, generating + persisting one if needed."
  @spec ensure_secret_key_base!() :: String.t()
  def ensure_secret_key_base! do
    data_dir = Cairn.Config.resolve_data_dir(Cairn.Config.default_path())
    path = Path.join(data_dir, ".secret_key_base")

    case File.read(path) do
      {:ok, secret} when byte_size(secret) >= 64 ->
        String.trim(secret)

      _ ->
        secret = 64 |> :crypto.strong_rand_bytes() |> Base.encode64(padding: false)
        File.mkdir_p!(data_dir)
        File.write!(path, secret)
        File.chmod(path, 0o600)
        secret
    end
  end
end
