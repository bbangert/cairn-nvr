defmodule Cairn.TwinBoard do
  @moduledoc """
  The generic board plus one accelerator backend, `accel`, whose artifact the
  CPU baseline cannot run: no board in this tree has a `cpu_twin: true`
  backend. `attach/0` makes it the node's board for the calling test, which
  must not be async — the attachment is VM-global. Its own profile dir is the
  calling process's `:release_dir`, a release dir, where a rung may name a
  file to fetch.
  """

  alias Cairn.Board.Generic
  alias Cairn.Board.Loader

  @key {Loader, :board}

  def name, do: "twin"

  def backends do
    Map.put(Generic.backends(), "accel", %{
      artifact: "accel",
      fused_nms: true,
      dynamic_shapes: false,
      cpu_twin: true,
      experimental: true
    })
  end

  def profiles_dir, do: Process.get(:release_dir) || Generic.profiles_dir()

  defdelegate detect_chain(context), to: Generic
  defdelegate decoders, to: Generic
  defdelegate decoder_backend(decoder, base), to: Generic
  defdelegate engine(backend, base), to: Generic
  defdelegate preflight, to: Generic
  defdelegate artifacts(context), to: Generic

  @doc "Attaches this board until the calling test exits."
  def attach do
    before = :persistent_term.get(@key, :unset)

    ExUnit.Callbacks.on_exit(fn ->
      if before == :unset,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, before)
    end)

    :persistent_term.put(@key, {:attached, %{board: __MODULE__}})
    :ok
  end
end
