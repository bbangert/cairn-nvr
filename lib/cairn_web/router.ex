defmodule CairnWeb.Router do
  use CairnWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CairnWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CairnWeb do
    pipe_through :browser

    live "/", DashboardLive
  end

  scope "/hls", CairnWeb do
    get "/:camera/index.m3u8", HLSController, :playlist
    get "/:camera/init.mp4", HLSController, :init_segment
    get "/:camera/:segment", HLSController, :segment
  end

  # Other scopes may use custom stacks.
  # scope "/api", CairnWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard in development
  if Application.compile_env(:cairn, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CairnWeb.Telemetry
    end
  end
end
