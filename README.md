# Pavoi - Live Session Orchestrator

Pavoi is a purpose-built Phoenix LiveView application for TikTok live streaming sessions. It replaces ad hoc Google Sheets with real-time product catalog management, keyboard-driven navigation, and synchronized host/producer views.

## Quick Start (Core MVP)

### Prerequisites

- Elixir 1.15+ and Erlang/OTP 26+
- PostgreSQL 15+ (local or hosted, e.g., Supabase)
- Node.js 18+ (for asset compilation)

### 1. Clone and Install

```bash
git clone <your-repo-url>
cd pavoi
mix deps.get
```

### 2. Configure Database

**Option A: Use Supabase (Recommended)**

1. Create a Supabase project at https://supabase.com
2. Copy `.env.example` to `.env`:
   ```bash
   cp .env.example .env
   ```

3. Fill in your database URL in `.env`:
   ```bash
   DATABASE_URL=postgresql://postgres:your-password@your-project.supabase.co:5432/postgres
   ```

**Option B: Use Local PostgreSQL**

Leave DATABASE_URL unset in `.env`, and the app will use local PostgreSQL:
- Username: `postgres`
- Password: `postgres`
- Database: `pavoi_dev`

### 3. Create Database and Run Migrations

```bash
mix ecto.create
mix ecto.migrate
```

### 4. Seed Sample Data

```bash
mix run priv/repo/seeds.exs
```

This creates:
- 1 brand (Pavoi)
- 8 sample products with talking points
- 1 session with all products
- Initialized session state

### 5. Compile Assets

```bash
mix assets.build
```

### 6. Start the Server

```bash
mix phx.server
```

Visit: **http://localhost:4000/sessions/1/producer**

## Keyboard Controls

Pavoi is designed for hands-free operation during live streams:

### Primary Navigation (Direct Jumps)
- **Type number + Enter**: Jump directly to product (e.g., "23" → Enter jumps to product 23)

### Convenience Navigation (Sequential)
- **↓**: Next product
- **↑**: Previous product
- **Space**: Next product
- **←**: Previous image
- **→**: Next image

## Core Features (MVP)

✅ **Real-time state synchronization** via Phoenix PubSub
✅ **Keyboard-driven navigation** optimized for live streaming
✅ **Dark theme UI** with high contrast for studio environments
✅ **Temporary assigns** for memory management during 3-4 hour sessions
✅ **URL-based state persistence** (survives browser refreshes)
✅ **Markdown support** for product talking points
✅ **Per-session product overrides** (prices, talking points)

## Project Structure

```
pavoi/
├── lib/
│   ├── pavoi/
│   │   ├── catalog/           # Product catalog schemas
│   │   │   ├── brand.ex
│   │   │   ├── product.ex
│   │   │   └── product_image.ex
│   │   ├── sessions/          # Live session schemas
│   │   │   ├── session.ex
│   │   │   ├── session_product.ex
│   │   │   └── session_state.ex
│   │   ├── catalog.ex         # Catalog context (CRUD)
│   │   └── sessions.ex        # Sessions context (state management)
│   └── pavoi_web/
│       ├── live/
│       │   ├── session_host_live.ex       # Host view (read-only)
│       │   └── session_producer_live.ex   # Producer control panel
│       └── router.ex
├── assets/
│   ├── js/
│   │   ├── app.js
│   │   └── hooks.js           # Keyboard control hooks
│   └── css/
│       └── app.css            # Dark theme styles
├── priv/
│   └── repo/
│       ├── migrations/        # Database migrations
│       └── seeds.exs          # Sample data
└── docs/                      # Comprehensive documentation
    ├── README.md
    ├── product_requirements.md
    ├── architecture.md
    ├── domain_model.md
    ├── implementation_guide.md
    └── future_roadmap.md
```

## Development Workflow

### Running Tests (Coming Soon)
```bash
mix test
```

### Interactive Console
```bash
iex -S mix phx.server
```

### View LiveDashboard
Visit: http://localhost:4000/dev/dashboard

### Reset Database
```bash
mix ecto.reset  # Drops, creates, migrates, and seeds
```

## Real-Time Synchronization

Pavoi uses Phoenix PubSub to synchronize state across multiple connected clients:

1. **Host View**: Read-only display optimized for on-camera host
2. **Producer Console**: Remote control of session state
3. **State Changes**: Broadcast to all subscribers within <1 second

**PubSub Topics:**
- `session:#{id}:state` - Current product and image index changes
- Automatic reconnection with state recovery

## Memory Management

Pavoi is optimized for 3-4 hour live streaming sessions:

- **Temporary assigns**: Render-only data cleared after each render
- **Minimal state**: Only current product kept in memory
- **DB-first approach**: State persisted to database, not just LiveView process
- **Preloading strategy**: Adjacent products (±2) for arrow key convenience

## Database Schema

**Core tables:**
- `brands` - Brand information (e.g., Pavoi)
- `products` - Global product catalog with talking points
- `product_images` - Multiple images per product with ordering
- `sessions` - Live streaming events
- `session_products` - Products in a session with position and overrides
- `session_states` - Real-time current product/image tracking

See `docs/domain_model.md` for full schema details.

## Environment Variables

All configuration is managed via environment variables. See `.env.example` for the complete list.

**Required:**
- `DATABASE_URL` - PostgreSQL connection string
- `SECRET_KEY_BASE` - Phoenix secret (generate with `mix phx.gen.secret`)

**Optional:**
- `SHOPIFY_ACCESS_TOKEN` - Shopify API access token for product images
- `SHOPIFY_STORE_NAME` - Your Shopify store name

## Troubleshooting

### Database Connection Issues

If you see SSL verification errors when connecting to a remote PostgreSQL database, ensure your database provider's SSL certificate is properly configured in your connection string or system trust store.

### Compilation Warnings

You may see a warning about spaces in the path (Dropbox folder). This doesn't affect functionality but can be resolved by moving the project to a path without spaces.

### Port Already in Use

If port 4000 is busy:
```bash
PORT=4001 mix phx.server
```

## Next Steps

For deployment, production configuration, and roadmap features, see `docs/future_roadmap.md`.

## Contributing

1. Review `docs/architecture.md` for system design
2. Follow existing code patterns
3. Add tests for new features
4. Update documentation

## Links

- **Phoenix Framework**: https://phoenixframework.org
- **Phoenix LiveView**: https://hexdocs.pm/phoenix_live_view
- **Supabase**: https://supabase.com/docs
- **Documentation**: See `docs/` directory

## License

Proprietary - Internal use only

---

**Built with Phoenix LiveView for real-time, low-latency live streaming control.**
