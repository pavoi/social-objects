# Domain Model & Database Schema

## 1. Overview

The Pavoi domain model centers around **Products** (catalog) and **Sessions** (live streaming events). Products are reusable entities managed globally, while Sessions reference products with optional per-session overrides for prices, talking points, and ordering.

### Core Concepts

- **Brands** - Companies whose products are featured (e.g., Pavoi)
- **Products** - Catalog items with images, prices, and talking points
- **Sessions** - Live streaming events with curated product lineups
- **SessionState** - Real-time control state (which product/image is currently displayed)

---

## 2. Entity-Relationship Diagram

```
┌─────────────┐
│   Brand     │
│─────────────│
│ id          │◀───────────┐
│ name        │            │ brand_id
│ slug        │            │
└─────────────┘            │
                           │
                 ┌─────────┴────────┐
                 │                  │
         ┌───────┴────────┐ ┌──────┴────────┐
         │    Product     │ │    Session    │
         │────────────────│ │───────────────│
         │ id             │ │ id            │
         │ brand_id    ───┼─│ brand_id   ───┤
         │ name           │ │ name          │
         │ talking_points │ │ slug          │
         │ prices         │ │ notes         │
         │ pid, sku       │ └───────────────┘
         └────────┬───────┘         │
                  │                 │
         ┌────────┴─────┐       ┌───┴────────────────┐
         │              │       │                    │
  ┌──────▼────────┐    │  ┌────▼──────────┐  ┌──────▼──────────┐
  │ ProductImage  │    │  │SessionProduct │  │  SessionHost   │
  │───────────────│    │  │───────────────│  │─────────────────│
  │ id            │    │  │ id            │  │ id              │
  │ product_id ───┼────┘  │ session_id ───┼──│ session_id   ───┤
  │ url           │       │ product_id ───┼──│ host_id      ───┤
  │ position      │       │ position      │  │ role            │
  │ is_primary    │       │ overrides     │  └─────────────────┘
  └───────────────┘       └───────┬───────┘                │
                                  │                        │
                          ┌───────▼─────────┐      ┌───────▼──────┐
                          │ SessionState    │      │    Host      │
                          │─────────────────│      │──────────────│
                          │ id              │      │ id           │
                          │ session_id      │      │ name         │
                          │ current_sp_id   │      └──────────────┘
                          │ image_index     │
                          └─────────────────┘
```

---

## 3. Entity Definitions

### 3.1 Brand

Represents a company/brand whose products are featured in live sessions.

**Table:** `brands`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `name` | varchar(255) | NOT NULL, UNIQUE | Brand name (e.g., "Pavoi") |
| `slug` | varchar(255) | NOT NULL, UNIQUE | URL-safe identifier |
| `notes` | text | NULLABLE | Internal notes |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Unique index on `name`
- Unique index on `slug`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Catalog.Brand do
  use Ecto.Schema
  import Ecto.Changeset

  schema "brands" do
    field :name, :string
    field :slug, :string
    field :notes, :string

    has_many :products, Pavoi.Catalog.Product
    has_many :sessions, Pavoi.Sessions.Session

    timestamps()
  end

  def changeset(brand, attrs) do
    brand
    |> cast(attrs, [:name, :slug, :notes])
    |> validate_required([:name, :slug])
    |> unique_constraint(:name)
    |> unique_constraint(:slug)
  end
end
```

**Sample Data:**
```sql
INSERT INTO brands (name, slug, notes, inserted_at, updated_at)
VALUES ('Pavoi', 'pavoi', 'Primary jewelry brand', NOW(), NOW());
```

---

### 3.2 Product

Catalog item with global product information. Products are reusable across multiple sessions.

**Table:** `products`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `brand_id` | bigint | NOT NULL, REFERENCES brands(id) | Owning brand |
| `name` | varchar(500) | NOT NULL | Full product name |
| `description` | text | NULLABLE | Short description |
| `talking_points_md` | text | NULLABLE | Markdown-formatted bullet points |
| `original_price_cents` | integer | NOT NULL | Original price in cents |
| `sale_price_cents` | integer | NULLABLE | Sale price in cents |
| `pid` | varchar(100) | NULLABLE, UNIQUE | TikTok Product ID or external ID |
| `sku` | varchar(100) | NULLABLE | Internal SKU |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Foreign key on `brand_id`
- Unique index on `pid` (if not null)
- Index on `sku`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Catalog.Product do
  use Ecto.Schema
  import Ecto.Changeset

  schema "products" do
    field :name, :string
    field :description, :string
    field :talking_points_md, :string
    field :original_price_cents, :integer
    field :sale_price_cents, :integer
    field :pid, :string
    field :sku, :string

    belongs_to :brand, Pavoi.Catalog.Brand
    has_many :product_images, Pavoi.Catalog.ProductImage, preload_order: [asc: :position]
    has_many :session_products, Pavoi.Sessions.SessionProduct

    timestamps()
  end

  def changeset(product, attrs) do
    product
    |> cast(attrs, [
      :brand_id, :name, :description,
      :talking_points_md, :original_price_cents, :sale_price_cents,
      :pid, :sku
    ])
    |> validate_required([:brand_id, :name, :original_price_cents])
    |> validate_number(:original_price_cents, greater_than: 0)
    |> validate_number(:sale_price_cents, greater_than: 0)
    |> unique_constraint(:pid)
    |> foreign_key_constraint(:brand_id)
  end
end
```

**Design Notes:**
- Prices stored in **cents** (integer) to avoid floating-point rounding errors
- `talking_points_md` uses Markdown for formatting flexibility
- `pid` is unique for integration with TikTok/Shopify

---

### 3.3 ProductImage

Images associated with products. Products can have multiple images with ordering.

**Table:** `product_images`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `product_id` | bigint | NOT NULL, REFERENCES products(id) ON DELETE CASCADE | Parent product |
| `position` | integer | NOT NULL, DEFAULT 0 | Sort order (0 = primary) |
| `path` | varchar(1000) | NOT NULL | Supabase object path (e.g., `products/123/full/a.jpg`) |
| `thumbnail_path` | varchar(1000) | NULLABLE | Low-res placeholder object path |
| `alt_text` | varchar(500) | NULLABLE | Accessibility text |
| `is_primary` | boolean | NOT NULL, DEFAULT false | Primary image flag |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Foreign key on `product_id`
- Composite index on `(product_id, position)` for ordered queries
- Partial unique index on `(product_id)` WHERE `is_primary = true` (only one primary per product)

**Schema (Elixir):**
```elixir
defmodule Pavoi.Catalog.ProductImage do
  use Ecto.Schema
  import Ecto.Changeset

  schema "product_images" do
    field :position, :integer, default: 0
    field :path, :string
    field :thumbnail_path, :string
    field :alt_text, :string
    field :is_primary, :boolean, default: false

    belongs_to :product, Pavoi.Catalog.Product

    timestamps()
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:product_id, :position, :path, :thumbnail_path, :alt_text, :is_primary])
    |> validate_required([:product_id, :path])
    |> foreign_key_constraint(:product_id)
  end
end
```

**Design Notes:**
- `position = 0` by convention means primary image
- `CASCADE DELETE` ensures images are removed with product
- Only one image can be marked `is_primary` per product (enforced by constraint)
- Paths (not full URLs) are persisted so Phoenix can prepend the Supabase public storage base URL and serve via CDN without storing hostnames in the DB.

---

### 3.4 Host

Hosts who present during live sessions.

**Table:** `hosts`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `name` | varchar(255) | NOT NULL | Display name |
| `notes` | text | NULLABLE | Internal notes (contact info, etc.) |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Sessions.Host do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hosts" do
    field :name, :string
    field :notes, :string

    many_to_many :sessions, Pavoi.Sessions.Session,
      join_through: Pavoi.Sessions.SessionHost

    timestamps()
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:name, :notes])
    |> validate_required([:name])
  end
end
```

---

### 3.5 Session

A live streaming event with a curated product lineup.

**Table:** `sessions`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `name` | varchar(500) | NOT NULL | Session name (e.g., "Holiday Favorites - Dec 2024 AM") |
| `slug` | varchar(255) | NOT NULL, UNIQUE | URL-safe identifier |
| `brand_id` | bigint | NOT NULL, REFERENCES brands(id) | Primary brand for session |
| `notes` | text | NULLABLE | Producer notes |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Unique index on `slug`
- Foreign key on `brand_id`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Sessions.Session do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sessions" do
    field :name, :string
    field :slug, :string
    field :notes, :string

    belongs_to :brand, Pavoi.Catalog.Brand
    has_many :session_products, Pavoi.Sessions.SessionProduct, preload_order: [asc: :position]
    has_one :session_state, Pavoi.Sessions.SessionState
    many_to_many :hosts, Pavoi.Sessions.Host,
      join_through: Pavoi.Sessions.SessionHost

    timestamps()
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:brand_id, :name, :slug, :notes])
    |> validate_required([:brand_id, :name, :slug])
    |> unique_constraint(:slug)
    |> foreign_key_constraint(:brand_id)
  end
end
```

---

### 3.6 SessionHost

Join table linking hosts to sessions with roles.

**Table:** `session_hosts`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `session_id` | bigint | NOT NULL, REFERENCES sessions(id) ON DELETE CASCADE | Parent session |
| `host_id` | bigint | NOT NULL, REFERENCES hosts(id) | Assigned host |
| `role` | varchar(100) | NOT NULL, DEFAULT 'primary' | Host role (primary, co-host) |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Foreign keys on `session_id`, `host_id`
- Unique index on `(session_id, host_id)` (same host can't be assigned twice)

**Schema (Elixir):**
```elixir
defmodule Pavoi.Sessions.SessionHost do
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_hosts" do
    field :role, :string, default: "primary"

    belongs_to :session, Pavoi.Sessions.Session
    belongs_to :host, Pavoi.Sessions.Host

    timestamps()
  end

  def changeset(session_host, attrs) do
    session_host
    |> cast(attrs, [:session_id, :host_id, :role])
    |> validate_required([:session_id, :host_id])
    |> unique_constraint([:session_id, :host_id])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:host_id)
  end
end
```

---

### 3.7 SessionProduct

Products assigned to a session with ordering and per-session overrides.

**Table:** `session_products`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `session_id` | bigint | NOT NULL, REFERENCES sessions(id) ON DELETE CASCADE | Parent session |
| `product_id` | bigint | NOT NULL, REFERENCES products(id) | Reference to product |
| `position` | integer | NOT NULL | Order in session (1, 2, 3...) |
| `section` | varchar(255) | NULLABLE | Section name (e.g., "Holiday Vault", "Bracelets") |
| `featured_name` | varchar(500) | NULLABLE | Session-specific name override |
| `featured_talking_points_md` | text | NULLABLE | Session-specific talking points |
| `featured_original_price_cents` | integer | NULLABLE | Session-specific original price |
| `featured_sale_price_cents` | integer | NULLABLE | Session-specific sale price |
| `notes` | text | NULLABLE | Producer notes for this session |
| `inserted_at` | timestamp | NOT NULL | Record creation |
| `updated_at` | timestamp | NOT NULL | Last update |

**Indexes:**
- Primary key on `id`
- Foreign keys on `session_id`, `product_id`
- Unique index on `(session_id, position)` (no duplicate positions in a session)
- Index on `(session_id, product_id)`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Sessions.SessionProduct do
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_products" do
    field :position, :integer
    field :section, :string
    field :featured_name, :string
    field :featured_talking_points_md, :string
    field :featured_original_price_cents, :integer
    field :featured_sale_price_cents, :integer
    field :notes, :string

    belongs_to :session, Pavoi.Sessions.Session
    belongs_to :product, Pavoi.Catalog.Product

    timestamps()
  end

  def changeset(session_product, attrs) do
    session_product
    |> cast(attrs, [
      :session_id, :product_id, :position, :section,
      :featured_name, :featured_talking_points_md,
      :featured_original_price_cents, :featured_sale_price_cents,
      :notes
    ])
    |> validate_required([:session_id, :product_id, :position])
    |> validate_number(:position, greater_than: 0)
    |> unique_constraint([:session_id, :position])
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:product_id)
  end

  # Helper: Get effective name (override or original)
  def effective_name(%__MODULE__{featured_name: nil, product: product}), do: product.name
  def effective_name(%__MODULE__{featured_name: name}), do: name

  # Helper: Get effective talking points
  def effective_talking_points(%__MODULE__{featured_talking_points_md: nil, product: product}),
    do: product.talking_points_md
  def effective_talking_points(%__MODULE__{featured_talking_points_md: points}), do: points

  # Helper: Get effective prices
  def effective_prices(%__MODULE__{} = sp) do
    %{
      original: sp.featured_original_price_cents || sp.product.original_price_cents,
      sale: sp.featured_sale_price_cents || sp.product.sale_price_cents
    }
  end
end
```

**Design Notes:**
- `featured_*` fields override global product data when set
- Use helper functions to get effective values (override > original)
- Position is 1-indexed for user display

---

### 3.8 SessionState

Real-time control state for live sessions. Tracks which product and image is currently displayed.

**Table:** `session_states`

| Column | Type | Constraints | Description |
|--------|------|-------------|-------------|
| `id` | bigserial | PRIMARY KEY | Auto-incrementing ID |
| `session_id` | bigint | NOT NULL, UNIQUE, REFERENCES sessions(id) ON DELETE CASCADE | Parent session (one state per session) |
| `current_session_product_id` | bigint | NULLABLE, REFERENCES session_products(id) | Current product being displayed |
| `current_image_index` | integer | NOT NULL, DEFAULT 0 | Current image index (0-based) |
| `updated_at` | timestamp | NOT NULL | Last state change |

**Indexes:**
- Primary key on `id`
- Unique index on `session_id` (one state per session)
- Foreign keys on `session_id`, `current_session_product_id`

**Schema (Elixir):**
```elixir
defmodule Pavoi.Sessions.SessionState do
  use Ecto.Schema
  import Ecto.Changeset

  schema "session_states" do
    field :current_image_index, :integer, default: 0
    field :updated_at, :utc_datetime

    belongs_to :session, Pavoi.Sessions.Session
    belongs_to :current_session_product, Pavoi.Sessions.SessionProduct

    # No inserted_at - only updated_at matters
  end

  def changeset(state, attrs) do
    state
    |> cast(attrs, [:session_id, :current_session_product_id, :current_image_index])
    |> validate_required([:session_id])
    |> validate_number(:current_image_index, greater_than_or_equal_to: 0)
    |> unique_constraint(:session_id)
    |> foreign_key_constraint(:session_id)
    |> foreign_key_constraint(:current_session_product_id)
    |> put_change(:updated_at, DateTime.utc_now())
  end
end
```

**Design Notes:**
- One state record per session (enforced by unique constraint)
- Updated frequently during live sessions
- `current_image_index` is 0-based (0 = first image)

---

## 4. Migration Strategy

### 4.1 Migration Order

Migrations must be created in dependency order:

1. `brands`
2. `hosts`
3. `products`
4. `product_images`
5. `sessions`
6. `session_hosts`
7. `session_products`
8. `session_states`

### 4.2 Sample Migration: Products

```elixir
defmodule Pavoi.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products) do
      add :brand_id, references(:brands, on_delete: :restrict), null: false
      add :name, :string, size: 500, null: false
      add :description, :text
      add :talking_points_md, :text
      add :original_price_cents, :integer, null: false
      add :sale_price_cents, :integer
      add :pid, :string, size: 100
      add :sku, :string, size: 100
      add :external_url, :string, size: 500

      timestamps()
    end

    create index(:products, [:brand_id])
    create unique_index(:products, [:pid], where: "pid IS NOT NULL")
    create index(:products, [:sku])
  end
end
```

### 4.3 Sample Migration: SessionProducts

```elixir
defmodule Pavoi.Repo.Migrations.CreateSessionProducts do
  use Ecto.Migration

  def change do
    create table(:session_products) do
      add :session_id, references(:sessions, on_delete: :delete_all), null: false
      add :product_id, references(:products, on_delete: :restrict), null: false
      add :position, :integer, null: false
      add :section, :string
      add :featured_name, :string, size: 500
      add :featured_talking_points_md, :text
      add :featured_original_price_cents, :integer
      add :featured_sale_price_cents, :integer
      add :notes, :text

      timestamps()
    end

    create index(:session_products, [:session_id])
    create index(:session_products, [:product_id])
    create unique_index(:session_products, [:session_id, :position])
    create index(:session_products, [:session_id, :product_id])
  end
end
```

### 4.4 Cascade Deletion Strategy

| Parent | Child | On Delete |
|--------|-------|-----------|
| Brand → Product | `RESTRICT` | Don't allow brand deletion if products exist |
| Product → ProductImage | `CASCADE` | Delete images when product is deleted |
| Session → SessionProduct | `CASCADE` | Delete session products when session is deleted |
| Session → SessionState | `CASCADE` | Delete state when session is deleted |
| Product → SessionProduct | `RESTRICT` | Don't allow product deletion if used in sessions |

---

## 5. Indexes & Performance

### 5.1 Recommended Indexes

**Critical Indexes (Required):**
- All primary keys (automatic)
- All foreign keys
- Unique constraints (name, slug, pid)

**Performance Indexes:**
- `products(brand_id)` - Filter products by brand
- `products(pid)` - Lookup by TikTok ID
- `session_products(session_id, position)` - Ordered session products
- `session_states(session_id)` - Quick state lookup

### 5.2 Query Patterns

**Get session with products (ordered):**
```elixir
from s in Session,
  where: s.id == ^session_id,
  preload: [
    session_products: {
      from sp in SessionProduct,
      order_by: [asc: sp.position],
      preload: [product: [:brand, :product_images]]
    }
  ]
```

**Get current session state with product details:**
```elixir
from ss in SessionState,
  where: ss.session_id == ^session_id,
  preload: [
    current_session_product: [
      product: [:brand, :product_images]
    ]
  ]
```

**Search products by name or SKU:**
```elixir
from p in Product,
  where: ilike(p.name, ^"%#{query}%") or ilike(p.sku, ^"%#{query}%"),
  preload: [:brand, product_images: from(pi in ProductImage, where: pi.is_primary == true)]
```

---

## 6. Data Validation Rules

### 6.1 Product Validation

- **Name:** Required, max 500 chars
- **Original Price:** Required, > 0
- **Sale Price:** Optional, must be > 0 if provided
- **PID:** Unique if provided
- **Stock:** Must be >= 0 if provided
- **Tags:** Each tag max 50 chars

### 6.2 Session Validation

- **Name:** Required, max 500 chars
- **Slug:** Required, unique, URL-safe (lowercase, hyphens only)
- **Status:** Must be one of: draft, live, complete
- **Scheduled At:** Must be in future for new sessions (optional validation)

### 6.3 SessionProduct Validation

- **Position:** Required, > 0, unique within session
- **Featured Prices:** Must be > 0 if provided
- **Product:** Must exist and belong to valid brand

### 6.4 SessionState Validation

- **Session:** Required, must exist
- **Current Session Product:** Must belong to same session
- **Image Index:** Must be >= 0, < number of images for current product

---

## 7. Sample Data Seeds

```elixir
# priv/repo/seeds.exs
alias Pavoi.{Catalog, Sessions}
alias Pavoi.Repo

# Create brand
{:ok, pavoi} = Catalog.create_brand(%{
  name: "Pavoi",
  slug: "pavoi",
  notes: "Premium jewelry brand"
})

# Create host
{:ok, host} = Repo.insert!(%Sessions.Host{
  name: "Sarah Johnson"
})

# Create products
{:ok, necklace} = Catalog.create_product(%{
  brand_id: pavoi.id,
  name: "CZ Lariat Station Necklace - Gold",
  talking_points_md: """
  - High-quality cubic zirconia stones
  - Adjustable lariat style
  - Perfect for layering
  - Tarnish-free 14K gold plating
  """,
  original_price_cents: 4999,
  sale_price_cents: 2999,
  pid: "TT12345",
  sku: "NECK-001"
})

# Add images
Catalog.create_product_image(necklace.id, %{
  path: "products/#{necklace.id}/full/necklace-1.jpg",
  thumbnail_path: "products/#{necklace.id}/thumb/necklace-1.jpg",
  position: 0,
  is_primary: true,
  alt_text: "Gold lariat necklace front view"
})

# Create session
{:ok, session} = Sessions.create_session(%{
  brand_id: pavoi.id,
  name: "Holiday Favorites - December 2024",
  slug: "holiday-favorites-dec-2024"
})

# Assign host
Sessions.assign_host_to_session(session.id, host.id, "primary")

# Add product to session
{:ok, sp} = Sessions.add_product_to_session(session.id, necklace.id, %{
  position: 1,
  section: "Featured Necklaces",
  # Override sale price for this session
  featured_sale_price_cents: 2499,
  notes: "Push this hard - holiday exclusive price"
})

# Initialize session state
Sessions.create_session_state(%{
  session_id: session.id,
  current_session_product_id: sp.id,
  current_image_index: 0
})
```

---

## 8. Schema Evolution Guidelines

### 8.1 Adding Fields

**New nullable field:**
```bash
mix ecto.gen.migration add_product_subtitle
```

```elixir
def change do
  alter table(:products) do
    add :subtitle, :string
  end
end
```

**New required field with default:**
```elixir
def change do
  alter table(:products) do
    add :is_active, :boolean, default: true, null: false
  end
end
```

### 8.2 Renaming Fields

```elixir
def change do
  rename table(:products), :talking_points_md, to: :description_md
end
```

### 8.3 Removing Fields

```elixir
def change do
  alter table(:products) do
    remove :old_field
  end
end
```

### 8.4 Complex Data Migrations

For data transformations, use separate migration:

```elixir
def up do
  # Add new field
  alter table(:products) do
    add :price_currency, :string, default: "USD"
  end

  # Migrate data
  execute "UPDATE products SET price_currency = 'USD'"

  # Make required
  alter table(:products) do
    modify :price_currency, :string, null: false
  end
end

def down do
  alter table(:products) do
    remove :price_currency
  end
end
```

---

## 9. Design Decisions & Rationale

### 9.1 Why SessionProduct Overrides?

**Problem:** Products are reused across sessions, but prices/messaging may change per session (flash sales, promotions).

**Solution:** `session_products` table holds optional overrides. Original product data is preserved.

**Benefits:**
- Update global product without affecting past sessions
- Session-specific promotions without duplicating products
- Clear audit trail of what was shown in each session

### 9.2 Why Store State in DB?

**Problem:** Session state must survive browser refreshes and process crashes during 3-4 hour streams.

**Alternatives Considered:**
- Memory-only (fast but not resilient)
- Redis cache (adds dependency)
- URL params only (works but no producer control)

**Solution:** Store in DB + URL params + PubSub.

**Benefits:**
- Single source of truth
- Survives crashes
- URL bookmarking works
- ~10-20ms latency acceptable for navigation

### 9.3 Why Separate ProductImage Table?

**Alternative:** Store image URLs as array in products table.

**Why Separate Table:**
- Need explicit ordering (position field)
- Need metadata per image (alt_text)
- Easier to add image-specific features later (captions, variants)
- Standard relational pattern

### 9.4 Why Integer Cents for Prices?

**Alternative:** Decimal or float types.

**Why Integer Cents:**
- No floating-point rounding errors
- Fast integer arithmetic
- Standard e-commerce pattern
- Easy currency conversion (divide by 100)

---

## 10. ER Diagram (Textual)

```
Brand
  ||
  ||--< Product
  ||       ||
  ||       ||--< ProductImage
  ||       ||
  ||       ||--< SessionProduct >--|| Session
  ||                                     ||
  ||--< Session                          ||
        ||                               ||
        ||--< SessionHost >--|| Host     ||
        ||                               ||
        ||--< SessionState <-------------||
```

---

## Summary

This domain model provides:
- **Catalog Management** - Brands, products, images
- **Session Planning** - Sessions with curated product lineups
- **Per-Session Flexibility** - Override prices and talking points
- **Real-Time State** - Track current product during live streams
- **Data Integrity** - Foreign keys, constraints, cascades
- **Performance** - Strategic indexes for common queries
- **Resilience** - State persists across crashes and refreshes

The schema supports MVP requirements while allowing future extensions (Shopify sync, analytics, user accounts).
