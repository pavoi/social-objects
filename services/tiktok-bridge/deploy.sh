#!/bin/bash
# Deploy TikTok Bridge to Railway
# Run from services/tiktok-bridge directory

set -e

echo "Deploying TikTok Bridge to Railway..."

# Link to the correct service
railway link -p pavoi -s tiktok-bridge

# Deploy with path-as-root since we're in a subdirectory
railway up --path-as-root .

echo "Deployment initiated. Check logs with: railway logs --build"
