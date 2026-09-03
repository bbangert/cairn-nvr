defmodule CairnWeb.Router do
  use CairnWeb, :router

  # inline styles are part of the design-system port; fonts/icons come from
  # the CDNs pinned in root.html.heex; media plays from blobs (MSE) and self
  @csp "default-src 'self'; " <>
         "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com https://rsms.me; " <>
         "font-src 'self' https://fonts.gstatic.com https://rsms.me; " <>
         "img-src 'self' data:; media-src 'self' blob:; " <>
         "connect-src 'self' ws: wss:; script-src 'self'; " <>
         "object-src 'none'; frame-ancestors 'self'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CairnWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  # Home Assistant surface: token-authed, JSON. Distinct from :browser so the
  # cookie-authed LiveView pages are unaffected. HA fetches server-side, so CORS
  # is not needed; requests carry `Authorization: Bearer <token>`.
  pipeline :api do
    plug :accepts, ["json", "sse", "sdp"]
    plug CairnWeb.Plugs.ApiAuth
  end

  # Media is token-authed like :api but negotiates no format: MediaController
  # sets the content-type itself (mp4/jpg/msgpack), and restricting `:accepts`
  # would 406 a player sending `Accept: video/mp4` / `image/jpeg`.
  pipeline :api_media do
    plug CairnWeb.Plugs.ApiAuth
  end

  scope "/", CairnWeb do
    pipe_through :browser

    live "/", DashboardLive
    live "/events", EventsLive
    live "/events/:id", EventLive
    live "/tracks", TracksLive
    live "/cameras", CamerasLive, :index
    live "/cameras/new", CamerasLive, :new
    live "/cameras/:id/edit", CamerasLive, :edit
    live "/config", ConfigLive
  end

  scope "/hls", CairnWeb do
    get "/:camera/index.m3u8", HLSController, :playlist
    get "/:camera/init.mp4", HLSController, :init_segment
    get "/:camera/:segment", HLSController, :segment
  end

  scope "/media", CairnWeb do
    get "/events/:id", MediaController, :event_clip
    get "/events/:id/tracks", MediaController, :event_tracks
    get "/snapshots/:id", MediaController, :snapshot
  end

  # Home Assistant integration API (token-authed). Controllers live under
  # CairnWeb.Api.*; see docs/ha-api.md for the contract.
  scope "/api", CairnWeb.Api do
    pipe_through :api

    get "/cameras", CameraController, :index
    post "/cameras/:id/control", CameraController, :control
    get "/events", EventController, :index
    get "/events/:id", EventController, :show
    get "/labels", EventController, :labels
    get "/stream", EventStreamController, :stream

    # WHEP WebRTC live stream: POST an offer, DELETE the returned resource.
    post "/cameras/:id/webrtc", WhepController, :create
    delete "/webrtc/:resource_id", WhepController, :delete
  end

  # Media reuse: the browser's MediaController (Range-capable on clips) served
  # under the token-authed :api pipeline, so HA's Media Browser resolves
  # clips/snapshots. The track sidecar rides along for parity; no HA response
  # links to it yet.
  scope "/api/media", CairnWeb do
    pipe_through :api_media

    get "/events/:id", MediaController, :event_clip
    get "/events/:id/tracks", MediaController, :event_tracks
    get "/snapshots/:id", MediaController, :snapshot
  end

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
