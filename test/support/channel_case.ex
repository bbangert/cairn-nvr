defmodule CairnWeb.ChannelCase do
  @moduledoc """
  Test case for channel tests (`Phoenix.ChannelTest` against
  `CairnWeb.Endpoint`).
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import CairnWeb.ChannelCase

      @endpoint CairnWeb.Endpoint
    end
  end
end
