defmodule Cairn.Config.PluginGroup do
  @moduledoc """
  A named entry of the top-level `plugins:` map: the profile every camera
  that references it by name (`plugin: <name>`) detects on.

  Historically a group also carried the `command:` of an external plugin
  process serving its members; that path was deleted in membrane port
  phase 6 (detection runs in this node's own engine — `Cairn.Native.Host`),
  so a leftover `command:` key gets the unknown-key warning rather than an
  error, and a group is now nothing but a profile reference.

  `allow_experimental` is the operator's acknowledgement that a profile
  naming a non-ort backend — stubbed (rknn) or not yet proven in soak
  (qnn) — may run anyway (the profile must declare `experimental: true`
  too — `Cairn.Config` enforces both halves).
  """

  alias Cairn.Config

  @known_keys ~w(profile allow_experimental)

  defstruct name: nil,
            # A profile name string at parse; the resolved
            # `Cairn.Config.Profile` struct (or nil) after `Cairn.Config`'s
            # second pass — the same two-phase shape a camera's `plugin:`
            # reference resolves through.
            profile: nil,
            allow_experimental: false

  @type t :: %__MODULE__{}

  @doc false
  @spec parse(term(), term(), map()) :: {t() | nil, map()}
  def parse(raw, name, acc) when is_map(raw) do
    acc = warn_unknown(acc, raw, @known_keys, "plugin #{name}")

    with {profile, acc} when profile != :error <-
           parse_profile(Map.get(raw, "profile"), name, acc),
         {allow, acc} when allow != :error <-
           parse_allow_experimental(Map.get(raw, "allow_experimental"), name, acc) do
      {%__MODULE__{name: name, profile: profile, allow_experimental: allow}, acc}
    else
      {_failed, acc} -> {nil, acc}
    end
  end

  def parse(_raw, name, acc) do
    {nil, add_error(acc, "plugin #{name}: must be a mapping")}
  end

  # Required, where it used to be optional beside a `command:`: a group is
  # only a profile reference now, so one without a profile selects nothing.
  defp parse_profile(nil, name, acc) do
    {:error,
     add_error(
       acc,
       "plugin #{name}: profile is required — a plugins: entry names the profile its " <>
         "cameras detect on (the external command: form was removed in membrane port phase 6)"
     )}
  end

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
