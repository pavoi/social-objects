# Implementation Guide

This guide tracks implementation progress and provides instructions for remaining features.

## Implementation Status

### ✅ Completed (Core MVP)

- [x] **Project Setup** - Phoenix 1.8 with LiveView, no Tailwind
- [x] **Database Configuration** - PostgreSQL (hosted or local) with SSL/TLS support
- [x] **Dependencies** - earmark, req, oban, openai_ex
- [x] **Domain Model** - All schemas and migrations (brands, products, product_images, sessions, session_products, session_states)
- [x] **Contexts** - Catalog and Sessions contexts with CRUD operations
- [x] **SessionHostLive & SessionControllerLive** - Separated views with real-time state sync
- [x] **Template** - Dark theme UI optimized for live streaming (3-foot viewing distance)
- [x] **Keyboard Navigation** - JS hooks for hands-free control (direct jump + arrow keys)
- [x] **Voice Control** - Local speech recognition with Whisper.js + Silero VAD (see VOICE_CONTROL_PLAN.md)
- [x] **State Management** - PubSub broadcasting, URL persistence, temporary assigns
- [x] **Seed Data** - 8 sample products with talking points

### 🚧 In Progress / Next Steps

- [x] **Shopify Integration** - Hourly sync via Oban (see `lib/social_objects/shopify/` and `lib/social_objects/workers/shopify_sync_worker.ex`)
- [ ] **Testing** - Context and LiveView tests

### 📦 Post-MVP Features

- [ ] **Authentication Gate** - Hash shared secrets, session tokens, rate limiting
- [ ] **Production Deployment** - Cloud hosting (see DEPLOYMENT.md)

---

## 1. Testing

**Status:** Not implemented
**Priority:** Medium

### 1.1 Context Tests

```elixir
# test/social_objects/sessions_test.exs
defmodule SocialObjects.SessionsTest do
  use SocialObjects.DataCase
  alias SocialObjects.Sessions

  describe "jump_to_product/2" do
    setup do
      session = insert(:session)
      sp1 = insert(:session_product, session: session, position: 1)
      sp10 = insert(:session_product, session: session, position: 10)
      {:ok, _state} = Sessions.initialize_session_state(session.id)

      {:ok, session: session, sp1: sp1, sp10: sp10}
    end

    test "jumps directly to product by position", %{session: session, sp10: sp10} do
      Phoenix.PubSub.subscribe(SocialObjects.PubSub, "session:#{session.id}:state")

      {:ok, new_state} = Sessions.jump_to_product(session.id, 10)

      assert new_state.current_session_product_id == sp10.id
      assert new_state.current_image_index == 0
      assert_receive {:state_changed, ^new_state}
    end

    test "returns error for invalid position", %{session: session} do
      {:error, :invalid_position} = Sessions.jump_to_product(session.id, 999)
    end
  end
end
```

### 1.2 LiveView Tests

```elixir
# test/social_objects_web/live/session_controller_live_test.exs
defmodule SocialObjectsWeb.SessionControllerLiveTest do
  use SocialObjectsWeb.ConnCase
  import Phoenix.LiveViewTest

  test "loads session and displays first product", %{conn: conn} do
    session = insert(:session)
    sp1 = insert(:session_product, session: session, position: 1)

    {:ok, view, html} = live(conn, ~p"/sessions/#{session}/controller")

    assert html =~ session.name
    assert has_element?(view, "#product-img-#{sp1.product_id}-0")
  end
end
```

---

## 2. Authentication Gate (Post-MVP)

**Status:** Not implemented
**Priority:** Low for MVP (local/internal use only)

### MVP Approach

Social Objects is designed for local use by internal team members. Authentication is deferred to post-MVP because:

- **Local deployment only** - Runs on localhost, not exposed to internet
- **Trusted network** - Used by internal team on secure network
- **Simplified onboarding** - No login required, just start the server
- **Focus on core features** - Prioritize session control and image loading

### Future Implementation (When Needed)

When deploying to production or remote access is required:

1. **Create role-specific secrets** and store in `.env`:
   ```bash
   CONTROLLER_SHARED_SECRET=...
   HOST_SHARED_SECRET=...
   ADMIN_SHARED_SECRET=...
   ```

2. **Hash secrets on boot** in `config/runtime.exs`:
   ```elixir
   config :social_objects, SocialObjects.Auth,
     controller_secret_hash: Bcrypt.hash_pwd_salt(System.fetch_env!("CONTROLLER_SHARED_SECRET")),
     host_secret_hash: Bcrypt.hash_pwd_salt(System.fetch_env!("HOST_SHARED_SECRET")),
     admin_secret_hash: Bcrypt.hash_pwd_salt(System.fetch_env!("ADMIN_SHARED_SECRET")),
     session_ttl: 4 * 60 * 60
   ```

3. **Verify logins** with `Bcrypt.verify_pass/2`; issue signed session tokens
4. **Throttle** `/login` route (e.g., using `Hammer`) to 5 attempts/min/IP
5. **Log audit events** (login, logout, elevated actions) with structured metadata

Designate plugs (`SocialObjectsWeb.RequireController`, etc.) now so migrating to `mix phx.gen.auth` later is drop-in.

---

## 3. Production Deployment (Post-MVP)

**Status:** Not implemented
**Priority:** Low (localhost sufficient for MVP)

### 6.1 Production Configuration

```elixir
# config/runtime.exs
if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "DATABASE_URL not set"

  config :social_objects, SocialObjects.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true

  config :social_objects, SocialObjectsWeb.Endpoint,
    server: true,  # CRITICAL for deployment
    http: [port: String.to_integer(System.get_env("PORT") || "4000")]
end
```

---

## Performance Checklist

Critical patterns already implemented:

- [x] ✅ Use `temporary_assigns` for render-only data
- [x] ✅ Preload associations to avoid N+1 queries
- [x] ✅ Subscribe to PubSub only in `connected?(socket)`
- [x] ✅ Use `push_patch` instead of full navigation
- [x] ✅ Debounce rapid user input (keyboard buffer with timeout)
- [x] ✅ Clean up event listeners in hook `destroyed()`
- [ ] ⏳ Monitor socket memory with telemetry
- [ ] ⏳ Use `streams` for large collections (if needed later)

---

## Current Architecture

### File Structure

```
lib/
├── social_objects/
│   ├── catalog/              # Product catalog schemas
│   │   ├── brand.ex
│   │   ├── product.ex
│   │   └── product_image.ex
│   ├── sessions/             # Live session schemas
│   │   ├── session.ex
│   │   ├── session_product.ex
│   │   └── session_state.ex
│   ├── catalog.ex            # Catalog context (CRUD)
│   └── sessions.ex           # Sessions context (state management)
└── social_objects_web/
    ├── live/
    │   ├── session_run_live.ex        # Main LiveView
    │   └── session_run_live.html.heex # Template
    └── router.ex

assets/
├── js/
│   ├── app.js
│   └── hooks.js              # Keyboard control + connection status
└── css/
    └── app.css               # Dark theme styles

priv/
└── repo/
    ├── migrations/           # 6 migrations
    └── seeds.exs             # Sample data (8 products, 1 session)
```

### Key Implementation Details

**Temporary Assigns (Memory Management):**
```elixir
# lib/social_objects_web/live/session_run_live.ex:31-36
{:ok, socket, temporary_assigns: [
  current_session_product: nil,
  current_product: nil,
  talking_points_html: nil,
  product_images: []
]}
```

**State Synchronization:**
```elixir
# lib/social_objects/sessions.ex:258-266
defp broadcast_state_change({:ok, %SessionState{} = state}) do
  Phoenix.PubSub.broadcast(
    SocialObjects.PubSub,
    "session:#{state.session_id}:state",
    {:state_changed, state}
  )
  {:ok, state}
end
```

**Navigation:**
- **Keyboard (Primary):** Type number + Enter (e.g., "23" + Enter)
- **Keyboard (Sequential):** ↑/↓ arrows, Space for products, ←/→ arrows for images
- **Voice Control:** Say product numbers (e.g., "twenty three") - toggle with Ctrl/Cmd + M
  - Local processing with Whisper.js (speech recognition) + Silero VAD (voice activity detection)
  - See VOICE_CONTROL_PLAN.md for complete documentation

**Database Timestamp Handling:**
```elixir
# lib/social_objects/sessions/session_state.ex:22
|> put_change(:updated_at, DateTime.utc_now() |> DateTime.truncate(:second))
```
_Note: PostgreSQL `:utc_datetime` rejects microseconds, must truncate to seconds_

---

## Known Issues & Solutions

### Issue: Navigation crashes with "reconnecting..."

**Cause:** `SessionState.updated_at` field rejected microseconds
**Solution:** Truncate timestamps to seconds in changeset (line 22 of `session_state.ex`)

### Issue: Template errors when state not loaded

**Cause:** Template tried to render before WebSocket connected and loaded state
**Solution:** Wrap product display in conditional checks for nil assigns

---

## Next Session Checklist

When you're ready to continue development:

1. **Add authentication** - Hash secrets, session tokens, rate limiting
4. **Write tests** - Context and LiveView coverage
5. **Deploy to production** - Cloud hosting (see DEPLOYMENT.md)

---

## Summary

**Core MVP is complete and functional:**
- Real-time session control with PubSub synchronization
- Keyboard-driven navigation optimized for live streaming
- Dark theme UI with proper contrast for 3-foot viewing
- Memory-optimized for 3-4 hour sessions
- URL-based state persistence (survives refreshes)
- Database schema with proper associations and constraints

**Ready for use:**
```bash
mix phx.server
# Visit: http://localhost:4000/sessions/2/controller
```

**Next priorities:**
1. Authentication gate
