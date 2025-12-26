/**
 * TikTok Live Bridge Service
 *
 * Connects to TikTok Live streams and forwards events to the Elixir app.
 * Uses tiktok-live-connector library for TikTok protocol handling.
 *
 * API:
 *   POST /connect       - Start capturing a stream (body: { uniqueId: "username" })
 *   POST /disconnect    - Stop capturing (body: { uniqueId: "username" })
 *   GET  /status        - List active connections
 *   GET  /health        - Health check
 *   WS   /events        - WebSocket for real-time event streaming to Elixir
 */

import http from 'http';
import { URL } from 'url';
import { WebSocketServer, WebSocket } from 'ws';
import { WebcastPushConnection } from 'tiktok-live-connector';
import ffmpeg from 'fluent-ffmpeg';
import ffmpegPath from 'ffmpeg-static';
import fs from 'fs';
import os from 'os';
import path from 'path';

// Set FFmpeg path from static binary
ffmpeg.setFfmpegPath(ffmpegPath);

const PORT = process.env.PORT || 8080;
const HOST = process.env.HOST || '0.0.0.0';
const DEBUG_RAW_EVENTS = process.env.DEBUG_RAW_EVENTS === 'true';

// Shopping-related message types to capture via rawData
const SHOPPING_MESSAGE_TYPES = [
  'WebcastOecLiveShoppingMessage',
  'WebcastVideoLiveGoodsOrderMessage',
  'WebcastVideoLiveGoodsRcmdMessage',
  'WebcastVideoLiveCouponRcmdMessage',
  'WebcastLiveEcomMessage',
  'WebcastLiveShoppingMessage'
];

// Active TikTok connections: Map<uniqueId, connection>
const connections = new Map();

// WebSocket clients subscribed to events
const wsClients = new Set();

// Stats
const stats = {
  startTime: Date.now(),
  totalConnections: 0,
  totalEvents: 0
};

/**
 * Broadcast an event to all connected WebSocket clients
 */
function broadcastEvent(event) {
  stats.totalEvents++;
  const message = JSON.stringify(event);

  for (const client of wsClients) {
    if (client.readyState === WebSocket.OPEN) {
      client.send(message);
    }
  }
}

/**
 * Extract product information from shopping events.
 *
 * TikTok shopping events contain various structures depending on the event type.
 * Common structures include:
 * - products/productList arrays with product details
 * - Nested productInfo objects
 *
 * We normalize these into a consistent format.
 */
function extractProducts(data) {
  const products = [];

  // Try to find products in common locations
  const productSources = [
    data?.products,
    data?.productList,
    data?.product ? [data.product] : null,
    data?.productInfo ? [data.productInfo] : null
  ];

  for (const source of productSources) {
    if (Array.isArray(source)) {
      for (const p of source) {
        const product = extractProductDetails(p);
        if (product) {
          products.push(product);
        }
      }
    }
  }

  // Log for debugging if we have data but couldn't extract products
  if (DEBUG_RAW_EVENTS && products.length === 0 && data) {
    console.log('Shopping event structure (for debugging):', JSON.stringify(data, null, 2).slice(0, 500));
  }

  return products;
}

/**
 * Extract normalized product details from a product object.
 */
function extractProductDetails(p) {
  if (!p) return null;

  // Try various field name conventions
  const productId = (
    p.productId ||
    p.product_id ||
    p.id ||
    p.productInfo?.productId ||
    p.productInfo?.id
  )?.toString();

  if (!productId) return null;

  return {
    tiktokProductId: productId,
    title: p.title || p.name || p.productName || p.productInfo?.title || null,
    price: extractPrice(p),
    imageUrl: p.imageUrl || p.image || p.coverUrl || p.productInfo?.imageUrl || null,
    sellerId: (p.sellerId || p.seller_id)?.toString() || null
  };
}

/**
 * Capture a video thumbnail from a stream URL (HLS, FLV, or RTMP).
 * Returns base64-encoded JPEG image data.
 */
async function captureVideoThumbnail(streamUrl, uniqueId) {
  const tmpFile = path.join(os.tmpdir(), `thumb_${uniqueId}_${Date.now()}.jpg`);

  return new Promise((resolve, reject) => {
    // Use a shorter timeout and skip seeking for FLV/RTMP streams
    const isHls = streamUrl.includes('.m3u8') || streamUrl.includes('hls');

    console.log(`[${uniqueId}] FFmpeg capturing from ${isHls ? 'HLS' : 'FLV/RTMP'} stream...`);

    const command = ffmpeg(streamUrl)
      .inputOptions([
        '-y',                    // Overwrite output
        '-t', '10',              // Limit input duration to 10 seconds
      ])
      .frames(1)
      .outputOptions([
        '-vf', 'scale=-2:320',   // Scale to 320px height
        '-q:v', '2'              // JPEG quality
      ])
      .output(tmpFile);

    // For HLS, skip ahead a few seconds to avoid black frames
    if (isHls) {
      command.setStartTime(3);
    }

    command
      .on('end', () => {
        try {
          const buffer = fs.readFileSync(tmpFile);
          const base64 = buffer.toString('base64');
          fs.unlinkSync(tmpFile);
          resolve(base64);
        } catch (err) {
          reject(err);
        }
      })
      .on('error', (err, stdout, stderr) => {
        console.error(`[${uniqueId}] FFmpeg stderr:`, stderr?.substring(0, 500));
        reject(err);
      })
      .run();
  });
}

/**
 * Extract price in cents from various price formats.
 */
function extractPrice(p) {
  // Try to find price in various locations and formats
  const priceValue = (
    p.price ||
    p.priceInfo?.price ||
    p.salePrice ||
    p.originalPrice
  );

  if (priceValue == null) return null;

  // If already a number, assume it might be in cents or dollars
  if (typeof priceValue === 'number') {
    // If less than 1000, probably dollars, convert to cents
    return priceValue < 1000 ? Math.round(priceValue * 100) : priceValue;
  }

  // If string, try to parse
  if (typeof priceValue === 'string') {
    const cleaned = priceValue.replace(/[^0-9.]/g, '');
    const parsed = parseFloat(cleaned);
    if (!isNaN(parsed)) {
      return Math.round(parsed * 100);
    }
  }

  return null;
}

/**
 * Connect to a TikTok Live stream
 */
async function connectToStream(uniqueId) {
  if (connections.has(uniqueId)) {
    return { success: false, error: 'Already connected to this stream' };
  }

  console.log(`[${uniqueId}] Connecting...`);

  try {
    const connection = new WebcastPushConnection(uniqueId, {
      processInitialData: true,
      enableExtendedGiftInfo: true,
      enableWebsocketUpgrade: true,
      requestPollingIntervalMs: 2000
    });

    // Set up event handlers
    connection.on('connected', (state) => {
      console.log(`[${uniqueId}] Connected! Room ID: ${state.roomId}`);

      // Debug: log roomInfo structure to understand what TikTok returns
      const streamUrl = state.roomInfo?.stream_url;
      console.log(`[${uniqueId}] roomInfo keys:`, Object.keys(state.roomInfo || {}));

      // Helper to extract URL from field (handles both string and object/map formats)
      const extractUrl = (field) => {
        if (!field) return null;
        if (typeof field === 'string' && field.length > 0) return field;
        if (typeof field === 'object') {
          const values = Object.values(field);
          return values.length > 0 ? values[0] : null;
        }
        return null;
      };

      if (streamUrl) {
        console.log(`[${uniqueId}] stream_url keys:`, Object.keys(streamUrl));
        console.log(`[${uniqueId}] hls_pull_url type:`, typeof streamUrl.hls_pull_url);
        console.log(`[${uniqueId}] flv_pull_url type:`, typeof streamUrl.flv_pull_url);
      }


      // Try multiple stream URL sources for thumbnail capture
      // Priority: HLS string > HLS map > FLV string > FLV map
      const hlsUrl = extractUrl(streamUrl?.hls_pull_url) ||
                     extractUrl(streamUrl?.hls_pull_url_map) ||
                     extractUrl(streamUrl?.flv_pull_url) ||
                     extractUrl(streamUrl?.rtmp_pull_url);

      console.log(`[${uniqueId}] Selected stream URL:`, hlsUrl ? hlsUrl.substring(0, 80) + '...' : 'NONE');

      // Broadcast connected event immediately (don't block on thumbnail)
      broadcastEvent({
        type: 'connected',
        uniqueId,
        roomId: state.roomId,
        roomInfo: state.roomInfo
      });

      // Capture thumbnail asynchronously, send separate event when done
      if (hlsUrl) {
        console.log(`[${uniqueId}] Stream URL found: ${hlsUrl.substring(0, 80)}...`);
        console.log(`[${uniqueId}] Capturing video thumbnail...`);
        captureVideoThumbnail(hlsUrl, uniqueId)
          .then((thumbnailBase64) => {
            console.log(`[${uniqueId}] Thumbnail captured (${thumbnailBase64.length} chars base64)`);
            broadcastEvent({
              type: 'thumbnail',
              uniqueId,
              thumbnailBase64,
              contentType: 'image/jpeg'
            });
          })
          .catch((err) => {
            console.error(`[${uniqueId}] Thumbnail capture failed:`, err.message);
          });
      } else {
        console.log(`[${uniqueId}] No stream URL available for thumbnail capture`);
      }
    });

    connection.on('disconnected', () => {
      console.log(`[${uniqueId}] Disconnected`);
      connections.delete(uniqueId);
      broadcastEvent({
        type: 'disconnected',
        uniqueId
      });
    });

    connection.on('error', (err) => {
      console.error(`[${uniqueId}] Error:`, err.message);
      broadcastEvent({
        type: 'error',
        uniqueId,
        error: err.message
      });
    });

    connection.on('chat', (data) => {
      broadcastEvent({
        type: 'chat',
        uniqueId,
        data: {
          msgId: data.msgId,
          userId: data.userId,
          uniqueId: data.uniqueId,
          nickname: data.nickname,
          comment: data.comment,
          createTime: data.createTime
        }
      });
    });

    connection.on('gift', (data) => {
      broadcastEvent({
        type: 'gift',
        uniqueId,
        data: {
          userId: data.userId,
          uniqueId: data.uniqueId,
          nickname: data.nickname,
          giftId: data.giftId,
          giftName: data.giftName,
          diamondCount: data.diamondCount,
          repeatCount: data.repeatCount,
          repeatEnd: data.repeatEnd,
          createTime: data.createTime
        }
      });
    });

    connection.on('like', (data) => {
      broadcastEvent({
        type: 'like',
        uniqueId,
        data: {
          userId: data.userId,
          uniqueId: data.uniqueId,
          nickname: data.nickname,
          likeCount: data.likeCount,
          totalLikeCount: data.totalLikeCount
        }
      });
    });

    connection.on('member', (data) => {
      broadcastEvent({
        type: 'member',
        uniqueId,
        data: {
          userId: data.userId,
          uniqueId: data.uniqueId,
          nickname: data.nickname,
          actionId: data.actionId
        }
      });
    });

    connection.on('roomUser', (data) => {
      broadcastEvent({
        type: 'roomUser',
        uniqueId,
        data: {
          viewerCount: data.viewerCount
        }
      });
    });

    connection.on('social', (data) => {
      broadcastEvent({
        type: 'social',
        uniqueId,
        data: {
          userId: data.userId,
          uniqueId: data.uniqueId,
          nickname: data.nickname,
          displayType: data.displayType,
          label: data.label
        }
      });
    });

    connection.on('streamEnd', (data) => {
      console.log(`[${uniqueId}] Stream ended`);
      connections.delete(uniqueId);
      broadcastEvent({
        type: 'streamEnd',
        uniqueId,
        data
      });
    });

    // Shopping/Product events
    connection.on('oecLiveShopping', (data) => {
      console.log(`[${uniqueId}] Shopping event received`);

      // Extract product information from the shopping event
      const products = extractProducts(data);

      broadcastEvent({
        type: 'shopping',
        uniqueId,
        data: {
          products: products,
          raw: data
        }
      });
    });

    connection.on('liveIntro', (data) => {
      broadcastEvent({
        type: 'liveIntro',
        uniqueId,
        data: {
          id: data.id,
          description: data.description
        }
      });
    });

    connection.on('envelope', (data) => {
      broadcastEvent({
        type: 'envelope',
        uniqueId,
        data: {
          coins: data.coins,
          canOpen: data.canOpen,
          timestamp: data.timestamp
        }
      });
    });

    // Raw data handler for shopping messages and debug logging
    connection.on('rawData', (messageTypeName, binary) => {
      // Debug mode: log all message types
      if (DEBUG_RAW_EVENTS) {
        console.log(`[${uniqueId}] Raw message type: ${messageTypeName}`);
      }

      // Forward shopping-related messages
      if (SHOPPING_MESSAGE_TYPES.includes(messageTypeName)) {
        console.log(`[${uniqueId}] Raw shopping message: ${messageTypeName}`);
        broadcastEvent({
          type: 'rawShopping',
          uniqueId,
          data: {
            messageType: messageTypeName,
            payload: Buffer.from(binary).toString('base64'),
            timestamp: Date.now()
          }
        });
      }
    });

    // Connect
    const state = await connection.connect();
    connections.set(uniqueId, connection);
    stats.totalConnections++;

    return {
      success: true,
      roomId: state.roomId,
      viewerCount: state.roomInfo?.viewerCount || 0
    };

  } catch (error) {
    console.error(`[${uniqueId}] Connection failed:`, error.message);
    return { success: false, error: error.message };
  }
}

/**
 * Disconnect from a TikTok Live stream
 */
function disconnectFromStream(uniqueId) {
  const connection = connections.get(uniqueId);
  if (!connection) {
    return { success: false, error: 'Not connected to this stream' };
  }

  connection.disconnect();
  connections.delete(uniqueId);
  console.log(`[${uniqueId}] Disconnected by request`);

  return { success: true };
}

/**
 * HTTP request handler
 */
async function handleRequest(req, res) {
  const url = new URL(req.url, `http://${req.headers.host}`);

  // CORS headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Health check
  if (url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      status: 'ok',
      uptime: Math.floor((Date.now() - stats.startTime) / 1000),
      connections: connections.size,
      wsClients: wsClients.size
    }));
    return;
  }

  // Status - list active connections
  if (url.pathname === '/status' && req.method === 'GET') {
    const activeConnections = Array.from(connections.keys()).map(uniqueId => ({
      uniqueId,
      connected: true
    }));

    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      connections: activeConnections,
      stats: {
        uptime: Math.floor((Date.now() - stats.startTime) / 1000),
        totalConnections: stats.totalConnections,
        totalEvents: stats.totalEvents,
        wsClients: wsClients.size
      }
    }));
    return;
  }

  // Connect to a stream
  if (url.pathname === '/connect' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
      try {
        const { uniqueId } = JSON.parse(body);
        if (!uniqueId) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Missing uniqueId' }));
          return;
        }

        const result = await connectToStream(uniqueId);
        res.writeHead(result.success ? 200 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
    return;
  }

  // Disconnect from a stream
  if (url.pathname === '/disconnect' && req.method === 'POST') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', () => {
      try {
        const { uniqueId } = JSON.parse(body);
        if (!uniqueId) {
          res.writeHead(400, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: 'Missing uniqueId' }));
          return;
        }

        const result = disconnectFromStream(uniqueId);
        res.writeHead(result.success ? 200 : 400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(result));
      } catch (error) {
        res.writeHead(400, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Invalid JSON' }));
      }
    });
    return;
  }

  // 404 for unknown routes
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'Not found' }));
}

// Create HTTP server
const server = http.createServer(handleRequest);

// Create WebSocket server for event streaming
const wss = new WebSocketServer({ server, path: '/events' });

wss.on('connection', (ws) => {
  console.log('WebSocket client connected');
  wsClients.add(ws);

  ws.on('close', () => {
    console.log('WebSocket client disconnected');
    wsClients.delete(ws);
  });

  ws.on('error', (err) => {
    console.error('WebSocket error:', err.message);
    wsClients.delete(ws);
  });

  // Send current status on connect
  ws.send(JSON.stringify({
    type: 'status',
    connections: Array.from(connections.keys())
  }));
});

// Graceful shutdown
async function shutdown(signal) {
  console.log(`\nReceived ${signal}, shutting down...`);

  // Close all TikTok connections
  for (const [uniqueId, connection] of connections) {
    console.log(`Disconnecting from ${uniqueId}...`);
    connection.disconnect();
  }
  connections.clear();

  // Close WebSocket clients
  for (const client of wsClients) {
    client.close();
  }
  wsClients.clear();

  // Close server
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));

// Start server
server.listen(PORT, HOST, () => {
  console.log(`TikTok Bridge running on http://${HOST}:${PORT}`);
  console.log('');
  console.log('HTTP Endpoints:');
  console.log('  GET  /health      - Health check');
  console.log('  GET  /status      - List active connections');
  console.log('  POST /connect     - Connect to stream { uniqueId: "username" }');
  console.log('  POST /disconnect  - Disconnect from stream { uniqueId: "username" }');
  console.log('');
  console.log('WebSocket:');
  console.log('  WS /events        - Real-time event stream');
});
