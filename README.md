# Pavoi

Phoenix LiveView app for TikTok live streaming sessions. Real-time product catalog with keyboard-driven navigation and synchronized host/producer views.

## Setup

```bash
mix deps.get
cp .env.example .env
# Edit .env with your DATABASE_URL (or leave unset for local postgres)
mix ecto.create && mix ecto.migrate
mix run priv/repo/seeds.exs
mix assets.build
mix phx.server
```

Visit: **http://localhost:4000/sessions/1/producer**

## Controls

**Keyboard:**
- **Type number + Enter**: Jump directly to product (e.g., "23" → Enter)
- **↓ / ↑ / Space**: Navigate products
- **← / →**: Navigate images

**Voice Control:**
- **Ctrl/Cmd + M**: Toggle voice recognition
- **Say product numbers**: "twenty three", "product 12", etc.
- 100% local processing (Whisper.js + Silero VAD)

See [VOICE_CONTROL_PLAN.md](VOICE_CONTROL_PLAN.md) for complete documentation.

## Production (Railway)

```bash
railway login && railway link
railway add  # Select Postgres
railway variables set SECRET_KEY_BASE="$(mix phx.gen.secret)"
railway variables set PHX_SERVER="true"
railway variables set PHX_HOST="your-app.up.railway.app"
railway variables set SITE_PASSWORD="your-password"
railway variables set MIX_ENV="prod"
railway up
```

Set `SITE_PASSWORD` to enable password protection.
