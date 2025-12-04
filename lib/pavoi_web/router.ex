defmodule PavoiWeb.Router do
  use PavoiWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PavoiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Protected pipeline - requires password in production if SITE_PASSWORD env var is set
  pipeline :protected do
    plug PavoiWeb.Plugs.RequirePassword
  end

  # Authentication routes (not protected to avoid infinite redirect)
  scope "/auth", PavoiWeb do
    pipe_through :browser

    get "/login", AuthController, :login
    post "/authenticate", AuthController, :authenticate
    get "/logout", AuthController, :logout
  end

  # TikTok Shop OAuth routes (not protected to allow callbacks)
  scope "/tiktok", PavoiWeb do
    pipe_through :browser

    get "/callback", TiktokShopController, :callback
  end

  # TikTok Shop API test route
  scope "/api/tiktok", PavoiWeb do
    pipe_through :api

    get "/test", TiktokShopController, :test
  end

  # Main application routes (protected in production)
  scope "/", PavoiWeb do
    pipe_through [:browser, :protected]

    # Redirect root to sessions manager
    get "/", Redirector, :redirect_to_sessions

    # Product management
    live "/products", ProductsLive.Index

    # Session management and live control
    live "/sessions", SessionsLive.Index
    live "/sessions/:id/host", SessionHostLive
    live "/sessions/:id/controller", SessionControllerLive

    # Creator CRM
    live "/creators", CreatorsLive.Index
  end

  # Other scopes may use custom stacks.
  # scope "/api", PavoiWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pavoi, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PavoiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
