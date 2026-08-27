# Longnames on 127.0.0.1, like the board contract (bare-IP, no DNS) —
# and unlike shortnames it needs no resolvable hostname in CI.
{_, 0} = System.cmd("epmd", ["-daemon"])

case :net_kernel.start(:"driver_test@127.0.0.1", %{name_domain: :longnames}) do
  {:ok, _pid} -> :ok
  {:error, {:already_started, _pid}} -> :ok
end

ExUnit.start()
