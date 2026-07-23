defmodule CairnWeb.PageController do
  use CairnWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
