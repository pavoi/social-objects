# Hudson Documentation

**Hudson** is a live session orchestrator for TikTok streaming built with Phoenix LiveView, optimized for 3-4 hour live sessions.

## Quick Start

```bash
# Clone and setup
git clone <repository-url>
cd hudson
mix deps.get
mix ecto.setup

# Start development server
mix phx.server
```

Visit `http://localhost:4000` to access the application.

## Documentation Index

### Planning & Requirements
- **[Product Requirements](product_requirements.md)** - Goals, user personas, UX requirements, and success metrics
- **[Future Roadmap](future_roadmap.md)** - Planned features and enhancements beyond MVP

### Technical Documentation
- **[Architecture](architecture.md)** - System design patterns, context boundaries, and architectural decisions (high-level)
- **[Domain Model](domain_model.md)** - Database schema, entities, relationships, and migrations
- **[Implementation Guide](implementation_guide.md)** - Complete development guide with code examples, deployment, and error handling

## Project Overview

### The Problem
TikTok live streaming sessions (3-4 hours) need:
- Organized product catalogs and talking points
- Efficient navigation during live streams
- Real-time coordination between hosts and producers
- Easy remote control and editing

### The Solution
Hudson provides:
- **Product Catalog Management** - CRUD interface for products, images, and talking points (manual entry + Shopify sync)
- **Session Planning** - Build sessions with product selection, ordering, and per-session overrides
- **Host View** - Large-format display optimized for streaming with keyboard navigation
- **Producer Console** - Remote control of session state with real-time sync

### Tech Stack

- **Backend:** Elixir + Phoenix + LiveView
- **Database:** PostgreSQL (Supabase-hosted)
- **Storage:** Supabase Storage buckets
- **Real-time:** Phoenix PubSub
- **Deployment:** Cloud-hosted web application (Fly.io, Render, etc.)

### Key Features

- Keyboard-first navigation (↑/↓ for products, ←/→ for images)
- Multi-client state synchronization via PubSub
- URL-based state persistence (survives refreshes)
- Markdown support for talking points
- Image preloading for smooth transitions
- Per-session product overrides (prices, talking points)
- Optimized for long-running sessions (3-4 hours)

## Architecture Highlights

```
┌─────────────────────────────────────┐
│         LiveView Clients            │
│  ┌──────────┐      ┌──────────┐    │
│  │   Host   │      │ Producer │    │
│  │   View   │      │ Console  │    │
│  └────┬─────┘      └────┬─────┘    │
│       │                 │           │
│       └────────┬────────┘           │
└────────────────┼────────────────────┘
                 │
                 │ WebSocket
                 │
┌────────────────▼────────────────────┐
│       Phoenix Application           │
│  ┌──────────────────────────────┐  │
│  │     Phoenix PubSub           │  │
│  │  session:#{id}:state         │  │
│  └──────────────────────────────┘  │
│                                     │
│  ┌──────────┐    ┌──────────────┐  │
│  │ Catalog  │    │   Sessions   │  │
│  │ Context  │    │   Context    │  │
│  └──────────┘    └──────────────┘  │
└────────────────┬────────────────────┘
                 │
                 │ Ecto
                 │
┌────────────────▼────────────────────┐
│      PostgreSQL (Supabase)          │
│  - Products, Sessions, State        │
└─────────────────────────────────────┘
```

## Development Workflow

1. **Local Development:**
   - `mix phx.server` for hot-reload development
   - Connect to Supabase DB via `DATABASE_URL`
   - LiveDashboard at `/dev/dashboard`

2. **Testing:**
   - Unit tests: `mix test`
   - LiveView tests: `mix test test/live/`
   - Integration tests: `mix test --only integration`

3. **Deployment:**
   - See [DEPLOYMENT.md](../DEPLOYMENT.md) for detailed instructions

## Common Tasks

### Create a New Product
```elixir
Hudson.Catalog.create_product(%{
  brand_id: brand.id,
  name: "CZ Lariat Station Necklace",
  talking_points_md: "- High quality\n- Best seller",
  original_price_cents: 4999,
  sale_price_cents: 2999,
  pid: "TT12345",
  sku: "NECK-001"
})
```

### Start a Live Session
1. Navigate to `/sessions`
2. Select or create session
3. Add products and reorder
4. Click "Start Session" → opens Host View
5. Share URL with producer for remote control

## Support & Contributing

### Getting Help
- Check documentation in this directory
- Review implementation examples in codebase
- For Phoenix/LiveView help: [Phoenix Forum](https://elixirforum.com/c/phoenix-forum)

### Contributing
1. Review [Architecture](architecture.md) and [Domain Model](domain_model.md)
2. Follow existing code patterns
3. Add tests for new features
4. Update documentation

## Links

- **Phoenix Framework:** https://phoenixframework.org
- **Phoenix LiveView:** https://hexdocs.pm/phoenix_live_view
- **Supabase:** https://supabase.com/docs
