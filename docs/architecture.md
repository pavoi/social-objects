# Technical Architecture

## 1. Stack Overview

### Core Technologies

**Backend:**
- **Elixir 1.15+** - Functional, concurrent language built on BEAM VM
- **Phoenix 1.7+** - Web framework with built-in real-time capabilities
- **LiveView 0.20+** - Server-rendered real-time UI without JavaScript frameworks
- **Ecto 3.11+** - Database wrapper and query language

**Database & Storage:**
- **PostgreSQL 15+** (Supabase-hosted) - Primary data store
- **Supabase Storage** - Object storage for product images

**Real-Time:**
- **Phoenix PubSub** - Distributed pub/sub with pg2 adapter
- **Phoenix Presence** (optional) - Track connected users

**Development Tools:**
- **Phoenix LiveDashboard** - Runtime metrics and debugging
- **Telemetry** - Performance monitoring and instrumentation
- **ExUnit** - Testing framework

### Why This Stack?

**Phoenix LiveView Benefits:**
- Real-time UI without separate frontend framework
- Automatic reconnection and state recovery
- Server authoritative (harder to manipulate)
- Smaller payload than JSON APIs + React
- Built-in presence and PubSub

**Elixir/BEAM Benefits:**
- Handles concurrent connections efficiently (producer + host)
- Fault-tolerant with supervision trees
- Low latency for real-time updates (<100ms)
- Proven for long-running processes (3-4 hour sessions)
- Hot code reloading without downtime

**Supabase Benefits:**
- Managed PostgreSQL with backups
- Built-in storage with CDN
- Easy remote access for development
- Row-Level Security for fine-grained permissions

---

## 2. System Architecture

### 2.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Browser Clients                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │  Host View   │  │   Producer   │  │    Admin     │     │
│  │  (Read-Only) │  │   Console    │  │    CRUD      │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
└─────────┼──────────────────┼──────────────────┼────────────┘
          │                  │                  │
          │ WebSocket        │ WebSocket        │ WebSocket
          │ (LiveView)       │ (LiveView)       │ (LiveView)
          │                  │                  │
┌─────────▼──────────────────▼──────────────────▼────────────┐
│              Phoenix Application (Elixir)                   │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │            Phoenix Endpoint & Router                │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌─────────────────────────────────────────────────────┐  │
│  │              Phoenix PubSub                         │  │
│  │  Topics:                                            │  │
│  │    - session:#{session_id}:state                    │  │
│  │    - session:#{session_id}:meta                     │  │
│  └─────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌──────────────┐  ┌──────────────┐                        │
│  │   Catalog    │  │   Sessions   │                        │
│  │   Context    │  │   Context    │                        │
│  │              │  │              │                        │
│  │ - Brand      │  │ - Session    │                        │
│  │ - Product    │  │ - Session    │                        │
│  │ - Product    │  │   Product    │                        │
│  │   Image      │  │ - Session    │                        │
│  │              │  │   State      │                        │
│  └──────┬───────┘  └──────┬───────┘                        │
│         │                  │                               │
│         └──────────────────┘                               │
│                    │                                        │
└────────────────────┼────────────────────────────────────────┘
                     │
                     │ Ecto (Database)
                     │
┌────────────────────▼────────────────────────────────────────┐
│              PostgreSQL (Supabase)                          │
│  Tables:                                                    │
│    - brands, hosts                                          │
│    - products, product_images                               │
│    - sessions, session_hosts, session_products              │
│    - session_states                                         │
└──────────────────────────┬──────────────────────────────────┘
                           │
                  RLS Policies
                           │
┌──────────────────────────▼──────────────────────────────────┐
│              Supabase Storage                               │
│  Buckets:                                                   │
│    - products/ (images)                                     │
│      - pavoi/products/{product_id}/{filename}               │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow: Producer Jumps to Product

```
Producer Browser → keyboard input (number + Enter) → SessionProducerLive
  ↓
Sessions.jump_to_product(session_id, position)
  ↓
Update session_states table + Broadcast PubSub
  ↓
All subscribed LiveViews receive {:state_changed, new_state}
  ↓
SessionProducerLive and SessionHostLive re-render with new product

Note: Arrow keys (next/previous) also supported for convenience,
but direct jumps are the primary navigation method.
```

### 2.3 Supervision Tree

```
Application
│
├── Phoenix.PubSub.Supervisor
├── Hudson.Repo (Ecto connection pool)
├── HudsonWeb.Endpoint
│   ├── HTTP Server (Cowboy)
│   └── LiveView Socket Pool
└── Hudson.Application (custom supervisors)
```

---

## 3. Context Boundaries

Phoenix contexts provide API boundaries around domain functionality. Keep contexts small, focused, and composable.

### 3.1 Catalog Context

**Module:** `Hudson.Catalog`

**Responsibilities:**
- Manage brands, products, and product images
- CRUD operations for catalog entities
- Image upload coordination with Supabase Storage
- Product search and filtering

**Key Functions:**
- `list_products(filters)` - Query products with filtering
- `create_product(attrs)` - Insert new product
- `upload_product_image(product_id, file)` - Upload to Supabase
- `search_products(query)` - Full-text search

**Schemas:** Brand, Product, ProductImage

**Design Principles:**
- Products belong to brands (required association)
- Product images ordered by `position` field
- Prices stored in cents (integer) to avoid floating point issues

_See [Implementation Guide](implementation_guide.md) for code examples._

### 3.2 Sessions Context

**Module:** `Hudson.Sessions`

**Responsibilities:**
- Manage live streaming sessions
- Session product selection and ordering
- Real-time session state management
- Host assignment to sessions

**Key Functions:**
- `create_session(attrs)` - Create new session
- `add_product_to_session(session_id, product_id, attrs)` - Build session lineup
- `jump_to_product(session_id, position)` - Direct navigation to product (primary)
- `advance_to_next_product(session_id)` - Sequential navigation (convenience)
- `update_session_state(session_id, attrs)` - Update + broadcast state

**Schemas:** Session, SessionHost, SessionProduct, SessionState

**Design Principles:**
- SessionProduct holds per-session overrides (prices, talking points)
- SessionState stores live control state (current product, image)
- State changes broadcast via PubSub automatically

_See [Implementation Guide](implementation_guide.md) for code examples._

---

## 4. LiveView Architecture

### 4.1 LiveView Modules

**SessionHostLive** - Host Display View (Read-Only)
- Route: `/sessions/:id/host`
- Purpose: Optimized display view for host during live streaming
- Key Features:
  - Read-only (no keyboard controls)
  - Large product display with images and talking points
  - Floating banner for producer messages
  - PubSub sync for real-time updates from producer
  - Memory-optimized with temporary assigns

**SessionProducerLive** - Producer Control Panel
- Route: `/sessions/:id/producer`
- Purpose: Full control panel for managing live sessions
- Key Features:
  - Keyboard navigation controls (jump to product, cycle images)
  - Send live messages to host (persistent in database)
  - View mode toggling (fullscreen config, split-screen, fullscreen host preview)
  - PubSub sync for real-time state management
  - Memory-optimized with temporary assigns


**SessionEditLive** - Session Builder
- Route: `/sessions/:id/edit`
- Purpose: Prepare sessions before going live
- Key Features: Product picker, drag-and-drop reordering, autosave

**SessionIndexLive** - Session List
- Route: `/sessions`
- Purpose: Browse and manage sessions

**CatalogProductLive** - Product CRUD
- Route: `/products`
- Purpose: Manage product catalog

### 4.2 LiveView Lifecycle Pattern

**Key Stages:**
1. **Mount** - Called twice (HTTP then WebSocket)
2. **Connected check** - Use `connected?(socket)` to distinguish
3. **PubSub subscription** - Only after WebSocket connection
4. **State recovery** - From URL params or DB
5. **Event handling** - User interactions via `handle_event/3`
6. **PubSub updates** - Receive broadcasts via `handle_info/2`

**Critical Pattern:** Use `temporary_assigns` for render-only data to prevent memory bloat during 3-4 hour sessions.

_See [Implementation Guide](implementation_guide.md#sessionrunlive) for full code examples._

---

## 5. Performance Architecture

### 5.1 Memory Management Strategy

**Problem:** LiveView keeps all assigns in memory. 3-4 hour sessions can accumulate megabytes causing memory bloat.

**Solutions:**

1. **Temporary Assigns** - Mark render-only data as temporary (cleared after each render)
   - Product details, talking points, images
   - Formatted/computed values

2. **Streams** - Use Phoenix streams for large collections instead of assigns
   - Diffs at item level, not entire collection
   - Reduces memory footprint for product lists

3. **Selective Preloading** - Optimized for arbitrary navigation
   - Preload adjacent products (±2 positions) for arrow key convenience
   - Progressive background preload of remaining products
   - Prioritize current product images for immediate display

_See [Implementation Guide](implementation_guide.md#performance) for implementation details._

### 5.2 Database Optimization Patterns

- **Preload associations** to avoid N+1 queries
- **Use `select`** to limit columns loaded
- **Index frequently queried fields** (session_id, position, pid)
- **Connection pooling** configured for concurrent load

### 5.3 PubSub Optimization

- **Scope topics narrowly:** `session:#{id}:state` not `sessions`
- **Broadcast minimal payloads:** IDs only, let receivers fetch details
- **Use `broadcast_from/4`** to exclude sender when appropriate

### 5.4 Monitoring

- **Telemetry metrics** for LiveView mount duration, event handling
- **LiveDashboard** for process memory, PubSub metrics
- **Socket size tracking** in development to catch bloat early

---

## 6. Real-Time State Synchronization

### 6.1 PubSub Topic Design

| Topic | Purpose | Subscribers | Payload |
|-------|---------|-------------|---------|
| `session:#{id}:state` | Current product/image changes + host messages | Host, Producer | SessionState struct with product_id, image_index, and host_message fields |
| `session:#{id}:meta` | Session metadata changes | Admin | `{name, notes, etc}` |
| `session:#{id}:presence` | Who's connected | All | Presence data |

**Note:** Host messages are included in the main `:state` topic rather than a separate topic. This ensures atomic updates and simplifies synchronization.

### 6.2 State Synchronization Flow

**Navigation Flow:**
1. **Producer triggers change** (keyboard event)
2. **Context function updates DB** and broadcasts
3. **All subscribers receive** via `handle_info/2`
4. **LiveViews re-render** with new state

**Host Message Flow:**
1. **Producer sends message** (form submission)
2. **`Sessions.send_host_message/2`** updates SessionState with message text, ID, timestamp
3. **Broadcast via `:state` topic** includes updated SessionState
4. **Host view receives broadcast** and displays floating banner
5. **Producer can clear message** via `Sessions.clear_host_message/1`

**Key Decision:** DB-first approach (write to DB then broadcast) for resilience. State survives crashes and browser refreshes. Host messages are persisted to enable session history and review.

_See [Implementation Guide](implementation_guide.md#state-sync) for implementation._

### 6.3 State Persistence Strategy

**Tri-fold approach:**
1. **Database** - Primary source of truth (SessionState table)
2. **URL params** - Enables bookmarking and refresh recovery (`?sp=123&img=2`)
3. **PubSub** - Real-time synchronization across clients

**Recovery Priority:** URL params > DB state > first product

---

## 7. Error Handling & Fault Tolerance

### 7.1 Supervision Strategy

Phoenix has built-in supervision for:
- LiveView processes (automatic restart on crash)
- Ecto connection pool
- PubSub infrastructure

**Supervision strategies:**
- `:one_for_one` - Restart only crashed process (default)
- `:one_for_all` - Restart all if one crashes
- `:rest_for_one` - Restart crashed process and dependents

### 7.2 Automatic Reconnection

LiveView reconnects automatically with exponential backoff:
- Immediate → 2s → 5s → 10s → continues with increasing delays

**State recovery:** On reconnect, `mount/3` is called again and restores state from DB/URL.

### 7.3 Error Handling Principles

- **Graceful degradation** - Show cached data rather than blank screens
- **User feedback** - Connection status indicators
- **Idempotency** - Operations safe to retry
- **Fallback values** - Never crash on missing data

_See [Implementation Guide](implementation_guide.md#error-handling) for patterns and code._

---

## 8. Security Architecture

### 8.1 Authentication (MVP)

- **Hashed shared secrets per role** (host, producer, admin) stored in config and compared with `Comeonin`/`bcrypt` rather than plain-text equality.
- **Short-lived session tokens** scoped to the role that logged in; revoke on logout and after prolonged inactivity (4h maximum).
- **Rate limiting + lockouts** on the login endpoint to defend against credential stuffing; log failed attempts for audit.
- **Signed invite links** for one-off access when onboarding new producers without redeploying secrets.

**Future:** Generate real user accounts with `mix phx.gen.auth` and layered authorization (Admin, Producer, Host, Cataloger). Keeping the MVP interface role-aware now (separate plugs + assigns) makes that migration trivial.

### 8.2 Supabase Security

**Critical principles:**
- **Never expose service role key** to frontend
- **Storage bucket is read-public** (product images are already public marketing assets) while writes remain server-only
- **Persist storage object paths only**; Phoenix builds public CDN URLs on the fly via the Supabase project/base path
- **RLS policies** still enforce that only service key can write/delete objects
- **HTTPS** enforced in production
- **Secrets** in environment variables, never committed

_See [Implementation Guide](implementation_guide.md#supabase-security) for configuration._

### 8.3 Transport Security

- **TLS verification stays enabled**. Point `:ssl_opts` at Supabase’s CA bundle (via `castore` or custom `cacertfile`) instead of `verify: :verify_none`.
- **Strict-Transport-Security** headers on the Phoenix endpoint so browsers refuse to downgrade.
- **WebSocket over WSS** only; block insecure origins in the Endpoint.

These guard rails keep remote producers safe when connecting over public networks.

---

## 9. Testing Strategy

### 9.1 Test Layers

1. **Context tests** - Business logic, database operations
2. **LiveView tests** - User interactions, rendering
3. **Integration tests** - PubSub synchronization, end-to-end flows

### 9.2 Key Test Scenarios

- State synchronization across multiple clients
- Memory management (no leaks over long sessions)
- Error recovery (reconnection, database failures)
- Import validation and rollback

_See [Implementation Guide](implementation_guide.md#testing) for test examples._

---

## 10. Scalability Considerations

### Current Scale (MVP)
- 1-2 simultaneous live sessions
- 2-3 connected clients per session
- 40-100 products per session
- 3-4 hour session duration

### Scalability Path

**Phase 1: Single Machine (MVP)**
- Localhost deployment
- All processes on one BEAM instance
- Supabase for database/storage

**Phase 2: Horizontal Scaling**
- Deploy to Fly.io or Render
- Add libcluster for node discovery
- PubSub automatically works across nodes

**Phase 3: Performance Optimization**
- Redis for session state caching
- CDN for image delivery
- Background jobs for imports
- Read replicas for database

---

## 11. Architecture Decision Records

### ADR-001: LiveView vs SPA

**Decision:** Use Phoenix LiveView for all UI

**Rationale:**
- Real-time sync needed between clients
- Server authoritative (prevents manipulation)
- Simpler than REST API + React
- One language (Elixir) for full stack
- Automatic reconnection and state recovery

**Trade-offs:** Requires server round-trip for interactions (~10-20ms latency, acceptable)

### ADR-002: DB-First State Management

**Decision:** Store session state in DB, not just memory

**Rationale:**
- Survives process crashes and restarts
- Enables URL-based bookmarking
- Single source of truth
- Acceptable latency (~10-20ms)

**Trade-offs:** Slightly higher latency than memory-only, more database load

### ADR-003: Supabase for Database & Storage

**Decision:** Use Supabase-hosted PostgreSQL and Storage

**Rationale:**
- Remote access for development
- Managed backups and scaling
- Built-in storage with CDN
- RLS for fine-grained permissions
- Easy migration path to self-hosted Postgres later

**Trade-offs:** Vendor dependency, Supabase-specific auth handling

### ADR-004: Temporary Assigns for Memory Management

**Decision:** Use temporary assigns for all render-only data

**Rationale:**
- Critical for 3-4 hour session stability
- Prevents memory bloat
- Industry best practice for long-running LiveViews

**Trade-offs:** Must carefully categorize assigns, slight learning curve

---

## Summary

This architecture provides:
- **Real-time synchronization** via PubSub
- **Memory efficiency** via temporary assigns and streams
- **Fault tolerance** via supervision and state persistence
- **Performance** optimized for 3-4 hour sessions
- **Simplicity** with idiomatic Phoenix patterns
- **Scalability** path from localhost to distributed deployment

**For implementation details, see:**
- [Implementation Guide](implementation_guide.md) - Step-by-step code examples
- [Domain Model](domain_model.md) - Database schema
- [Product Requirements](product_requirements.md) - User needs and UX specs
