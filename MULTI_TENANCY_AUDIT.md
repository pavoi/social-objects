# Multi-Tenancy Feasibility Audit for Pavoi

*Audit Date: January 2026*

## Executive Summary

**Current State:** The Pavoi codebase is approximately **40-50% ready** for multi-tenancy. A foundational `brands` table exists with proper relationships to products, product sets, and creators. However, the application layer doesn't enforce tenant isolation, authentication is a single shared password, and all external API integrations assume a single brand.

**Feasibility:** Converting to multi-tenant is **feasible but requires significant work** across database, authentication, routing, and external integrations.

---

## Requirements (Confirmed)

| Decision | Choice |
|----------|--------|
| **TikTok App Strategy** | Shared App - brands OAuth into your existing TikTok app |
| **Feature Scope** | All features ideally; Product Sets + Products + Streams priority |
| **Onboarding Model** | Self-service (aim for it) |
| **Data Isolation** | Complete isolation - NO shared creators |

### Implications of Complete Isolation
Since complete data isolation was chosen (not shared creators), this **simplifies** some aspects:
- Each brand has their own creators - no junction table complexity
- No cross-brand data leakage concerns
- Simpler authorization (just check `brand_id` matches)

But requires:
- `creators` table needs `brand_id` FK (currently global)
- Remove/repurpose `brand_creators` junction table
- All creator-related queries must scope by brand

---

## 1. Database Schema Assessment

### Already Multi-Tenant Ready (9 tables)
| Table | Isolation Method |
|-------|-----------------|
| `brands` | Root tenant table |
| `products` | Direct `brand_id` FK |
| `product_images` | Via `products.brand_id` |
| `product_variants` | Via `products.brand_id` |
| `product_sets` | Direct `brand_id` FK |
| `product_set_products` | Via `product_sets.brand_id` |
| `product_set_states` | Via `product_sets.brand_id` |
| `brand_creators` | Junction table (brand ↔ creator) |
| `creator_tags` | Direct `brand_id` FK |

### Needs Brand Isolation (Critical)
| Table | Issue | Fix Required |
|-------|-------|--------------|
| `tiktok_streams` | No `brand_id`, optional `product_set_id` | Add `brand_id` FK |
| `tiktok_comments` | Inherits from streams | Depends on streams fix |
| `tiktok_stream_stats` | Inherits from streams | Depends on streams fix |
| `tiktok_shop_auth` | **SINGLETON** - single global record (enforced by `Repo.one/1` + upsert in code, not by DB constraint; the migration's unique index on `id` is redundant with the PK) | Complete redesign to per-brand auth |
| `outreach_logs` | No `brand_id` | Add `brand_id` FK |
| `email_templates` | Global templates | Add `brand_id` FK |
| `system_settings` | Global key-value store | Add namespacing |

### Needs Brand Isolation (Creators)
Since complete isolation was chosen, creators must be brand-scoped:
- `creators` - Currently global, needs `brand_id` FK added
- `creator_videos` - Needs `brand_id` FK (inherits from creator)
- `creator_performance_snapshots` - Needs `brand_id` FK
- `creator_purchases` - Needs `brand_id` FK
- `brand_creators` junction table - Can be removed (no longer needed)

This is cleaner than shared creators but requires more migration work.

---

## 2. External API Integrations

### TikTok Shop API (CRITICAL)
**Current:** Single TikTok "app" with credentials in environment variables
- `TTS_APP_KEY`, `TTS_APP_SECRET`, `TTS_SERVICE_ID` → all global
- `tiktok_shop_auth` table has a redundant unique index on `id` (already a PK); singleton is enforced in application code via `Repo.one(Auth)` + upsert pattern in `store_tokens/1`
- Token refresh worker assumes one auth

**Recommended: Shared App Model**
- TikTok app credentials (`TTS_APP_KEY`, `TTS_APP_SECRET`) stay in env vars (one app, multiple authorized shops)
- Each brand completes OAuth → gets their own `access_token`/`refresh_token`
- Store tokens in `tiktok_shop_auth` with `brand_id` FK
- Remove singleton pattern (both the redundant unique index and the `Repo.one/1` calls)

**Implementation:**
```elixir
# Migration: Add brand_id to tiktok_shop_auth
alter table(:tiktok_shop_auth) do
  add :brand_id, references(:brands, on_delete: :delete_all), null: false
end
drop unique_index(:tiktok_shop_auth, [:id])  # Remove redundant unique index
create unique_index(:tiktok_shop_auth, [:brand_id])  # One auth per brand

# Update TiktokShop module to accept brand_id
def get_auth(brand_id) do
  Repo.get_by(Auth, brand_id: brand_id)
end
```

**OAuth Flow for Brand Onboarding (Critical: bind callback to brand via `state`):**
1. Brand clicks "Connect TikTok Shop" in settings
2. Generate a CSRF `state` token, store a `{state → brand_id}` mapping server-side
3. Redirect to TikTok OAuth: `services.us.tiktokshop.com/open/authorize?service_id=...&state=<token>` (US) or `services.tiktokshop.com/open/authorize?...` (Global)
4. TikTok redirects back to `/tiktok/callback` with `auth_code` + `state`
5. Look up `brand_id` from the `state` mapping, exchange code for tokens, store with `brand_id`

> **Note:** The TikTok Shop Owner account (not just an admin/sub-account) must perform the authorization. Only the main account holder has authority to authorize third-party apps. The shop region (US vs Global) determines which authorization URL to use.

### BigQuery
**Current:** Single project/dataset via environment variables
**Fix:** Store credentials per-brand in database table, or use single project with brand-namespaced tables

### Shopify
**Current:** Single store credentials in env vars
**Fix:** Each brand links their own Shopify store via OAuth flow

### Slack, SendGrid, OpenAI
**Current:** Global API keys
**Fix:** Either share (with brand metadata in payloads) or store per-brand credentials

---

## 3. Authentication & Authorization

### Current State
- **No user system** - single `SITE_PASSWORD` env var
- Anyone with password sees ALL brands/data
- No roles, permissions, or user-brand relationships

### Required for Multi-Tenancy
1. **Users table:** `id`, `email`, `password_hash`, `name`
2. **User-Brand relationship:** `user_brands` junction table with `role` (owner/admin/viewer)
3. **Plugs for authorization:**
   - `RequireAuth` - ensure logged in
   - `RequireBrandAccess` - ensure user can access requested brand
   - `SetCurrentBrand` - resolve brand from URL and set in conn assigns

---

## 4. Routing Architecture

### Current Routes (No Brand Context)
```
/products          → shows ALL products
/product-sets      → shows ALL product sets
/creators          → shows ALL creators
/streams           → shows ALL streams
```

### Recommended: Path-Based Multi-Tenancy
```
/b/:brand_slug/products       → shows brand's products
/b/:brand_slug/product-sets   → shows brand's product sets
/b/:brand_slug/creators       → shows brand's creators
/b/:brand_slug/streams        → shows brand's streams
```

**Why path-based over subdomains:**
- Simpler SSL (one cert vs wildcard)
- Easier development/testing
- No DNS changes needed
- Phoenix plugs handle naturally

### Implementation Pattern
```elixir
# router.ex
scope "/b/:brand_slug", PavoiWeb do
  pipe_through [:browser, :require_auth, :set_brand, :require_brand_access]

  live "/products", ProductsLive.Index
  live "/product-sets", ProductSetsLive.Index
  # ...
end

# plugs/set_brand.ex
def call(conn, _opts) do
  brand = Catalog.get_brand_by_slug!(conn.params["brand_slug"])
  assign(conn, :current_brand, brand)
end
```

---

## 5. Hardcoded References

**223 occurrences** of "Pavoi"/"pavoi" found:

### Must Change for Multi-Tenancy
| Location | Reference | Fix |
|----------|-----------|-----|
| `config/config.exs:71` | `accounts: ["pavoi"]` | Move to brand settings |
| `lib/pavoi/communications/email.ex` | `from_name: "Pavoi"` | Read from brand |
| `lib/pavoi/stream_report.ex` | `app.pavoi.com` URLs | Build from brand settings |
| `lib/pavoi_web/components/layouts/root.html.heex` | `<title>Pavoi</title>` | Dynamic brand name |
| `lib/pavoi_web/controllers/auth_html/login.html.heex` | "Pavoi" heading | Generic or brand-specific |
| `lib/pavoi/workers/tiktok_sync_worker.ex:472` | `get_or_create_tiktok_brand` hardcodes slug `"pavoi"` and name `"PAVOI"` | Accept `brand_id` param, remove auto-creation |
| `lib/pavoi/workers/creator_enrichment_worker.ex:662` | `get_pavoi_brand_id` hardcodes slug `"pavoi"` | Accept `brand_id` param, remove hardcoded lookup |
| `lib/pavoi/workers/bigquery_order_sync_worker.ex:111` | Hardcoded BigQuery project `data-459112` and dataset `pavoi_4980_prod_staging` in SQL | Parameterize project/dataset per brand or via config |

### Can Keep (Module Names)
- `Pavoi.*` and `PavoiWeb.*` module prefixes (81 occurrences)
- These are internal namespacing, not user-facing

---

## 6. Recommended Multi-Tenancy Strategy

Based on research of Phoenix best practices:

### Data Isolation: Foreign Key Approach (Recommended)
- Add `brand_id` FK to ALL tables needing isolation
- Scope all queries with `where: [brand_id: ^brand_id]`
- **Not** schema-per-tenant (overkill for this use case)

**Why foreign key approach works:**
- Complete isolation - no shared data needed
- Simpler migrations (one schema, just add FKs)
- Existing pattern partially implemented
- Easier to query across brands for admin purposes if ever needed

### Query Scoping Pattern
```elixir
# In context modules
def list_products(brand_id) do
  Product
  |> where([p], p.brand_id == ^brand_id)
  |> Repo.all()
end

# Or with Ecto query prefix
def list_products(brand) do
  Product
  |> where([p], p.brand_id == ^brand.id)
  |> preload(:variants)
  |> Repo.all()
end
```

### LiveView Pattern
```elixir
def mount(%{"brand_slug" => slug}, session, socket) do
  brand = Catalog.get_brand_by_slug!(slug)
  user = get_user_from_session(session)

  if authorized?(user, brand) do
    {:ok, assign(socket, current_brand: brand, current_user: user)}
  else
    {:ok, redirect(socket, to: "/unauthorized")}
  end
end
```

---

## 7. Implementation Phases (Recommended Order)

### Phase 1: Database Migrations (Foundation)
Add `brand_id` to all tables that need it:
```
priv/repo/migrations/
├── YYYYMMDD_add_brand_id_to_creators.exs
├── YYYYMMDD_add_brand_id_to_tiktok_streams.exs
├── YYYYMMDD_add_brand_id_to_outreach_logs.exs
├── YYYYMMDD_add_brand_id_to_email_templates.exs
├── YYYYMMDD_add_brand_id_to_tiktok_shop_auth.exs  # + remove singleton
├── YYYYMMDD_create_users_table.exs
├── YYYYMMDD_create_user_brands_table.exs
└── YYYYMMDD_create_brand_settings_table.exs
```

### Phase 2: User Authentication System
**New files:**
- `lib/pavoi/accounts/user.ex` - User schema
- `lib/pavoi/accounts/user_brand.ex` - User-Brand relationship
- `lib/pavoi/accounts.ex` - Context for user operations
- `lib/pavoi_web/plugs/require_auth.ex` - Authentication plug
- `lib/pavoi_web/controllers/session_controller.ex` - Login/logout
- `lib/pavoi_web/controllers/session_html/` - Login templates

**Modify:**
- `lib/pavoi_web/router.ex` - Add auth routes

### Phase 3: Brand-Scoped Routing
**New files:**
- `lib/pavoi_web/plugs/set_brand.ex` - Resolve brand from URL
- `lib/pavoi_web/plugs/require_brand_access.ex` - Authorization

**Modify:**
- `lib/pavoi_web/router.ex` - Add `/b/:brand_slug` scope
- All 10 LiveViews - Read `@current_brand` from assigns

### Phase 4: Query Scoping (Priority Features)
Focus on Product Sets + Products + Streams first:
- `lib/pavoi/catalog.ex` - Add brand_id to all product queries
- `lib/pavoi/product_sets.ex` - Add brand_id to all product set queries
- `lib/pavoi/tiktok_live.ex` - Add brand_id to stream queries
- `lib/pavoi/creators.ex` - Add brand_id (now required, not via junction)

### Phase 5: TikTok Shop Multi-Tenant
- `lib/pavoi/tiktok_shop/auth.ex` - Accept brand_id
- `lib/pavoi/tiktok_shop.ex` - Pass brand_id to all API calls
- `lib/pavoi/workers/tiktok_token_refresh_worker.ex` - Iterate all brands
- `lib/pavoi/workers/tiktok_sync_worker.ex` - Per-brand execution
- New: OAuth callback handler for brand onboarding

### Phase 6: Brand Settings & Self-Service Onboarding
- Brand settings UI for email from, Slack channel, etc.
- TikTok Shop OAuth connect flow
- Shopify OAuth connect flow (if needed)
- Invite user to brand flow

---

## 8. Effort Estimate

| Component | Complexity | Files Affected |
|-----------|------------|----------------|
| Users & Auth | Medium | ~10 new files |
| Brand Routing | Medium | router.ex, 10 LiveViews, 3 plugs |
| Query Scoping | Medium-High | All context modules (~15 files) |
| DB Migrations | Low | 5-8 migration files |
| TikTok Shop Multi-tenant | High | 5+ files, OAuth flow |
| Other Integrations | Medium | ~10 files |
| Hardcoded Strings | Low | ~15 files |

**Total:** Significant refactor, but achievable incrementally.

---

## 9. Remaining Considerations

1. **Pricing/Billing:** Any metering or usage tracking needed per brand? (e.g., number of sessions, streams captured)

2. **Admin Access:** Do you (as the platform owner) need a super-admin view to see all brands' data?

3. **TikTok App Approval:** Your TikTok app may need additional approval to support multiple shops. Check TikTok developer portal requirements.

4. **Existing Pavoi Data:** How to handle existing data during migration? Keep as "Pavoi" brand, or something else?

5. **Domain Strategy:** Will other brands use `app.pavoi.com/b/theirbrand` or would they eventually want custom domains?

---

## 10. Critical Files Summary

### Must Modify (High Priority)
| File | Change |
|------|--------|
| `lib/pavoi_web/router.ex` | Add brand-scoped routes, auth routes |
| `lib/pavoi/tiktok_shop/auth.ex` | Accept brand_id, remove singleton logic |
| `lib/pavoi/tiktok_shop.ex` | Pass brand_id to all API calls |
| `lib/pavoi/catalog.ex` | Scope all queries by brand_id |
| `lib/pavoi/product_sets.ex` | Scope all queries by brand_id |
| `lib/pavoi/creators.ex` | Add brand_id param, remove junction table queries |
| All 10 LiveViews in `lib/pavoi_web/live/` | Read current_brand from assigns |

### Must Create (New Files)
| File | Purpose |
|------|---------|
| `lib/pavoi/accounts/user.ex` | User schema |
| `lib/pavoi/accounts/user_brand.ex` | User-brand relationship |
| `lib/pavoi/accounts.ex` | User context module |
| `lib/pavoi_web/plugs/set_brand.ex` | Resolve brand from URL |
| `lib/pavoi_web/plugs/require_brand_access.ex` | Authorization check |
| 5-8 migration files | Add brand_id FKs, create users tables |

---

## 11. Bottom Line Assessment

**Is multi-tenancy feasible?** Yes.

**How much work?** Significant - roughly 2-4 weeks of focused development for core features, more for full parity.

**Biggest challenges:**
1. TikTok Shop singleton redesign → per-brand auth (critical path)
2. User authentication system (from scratch)
3. Updating all queries to scope by brand
4. Removing hardcoded "PAVOI" brand assumptions in workers (`tiktok_sync_worker`, `creator_enrichment_worker`, `bigquery_order_sync_worker`)

**Risk mitigation:**
- Implement incrementally (don't try to do everything at once)
- Start with Phase 1-3 (database + auth + routing) before touching integrations
- Keep existing routes working during transition (backward compatibility)

**Recommended first step:** Before any implementation, verify your TikTok developer app can support OAuth for multiple shops. This is a potential blocker. Also, collect all external inputs from the new brand's team using the checklist below.

---

## 12. New Brand Onboarding Checklist (Team Request)

Use this checklist when onboarding a new brand. Items marked **(Required)** are blocking; items marked **(If applicable)** depend on which features you want active for the brand.

### TikTok Shop Authorization (Required)

- [ ] **Shop Owner performs OAuth authorization** — The TikTok Shop Owner's main account (not a sub-account or admin) must authorize your app. Sub-accounts cannot authorize third-party services.
- [ ] **Confirm shop region** — Is this a US shop or Global? This determines the authorization URL:
  - US: `https://services.us.tiktokshop.com/open/authorize?service_id=...`
  - Global: `https://services.tiktokshop.com/open/authorize?service_id=...`
- [ ] **Verify app scopes** — Before the shop authorizes, confirm your TikTok Partner Center app has the necessary scopes enabled (at minimum: Shop Authorized Information, Order Information, Product Basic, Affiliate Seller/Marketplace Creators). Scopes are configured at `partner.tiktokshop.com` (or `partner.us.tiktokshop.com` for US).
- [ ] **Verify redirect URL** — Your app's OAuth redirect URL (`/tiktok/callback`) must be registered in the TikTok Partner Center app settings before the shop can authorize.
- [ ] **Send authorization link** — Generate the link with your `service_id` and a `state` parameter encoding the brand. The shop owner clicks it, logs in, and approves.
- [ ] **Confirm tokens received** — After authorization, the system exchanges the returned `auth_code` for `access_token`/`refresh_token` and stores them with the `brand_id`. Verify the token was stored successfully.
- [ ] **Verify shop details** — Call the Get Authorized Shops API (`/authorization/202309/shops`) to retrieve `shop_id`, `shop_cipher`, `shop_name`, and `region`. Confirm correct shop is linked.

### Shopify Store (If applicable — product sync)

- [ ] **Confirm store ownership** — Is the Shopify store in the same Shopify organization as your app? Custom apps can only be installed on stores within the same org. If not, you'll need to use the OAuth authorization-code flow instead of client credentials.
- [ ] **Provide store subdomain** — e.g., `theirbrand.myshopify.com`
- [ ] **Install the Shopify app** — The store admin installs your Shopify app on their store.
- [ ] **Confirm access token** — Store the per-brand Shopify access token. Note: client-credentials tokens expire in ~24 hours and must be refreshed.

### BigQuery (If applicable — order sync / analytics)

- [ ] **Confirm data source** — Is order data in a separate BigQuery project/dataset, or will it be added to the existing Pavoi dataset with brand filtering?
- [ ] **Provide service account access** — If separate project: grant your GCP service account `roles/bigquery.dataViewer` on their dataset. Share the project ID and dataset name.
- [ ] **Confirm table schema** — Verify the BigQuery table structure matches expected schema (`TikTokShopOrders`, `TikTokShopOrderLineItems`), or document any differences.

### SendGrid (If applicable — outreach emails)

- [ ] **Brand-specific sender identity** — Provide the desired `from_name` and `from_email` for outreach emails.
- [ ] **Domain verification** — Verify the sender domain in SendGrid (or use a shared verified domain with a brand-specific from address).

### Slack (If applicable — alerts and notifications)

- [ ] **Brand-specific Slack channel** — Provide the channel ID where alerts should be routed for this brand.
- [ ] **Bot token** — If using a separate workspace, provide the Slack bot token. If using the same workspace, just the channel ID is sufficient.

### Brand Configuration (Internal)

- [ ] **Create brand record** — Add the brand to the `brands` table with `name`, `slug`, and any settings.
- [ ] **Assign users** — Create user-brand relationships in `user_brands` with appropriate roles.
- [ ] **Configure brand settings** — Set up email from name, Slack channel, BigQuery dataset, and any other brand-specific configuration.
- [ ] **Verify data isolation** — Confirm that all queries, workers, and API calls for this brand are scoped correctly and no data leaks to/from other brands.
- [ ] **Test end-to-end** — Run through product sync, stream monitoring, creator lookup, and order sync for the new brand to confirm everything works.

---

## 13. Sources

- [Building Multitenant Applications with Phoenix and Ecto](https://elixirmerge.com/p/building-multitenant-applications-with-phoenix-and-ecto)
- [Setting Up a Multi-tenant Phoenix App](https://blog.appsignal.com/2023/11/21/setting-up-a-multi-tenant-phoenix-app-for-elixir.html)
- [Subdomain-Based Multi-Tenancy in Phoenix](https://alembic.com.au/blog/subdomain-based-multi-tenancy-in-phoenix)
- [Triplex - Database multitenancy for Elixir](https://github.com/ateliware/triplex)
- [Multitenancy in Elixir: Complete Guide](https://www.curiosum.com/blog/multitenancy-in-elixir)
