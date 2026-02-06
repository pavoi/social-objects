defmodule PavoiWeb.Router do
  use PavoiWeb, :router

  import PavoiWeb.UserAuth

  # Custom CSP that allows GrapesJS template editor to function
  # The editor needs 'unsafe-inline' and 'unsafe-eval' for its canvas iframe
  # Also allows cdnjs.cloudflare.com for Font Awesome (used by newsletter plugin)
  @csp_header %{
    "content-security-policy" =>
      "default-src 'self'; " <>
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:; " <>
        "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "style-src-elem 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "img-src 'self' data: blob: https:; " <>
        "font-src 'self' data: https://cdnjs.cloudflare.com; " <>
        "frame-src 'self' blob: data:; " <>
        "child-src 'self' blob: data:; " <>
        "connect-src 'self' ws: wss: https://storage.railway.app; " <>
        "frame-ancestors 'self'; " <>
        "base-uri 'self';"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PavoiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @csp_header
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check endpoint (no auth, no database)
  scope "/", PavoiWeb do
    get "/health", HealthController, :check
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

  # SendGrid webhook endpoint (unauthenticated - SendGrid POSTs here)
  scope "/webhooks", PavoiWeb do
    pipe_through :api

    post "/sendgrid", SendgridWebhookController, :handle
  end

  # Public pages (unauthenticated - accessed from email links)
  scope "/", PavoiWeb do
    pipe_through :browser

    get "/invite/:token", UserInviteController, :accept
    get "/unsubscribe/:token", UnsubscribeController, :unsubscribe
    live "/join/:token", JoinLive, :index
    live "/share/:token", PublicProductSetLive, :index
  end

  # Root redirect (login or default brand)
  scope "/", PavoiWeb do
    pipe_through :browser

    get "/", HomeController, :index
  end

  # Brand-scoped application routes (authenticated)
  scope "/", PavoiWeb do
    pipe_through [:browser]

    live_session :require_authenticated_user,
      on_mount: [
        {PavoiWeb.UserAuth, :require_authenticated},
        {PavoiWeb.BrandAuth, :set_brand},
        {PavoiWeb.BrandAuth, :require_brand_access}
      ] do
      # Default host (path-based)
      scope "/b/:brand_slug" do
        live "/product-sets", ProductSetsLive.Index
        live "/product-sets/:id/host", ProductSetHostLive.Index
        live "/product-sets/:id/controller", ProductSetControllerLive.Index
        live "/creators", CreatorsLive.Index
        live "/templates/new", TemplateEditorLive, :new
        live "/templates/:id/edit", TemplateEditorLive, :edit
        live "/streams", TiktokLive.Index
        live "/readme", ReadmeLive.Index
      end

      # Custom domains (host-based)
      scope "/" do
        live "/product-sets", ProductSetsLive.Index
        live "/product-sets/:id/host", ProductSetHostLive.Index
        live "/product-sets/:id/controller", ProductSetControllerLive.Index
        live "/creators", CreatorsLive.Index
        live "/templates/new", TemplateEditorLive, :new
        live "/templates/:id/edit", TemplateEditorLive, :edit
        live "/streams", TiktokLive.Index
        live "/readme", ReadmeLive.Index
      end

      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end
  end

  # Platform admin routes (admin users only)
  scope "/admin", PavoiWeb do
    pipe_through [:browser]

    live_session :require_admin,
      layout: {PavoiWeb.Layouts, :app},
      on_mount: [
        {PavoiWeb.UserAuth, :require_authenticated},
        {PavoiWeb.AdminAuth, :require_admin},
        {PavoiWeb.NavHooks, :set_current_page}
      ] do
      live "/", AdminLive.Dashboard, :index
      live "/brands", AdminLive.Brands, :index
      live "/users", AdminLive.Users, :index
      live "/invites", AdminLive.Invites, :index
    end
  end

  # Legacy redirects for bookmarks
  scope "/b/:brand_slug", PavoiWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/sessions", Redirector, :redirect_to_product_sets
    get "/products", Redirector, :redirect_to_product_sets_products
  end

  scope "/", PavoiWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/sessions", Redirector, :redirect_to_product_sets
    get "/products", Redirector, :redirect_to_product_sets_products
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:pavoi, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: PavoiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", PavoiWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{PavoiWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
