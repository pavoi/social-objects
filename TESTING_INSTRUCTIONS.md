# Voice Control - Testing Instructions

## Week 1 Implementation - Ready to Test

All Week 1 deliverables are complete. The Whisper Web Worker is bundled and ready for testing.

## Quick Start

### 1. Start the Development Server

```bash
cd /Users/billy/Dropbox/Clients/Pavoi/app/code
mix phx.server
```

### 2. Test the Worker

The test hook is already registered and ready to use. You have two options:

#### Option A: Add Test Hook to Existing Page

Add this to any LiveView template (e.g., the home page or producer view):

```heex
<!-- Add this anywhere in your template -->
<div id="whisper-test" phx-hook="WhisperWorkerTest" style="margin: 20px; padding: 20px; border: 2px solid #ccc; border-radius: 8px; background: #f9f9f9;">
  <h3>Whisper Worker Test</h3>
  <p>Check browser console for detailed logs.</p>
  <div id="test-results" style="margin-top: 16px;"></div>
</div>
```

#### Option B: Check Browser Console

Once the hook is mounted, you'll see automatic tests in the console:

```
[Whisper Test] Hook mounted, testing worker...
[Whisper Test] Creating worker...
[Whisper Test] ✓ Worker created successfully (module worker pattern)
[Whisper Worker] Worker initialized
[Whisper Test] Received: pong
[Whisper Test] ✓ Worker responds to ping
[Whisper Test] Detected device: webgpu (or wasm)
[Whisper Worker] Loading model: Xenova/whisper-tiny.en on device: webgpu
[Whisper Test] Model loading: 0% - Initializing model...
[Whisper Test] Model loading: 15% - Downloading onnx/decoder_model_merged_quantized.onnx...
[Whisper Test] Model loading: 45% - Downloading onnx/encoder_model_quantized.onnx...
[Whisper Test] Model loading: 100% - Model ready
[Whisper Test] ✓ Model loaded successfully!
[Whisper Test] ✓ Using webgpu
[Whisper Test] ✓ Transformers.js loaded from local bundle
[Whisper Test] ✓ All tests passed! Worker is functional.
```

### 3. Expected Behavior

**First Load (Initial Model Download):**
- Model downloads ~40 MB from HuggingFace
- Progress updates every few seconds
- Takes 10-30 seconds depending on connection
- Model cached in IndexedDB after download

**Subsequent Loads:**
- Model loads from IndexedDB cache
- Near-instant loading (1-2 seconds)
- No network requests needed

**Device Detection:**
- **WebGPU (Optimal):** Chrome 113+, Firefox 141+, Safari 26+
  - Console will show: `Using webgpu`
  - Model runs on GPU (fast inference)

- **WASM (Fallback):** Older browsers or no GPU
  - Console will show: `Using wasm`
  - Model runs on CPU (slower but works everywhere)

## What's Bundled

### Main Application Bundle
- **File:** `priv/static/assets/js/app.js`
- **Size:** 406 KB (89 KB gzipped)
- **Impact:** +31 KB gzipped vs baseline
- **Contains:** Core app + voice control infrastructure

### Worker Bundle (On-Demand)
- **File:** `priv/static/assets/js/workers/whisper_worker.js`
- **Size:** 1.9 MB (329 KB gzipped)
- **Contains:** Transformers.js + ONNX Runtime + worker logic
- **Loading:** Only when voice control activates

### Verification

Check bundle files exist:
```bash
ls -lh priv/static/assets/js/app.js
ls -lh priv/static/assets/js/workers/whisper_worker.js
```

Expected output:
```
-rw-r--r-- 1 user staff  406K Nov 19 15:27 priv/static/assets/js/app.js
-rw-r--r-- 1 user staff  1.9M Nov 19 15:27 priv/static/assets/js/workers/whisper_worker.js
```

## Troubleshooting

### Error: "Cannot use 'import.meta' outside a module"
**Solution:** Already fixed! Script tag has `type="module"` in root.html.heex

### Error: "Failed to load worker"
**Check:**
1. `mix assets.build` completed successfully
2. `priv/static/assets/js/workers/whisper_worker.js` exists
3. Browser console for specific error message

### Model Download Fails
**Causes:**
- No internet connection (first load only)
- HuggingFace servers unreachable
- Firewall/proxy blocking

**Solution:**
- Ensure internet connection for first load
- Model will be cached for offline use after first download

### WebGPU Not Detected (Using WASM Instead)
**This is normal if:**
- Browser doesn't support WebGPU (Chrome <113, Firefox <141, Safari <26)
- No GPU available
- WebGPU disabled in browser flags

**Performance:**
- WASM is slower but fully functional
- Still acceptable for voice control use case
- Transcription takes 2-5 seconds vs 500ms-2s on WebGPU

## Test Checklist

- [ ] Dev server starts without errors
- [ ] Browser loads page without console errors
- [ ] Test hook mounts and runs automatically
- [ ] Worker loads successfully (console shows "Worker initialized")
- [ ] Ping/pong communication works
- [ ] Device detection identifies WebGPU or WASM
- [ ] Model loading begins (progress updates appear)
- [ ] Model downloads successfully (first time)
- [ ] Model loads from cache (subsequent times)
- [ ] "All tests passed!" message appears
- [ ] Test results display in UI (if added to template)

## Week 1 Complete ✅

Once all tests pass, Week 1 is verified complete! You can proceed to:

### Week 2: Core Voice Control Hook
- Create `assets/js/hooks/voice_control.js`
- Integrate VAD for speech detection
- Build audio processing pipeline
- Implement number extraction
- Wire up LiveView events

See `VOICE_CONTROL_PLAN.md` for detailed Week 2 tasks.

## File Reference

**Documentation:**
- `VOICE_CONTROL_PLAN.md` - Complete 4-week roadmap
- `WEEK1_PROGRESS.md` - Week 1 detailed progress report
- `TESTING_INSTRUCTIONS.md` - This file

**Implementation:**
- `assets/js/workers/whisper_worker.js` - Main worker (1.9 MB bundled)
- `assets/js/hooks/whisper_worker_test.js` - Test hook
- `config/config.exs` - esbuild configuration (ESM + splitting)
- `lib/pavoi_web/components/layouts/root.html.heex` - Module script tag

**Dependencies:**
- `package.json` - Voice control dependencies

## Support

If you encounter issues:
1. Check browser console for error messages
2. Verify all files were created/modified correctly
3. Ensure `mix assets.build` completes without errors
4. Test in latest Chrome/Firefox/Safari for best WebGPU support

---

**Status:** Ready for testing! 🎉
**Next:** Verify all tests pass, then proceed to Week 2
