# Creator CRM Data Model & Implementation Plan

> **Status**: Phase 2 Complete - Basic CRM UI Done
> **Created**: 2025-12-01
> **Last Updated**: 2025-12-02

## Data Analysis Summary

### Source Files Analyzed

| File | Rows | Unique Creators | Key Data |
|------|------|-----------------|----------|
| All Free Sample Data | ~123K | 9,002 buyers | Order ID, Username, Recipient, Phone, Product, Address |
| Creator Data L6 Months (Refunnel) | 7,271 | 7,271 | Username, Followers, EMV, GMV, Engagement metrics |
| Creator email/phone (Euka) | 25,284 | 25,284 | Handle, Email (55% filled), Phone (16% filled), Address |
| Phone Numbers Raw Data | 36,308 | 17,370 | Username, First/Last Name, Phone |
| Video Data Last 90 Days | 59,894 | 16,728 | Video ID, Creator, GMV, Items Sold, Impressions |
| Product Analytics | 611 | N/A | TikTok Product ID, GMV, Sales by channel |

### Key Findings

**1. Primary Identifier: TikTok Username**
- All files use TikTok username as the common key
- Must normalize (lowercase, trim) for matching
- ~8,350 creators overlap between Sample Orders and Euka contact data

**2. Data Quality Issues**
- Phone numbers: Mixed formats (masked `(+1)832*****59` vs full `(+1)3159212129`)
- Duplicates in Phone Numbers file (same creator, same data repeated)
- Missing data: 45% missing email in Euka, 84% missing phone
- Some names have encoding issues (e.g., `MartÃ­nez`)

**3. Data Relationships**
```
                    ┌──────────────────┐
                    │     Creator      │
                    │  (tiktok_handle) │
                    └────────┬─────────┘
                             │
         ┌───────────────────┼───────────────────┐
         │                   │                   │
         ▼                   ▼                   ▼
┌─────────────────┐  ┌───────────────┐  ┌────────────────┐
│ Creator Samples │  │Creator Videos │  │  Performance   │
│ (what received) │  │(content made) │  │  (metrics)     │
└─────────────────┘  └───────────────┘  └────────────────┘
         │                   │
         ▼                   ▼
    ┌─────────┐        ┌─────────┐
    │ Product │        │ Product │
    └─────────┘        └─────────┘
```

---

## Design Decisions

### 1. Creator Tiers: TikTok Shop Creator Badge System
TikTok has an official Creator Badge system based on **monthly GMV** (not followers):

| Badge | GMV Range (Monthly) |
|-------|---------------------|
| Bronze | Entry level |
| Silver | $1K - $5K |
| Gold | $5K+ (estimated) |
| Platinum | Higher |
| Ruby | Higher |
| Emerald | Higher |
| Sapphire | Higher |
| Diamond | Top tier |

Source: [TikTok Seller University - Creator Badges](https://seller-us.tiktok.com/university/essay?knowledge_id=1082957398361902&lang=en)

### 2. Phone Number Strategy
- Store all phone numbers (including masked)
- Normalize to E.164 format where possible
- `phone_verified` boolean tracks data quality

### 3. Multi-Brand Support
- Creators linked to brands via `brand_creators` junction table
- Sample data is brand-specific

---

## Implementation Phases

### Phase 1: Data Model & Initial Import ✅ COMPLETE

- [x] Create migrations for new tables (6 migrations)
- [x] Create Ecto schemas (lib/pavoi/creators/ context)
- [x] Build CSV import workers (Oban jobs)
- [x] Run initial data import

**Import Results (Local Dev DB):**
| Data Type | Records |
|-----------|---------|
| Creators | 36,876 |
| Samples | 24,603 |
| Videos | 59,834 |
| Performance Snapshots | 7,272 |
| Brand-Creator Links | 9,001 |

**Files Created:**
- `lib/pavoi/creators.ex` - Context module
- `lib/pavoi/creators/creator.ex` - Creator schema
- `lib/pavoi/creators/brand_creator.ex` - Brand-Creator junction
- `lib/pavoi/creators/creator_sample.ex` - Sample tracking
- `lib/pavoi/creators/creator_video.ex` - Video performance
- `lib/pavoi/creators/creator_video_product.ex` - Video-Product junction
- `lib/pavoi/creators/creator_performance_snapshot.ex` - Historical metrics
- `lib/pavoi/workers/creator_import_worker.ex` - CSV import worker
- 6 migrations in `priv/repo/migrations/`

### Phase 2: Basic CRM UI ✅ COMPLETE

- [x] Creator list view (`/creators`) with search, badge/brand filters, sortable columns
- [x] Creator detail view (`/creators/:id`) with contact info, stats, tabbed sections
- [x] Manual creator editing (contact info, notes, whitelisted status)
- [x] Display tags, whitelisted badge, brand relationships
- [x] Samples tab with product thumbnails
- [x] Videos tab with clickable TikTok links
- [x] Performance history tab
- [x] Helpful empty states for all tabs

**Files Created:**
- `lib/pavoi_web/live/creators_live/index.ex` + `index.html.heex`
- `lib/pavoi_web/live/creators_live/show.ex` + `show.html.heex`
- `lib/pavoi_web/components/creator_components.ex`
- `assets/css/04-layouts/creators-index.css`
- `assets/css/05-components/creator.css`

**Files Modified:**
- `lib/pavoi_web/router.ex` - Added `/creators` routes
- `lib/pavoi_web/components/core_components.ex` - Added Creators nav link
- `lib/pavoi_web/live/nav_hooks.ex` - Added creators page detection

### Phase 3: Analytics Dashboard
- [ ] Creator performance metrics aggregation
- [ ] Sample tracking dashboard (conversion rates, pending samples)
- [ ] Video performance by creator (top performers, trending)
- [ ] Export functionality

### Phase 4: Communication Integrations
- [ ] Mailgun email sending
- [ ] Twilio SMS sending
- [ ] Communication history logging
- [ ] `creator_communications` table migration

### Phase 5: Ongoing Sync
- [ ] TikTok Shop API integration for affiliate data
- [ ] Scheduled sync workers
- [ ] Webhook handlers for real-time updates

---

## Database Schema Reference

### Tables
| Table | Purpose |
|-------|---------|
| `creators` | Central creator entity with contact info, metrics, classification |
| `brand_creators` | Many-to-many junction linking creators to brands |
| `creator_samples` | Tracks free product samples sent to creators |
| `creator_videos` | TikTok video performance data |
| `creator_video_products` | Links videos to products they promote |
| `creator_performance_snapshots` | Historical metrics from Refunnel etc. |

### Key Fields on `creators`
- `tiktok_username` - Primary identifier (normalized lowercase)
- `tiktok_badge_level` - Official TikTok badge tier
- `is_whitelisted` - Internal VIP flag
- `tags` - Array of custom tags
- `notes` - Free-form notes
- `follower_count`, `total_gmv_cents`, `total_videos` - Cached metrics
