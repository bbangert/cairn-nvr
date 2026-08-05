defmodule Cairn.Config.PluginGroup do
  @moduledoc """
  A named entry of the top-level `plugins:` map: one plugin process serving
  every camera that references it by name (`plugin: <name>`).

  `command` is the argv of the plugin command: the operator's own tokens,
  followed — for a group naming a `profile:` — by the model flags
  `Cairn.Config` expands from that profile at load
  (`Cairn.Config.Profile`'s "Rust argv"). Expanding it there is what leaves
  everything downstream of the load — `Cairn.PluginGroupPort` included —
  treating the argv as one opaque list that never mentions a profile.

  `allow_experimental` is the operator's acknowledgement that a profile
  naming a backend the Rust plugin has not implemented yet may run anyway
  (the profile must declare `experimental: true` too — `Cairn.Config`
  enforces both halves).

  `members` is resolved by
  `Cairn.Config` once the whole file is parsed — one entry per referencing
  camera, in `cameras:` order, carrying the UDP port and score floors the
  group process is launched with. A group nobody references keeps an empty
  member list.
  """

  alias Cairn.Config

  @known_keys ~w(command profile allow_experimental)

  defstruct name: nil,
            command: nil,
            # A profile name string at parse; the resolved
            # `Cairn.Config.Profile` struct (or nil) after `Cairn.Config`'s
            # second pass — the same two-phase shape a camera's `plugin:`
            # reference resolves through.
            profile: nil,
            allow_experimental: false,
            members: []

  @type member :: %{
          id: String.t(),
          udp_port: pos_integer(),
          min_score: %{String.t() => float()}
        }

  @type t :: %__MODULE__{}

  @doc false
  @spec parse(term(), term(), map()) :: {t() | nil, map()}
  def parse(raw, name, acc) when is_map(raw) do
    acc = warn_unknown(acc, raw, @known_keys, "plugin #{name}")

    with {command, acc} when command != nil <- parse_command(Map.get(raw, "command"), name, acc),
         {profile, acc} when profile != :error <-
           parse_profile(Map.get(raw, "profile"), name, acc),
         {allow, acc} when allow != :error <-
           parse_allow_experimental(Map.get(raw, "allow_experimental"), name, acc) do
      {%__MODULE__{name: name, command: command, profile: profile, allow_experimental: allow},
       acc}
    else
      {_failed, acc} -> {nil, acc}
    end
  end

  def parse(_raw, name, acc) do
    {nil, add_error(acc, "plugin #{name}: must be a mapping")}
  end

  defp parse_command(nil, name, acc) do
    {nil, add_error(acc, "plugin #{name}: command is required")}
  end

  defp parse_command(cmd, name, acc) when is_binary(cmd) do
    case String.split(cmd) do
      [] -> {nil, add_error(acc, "plugin #{name}: command is required")}
      argv -> {argv, acc}
    end
  end

  defp parse_command(argv, name, acc) when is_list(argv) do
    if Enum.all?(argv, &is_binary/1) and argv != [] do
      {argv, acc}
    else
      {nil, invalid_command(acc, name)}
    end
  end

  defp parse_command(_other, name, acc), do: {nil, invalid_command(acc, name)}

  defp invalid_command(acc, name) do
    add_error(acc, "plugin #{name}: command must be a command string or argv list")
  end

  defp parse_profile(nil, _name, acc), do: {nil, acc}
  defp parse_profile(name, _group, acc) when is_binary(name) and name != "", do: {name, acc}

  defp parse_profile(_other, group, acc),
    do: {:error, add_error(acc, "plugin #{group}: profile must be a profile name string")}

  defp parse_allow_experimental(nil, _name, acc), do: {false, acc}
  defp parse_allow_experimental(value, _name, acc) when is_boolean(value), do: {value, acc}

  defp parse_allow_experimental(_other, name, acc),
    do: {:error, add_error(acc, "plugin #{name}: allow_experimental must be true or false")}

  defp add_error(acc, msg), do: Config.add_error(acc, msg)
  defp warn_unknown(acc, map, known, where), do: Config.warn_unknown(acc, map, known, where)
end
