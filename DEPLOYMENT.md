# Hudson Desktop Deployment (Tauri + Phoenix)

Ship Hudson as a cross‑platform desktop app using **Tauri** as the shell, while keeping the existing **Phoenix/LiveView** UI and adding a **SQLite + Neon** hybrid data layer plus media caching.

## 🎯 Quick Start (Pilot)

**The pilot is complete and working!** To test the native desktop app:

```bash
./run_native.sh
```

This launches a native macOS window with the full Hudson LiveView UI, backed by a 17MB single-binary BEAM release with SQLite local cache.

## 📌 Latest Progress (2025-02-18)
- ✅ Added a minimal **local sync operations queue** on SQLite with helpers + tests (`priv/local_repo/migrations/20250218120000_create_sync_operations.exs`, `lib/hudson/sync/operation.ex`, `lib/hudson/sync/queue.ex`, `test/hudson/sync/queue_test.exs`). Supports enqueue/pending/done/failed. Sync worker/backoff to Neon is still pending.
- ✅ Burrito targets are now configurable via `HUDSON_BURRITO_TARGETS`. Default: macOS ARM. `all` adds macOS Intel + Windows targets (see `mix.exs` release config).
- ✅ **Tauri automated bundling now working!** Fixed by adding `"active": true` to bundle config in `tauri.conf.json` (defaults to `false` in Tauri v1). Generated proper 1024x1024 icon with `cargo tauri icon`. Bundle created at `src-tauri/target/release/bundle/macos/Hudson.app` and verified working with `./run_native.sh`.

## ⚠️ Current State vs Future State

**This document describes the TARGET architecture.** Most components described here **do not exist yet** and need to be built. See the [Migration Checklist](#migration-checklist) section for concrete changes to existing code.

### What Exists Today (2025-01-18)
- ✅ Phoenix LiveView app running locally on PostgreSQL
- ✅ Shopify & OpenAI API integrations
- ✅ esbuild asset pipeline (no npm)
- ✅ Oban background jobs
- ✅ **Tauri desktop shell (pilot working)** - spawns BEAM, reads handshake, loads WebView
- ✅ **Burrito single-binary packaging (macOS ARM)** - 17MB binary with all NIFs validated
- ✅ **Health check endpoint** (`/healthz`)
- ✅ **Port handshake mechanism** (`/tmp/hudson_port.json`)
- ✅ **SQLite local cache structure** (schema + auto-migrations on startup)
- ✅ **Secure storage pattern** (file-based for pilot, OS keychain ready for production)

### What This Plan Adds
- 🔄 Expand Tauri to multi-platform (Windows, macOS Intel) - pilot is macOS ARM only
- 🔄 Sync worker/backoff to push local SQLite queue to Neon (queue + schema now exist)
- ❌ Full OS keychain/DPAPI integration (currently file-based for pilot)
- ❌ First-run wizard UI (bootstrap code exists, needs UI)
- ❌ Media cache system (not implemented)
- ❌ Auto-update mechanism (not implemented)
- ❌ CI/CD pipeline with code signing (not configured)

**Before following this guide:** Complete the [Migration Checklist](#migration-checklist) to update existing code, then proceed with implementation phases.

## Goals
- Preserve current LiveView UI; avoid template rewrites.
- Better desktop UX: native window/tray, smoother updates, no exposed public port, notarized/signable installers.
- Lower latency and add offline tolerance with a local cache (SQLite + media cache) while keeping Neon as the source of truth.
- Reduce deployment risk: no client-run DB migrations; safer secrets handling; integrity-checked updates.

## High-Level Architecture
- **Tauri shell** (Rust): boots BEAM release, manages lifecycle, native menus/tray, updater, and loads the Phoenix UI in the WebView (`http://127.0.0.1:<ephemeral_port>`). No UI rewrite.
- **Phoenix/LiveView** (unchanged UI): served locally. Endpoint binds to loopback on an ephemeral port handed to Tauri.
- **Data**: SQLite for low-latency/offline cache + Neon Postgres for authoritative data. Operation queue syncs to Neon with retries/conflict rules.
- **Media**: disk cache keyed by URL with TTL/size cap; prefetch per session.
- **Updates**: Tauri updater (or custom) with signature + checksum verification and rollback.

## Detailed Plan

### 1) Desktop Shell (Tauri)
- Add a Tauri workspace with a minimal Rust command that:
  - Spawns the Burrito/BEAM release as a child process.
  - Reads the chosen port from a small handshake file (`/tmp/hudson_port.json` on macOS, `%APPDATA%\Hudson\port.json` on Windows) containing `{"port": <int>}`; fallback: parse the first `PORT:<int>` line on stdout.
  - Waits for `/healthz` on that port with timeout/backoff, then loads WebView to that URL.
  - For shutdown, sends a TERM to BEAM and waits; on update, stop BEAM before replacing binaries.
- Disable remote content in WebView; allow only `127.0.0.1` + `localhost`. Set a strict Content-Security-Policy.
- Native chrome: menu/tray shortcut to open settings, restart, check for updates, open logs.

### 2) Runtime Bootstrap (Elixir)
- Adjust `config/runtime.exs` to:
  - Load persisted settings/creds from keychain/DPAPI-backed store; do **not** raise when env is missing on first run.
  - Generate `secret_key_base` on first run and persist in secure storage (not alongside the creds file).
  - Pick a random available port (unless `PORT` set), bind to `{127,0,0,1}`, and write the port to the handshake file for Tauri.
  - Keep Repo pool small (3–5) and tolerant of reconnects; add backoff/circuit-breaker behavior for Neon connectivity.
- Secure storage libraries:
  - macOS: OS Keychain via a small adapter (e.g., `:keychainx` or a Rust shim exposed via NIF/Port) with `get/put/delete`.
  - Windows: DPAPI/WinCred via adapter (e.g., `:wincred` or Rust bridge) with the same `get/put/delete` surface.

### 3) Data Layer: SQLite + Neon
- Add a local SQLite file (`~/Library/Application Support/Hudson/local.db` on macOS, `%APPDATA%\Hudson\local.db` on Windows).
- Define schema and migrations for SQLite separately from Neon. Keep them tiny and stable; **auto-run SQLite migrations on client startup** (safe because local).
- Add a sync/queue process:
  - Write ops to SQLite first; enqueue outbound mutations to Neon with retries/backoff.
  - On startup/online, pull deltas from Neon (timestamp/high-water mark) and reconcile (domain-specific conflict rules or last-write-wins).
  - For read paths, prefer SQLite cached data; fall back to Neon on cache miss when online.
- Keep Oban/Notifiers: run workers only if they are local-only tasks; otherwise point Oban to Neon via small pools and handle latency or disable as needed.
- Do **not** run `ecto.migrate` against Neon from clients. Migrations run in CI/CD before releasing binaries. On startup, check Neon schema version; if too far ahead, show “Update required” and refuse to start to avoid drift.
  - Schema gate: read `SELECT max(version) FROM schema_migrations`; if client code expects `N` and Neon is > N, require update before proceeding (threshold default 0).
- Conflict rules (initial pass):
  - Product catalog: last-write-wins (Shopify is source of truth; prefer fresh pull).
  - Session state (per user/session): local-first; sync up, but conflicts prompt user to choose.
  - Talking points/AI generations: append-only with timestamps; dedupe on merge.
  - Provide a conflict UI/log for visibility on auto-resolutions.

### 4) Media Cache
- Add a Req-based downloader with disk cache (URL-keyed) with TTL + LRU/size cap (default: **500MB cap, 7-day TTL**, configurable in settings).
- Prefetch session media when online; on offline, serve cached assets or placeholders.
- Store cache under the same app-data root (`media-cache/`). Periodic cleanup task.

### 5) Credentials & Secrets
- Storage: OS keychain (macOS) / DPAPI (Windows). If a file store is unavoidable, use envelope encryption with a key retrieved from OS secure storage; never store the key next to the ciphertext.
- Avoid `System.put_env/2` for secrets; keep them in memory and inject into clients at call time.
- Redact secrets from logs; ensure log rotation per-user under app-data `logs/`.

### 6) Updates
- Use Tauri’s auto-updater or custom flow that:
  - Downloads to temp file, verifies SHA256 + detached signature (ship a public key in the app).
  - Stops BEAM, atomically swaps binaries, keeps a rollback copy.
  - Supports staged rollout by channel (`stable`/`beta`).
- macOS: signed + notarized; Windows: Authenticode signing; both include updater signature checks.

### 7) Build & Packaging
- CI matrix: macOS for mac builds/notarization; Windows runner for Windows build/signing (avoid cross-building NIFs). Validate NIF load on each target via a smoke test.
- Tauri builds installers; Phoenix release embedded asset bundle. Keep `esbuild` pipeline and `phx.digest`.
- Entitlements: keep minimal (likely no `allow-unsigned-executable-memory` needed). Windows installer adds Start Menu shortcut and optional firewall rule for loopback port if required.
- Sidecar wiring: keep Burrito output under `burrito_out/` and **symlink** into `tauri/src-tauri` using Tauri’s expected naming (`hudson_backend-<target-triple>[.exe]`) to avoid copy steps.
- Toolchains: lock Zig versions per target (e.g., cargo-xwin + Zig 0.13.0 for Windows) to avoid build flakiness.

### 8) Networking / Firewall / Ports
- Bind Phoenix to loopback only; choose a random free port to minimize conflicts.
- Health endpoint (`/healthz`) for Tauri readiness.
- Handle firewall prompts gracefully; document that no inbound LAN access is required.

### 9) Observability & UX
- Add a diagnostics page in the UI: Neon connectivity, Shopify/OpenAI reachability, clock skew, cache status, update availability.
- Show offline/online state and queue depth in the UI; allow manual “sync now”. Add a small health indicator (🟢/🟡/🔴) in the navbar.
- Provide a conflict viewer for sync collisions; log auto-resolutions.
- Crash reporting (opt-in) with redaction; consider Sentry with consent.

### 10) Offline/Online Capability Matrix (initial)
| Feature                  | Offline | Online Required |
|--------------------------|---------|-----------------|
| View cached products     | ✅       | —               |
| View fresh products      | ❌       | ✅              |
| Create session (local)   | ✅       | —               |
| Add products to session  | ✅       | —               |
| Generate talking points  | ❌       | ✅ (OpenAI)     |
| Shopify sync             | ❌       | ✅              |
| Start live stream        | ✅       | ✅ (TikTok APIs)|

### 10) Testing/Verification
- Add automated smoke for each target:
  - Launch BEAM, hit `/healthz`, open WebView URL, verify bcrypt/lazy_html NIFs load.
  - SQLite migration + cache read/write.
  - Update flow in temp dir (download, verify, swap, rollback).
- Keep `mix precommit` green; add unit tests for the sync queue and media cache.

## ✅ Pilot Validation (COMPLETE)

**Goal:** Validate core lifecycle and platform blockers before full build.

**All pilot tasks completed (2025-01-18):**
- ✅ Health endpoint (`/healthz`) added - returns JSON with timestamp
- ✅ Random loopback port selection implemented - writes `/tmp/hudson_port.json`
- ✅ First-run friendly boot - works without environment variables via secure storage pattern
- ✅ Tauri shell working - spawns BEAM, reads handshake, polls health, loads WebView
- ✅ NIFs validated on macOS ARM - bcrypt_elixir and lazy_html load successfully in Burrito binary
- ✅ SQLite Repo + auto-migrations - runs on startup, handles version tracking
- ✅ Clean lifecycle - Tauri properly spawns and terminates BEAM backend

**Test Command:**
```bash
# Launch native desktop app with embedded backend
./run_native.sh
```

**Known Limitations (Pilot):**
- macOS ARM only (cross-compilation disabled due to spaces in path breaking lazy_html Makefile)
- File-based secret storage (OS keychain integration planned for production)

## Migration Checklist

**These changes must be made to existing files BEFORE starting the implementation phases.**

### 1. Modify `config/runtime.exs` for Desktop Bootstrap

**Current Issues:**
- Lines 45-50: Raises on missing `DATABASE_URL` (blocks first run)
- Lines 66-71: Raises on missing `SECRET_KEY_BASE` (blocks first run)
- Lines 94-100: Binds to `0.0.0.0` (exposes port publicly)
- Line 40-42: Requires `PHX_SERVER=true` env var

**Required Changes:**

```diff
# config/runtime.exs

if config_env() == :prod do
+  # First-run friendly: load from secure storage or use defaults
+  database_url = Hudson.SecureStorage.get("neon_url") ||
+    System.get_env("DATABASE_URL") ||
+    nil  # Will be set via first-run wizard
+
-  database_url =
-    System.get_env("DATABASE_URL") ||
-      raise """
-      environment variable DATABASE_URL is missing.
-      For example: ecto://USER:PASS@HOST/DATABASE
-      """

+  # Generate and persist secret_key_base on first run
+  secret_key_base = Hudson.SecureStorage.get("secret_key_base") ||
+    System.get_env("SECRET_KEY_BASE") ||
+    generate_and_store_secret()
+
-  secret_key_base =
-    System.get_env("SECRET_KEY_BASE") ||
-      raise """
-      environment variable SECRET_KEY_BASE is missing.
-      You can generate one by calling: mix phx.gen.secret
-      """

+  # Desktop mode: always enable server, bind to loopback, random port
+  config :hudson, HudsonWeb.Endpoint, server: true
+
-  if System.get_env("PHX_SERVER") do
-    config :hudson, HudsonWeb.Endpoint, server: true
-  end

+  # Pick random available port, write to handshake file for Tauri
+  port = pick_available_port()
+  write_port_handshake(port)
+
-  port = String.to_integer(System.get_env("PORT") || "4000")

  config :hudson, HudsonWeb.Endpoint,
    url: [host: host, port: port],
    http: [
-      ip: {0, 0, 0, 0, 0, 0, 0, 0},
+      ip: {127, 0, 0, 1},  # Localhost only for desktop
      port: port
    ],
    secret_key_base: secret_key_base
end

+# Helper functions
+defp generate_and_store_secret do
+  secret = :crypto.strong_rand_bytes(64) |> Base.encode64()
+  Hudson.SecureStorage.put("secret_key_base", secret)
+  secret
+end
+
+defp pick_available_port do
+  {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
+  {:ok, port} = :inet.port(socket)
+  :gen_tcp.close(socket)
+  port
+end
+
+defp write_port_handshake(port) do
+  handshake_path = case :os.type() do
+    {:unix, :darwin} -> "/tmp/hudson_port.json"
+    {:win32, _} -> Path.join(System.get_env("APPDATA"), "Hudson/port.json")
+  end
+  File.mkdir_p!(Path.dirname(handshake_path))
+  File.write!(handshake_path, Jason.encode!(%{port: port}))
+end
```

### ✅ 2. Add Missing Dependencies to `mix.exs` (COMPLETE)

**Desktop deployment dependencies added:**
- ✅ `{:burrito, "~> 1.5", runtime: false}` - Single-binary packaging
- ✅ `{:ecto_sqlite3, "~> 0.9"}` - SQLite local cache
- ✅ Burrito release configuration (macOS ARM only for pilot, cross-compilation disabled)
- ✅ `HUDSON_BURRITO_TARGETS` env var controls Burrito targets; default is macOS ARM, `all` adds macOS Intel + Windows sidecars.

**Secure storage:** Using file-based approach for pilot (see `lib/hudson/desktop/bootstrap.ex`). OS keychain integration planned for production.

### ✅ 3. Add Health Check Endpoint (COMPLETE)

**Controller implemented at `lib/hudson_web/controllers/health_controller.ex`**

Returns JSON response for Tauri readiness checks. Route added at `/healthz` with no authentication required.

### 4. Create Placeholder Scripts

**These scripts are referenced in CI/CD but don't exist yet:**

```bash
# scripts/build_sidecar.sh
#!/bin/bash
set -e
echo "Building BEAM sidecar with Burrito..."
MIX_ENV=prod mix deps.get --only prod
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
echo "Sidecar built: burrito_out/"
ls -lh burrito_out/

# scripts/link_binaries.sh
#!/bin/bash
TARGET=$1
if [ -z "$TARGET" ]; then
  echo "Usage: $0 <target-triple>"
  exit 1
fi

BURRITO_BIN="burrito_out/hudson_${TARGET//-/_}"
if [[ "$TARGET" == *"windows"* ]]; then
  BURRITO_BIN="${BURRITO_BIN}.exe"
fi

TAURI_SIDECAR="src-tauri/binaries/hudson_backend-${TARGET}"
if [[ "$TARGET" == *"windows"* ]]; then
  TAURI_SIDECAR="${TAURI_SIDECAR}.exe"
fi

mkdir -p $(dirname "$TAURI_SIDECAR")
ln -sf "../../${BURRITO_BIN}" "$TAURI_SIDECAR"
echo "Linked: $BURRITO_BIN -> $TAURI_SIDECAR"
```

**Make them executable:**
```bash
chmod +x scripts/*.sh
```

### 5. Add `.gitignore` Entries

```gitignore
# Desktop build artifacts
/burrito_out/
/src-tauri/target/
/src-tauri/binaries/
*.dmg
*.msi
*.pkg
```

### ✅ 6. Create Tauri Workspace (COMPLETE)

**Tauri workspace created at `src-tauri/`**

**Key files:**
- `src-tauri/src/main.rs` - Window management, BEAM lifecycle, handshake reading
- `src-tauri/tauri.conf.json` - Configuration with `"active": true` for automated bundling
- `src-tauri/Cargo.toml` - Rust dependencies (Tauri 1.5, tokio, reqwest)
- `src-tauri/icons/` - Full icon set generated by `cargo tauri icon`

**Current Configuration:**
- Window created programmatically with `WindowUrl::App("index.html")`
- BEAM backend bundled as external binary sidecar
- Health check polling with 10-second timeout
- Clean shutdown on window close
- Automated `.app` bundling working via `cargo tauri build`

## Action Items

### ✅ Pilot Phase (Complete)
- ✅ Add Tauri workspace + Rust bootstrap to spawn BEAM and load LiveView URL
- ✅ Implement health endpoint and port handshake mechanism
- ✅ Add SQLite local cache schema with auto-migrations
- ✅ Implement secure storage pattern (file-based for pilot)
- ✅ Validate bcrypt/lazy_html NIF loading on macOS ARM with Burrito build
- ✅ Configure Burrito single-binary packaging

### 🔄 Next Phase (Production-Ready Desktop)
- ❌ Expand to multi-platform (Windows, macOS Intel) - resolve cross-compilation issues
- ❌ Implement sync processing/backoff to push the SQLite operations queue to Neon (queue/tests exist)
- ❌ Add OS keychain/DPAPI integration (replace file-based storage)
- ❌ Build first-run wizard UI
- ❌ Implement Req-based media cache with TTL/LRU
- ❌ Wire Tauri updater with signature verification and rollback
- ❌ Add diagnostics UI + offline/online indicators
- ❌ Set up CI/CD pipeline with code signing and notarization

## Timeline & Effort Estimation

**Total Estimated Duration:** 18-20 working days

| Phase | Tasks | Duration | Dependencies |
|-------|-------|----------|--------------|
| **Phase 1: Foundation** | Tauri setup, Burrito config, health endpoint, port handshake | 2 days | — |
| **Phase 2: Data Layer** | SQLite Repo, sync queue, conflict resolution, schema versioning | 4 days | Phase 1 |
| **Phase 3: Credentials** | OS keychain/DPAPI integration, secure storage module | 2 days | Phase 1 |
| **Phase 4: Media Cache** | Req-based cache, LRU/TTL logic, prefetch | 1 day | Phase 2 |
| **Phase 5: Updates** | Tauri updater, signature verification, rollback | 2 days | Phase 1 |
| **Phase 6: UX & Diagnostics** | Settings UI, health indicators, conflict viewer, first-run wizard | 3 days | Phase 2, 3 |
| **Phase 7: Build & CI/CD** | GitHub Actions, code signing, notarization, installers | 2 days | All above |
| **Phase 8: Testing** | Multi-platform testing, offline scenarios, NIF validation | 2-3 days | All above |

**Critical Path:** Phase 1 → Phase 2 → Phase 6 → Phase 7 → Phase 8

## Dependencies & Tooling Requirements

### Development Machine Setup

**Required:**
- Elixir 1.15+ and Erlang/OTP 26+
- Rust 1.70+ (for Tauri)
- Zig 0.13.0 (exact version for Burrito Windows builds)
- Node.js 18+ (for Tauri CLI, not for Phoenix assets)
- Git

**Platform-Specific:**
- **macOS:** Xcode Command Line Tools, Apple Developer account/certificates
- **Windows:** Visual Studio Build Tools 2019+, Windows SDK

**Install Commands:**
```bash
# macOS
brew install elixir rust zig@0.13.0 node
rustup update stable

# Tauri CLI
cargo install tauri-cli

# Windows cross-compilation (from macOS/Linux)
cargo install cargo-xwin
```

### Elixir Dependencies (validation)

**These dependencies are already in `mix.exs`; keep versions aligned when updating the desktop toolchain:**

```elixir
defp deps do
  [
    # ... existing deps
    {:burrito, "~> 1.5", runtime: false},  # ❌ Not yet added
    {:ecto_sqlite3, "~> 0.9"},             # ❌ Not yet added
    {:req, "~> 0.5"},                      # ✅ Already present
    # Secure storage adapters (choose approach in Phase 3)
    # Option A: Use Tauri Rust bridge via Port (recommended)
    # Option B: {:ex_os_keychain, "~> 0.1"} for pure Elixir macOS
    # Option C: File-based envelope encryption (fallback)
  ]
end
```

See [Migration Checklist #2](#2-add-missing-dependencies-to-mixexs) for full changes.

### Rust Dependencies (Cargo.toml in src-tauri/)

Tauri workspace already exists; keep these dependencies in sync when upgrading:

```toml
[dependencies]
tauri = { version = "1.5", features = ["shell-open"] }
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"
tokio = { version = "1", features = ["full"] }

[target.'cfg(target_os = "macos")'.dependencies]
security-framework = "2.9"  # For keychain access (if implementing secure storage in Rust)

[target.'cfg(target_os = "windows")'.dependencies]
windows = { version = "0.51", features = ["Win32_Security_Credentials"] }  # For DPAPI
```

## Project File Structure

**Legend:** ✅ = Exists today | ❌ = Needs to be created | 🔄 = Modify existing

```
hudson/
├── lib/                                      ✅
│   ├── hudson/                               ✅
│   │   ├── sync/                             🔄 SQLite queue exists; Neon sync worker pending
│   │   │   ├── operation.ex                  ✅ Local queue schema/helpers
│   │   │   ├── queue.ex                      ✅ Enqueue/pending/done/failed
│   │   │   ├── reconciler.ex                 ❌
│   │   │   └── conflict_resolver.ex          ❌
│   │   ├── cache/                            ❌ Media cache
│   │   │   ├── media_cache.ex
│   │   │   └── lru_store.ex
│   │   ├── secure_storage.ex                 ❌ Keychain/DPAPI adapter
│   │   ├── local_repo.ex                     ✅ SQLite Repo
│   │   └── local_repo_migrator.ex            ✅ Migration runner for SQLite
│   └── hudson_web/                           ✅
│       ├── controllers/
│       │   └── health_controller.ex          ✅ For /healthz endpoint
│       └── live/
│           ├── settings_live/                🔄 Add credentials UI
│           └── diagnostics_live/             ❌ Health/sync dashboard
├── priv/                                     ✅
│   └── repo/
│       ├── migrations/                       ✅ Neon (CI-run only)
│       └── local_repo/                       ✅ SQLite (client-run; includes sync_operations)
├── src-tauri/                                ✅ Tauri Rust project (entire directory)
│   ├── src/
│   │   ├── main.rs                           ✅ Window setup, sidecar lifecycle
│   │   ├── backend.rs                        ✅ BEAM process management
│   │   └── secure_storage.rs                 ❌ Keychain/DPAPI bridge (optional)
│   ├── tauri.conf.json                       ✅
│   └── Cargo.toml                            ✅
├── config/                                   ✅
│   └── runtime.exs                           🔄 First-run friendly (see Migration Checklist #1)
├── .github/                                  ✅
│   └── workflows/
│       └── release.yml                       ❌ CI/CD pipeline
└── scripts/                                  ✅ Utilities (pilot validation, bundle helper)
    ├── make_app_bundle.sh                    ✅ Manual macOS bundle helper (current)
    ├── quick_test.sh                         ✅
    ├── test_pilot.sh                         ✅
    └── validate_pilot.sh                     ✅
```

## CI/CD Pipeline (GitHub Actions)

**⚠️ IMPORTANT: This workflow is ILLUSTRATIVE and will not work until:**
1. ✅ Tauri workspace exists (`src-tauri/` directory)
2. 🔄 Release-ready build/link scripts are added (current manual helpers under `scripts/`).
3. ✅ Burrito configured in `mix.exs` (targets controlled via `HUDSON_BURRITO_TARGETS`)
4. ✅ Apple certificates added to GitHub Secrets (if deploying macOS)

**Do not push a tag to trigger this workflow until prerequisites are complete.**

```yaml
# .github/workflows/release.yml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build-macos:
    runs-on: macos-latest
    strategy:
      matrix:
        target: [aarch64-apple-darwin, x86_64-apple-darwin]
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26'
      - uses: dtolnay/rust-toolchain@stable
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.13.0

      - name: Install Tauri CLI
        run: cargo install tauri-cli

      - name: Build BEAM sidecar
        run: |
          mix deps.get --only prod
          MIX_ENV=prod mix assets.deploy
          MIX_ENV=prod mix release
          ./scripts/link_binaries.sh ${{ matrix.target }}

      - name: Build Tauri app
        run: |
          cd src-tauri
          cargo tauri build --target ${{ matrix.target }}

      - name: Code sign & notarize
        env:
          APPLE_CERTIFICATE: ${{ secrets.APPLE_CERTIFICATE }}
          APPLE_CERTIFICATE_PASSWORD: ${{ secrets.APPLE_CERTIFICATE_PASSWORD }}
          APPLE_ID: ${{ secrets.APPLE_ID }}
          APPLE_PASSWORD: ${{ secrets.APPLE_PASSWORD }}
          APPLE_TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          # Import certificate
          echo "$APPLE_CERTIFICATE" | base64 --decode > certificate.p12
          security create-keychain -p actions build.keychain
          security import certificate.p12 -k build.keychain -P "$APPLE_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k actions build.keychain

          # Sign
          codesign --force --deep --sign "Developer ID Application" \
            src-tauri/target/${{ matrix.target }}/release/bundle/macos/Hudson.app

          # Notarize
          xcrun notarytool submit \
            src-tauri/target/${{ matrix.target }}/release/bundle/dmg/Hudson_*.dmg \
            --apple-id "$APPLE_ID" \
            --password "$APPLE_PASSWORD" \
            --team-id "$APPLE_TEAM_ID" \
            --wait

          # Staple
          xcrun stapler staple src-tauri/target/${{ matrix.target }}/release/bundle/dmg/Hudson_*.dmg

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: hudson-macos-${{ matrix.target }}
          path: src-tauri/target/${{ matrix.target }}/release/bundle/dmg/Hudson_*.dmg

  build-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.15'
          otp-version: '26'
      - uses: dtolnay/rust-toolchain@stable
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: 0.13.0

      - name: Install Tauri CLI
        run: cargo install tauri-cli

      - name: Build BEAM sidecar
        shell: bash
        run: |
          mix deps.get --only prod
          MIX_ENV=prod mix assets.deploy
          MIX_ENV=prod mix release
          ./scripts/link_binaries.sh x86_64-pc-windows-msvc

      - name: Build Tauri app
        run: |
          cd src-tauri
          cargo tauri build

      - name: Code sign (if certificate available)
        if: ${{ secrets.WINDOWS_CERTIFICATE }}
        shell: powershell
        run: |
          # Sign with SignTool
          # Add signing logic here

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: hudson-windows-x86_64
          path: src-tauri/target/release/bundle/msi/Hudson_*.msi

  create-release:
    needs: [build-macos, build-windows]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
      - uses: softprops/action-gh-release@v1
        with:
          files: |
            hudson-macos-*/*.dmg
            hudson-windows-*/*.msi
          draft: false
          generate_release_notes: true
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Error Handling & Graceful Degradation

### Startup Failure Scenarios

| Scenario | Detection | Response |
|----------|-----------|----------|
| No credentials configured | `Hudson.SecureStorage.get("neon_url") == nil` | Redirect to first-run wizard |
| Neon unreachable | Connection timeout > 10s | Start in offline mode, show banner |
| Neon schema too new | `neon_version > expected_version` | Block startup, show "Update Required" dialog |
| SQLite corruption | `Ecto.Adapters.SQL.query!` raises | Delete local.db, re-sync from Neon, log incident |
| Port conflict | `Bandit.start_link` fails | Retry with 3 random ports, then error |
| NIF load failure | `bcrypt_elixir` or `lazy_html` error | Log to file, show "Installation corrupted" dialog |

### Runtime Failure Scenarios

| Scenario | Detection | Response |
|----------|-----------|----------|
| Neon connection lost | Active query fails | Queue writes, show offline indicator |
| Shopify API rate limit | HTTP 429 response | Exponential backoff, show sync delay estimate |
| OpenAI API failure | HTTP 5xx or timeout | Retry 3x, then disable AI features temporarily |
| Disk cache full | Write fails | Evict LRU entries, reduce cache cap by 20% |
| Sync conflict | Timestamp collision | Log conflict, apply domain rule, notify user if manual resolution needed |

### Recovery Mechanisms

```elixir
# lib/hudson/sync/circuit_breaker.ex
defmodule Hudson.Sync.CircuitBreaker do
  use GenServer

  # State: :closed (healthy), :open (failing), :half_open (testing)
  # Open after 5 consecutive failures
  # Half-open after 60s
  # Close after 1 successful request in half-open

  def call(fun) do
    case get_state() do
      :closed -> try_request(fun)
      :open -> {:error, :circuit_open}
      :half_open -> test_request(fun)
    end
  end
end
```

## First-Run Setup Flow (UX)

### Initial Launch Sequence

1. **App starts** → Tauri boots → BEAM spawns
2. **No credentials found** → `Hudson.SecureStorage.first_run? == true`
3. **WebView loads** → `/setup/welcome` (bypasses auth check)
4. **Setup wizard** (LiveView multi-step form):
   - **Step 1:** Welcome screen with product explanation
   - **Step 2:** Neon database URL input + test connection button
   - **Step 3:** Shopify credentials (store name + access token) + test
   - **Step 4:** OpenAI API key + test
   - **Step 5:** Initial sync (pull products from Shopify → SQLite)
   - **Step 6:** Success screen → redirect to `/sessions`

### Credential Validation UI

```elixir
# lib/hudson_web/live/setup_live/credentials.ex
def handle_event("test_neon", %{"url" => url}, socket) do
  case Hudson.Sync.test_connection(url) do
    {:ok, version} ->
      {:noreply,
       socket
       |> assign(:neon_status, :success)
       |> assign(:neon_version, version)
       |> put_flash(:info, "Connected to Neon (schema v#{version})")}

    {:error, reason} ->
      {:noreply,
       socket
       |> assign(:neon_status, :error)
       |> put_flash(:error, "Connection failed: #{reason}")}
  end
end
```

## Security Considerations

### Threat Model

| Threat | Mitigation |
|--------|------------|
| Credential theft from disk | Store in OS keychain/DPAPI, never plaintext |
| Man-in-the-middle (Neon) | TLS 1.3+, verify Neon certificates |
| Binary tampering | Code sign + notarize, updater checks signatures |
| Log file secrets | Redact `DATABASE_URL`, API keys via Logger backend filter |
| Memory dumps | Use `:crypto.strong_rand_bytes` for secrets, avoid `System.put_env` |
| Malicious updates | GPG-signed release metadata, checksum verification |

### Secret Redaction

```elixir
# config/runtime.exs
config :logger, :console,
  format: {Hudson.LogFormatter, :format},
  metadata: [:request_id]

# lib/hudson/log_formatter.ex
defmodule Hudson.LogFormatter do
  @moduledoc """
  Custom log formatter that redacts sensitive information.
  """

  def format(level, message, timestamp, metadata) do
    # Default formatting
    formatted_message = Logger.Formatter.format(
      "$time $metadata[$level] $message\n",
      level,
      message,
      timestamp,
      metadata
    )

    # Redact secrets
    formatted_message
    |> to_string()
    |> redact(~r/DATABASE_URL=[^\s]+/, "DATABASE_URL=***")
    |> redact(~r/postgres:\/\/[^\s]+/, "postgres://***")
    |> redact(~r/sk-[a-zA-Z0-9\-]+/, "sk-***")  # OpenAI keys
    |> redact(~r/shpat_[a-f0-9]+/, "shpat_***")  # Shopify tokens
  end

  defp redact(string, pattern, replacement) do
    String.replace(string, pattern, replacement)
  end
end
```

## Notes on Current Code Risks (to address as part of the move)
- `config/runtime.exs` currently raises on missing `DATABASE_URL`/`SECRET_KEY_BASE`, which will block first-run in desktop mode; needs the new bootstrap flow.
- Client-side migrations against Neon would be risky; shift to CI-run only.
- Credentials are presently configured via env; move to secure storage and avoid env mutation for secrets.

## Resources & References

- **Tauri Documentation:** https://tauri.app/v1/guides/
- **Burrito + Tauri Guide:** https://mrpopov.com/posts/elixir-liveview-single-binary/
- **Ecto SQLite:** https://hexdocs.pm/ecto_sqlite3
- **Phoenix Releases:** https://hexdocs.pm/phoenix/releases.html
- **Apple Notarization:** https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution
- **Tauri Sidecar Pattern:** https://tauri.app/v1/guides/building/sidecar/
