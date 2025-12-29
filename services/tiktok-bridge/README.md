# TikTok Bridge Service

A Node.js service that connects to TikTok Live streams and forwards events to the Elixir app via WebSocket.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  Elixir App (Pavoi)                                         │
│    └─ BridgeClient (WebSocket client)                       │
│         │                                                    │
│         │ WebSocket (ws://tiktok-bridge:8080/events)        │
│         │ HTTP (POST /connect, /disconnect)                 │
│         ▼                                                    │
├─────────────────────────────────────────────────────────────┤
│  TikTok Bridge (this service)                               │
│    └─ tiktok-live-connector library                         │
│         │                                                    │
│         │ TikTok Protocol (WebSocket + HTTP + protobuf)     │
│         ▼                                                    │
├─────────────────────────────────────────────────────────────┤
│  TikTok Live Servers                                        │
└─────────────────────────────────────────────────────────────┘
```

## API

### HTTP Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |
| GET | `/status` | List active connections and stats |
| POST | `/connect` | Connect to a TikTok stream |
| POST | `/disconnect` | Disconnect from a stream |

### WebSocket

Connect to `ws://host:8080/events` to receive real-time events.

#### Event Types

```json
{ "type": "connected", "uniqueId": "username", "roomId": "123", "roomInfo": {...} }
{ "type": "disconnected", "uniqueId": "username" }
{ "type": "chat", "uniqueId": "username", "data": { "userId": "...", "comment": "..." } }
{ "type": "gift", "uniqueId": "username", "data": { "giftName": "...", "diamondCount": 100 } }
{ "type": "like", "uniqueId": "username", "data": { "likeCount": 5, "totalLikeCount": 1000 } }
{ "type": "member", "uniqueId": "username", "data": { "userId": "...", "nickname": "..." } }
{ "type": "roomUser", "uniqueId": "username", "data": { "viewerCount": 500 } }
{ "type": "social", "uniqueId": "username", "data": { "displayType": "follow" } }
{ "type": "streamEnd", "uniqueId": "username" }
{ "type": "error", "uniqueId": "username", "error": "error message" }
```

## Local Development

```bash
cd services/tiktok-bridge
npm install
npm start
```

Test with curl:
```bash
# Health check
curl http://localhost:8080/health

# Connect to a stream (user must be live)
curl -X POST http://localhost:8080/connect \
  -H "Content-Type: application/json" \
  -d '{"uniqueId": "pavoi"}'

# Check status
curl http://localhost:8080/status

# Disconnect
curl -X POST http://localhost:8080/disconnect \
  -H "Content-Type: application/json" \
  -d '{"uniqueId": "pavoi"}'
```

## Railway Deployment

### Quick Deploy (CLI)

From this directory (`services/tiktok-bridge`):

```bash
./deploy.sh
```

Or manually:

```bash
railway link -p pavoi -s tiktok-bridge
railway up --path-as-root .
```

The `--path-as-root` flag is required because this is a subdirectory of the main repo.

### First-Time Setup

1. Create a new service in Railway named `tiktok-bridge`
2. No configuration needed - the `railway.toml` handles build settings
3. Add to the main Elixir app's environment variables:
   ```
   TIKTOK_BRIDGE_URL=http://tiktok-bridge.railway.internal:8080
   ```

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `PORT` | `8080` | Server port (Railway sets this automatically) |
| `HOST` | `0.0.0.0` | Bind address |

### Internal Networking

Railway automatically provides internal URLs. The bridge is accessible at:
```
http://tiktok-bridge.railway.internal:8080
```

## Resource Requirements

- **Memory**: ~256-512MB (tiktok-live-connector is lightweight)
- **CPU**: Minimal (mostly I/O bound)
- **Network**: Internal only (no public exposure needed)

## Notes

- Uses `tiktok-live-connector` which relies on signing servers for TikTok authentication
- If signing servers become unavailable, consider implementing custom signing with Playwright
