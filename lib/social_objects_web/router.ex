defmodule SocialObjectsWeb.Router do
  use SocialObjectsWeb, :router

  import SocialObjectsWeb.UserAuth

  # Strict CSP for most routes - no unsafe-inline/unsafe-eval for scripts
  # This provides protection against XSS attacks for the majority of the application.
  # Note: 'unsafe-inline' is allowed for styles to support email template previews,
  # which use inline styles (standard for email HTML) in sandboxed iframe srcdoc.
  @strict_csp %{
    "content-security-policy" =>
      "default-src 'self'; " <>
        "script-src 'self' blob: data:; " <>
        "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "style-src-elem 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "img-src 'self' data: blob: https:; " <>
        "font-src 'self' data: https://cdnjs.cloudflare.com; " <>
        "frame-src 'self' blob: data: https://www.tiktok.com; " <>
        "child-src 'self' blob: data:; " <>
        "connect-src 'self' ws: wss: https://storage.railway.app; " <>
        "frame-ancestors 'self'; " <>
        "base-uri 'self';"
  }

  # Permissive CSP ONLY for GrapesJS template editor
  # The editor requires 'unsafe-inline' and 'unsafe-eval' for its canvas iframe
  # This is isolated to template editor routes only
  @editor_csp %{
    "content-security-policy" =>
      "default-src 'self'; " <>
        "script-src 'self' 'unsafe-inline' 'unsafe-eval' blob: data:; " <>
        "style-src 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "style-src-elem 'self' 'unsafe-inline' https://cdnjs.cloudflare.com; " <>
        "img-src 'self' data: blob: https:; " <>
        "font-src 'self' data: https://cdnjs.cloudflare.com; " <>
        "frame-src 'self' blob: data: https://www.tiktok.com; " <>
        "child-src 'self' blob: data:; " <>
        "connect-src 'self' ws: wss: https://storage.railway.app; " <>
        "frame-ancestors 'self'; " <>
        "base-uri 'self';"
  }

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SocialObjectsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @strict_csp
    plug :fetch_current_scope_for_user
  end

  # Separate pipeline for template editor with permissive CSP
  pipeline :browser_editor do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SocialObjectsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, @editor_csp
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Health check endpoint (no auth, no database)
  scope "/", SocialObjectsWeb do
    get "/health", HealthController, :check
  end

  # TikTok Shop OAuth routes (not protected to allow callbacks)
  scope "/tiktok", SocialObjectsWeb do
    pipe_through :browser

    get "/authorize", TiktokShopController, :authorize
    get "/callback", TiktokShopController, :callback
  end

  # TikTok Shop API test route
  scope "/api/tiktok", SocialObjectsWeb do
    pipe_through :api

    get "/test", TiktokShopController, :test
  end

  # SendGrid webhook endpoint (unauthenticated - SendGrid POSTs here)
  scope "/webhooks", SocialObjectsWeb do
    pipe_through :api

    post "/sendgrid", SendgridWebhookController, :handle
  end

  # Public pages (unauthenticated - accessed from email links)
  scope "/", SocialObjectsWeb do
    pipe_through :browser

    get "/unsubscribe/:token", UnsubscribeController, :unsubscribe
    live "/join/:token", JoinLive, :index
    live "/share/:token", PublicProductSetLive, :index
  end

  # Root redirect (login or default brand)
  scope "/", SocialObjectsWeb do
    pipe_through :browser

    get "/", HomeController, :index
  end

  # Brand-scoped application routes (authenticated)
  scope "/", SocialObjectsWeb do
    pipe_through [:browser]

    live_session :require_authenticated_user,
      layout: {SocialObjectsWeb.Layouts, :app},
      on_mount: [
        {SocialObjectsWeb.UserAuth, :require_authenticated},
        {SocialObjectsWeb.UserAuth, :require_password_changed},
        {SocialObjectsWeb.BrandAuth, :set_brand},
        {SocialObjectsWeb.BrandAuth, :require_brand_access},
        {SocialObjectsWeb.NavHooks, :set_current_page}
      ] do
      # Default host (path-based)
      scope "/b/:brand_slug" do
        live "/products", ProductsLive.Index
        live "/products/:id/host", ProductHostLive.Index
        live "/products/:id/controller", ProductControllerLive.Index
        live "/creators", CreatorsLive.Index
        live "/videos", VideosLive.Index
        live "/streams", TiktokLive.Index
        live "/shop-analytics", ShopAnalyticsLive.Index
        live "/readme", ReadmeLive.Index
      end

      # Custom domains (host-based)
      scope "/" do
        live "/products", ProductsLive.Index
        live "/products/:id/host", ProductHostLive.Index
        live "/products/:id/controller", ProductControllerLive.Index
        live "/creators", CreatorsLive.Index
        live "/videos", VideosLive.Index
        live "/streams", TiktokLive.Index
        live "/shop-analytics", ShopAnalyticsLive.Index
        live "/readme", ReadmeLive.Index
      end

      live "/users/settings", UserLive.Settings, :edit
    end
  end

  # Template editor routes with permissive CSP (GrapesJS requires unsafe-inline/eval)
  scope "/", SocialObjectsWeb do
    pipe_through [:browser_editor]

    live_session :template_editor,
      layout: {SocialObjectsWeb.Layouts, :app},
      on_mount: [
        {SocialObjectsWeb.UserAuth, :require_authenticated},
        {SocialObjectsWeb.UserAuth, :require_password_changed},
        {SocialObjectsWeb.BrandAuth, :set_brand},
        {SocialObjectsWeb.BrandAuth, :require_brand_access},
        {SocialObjectsWeb.NavHooks, :set_current_page}
      ] do
      scope "/b/:brand_slug" do
        live "/templates/new", TemplateEditorLive, :new
        live "/templates/:id/edit", TemplateEditorLive, :edit
      end

      scope "/" do
        live "/templates/new", TemplateEditorLive, :new
        live "/templates/:id/edit", TemplateEditorLive, :edit
      end
    end
  end

  # Platform admin routes (admin users only)
  scope "/admin", SocialObjectsWeb do
    pipe_through [:browser]

    live_session :require_admin,
      layout: {SocialObjectsWeb.Layouts, :app},
      on_mount: [
        {SocialObjectsWeb.UserAuth, :require_authenticated},
        {SocialObjectsWeb.UserAuth, :require_password_changed},
        {SocialObjectsWeb.AdminAuth, :require_admin},
        {SocialObjectsWeb.BrandAuth, :set_brand},
        {SocialObjectsWeb.NavHooks, :set_current_page}
      ] do
      live "/", AdminLive.Dashboard, :index
      live "/brands", AdminLive.Brands, :index
      live "/users", AdminLive.Users, :index
    end
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:social_objects, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: SocialObjectsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", SocialObjectsWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [
        {SocialObjectsWeb.UserAuth, :mount_current_scope},
        {SocialObjectsWeb.UserAuth, :require_authenticated}
      ] do
      live "/users/change-password", UserLive.ChangePassword, :edit
    end

    live_session :unauthenticated,
      on_mount: [{SocialObjectsWeb.UserAuth, :mount_current_scope}] do
      live "/users/log-in", UserLive.Login, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end
end
