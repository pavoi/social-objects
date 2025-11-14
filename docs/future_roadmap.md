# Future Roadmap

This document outlines planned features and enhancements beyond the MVP scope.

## Phase 1: MVP (Current)

**Status:** In Development
**Timeline:** Q4 2024

**Features:**
- ✅ Product catalog CRUD
- ✅ Session planning and management
- ✅ Real-time host/producer views
- ✅ Keyboard-driven navigation
- ✅ Image management (Supabase Storage)
- ✅ Per-session product overrides
- ✅ State persistence across refreshes
- ✅ Localhost deployment

**Success Criteria:**
- Replace Google Sheets for live streaming
- 3-4 hour sessions without performance degradation
- <1s sync latency between host and producer
- <15 minute session preparation time

---

## Phase 2: Enhanced Integrations

**Timeline:** Q1 2025
**Priority:** High

**Note:** Shopify sync has been completed! See `lib/hudson/shopify/` for implementation. Hourly sync runs via Oban.

### 2.1 TikTok Shop Integration

**Goal:** Direct product catalog sync with TikTok Shop

**Features:**
- Fetch product listings
- Real-time inventory sync
- Order status updates (future)
- Analytics integration (future)

**Dependencies:**
- TikTok Shop API access
- TikTok Seller account

---

## Phase 3: AI/LLM Features

**Timeline:** Q2 2025
**Priority:** Medium

### 3.1 AI-Generated Talking Points

**Goal:** Automatically generate persuasive talking points from product data

**Features:**
- Generate talking points from product name, description, specs
- Style customization (casual, professional, energetic)
- Bullet point format
- Edit and regenerate
- Save custom templates

**Implementation:**
```elixir
defmodule Hudson.AI.TalkingPoints do
  def generate(product, style \\ :energetic) do
    prompt = """
    Generate 4-6 bullet point talking points for this product:

    Product: #{product.name}
    Description: #{product.description}
    Price: #{format_price(product.original_price_cents)}
    Sale Price: #{format_price(product.sale_price_cents)}

    Style: #{style}
    Format: Markdown bullet list
    """

    # Call OpenAI/Claude API
    response = call_llm_api(prompt)

    # Parse and format
    parse_talking_points(response)
  end
end
```

**LLM Options:**
- OpenAI GPT-4
- Anthropic Claude
- Local LLMs (Llama, Mistral)

**Benefits:**
- Faster session preparation
- Consistent messaging
- Reduced creative burden

### 3.2 Live Comment Summarization

**Goal:** Real-time AI summary of viewer comments and questions

**Features:**
- Connect to TikTok live comment stream
- Summarize common questions
- Highlight product requests
- Sentiment analysis
- Alert host to trending topics

**Display:**
- Sidebar in producer view
- "Top Questions" panel
- Product request counter

**Benefits:**
- Better audience engagement
- Data-driven product selection
- Catch missed opportunities

**Complexity:** High (TikTok API, streaming data, real-time processing)

### 3.3 Session Performance Insights

**Goal:** Post-session AI analysis and recommendations

**Features:**
- Products that generated most engagement
- Optimal product order recommendations
- Talking points effectiveness analysis
- Viewer retention patterns
- Price optimization suggestions

**Implementation:**
- Collect session metrics (time on product, comments, etc.)
- Feed to LLM for analysis
- Generate actionable report

**Benefits:**
- Continuous improvement
- Data-driven decision making
- ROI measurement

---

## Phase 4: Advanced Studio Integration

**Timeline:** Q3 2025
**Priority:** Medium-High

### 4.1 OBS Integration

**Goal:** Control OBS scenes and sources from Hudson

**Features:**
- Switch OBS scenes when changing products
- Display product info overlay in stream
- Automatic countdown timers
- Lower thirds with pricing
- Chromakey product images

**Implementation:**
- OBS WebSocket plugin
- Hudson → OBS commands on product change
- Template-based overlays

**Benefits:**
- Professional broadcast quality
- Automated scene switching
- Consistent branding

**Technical Approach:**
```elixir
defmodule Hudson.OBS do
  # Connect to OBS via WebSocket
  def connect(host, port, password) do
    ObsWebSocket.connect(host, port, password)
  end

  # Switch scene when product changes
  def switch_to_product_scene(product) do
    ObsWebSocket.set_current_scene("Product Display")
    ObsWebSocket.set_text_source("ProductName", product.name)
    ObsWebSocket.set_text_source("ProductPrice", format_price(product.sale_price_cents))
    ObsWebSocket.set_image_source("ProductImage", product.primary_image_url)
  end
end
```

### 4.2 StreamDeck Integration

**Goal:** Hardware button control for session navigation

**Features:**
- Physical buttons for next/previous product
- LED feedback showing current product number
- Custom button actions
- Quick jump buttons (1-10)

**Implementation:**
- StreamDeck SDK
- WebSocket connection to Hudson
- Button mapping configuration

**Benefits:**
- Tactile control for producer
- Faster navigation than keyboard
- Professional production feel

### 4.3 Audio Wake-Word Control

**Goal:** Voice-activated navigation during stream

**Features:**
- Wake word detection ("Okay Hudson")
- Voice commands ("next product", "show image 3", "jump to product 15")
- Text-to-speech confirmation
- Noise-cancellation for studio environment

**Implementation:**
- Whisper.cpp for speech recognition (local, offline)
- Custom wake word model
- LiveView event triggers from detected commands

**Challenges:**
- Studio noise environment
- Avoiding false positives
- Low latency processing

**Safety:**
- Require confirmation for critical actions
- Manual override always available
- Disable during sensitive discussions

---

## Phase 5: Desktop Application

**Timeline:** Q4 2025
**Priority:** Medium

### 5.1 Native Desktop Packaging

**Goal:** Single-click installable desktop application for Windows/Mac/Linux

**Recommended Path:** Elixir Desktop

**Features:**
- No browser required
- System tray icon
- Auto-start on boot
- Auto-update mechanism
- Offline capability (local SQLite)

**Benefits:**
- Professional distribution
- Simplified installation
- Better user experience
- Reduced dependency on browser

### 5.1.1 Packaging Options Comparison

| Solution | Binary Size | Pros | Cons | Recommendation |
|----------|-------------|------|------|----------------|
| **Burrito** | ~15MB | Simple, self-contained | Version caching issues | ⭐ MVP |
| **Elixir Desktop** | Varies | Purpose-built, mobile support | Installers not ready yet | ⭐⭐ Long-term |
| **Tauri + Burrito** | 3-10MB | Smallest, auto-updater | Complex setup | Advanced only |

**MVP Recommendation:** Use Burrito for Windows service deployment

**Long-Term:** Migrate to Elixir Desktop once desktop installers are available (Q2-Q3 2025)

_See [Implementation Guide - Deployment](implementation_guide.md#10-deployment-setup) for setup details._

### 5.2 Mobile Companion App

**Goal:** iOS/Android app for remote session control

**Features:**
- View current product
- Navigate session
- Edit talking points
- Monitor connection status
- Push notifications for session start

**Use Cases:**
- Producer controlling from backstage
- Remote team member observing
- Backup control if main system fails

**Implementation:**
- Elixir Desktop supports mobile
- Or React Native with LiveView Native
- Same backend, different frontend

---

## Phase 6: Collaboration & Team Features

**Timeline:** 2026
**Priority:** Low-Medium

### 6.1 User Accounts & Permissions

**Goal:** Multi-user system with role-based access

**Roles:**
- **Admin** - Full access, configuration
- **Producer** - Session management, live control
- **Host** - Read-only during sessions
- **Cataloger** - Product CRUD only

**Features:**
- User registration and login
- Permission management
- Activity logging
- Session ownership

**Implementation:**
- `mix phx.gen.auth`
- Role-based authorization
- Audit trail

### 6.2 Collaborative Session Planning

**Goal:** Multiple team members planning sessions together

**Features:**
- Real-time collaborative editing
- Comment threads on products
- Approval workflow
- Session templates
- Shared notes

**Technical:**
- Presence tracking (Phoenix Presence)
- Operational transformation for concurrent edits
- Version history

### 6.3 Multi-Brand Management

**Goal:** Support multiple brands in single installation

**Features:**
- Brand-specific catalogs
- Brand switching in UI
- Shared products across brands
- Brand-specific templates and styling

**Use Cases:**
- Agency managing multiple clients
- Company with multiple product lines
- White-label Hudson for resale

---

## Phase 7: Analytics & Optimization

**Timeline:** 2026
**Priority:** Low

### 7.1 Session Analytics Dashboard

**Goal:** Detailed metrics on session performance

**Metrics:**
- Products viewed and duration
- Navigation patterns
- Image carousel usage
- Peak engagement times
- Comment volume per product

**Visualizations:**
- Product engagement heatmap
- Session timeline
- Comparison across sessions
- Trend analysis

**Benefits:**
- Optimize product ordering
- Identify top performers
- Improve session structure

### 7.2 A/B Testing

**Goal:** Test different talking points, product orders, pricing

**Features:**
- Split sessions with variations
- Automated metric collection
- Statistical significance testing
- Winner recommendation

**Use Cases:**
- Test price points
- Compare talking point styles
- Optimize product sequencing

### 7.3 TikTok Analytics Integration

**Goal:** Correlate Hudson data with TikTok performance metrics

**Data Points:**
- Viewer count
- New followers
- Purchases (if TikTok Shop)
- Engagement rate
- Watch time

**Benefits:**
- ROI measurement
- Product performance analysis
- Session effectiveness scoring

---

## Technical Debt & Refactoring

### Ongoing

**Code Quality:**
- Increase test coverage to 90%+
- Add property-based testing
- Performance profiling and optimization
- Documentation improvements

**Infrastructure:**
- CI/CD pipeline
- Automated deployment
- Staging environment
- Load testing

**Developer Experience:**
- Local development docker-compose
- Seed data scripts
- Development tooling
- Contribution guide

---

## Community & Open Source

### Potential Future Direction

**Consider open-sourcing Hudson:**
- Community contributions
- Plugin ecosystem
- Third-party integrations
- Broader adoption

**Plugin System:**
- Hooks for custom behaviors
- Integration adapters
- Custom component library
- Theme system

---

## Summary

**Immediate Next Steps (Post-MVP):**
1. ~~Shopify sync~~ ✅ Complete (see `lib/hudson/shopify/`)
2. Desktop packaging with Elixir Desktop (Q1-Q2 2025)
3. OBS integration (Q2 2025)
4. AI talking points generation (Q2 2025)

**Long-Term Vision:**
- Full studio automation platform
- Multi-platform presence (desktop, mobile, web)
- AI-powered optimization
- White-label solution for agencies
- Open-source community

**Guiding Principles:**
- Keep MVP lean and focused
- Add complexity only when proven need exists
- Prioritize features that directly improve live streaming
- Maintain performance for 3-4 hour sessions
- User experience over feature count

This roadmap is flexible and will evolve based on user feedback, market needs, and technical feasibility.
