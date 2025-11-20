# Product Requirements Document

## 1. Goals & Constraints

### Primary Goals (MVP)

Purpose-built application for TikTok streaming sessions that serves as:

1. **CRUD-able Catalog**
   - Central repository for products, images, and talking points
   - Support for multiple brands (starting with Pavoi)
   - Image management with ordering and primary image selection
   - Markdown-formatted talking points

2. **Host View for Live Streaming**
   - Optimized for 3–4 hour TikTok streaming sessions
   - Read-only display controlled by producer
   - Clear, high-contrast display of product information and images
   - Large, readable fonts suitable for reading while on camera
   - Minimal cognitive load during live performance
   - Floating banner for live messages from producer

3. **Remote Editing Capability**
   - Enable producer to edit catalog and sessions from outside studio
   - Real-time synchronization between host and producer views
   - Allow for on-the-fly session adjustments during live streams
   - Producer can send live messages to host during session

4. **Robust & Simple Implementation**
   - Idiomatic Phoenix/LiveView patterns
   - Minimal dependencies
   - Easy to understand and maintain
   - Resilient to network interruptions and process crashes

### Non-Goals (MVP)

These features are explicitly deferred to post-MVP phases:

- ~~**Shopify Integration**~~ ✅ Complete (hourly sync via Oban)
- ~~**Voice Control**~~ ✅ Complete (local speech recognition with Whisper.js + Silero VAD)
- **LLM Features** - No AI-generated talking points or comment summarization
- **OBS/StreamDeck Integration** - Manual scene switching for MVP
- **Multi-brand Management UI** - Single brand (Pavoi) hardcoded is acceptable
- **User Authentication System** - Simple shared password acceptable for MVP
- **Mobile Apps** - Browser-based web application only for MVP
- **Analytics & Reporting** - Focus on core streaming functionality

### Constraints

**Technical:**
- Must run on studio Windows machine with minimal setup
- Database must be remotely accessible (Supabase)
- Must work reliably during 3-4 hour sessions without restarts
- Network interruptions should not lose session state

**User Experience:**
- Host view must be readable while on camera
- Producer controls must sync to host view within 1 second
- Images must load smoothly with no visible flashing
- Host messages must be clearly visible as floating banners

**Business:**
- MVP must be production-ready for holiday season 2024
- Must support 40+ products per session
- Should accommodate future growth to 100+ products per session

---

## 2. User Personas

### Persona 1: Host (Primary User)

**Name:** Sarah (Live Host)
**Role:** On-camera host for TikTok live shopping sessions

**Responsibilities:**
- Present products on live stream (3-4 hours)
- Navigate through 40+ products per session
- Read talking points naturally while engaging with viewers
- Switch between product images during presentation
- Respond to viewer questions and comments

**Pain Points (Current Workflow):**
- Scrolling through Google Sheets is slow and clunky
- Difficult to find products quickly during live stream
- Sheet formatting breaks, cells overlap
- Hard to read small text on sheet while on camera
- Accidentally navigating away from sheet loses place
- No clear visual separation between products

**Goals for Pavoi:**
- Navigate products instantly with keyboard shortcuts
- See large, clear product images
- Read bullet-pointed talking points easily
- Never lose place in product sequence
- Focus on camera presence, not technical operations

**Success Criteria:**
- Can navigate 40 products in session without using mouse
- Can jump to any product number in <2 seconds
- Can read talking points without squinting
- Never experiences visible loading delays for images

### Persona 2: Producer (Secondary User)

**Name:** Mike (Session Producer)
**Role:** Remote session controller and content manager

**Responsibilities:**
- Prepare product sessions before live streams
- Curate product selection and ordering
- Write and update talking points
- Control session flow remotely during streams
- Make real-time adjustments based on viewer engagement
- Upload and organize product images

**Pain Points (Current Workflow):**
- Google Sheets have no version control
- Accidental edits corrupt formatting
- No preview of how host sees the information
- Can't control what host is viewing remotely
- Image management is manual and error-prone

**Goals for Pavoi:**
- Create sessions quickly from product catalog
- Control host view remotely during live streams
- Edit talking points without disrupting live session
- Preview exactly what host sees
- Reorder products on the fly if needed

**Success Criteria:**
- Can build a 40-product session in <15 minutes
- Changes sync to host view within 1 second
- Can remotely navigate host view during stream
- No accidental edits affect live sessions

### Persona 3: Content Manager (Tertiary User)

**Name:** Alex (Catalog Manager)
**Role:** Maintains product catalog and uploads content

**Responsibilities:**
- Add new products to catalog
- Upload product images
- Write initial talking points
- Set prices and product details
- Maintain product metadata (SKU, PID)

**Pain Points (Current Workflow):**
- No central product repository
- Duplicate effort for each session
- Image organization is chaotic
- Price updates require finding all sheets

**Goals for Pavoi:**
- Single source of truth for product data
- Organize images by product
- Update product details once, reflect everywhere
- Support Shopify sync and manual data entry

**Success Criteria:**
- Upload multiple images per product
- Edit product details from one interface
- See which products are used in which sessions

---

## 3. User Stories & Use Cases

### Epic 1: Session Preparation

**US-1.1: As a producer, I want to create a new session with a name, so I can prepare for an upcoming live stream.**

**Acceptance Criteria:**
- Can create session with name
- Can assign host(s) to session
- Session appears in session list
- Can add notes for internal reference

**US-1.2: As a producer, I want to search and select products for a session, so I can build a curated product lineup.**

**Acceptance Criteria:**
- Can search products by name, SKU, or PID
- Can filter by brand
- Can preview product images and details
- Selected products are added to session

**US-1.3: As a producer, I want to reorder products in a session, so I can optimize the presentation flow.**

**Acceptance Criteria:**
- Can drag-and-drop products to reorder
- Can use keyboard shortcuts to move products
- Position numbers update automatically
- Can group products into sections (optional)

**US-1.4: As a producer, I want to override talking points for specific sessions, so I can customize messaging without changing the global product.**

**Acceptance Criteria:**
- Can edit per-session talking points
- Original talking points remain unchanged
- Can revert to original talking points
- Overrides are clearly indicated

### Epic 2: Live Session Control

**US-2.1: As host, I want to jump directly to a product number, so I can respond to viewer requests quickly.**

**Acceptance Criteria:**
- Type product number (e.g., "23") then Enter
- Jumps directly to that product
- Invalid numbers show brief error message
- Works even during active navigation
- Number input buffer visible on screen

**US-2.2: As host, I want to navigate to adjacent products with arrow keys, so I can quickly move up/down the list when needed.**

**Acceptance Criteria:**
- ↓ or → advances to next product
- ↑ or ← returns to previous product
- Navigation wraps (last → first, first → last)
- Current product is clearly highlighted
- Used as convenience for sequential browsing, not primary navigation

**US-2.3: As host, I want to see large product images, so I can show products to viewers effectively.**

**Acceptance Criteria:**
- Images are at least 800px wide
- ← → keys cycle through product images
- Current image indicator shows position (e.g., "2/5")
- Images load without visible delay

**US-2.4: As host, I want to read talking points clearly, so I can present products naturally without memorization.**

**Acceptance Criteria:**
- Talking points are displayed as large, spaced bullet list
- Markdown formatting renders correctly
- Font size is readable from 3 feet away
- Bullet points don't wrap excessively

**US-2.5: As a producer, I want to control the host view remotely, so I can help navigate during the stream.**

**Acceptance Criteria:**
- Producer and host see synchronized state
- Producer navigation changes host view within 1 second
- Both can navigate independently (producer's changes take precedence)
- Connection status is visible

### Epic 3: Catalog Management

**US-3.1: As a content manager, I want to add new products with images and details, so I can expand the catalog.**

**Acceptance Criteria:**
- Can create product with all required fields
- Can upload multiple images per product
- Can set primary image
- Can reorder images via drag-and-drop

**US-3.2: [DEPRECATED] As a content manager, I want to import products from CSV, so I can migrate existing Google Sheets data.**

_Note: CSV import has been removed. Products are now managed via Shopify sync and manual CRUD operations._

**US-3.3: As a content manager, I want to edit product details, so I can keep information current.**

**Acceptance Criteria:**
- Can edit all product fields
- Changes save immediately
- Can add/remove images
- Can see which sessions use this product

### Epic 4: Error Recovery & Resilience

**US-4.1: As host, I want the session state to persist if I refresh the browser, so I don't lose my place during a stream.**

**Acceptance Criteria:**
- Current product and image are stored in DB and URL
- Refresh returns to exact same product/image
- Session state survives browser close/reopen

**US-4.2: As host, I want to see connection status, so I know if I'm synced with the producer.**

**Acceptance Criteria:**
- Connection indicator shows "Connected", "Reconnecting...", "Disconnected"
- Reconnection is automatic
- State synchronizes after reconnection
- Visual feedback when connection is restored

---

## 4. UX Requirements

### 4.1 Host View Layout

**Layout Structure:**

```
┌─────────────────────────────────────────────────────────────┐
│  [Session: Holiday Favorites] [Connected ●]                  │ Header
├──────────────────────┬──────────────────────────────────────┤
│                      │  CZ Lariat Station Necklace          │
│    Product Image     │  PID: TT12345  SKU: NECK-001         │
│    (Large)           │  $49.99  →  $29.99                   │
│    [◀ Image 2/5 ▶]   │                                       │
│                      ├──────────────────────────────────────┤
│                      │  Talking Points:                      │
│                      │  • High-quality cubic zirconia       │
│                      │  • Adjustable lariat style           │
│                      │  • Station design with 5 CZ points   │
│                      │  • Perfect for layering              │
│                      │  • Exclusive holiday collection      │
└──────────────────────┴──────────────────────────────────────┘
```

**Key Design Elements:**
- **Left:** Product image (60% width), centered, maximum size
- **Right Top:** Product name (large), number, pricing, metadata
- **Right Middle/Bottom:** Talking points in large bullet list
- **Header Bar:** Session name, progress (23/40), connection status

**Color Scheme:**
- Dark background (#1a1a1a) to reduce eye strain
- High-contrast text (white/light gray #f0f0f0)
- Accent color for current product (gold/yellow #ffd700)
- Price highlighting (original in gray strikethrough, sale in green)

**Typography:**
- Product name: 32-36px, bold, sans-serif
- Talking points: 24-28px, regular, line-height 1.6
- Metadata: 18-20px, medium
- Monospace for PID/SKU

### 4.2 Keyboard Shortcuts

| Key | Action | Notes |
|-----|--------|-------|
| `1-9`, `0` then `Enter` | Jump to product | **Primary navigation** - Type number, press Enter |
| `↓` | Next product | Convenience - sequential navigation |
| `↑` | Previous product | Convenience - sequential navigation |
| `→` | Next image | For current product |
| `←` | Previous image | For current product |
| `Space` | Next product | Alternative to ↓ |
| `F` | Toggle fullscreen image | Maximize current image |
| `ESC` | Exit fullscreen | Return to normal view |

**Modifier Keys (Future):**
- `Ctrl+F`: Search products
- `Ctrl+P`: Print/export current session
- `Ctrl+R`: Refresh/re-sync state

### 4.3 Producer Console

**Layout Differences from Host View:**
- Smaller preview of current product
- Sidebar with full session product list
- Editable talking points
- Session controls (start/stop, timer)
- Upcoming products preview (next 3)

**Additional Controls:**
- Quick edit for talking points
- Image upload
- Product reordering

### 4.4 Accessibility

**Minimum Requirements:**
- Keyboard-only operation (no mouse required)
- High contrast mode support
- Scalable font sizes (user can zoom)
- Screen reader compatible (ARIA labels)
- No flashing/strobing animations

**Visual Considerations:**
- Minimum font size: 18px
- Minimum contrast ratio: 4.5:1 (WCAG AA)
- Focus indicators on interactive elements
- No color-only information (use icons + color)

---

## 5. Live Streaming Best Practices (Baked In)

### 5.1 Performance Optimizations

**Image Preloading:**
- Preload all images for current product immediately
- Preload adjacent products (±2 positions) for arrow key convenience
- Use Low-Quality Image Placeholder (LQIP) pattern:
  - Show 10-20px blur preview instantly
  - Load high-res in background
  - Smooth transition when loaded
- Progressive preload remaining products in background

**Asset Caching:**
- Browser caches images via proper headers
- Service worker for offline capability (future)
- Eager preload strategy (arbitrary navigation requires all products ready)

**UI Responsiveness:**
- All navigation completes in <100ms
- No visible loading spinners for images
- Smooth CSS transitions (200-300ms)
- No layout shift during image loads

### 5.2 Low-Friction UI Design

**Visual Design:**
- Dark theme to reduce eye strain (3-4 hour sessions)
- High contrast for readability under studio lights
- Large click/touch targets (even though keyboard-driven)
- Minimal chrome and distractions

**Interaction Design:**
- No confirmation dialogs for navigation
- Instant feedback on all actions
- Clear current state indicators
- No unexpected navigation (disable scroll, etc.)

**Cognitive Load Reduction:**
- One product at a time (no multi-column layouts)
- Clear visual hierarchy
- Consistent layout across all products
- Progress indicator (23/40) for orientation

### 5.3 Reliability Measures

**State Persistence:**
- Current product/image stored in DB
- URL params preserve state across refreshes
- Automatic state recovery after disconnection

**Error Prevention:**
- Disable browser shortcuts that cause navigation
- Capture space/arrow keys to prevent scroll
- Prevent accidental tab/window close
- Auto-save all edits (no save button needed)

**Monitoring:**
- Connection status always visible
- Subtle indicators for background updates
- No intrusive error messages during stream
- Log errors for post-stream review

### 5.4 Studio Environment Considerations

**Hardware:**
- Optimized for 1920x1080 display (studio monitor)
- Works with studio lighting (high contrast)
- Minimal CPU usage (streaming uses resources)
- Low network bandwidth usage

**Workflow:**
- Host opens session URL, leaves it open 3-4 hours
- Producer can connect from anywhere
- No need to restart during session
- Session can be paused/resumed

---

## 6. Success Metrics

### MVP Launch Criteria

**Must Have (P0):**
- [ ] 40 products can be added to catalog with images
- [ ] Session can be created and products assigned
- [ ] Jump-to-product by number (primary navigation method)
- [ ] Host can navigate all 40 products with keyboard only
- [ ] Producer can control host view remotely in <1s sync
- [ ] Images preload without visible delay
- [ ] State persists across browser refresh
- [ ] Connection recovers automatically after interruption
- [ ] Runs for 4 hours without performance degradation

**Should Have (P1):**
- [ ] Per-session talking point overrides work
- [ ] Image carousel with 5+ images per product
- [ ] Arrow key navigation for sequential browsing (convenience)
- [ ] Fullscreen image mode works

**Nice to Have (P2):**
- [ ] Product search and filtering
- [ ] Session cloning
- [ ] Dark/light theme toggle
- [ ] Session templates

### Post-Launch Metrics

**Usage Metrics:**
- Products per session (target: 40+)
- Keyboard shortcut usage rate (target: 90%+)
- Mouse interaction rate (target: <10%)

**Performance Metrics:**
- Image load time (target: <500ms)
- Navigation latency (target: <100ms)
- State sync latency (target: <1s)
- Memory usage over 4 hours (target: <100MB growth)
- Crash rate (target: 0 per 10 sessions)

**User Satisfaction:**
- Host confidence rating (target: 9/10)
- Navigation speed vs. Google Sheets (target: 3x faster)
- Producer setup time (target: <15 minutes)
- Technical support requests (target: <1 per 10 sessions)

### Rollout Plan

**Phase 1: Internal Testing**
- Test with 5 products, 30-minute sessions
- Iterate on UX based on host feedback
- Fix critical bugs

**Phase 2: Dress Rehearsal**
- Full 40-product session, 2-hour test stream
- Producer and host use simultaneously
- Monitor performance and errors

**Phase 3: Soft Launch**
- Use for non-critical live session
- Have fallback plan ready
- Gather feedback immediately after

**Phase 4: Full Production**
- Primary tool for all sessions
- Monitor first 3 sessions closely

---

## 7. Open Questions & Decisions Needed

> Resolve every item below before the final MVP rehearsal. Each answer drives specific UI, data-model, and training work.

### Product Decisions
- [ ] Should host be able to skip products, or must they go sequentially?
- [ ] Should price changes during session be allowed, and who approves them?

### Technical Decisions
- [ ] Authentication approach: Hashed shared secrets (see Implementation Guide §1.5) vs. full per-user accounts?
- [ ] How to handle multi-brand if needed sooner than expected?
- [ ] Should producer changes during stream be logged for review/audit history?

### Operational Decisions
- [ ] Who manages product catalog day-to-day?
- [ ] How far in advance are sessions prepared?
- [ ] Define the rollback plan if Pavoi fails mid-stream (who handles fallback, what state must be documented, how to notify TikTok audience).

---

## Appendix: Current Workflow Analysis

### Google Sheets Workflow (Current State)

**Preparation (Producer):**
1. Copy previous session sheet
2. Manually update product list
3. Copy/paste talking points from various sources
4. Add product image URLs (stored in separate folders)
5. Format cells for readability
6. Share sheet with host

**During Stream (Host):**
1. Open Google Sheet on second monitor
2. Scroll down as products are presented
3. Read talking points while presenting
4. Switch tabs to view product images (if URLs provided)
5. Manually track which product is current

**Pain Points Observed:**
- Scrolling is slow and imprecise
- Formatting breaks unexpectedly
- Images are not embedded (URLs only)
- No synchronization between host and producer
- Easy to lose place in sheet
- Accidental edits during live stream
- Sheet becomes sluggish with 40+ rows

**Time Analysis:**
- Session prep: 45-60 minutes
- Mid-stream adjustments: Not possible
- Post-stream cleanup: 10-15 minutes

**Target Improvement:**
- Session prep: <15 minutes (4x faster)
- Mid-stream adjustments: Real-time
- Post-stream cleanup: None needed (data persists)
