# Voice Control Implementation Plan

**Project:** Pavoi - Voice-Activated Product Switching
**Created:** 2025-11-19
**Status:** Week 1 Complete ✅ - Week 2 In Progress
**Last Updated:** 2025-11-19

## Executive Summary

Implement voice control for the Producer view to enable hands-free product navigation during live streaming sessions. Users will speak product numbers (e.g., "twenty three") to automatically switch to that product, using 100% local speech recognition that runs reliably for 4+ hour sessions.

**Key Decisions:**
- ✅ **Approach:** Whisper (local AI model) + Silero VAD
- ✅ **Scope:** Producer view only (numbers-only initial command set)
- ✅ **UI:** Fixed top-right corner panel
- ✅ **Privacy:** 100% local processing; no cloud/CDN runtime dependencies
- ✅ **Timeline:** 3-4 weeks (with reduced initial scope: CPU/WASM path + Chrome first)

---

## Table of Contents

1. [Current System Analysis](#current-system-analysis)
2. [Technical Research](#technical-research)
3. [Recommended Architecture](#recommended-architecture)
4. [Implementation Roadmap](#implementation-roadmap)
5. [Code Examples](#code-examples)
6. [Testing Strategy](#testing-strategy)
7. [Risks & Mitigations](#risks--mitigations)

---

## Current System Analysis

### Producer View Architecture

**File:** `lib/pavoi_web/live/session_producer_live.ex`

The Producer view is a Phoenix LiveView that provides:
- Real-time product navigation with PubSub synchronization
- Keyboard shortcuts (number keys, arrows, space, enter)
- Product grid with thumbnails and positions
- Host message composition
- Split-screen and fullscreen modes

**Product Navigation Flow:**
```
User Input → LiveView Event → Sessions.jump_to_product(session_id, position) →
Database Update → PubSub Broadcast → UI Updates (Producer + Host)
```

**Key Event Handler (Lines 79-96):**
```elixir
def handle_event("jump_to_product", %{"position" => position}, socket) do
  session_id = socket.assigns.session.id
  Sessions.jump_to_product(session_id, String.to_integer(position))
  {:noreply, socket}
end
```

**Important:** Voice control will reuse this exact event handler - no server-side changes needed!

### Current Keyboard Navigation

**File:** `assets/js/hooks/session_host_keyboard.js`

- Number keys (0-9) build a buffer for multi-digit entry
- 500ms debounce for double-digit numbers
- Enter key triggers immediate jump
- Escape cancels pending jump
- Arrow keys for sequential navigation
- Space bar for next product

**Voice control will complement, not replace, keyboard navigation.**

### Product Data Model

**SessionProduct** (1-based sequential positions):
- Links products to sessions with `position` field (integer)
- Unique constraint: `[session_id, position]`
- Supports 1-999+ products per session

**Validation needed:**
- Ensure recognized number is between 1 and `total_products`
- Handle invalid/out-of-range numbers gracefully

---

## Technical Research

### Evaluated Solutions

| Technology | Latency | Accuracy | Privacy | 4hr Sessions | Complexity | Recommendation |
|------------|---------|----------|---------|--------------|------------|----------------|
| **Web Speech API** | <100ms | Good | ❌ Cloud | ⚠️ Unreliable | Low | ❌ Not suitable |
| **Whisper + Transformers.js** | 500ms-2s | Excellent | ✅ Local | ✅ Excellent | High | ✅ **SELECTED** |
| **Vosk** | ~300ms | Adequate | ✅ Local | Good | Medium | Alternative |
| **Picovoice** | <200ms | Good | ✅ Local | Excellent | Medium | Commercial option |

### Selected Technology Stack

#### 1. Whisper (Speech Recognition)

**Model:** OpenAI Whisper Tiny (English)
- **Size:** 40MB (cached locally after first load)
- **Accuracy:** State-of-the-art for speech recognition
- **Speed:** 500ms-2s per segment (acceptable with VAD)
- **Privacy:** 100% local processing via ONNX Runtime
- **Offline:** Works completely offline after initial model download

**Why Whisper?**
- Robust for 4+ hour sessions (no timeouts, no quotas)
- Excellent number recognition ("twenty three" → 23)
- Handles accents and background noise well
- Future-proof: can add more commands beyond numbers
- Free and open source (MIT license)

**Runtime:** ONNX Runtime Web
- WebGPU acceleration (Chrome 113+, Firefox 141+, Safari 26+)
- Automatic CPU fallback for unsupported browsers
- Runs in Web Worker (non-blocking)

#### 2. Silero VAD (Voice Activity Detection)

**Library:** `@ricky0123/vad-web`
- **Purpose:** Detect when user is speaking vs silence
- **Benefit:** Reduces processing by 80%+ (only process speech segments)
- **Size:** ~1MB model
- **Accuracy:** Enterprise-grade, minimal false positives
- **Critical for 4+ hours:** Prevents continuous audio processing

**How VAD helps:**
```
Without VAD: Process every second = 14,400 inferences per 4hr session
With VAD: Process only speech = ~500-1000 inferences per 4hr session
```

#### 3. Number Extraction

**Library:** `words-to-numbers`
- Converts spoken numbers to integers
- Handles: "one" → 1, "twenty three" → 23, "one hundred five" → 105
- Fallback: Regex extraction for digit patterns

**Edge Cases:**
- "product twenty three" → 23
- "go to number five" → 5
- "show me twelve" → 12
- "23" (already a digit) → 23

**Hosting & Packaging Decisions**
- No remote CDNs; all JS/WASM/ONNX assets are bundled and served locally via the Phoenix asset pipeline with hashed filenames.
- Web Worker loaded with a generated URL (e.g., `new Worker(new URL('../workers/whisper_worker.js', import.meta.url), { type: 'module' })`) to align with esbuild output.
- Whisper model weights hosted with static assets; initial download cached (HTTP + IndexedDB) after a successful local fetch. Provide a cache-bust/versioning strategy.
- CPU/WASM is the baseline; WebGPU is opportunistic when detected.

---

## Recommended Architecture

### System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│ Producer View (Phoenix LiveView)                                │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Voice Control UI (Fixed Top-Right)                      │   │
│  │ ┌─────────┐ ┌──────────────┐ ┌──────────────────────┐ │   │
│  │ │ Start/  │ │ Mic Select   │ │ Status: Listening... │ │   │
│  │ │ Stop    │ │ (Dropdown)   │ │ Transcript: "23"     │ │   │
│  │ └─────────┘ └──────────────┘ └──────────────────────┘ │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ VoiceControl Hook (JavaScript)                          │   │
│  └─────────────────────────────────────────────────────────┘   │
└───────────────────────┬───────────────────────────────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ Microphone Input              │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ VAD (@ricky0123/vad-web)      │
        │ - Detects speech vs silence   │
        │ - Segments audio into chunks  │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ Web Worker                    │
        │ - Loads Whisper model (40MB)  │
        │ - Runs inference (WebGPU)     │
        │ - Returns transcript          │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ Number Extraction             │
        │ - words-to-numbers library    │
        │ - Regex fallback              │
        │ - Validation (1-999+)         │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ LiveView Event                │
        │ pushEvent("jump_to_product",  │
        │   {position: 23})             │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ Existing Event Handler        │
        │ Sessions.jump_to_product()    │
        │ (NO CHANGES NEEDED)           │
        └───────────────┬───────────────┘
                        │
                        ▼
        ┌───────────────────────────────┐
        │ PubSub Broadcast              │
        │ - Updates Producer view       │
        │ - Updates Host view           │
        └───────────────────────────────┘
```

### Key Components

#### 1. VoiceControl LiveView Hook
**File:** `assets/js/hooks/voice_control.js`

Responsibilities:
- Initialize VAD and Whisper model (single-flight guarded load)
- Manage microphone access and device selection (permission-aware)
- Handle start/stop controls
- Process audio segments through Whisper with bounded queue/back-pressure
- Extract numbers from transcripts
- Push events to LiveView
- Manage UI state and visual feedback

#### 2. Web Worker
**File:** `assets/js/workers/whisper_worker.js`

Responsibilities:
- Load bundled Transformers.js and Whisper model (no CDN)
- Cache model in IndexedDB after local download
- Run inference on audio chunks
- Return transcripts to main thread
- Handle WebGPU/CPU selection with CPU as baseline

#### 3. UI Components
**Location:** Integrated into `session_producer_live.html.heex`

Components:
- Start/Stop button with active state
- Microphone selection dropdown
- Status indicator (ready/listening/processing/success/error)
- Live transcript display
- Model loading progress bar

---

## Implementation Roadmap

### Week 1: Setup & Infrastructure ✅ COMPLETE

**Status:** Completed 2025-11-19 | All tests passed with WebGPU support

**Completed Tasks:**
1. ✅ **Dependencies installed** (90 packages, 0 vulnerabilities)
   - `@huggingface/transformers@^3.2.0`
   - `@ricky0123/vad-web@^0.0.19`
   - `onnxruntime-web@^1.20.0`
   - `words-to-numbers@^1.5.1`

2. ✅ **Whisper Web Worker** (`assets/js/workers/whisper_worker.js`)
   - Transformers.js bundled locally (no CDN)
   - WebGPU detection with CPU/WASM fallback (tested: WebGPU working!)
   - Progress reporting for model loading
   - Message passing interface (load/transcribe/ping)
   - IndexedDB caching via Transformers.js

3. ✅ **Bundle Configuration** (`config/config.exs`)
   - ESM format with code splitting enabled
   - Worker as separate entry point
   - Main bundle: 406 KB (89 KB gzipped)
   - Worker bundle: 1.9 MB (329 KB gzipped)

4. ✅ **Test Infrastructure** (`assets/js/hooks/whisper_worker_test.js`)
   - Live browser test: All tests passed
   - Device detection: WebGPU confirmed working
   - Model loading: Successful (cached for future use)

**Test Results:**
```
✓ Worker communication works
✓ Model ready on webgpu
✓ Using webgpu
✓ Transformers.js loaded from local bundle
✓ All tests passed! Worker is functional.
```

**Key Achievements:**
- Zero runtime CDN dependencies (CSP compliant)
- WebGPU acceleration verified and working
- Excellent compression: 83% on worker (1.9 MB → 329 KB gzipped)
- On-demand worker loading (users who don't use voice control pay zero cost)

---

### Week 2: Core Voice Control Hook

**Tasks:**
1. Create `assets/js/hooks/voice_control.js`:
- Phoenix LiveView hook boilerplate
- VAD integration
- Audio chunking (5-10s segments)
- Queue management for processing with back-pressure (e.g., max 1 in-flight transcript, drop oldest on overflow)

2. Implement VAD integration:
```javascript
const vad = await MicVAD.new({
  deviceId: selectedMicId,
     onSpeechStart: () => updateStatus("listening"),
     onSpeechEnd: (audio) => processAudioChunk(audio)
   });
   ```

3. Build audio processing pipeline:
- Collect audio chunks from VAD
- Send to Web Worker for transcription
- Handle worker responses
- Manage processing queue (FIFO) with bounds and cancellation on stop/restart

4. Implement number extraction:
   ```javascript
   function extractNumber(transcript) {
     // Clean transcript
     const cleaned = transcript.toLowerCase()
       .replace(/^(product|number|item|go to|show)\s+/i, '');

     // Try direct parsing
     const direct = parseInt(cleaned);
     if (!isNaN(direct)) return direct;

     // Try words-to-numbers
     const converted = wordsToNumbers(cleaned);
     if (typeof converted === 'number') return converted;

     // Regex fallback
     const match = transcript.match(/\d+/);
     return match ? parseInt(match[0]) : null;
   }
   ```

5. Wire up LiveView events:
   ```javascript
   if (number >= 1 && number <= totalProducts) {
     this.pushEvent("jump_to_product", {
       position: number.toString()
     });
   }
   ```

**Deliverables:**
- ✅ VoiceControl hook functional
- ✅ VAD detecting speech segments
- ✅ Whisper transcribing audio
- ✅ Numbers extracted correctly
- ✅ Events pushing to LiveView with bounded queue/back-pressure

---

### Week 3: UI Components & Integration

**Tasks:**
1. Build voice control UI panel:
- HTML structure via HEEx in `session_producer_live.html.heex` (avoid large `innerHTML`), keep IDs stable
- Start/Stop toggle button
- Microphone selection dropdown
- Status indicator with animations
- Live transcript display
- Model loading progress bar

2. Implement microphone enumeration:
   ```javascript
   async loadMicrophones() {
     const devices = await navigator.mediaDevices.enumerateDevices();
     const audioInputs = devices.filter(d => d.kind === 'audioinput');
     // Populate dropdown
     // Save selection to localStorage
   }
   ```

3. Add visual feedback:
   - Ready state: green indicator
   - Listening state: pulsing orange animation
   - Processing state: blue with spinner
   - Success state: green flash with number
   - Error state: red with message

4. Integrate into Producer view:
```heex
<!-- session_producer_live.html.heex -->
<div
  id="voice-control"
  phx-hook="VoiceControl"
  data-total-products={length(@products)}
>
</div>
```

5. Add CSS styling:
- File: `assets/css/05-components/voice-control.css`
- Fixed positioning (top-right)
- Responsive design
- Dark mode support
- Animations (pulse, fade, slide)

6. Register hook in `assets/js/app.js`:
```javascript
import VoiceControl from "./hooks/voice_control"

let Hooks = {
  SessionHostKeyboard,
  VoiceControl  // Add this
}
```

**Deliverables:**
- ✅ UI panel rendered and styled within existing tokens
- ✅ Microphone selection working
- ✅ Visual feedback functional
- ✅ Integrated into Producer view
- ✅ CSS animations polished

---

### Week 4: Testing, Optimization & Polish

**Tasks:**
1. Extended session testing:
   - Run 4+ hour continuous sessions
   - Monitor memory usage (Chrome DevTools)
   - Check for memory leaks
   - Verify VAD efficiency
   - Test model persistence

2. Performance optimization:
   - Tune chunk size (trade-off: latency vs accuracy)
   - Optimize worker message passing
   - Reduce audio buffer allocations
   - Test WebGPU vs CPU performance
   - Profile with Chrome Performance tab

3. Number recognition testing:
   - Test 1-999+ range
   - Various accents (US, UK, Australian, etc.)
   - Background noise scenarios
   - Multiple speakers
   - Edge cases ("number twenty three", "go to five")

4. Cross-browser testing:
   - Chrome (WebGPU)
   - Firefox (WebGPU in 141+)
   - Safari (WebGPU in 26+)
   - Edge (WebGPU)
   - Verify CPU fallback in older browsers

5. Error handling:
   - Microphone permission denied
   - Model loading failures
   - Network errors (initial model download)
   - WebGPU not supported
   - Worker crashes
   - Invalid audio input

6. Polish & UX improvements:
   - Keyboard shortcut to toggle (Ctrl+M / Cmd+M)
   - Persist microphone preference (localStorage)
   - Show confidence scores (optional)
   - Transcript history (last 5 commands)
   - Success sound feedback (optional)
   - Tooltips and help text
   - Undo/cancel for last jump (e.g., Escape)

7. Documentation:
   - User guide: How to use voice control
   - Technical docs: Architecture and code structure
   - Troubleshooting guide: Common issues
   - Browser compatibility matrix
   - CSP note: all assets bundled locally; how to pre-download/cache the model

**Deliverables:**
- ✅ Tested for 4+ hours continuously
- ✅ Performance optimized
- ✅ Cross-browser compatible
- ✅ Error handling robust
- ✅ UX polished
- ✅ Documentation complete

---

## Code Examples

### 1. VoiceControl Hook (Complete)

**File:** `assets/js/hooks/voice_control.js`

```javascript
import { MicVAD } from "@ricky0123/vad-web";
import wordsToNumbers from "words-to-numbers";

export default {
  mounted() {
    this.isActive = false;
    this.totalProducts = parseInt(this.el.dataset.totalProducts);
    this.vad = null;
    this.worker = null;
    this.processingQueue = [];

    this.setupWorker();
    this.setupUI();
    this.loadMicrophones();
  },

  setupWorker() {
    this.worker = new Worker(
      new URL('../workers/whisper_worker.js', import.meta.url),
      { type: 'module' }
    );

    this.worker.onmessage = (e) => {
      const { type, data } = e.data;

      switch (type) {
        case 'model_loading':
          this.updateStatus('loading', `Loading model: ${data.progress}%`);
          break;

        case 'model_ready':
          this.updateStatus('ready', 'Model loaded');
          this.modelReady = true;
          break;

        case 'transcript':
          this.handleTranscript(data.text);
          break;

        case 'error':
          this.handleError(data.message);
          break;
      }
    };

    // Load model
    this.worker.postMessage({
      type: 'load_model',
      model: 'Xenova/whisper-tiny.en',
      device: this.detectDevice()
    });
  },

  detectDevice() {
    // Check for WebGPU support
    if ('gpu' in navigator) {
      return 'webgpu';
    }
    return 'wasm'; // CPU fallback
  },

  setupUI() {
    // Markup is rendered via HEEx; just wire up the elements
    this.toggleBtn = this.el.querySelector('#voice-toggle');
    this.micSelect = this.el.querySelector('#mic-select');
    this.statusEl = this.el.querySelector('#voice-status');
    this.transcriptEl = this.el.querySelector('#voice-transcript');

    this.toggleBtn.addEventListener('click', () => this.toggle());

    // Keyboard shortcut: Ctrl/Cmd + M
    document.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'm') {
        e.preventDefault();
        this.toggle();
      }
    });
  },

  async loadMicrophones() {
    try {
      // Must request permission before labels appear on some browsers
      await navigator.mediaDevices.getUserMedia({ audio: true });

      const devices = await navigator.mediaDevices.enumerateDevices();
      const audioInputs = devices.filter(d => d.kind === 'audioinput');

      if (audioInputs.length === 0) {
        this.handleError('No microphones found');
        return;
      }

      audioInputs.forEach((device, index) => {
        const option = document.createElement('option');
        option.value = device.deviceId;
        option.text = device.label || `Microphone ${index + 1}`;
        this.micSelect.appendChild(option);
      });

      // Restore saved preference
      const savedMic = localStorage.getItem('pavoi_voice_mic');
      if (savedMic) {
        this.micSelect.value = savedMic;
      }

      this.micSelect.addEventListener('change', () => {
        localStorage.setItem('pavoi_voice_mic', this.micSelect.value);
        if (this.isActive) {
          this.restart();
        }
      });

    } catch (error) {
      console.error('Failed to enumerate microphones:', error);
      this.handleError('Microphone access denied');
    }
  },

  async toggle() {
    if (this.isActive) {
      this.stop();
    } else {
      await this.start();
    }
  },

  async start() {
    if (!this.modelReady) {
      this.updateStatus('error', 'Model not ready');
      return;
    }

    try {
      // Initialize VAD
      this.vad = await MicVAD.new({
        deviceId: this.micSelect.value || undefined,

        onSpeechStart: () => {
          this.updateStatus('listening', 'Listening...');
        },

        onSpeechEnd: (audio) => {
          this.updateStatus('processing', 'Processing...');
          this.processAudio(audio);
        },

        onVADMisfire: () => {
          console.log('VAD misfire (false positive)');
        }
      });

      await this.vad.start();

      this.isActive = true;
      this.toggleBtn.classList.add('active');
      this.toggleBtn.querySelector('.text').textContent = 'Stop';
      this.updateStatus('ready', 'Ready - say a number');

    } catch (error) {
      console.error('Failed to start voice control:', error);
      this.handleError('Failed to start: ' + error.message);
    }
  },

  stop() {
    if (this.vad) {
      this.vad.pause();
      this.vad = null;
    }

    this.isActive = false;
    this.toggleBtn.classList.remove('active');
    this.toggleBtn.querySelector('.text').textContent = 'Start';
    this.updateStatus('stopped', 'Stopped');
  },

  async restart() {
    this.stop();
    await new Promise(resolve => setTimeout(resolve, 100));
    await this.start();
  },

  processAudio(audioData) {
    // Convert Float32Array to regular array for worker transfer
    const audioArray = Array.from(audioData);

    // Send to worker for transcription
    this.worker.postMessage({
      type: 'transcribe',
      audio: audioArray
    });
  },

  handleTranscript(text) {
    console.log('Transcript:', text);
    this.transcriptEl.textContent = `Heard: "${text}"`;

    const number = this.extractNumber(text);

    if (number !== null && number >= 1 && number <= this.totalProducts) {
      this.updateStatus('success', `Jumping to product ${number}`);

      // Push event to LiveView
      this.pushEvent("jump_to_product", {
        position: number.toString()
      });

      // Reset to ready after 2 seconds
      setTimeout(() => {
        if (this.isActive) {
          this.updateStatus('ready', 'Ready - say a number');
        }
      }, 2000);

    } else {
      const message = number === null
        ? 'No number detected'
        : `Invalid: ${number} (must be 1-${this.totalProducts})`;

      this.updateStatus('error', message);

      setTimeout(() => {
        if (this.isActive) {
          this.updateStatus('ready', 'Ready - say a number');
        }
      }, 2000);
    }
  },

  extractNumber(text) {
    if (!text) return null;

    // Clean transcript - remove common prefixes
    const cleaned = text.toLowerCase()
      .trim()
      .replace(/^(product|number|item|go to|goto|show|display|jump to)\s+/i, '')
      .replace(/\s+/g, ' ');

    // Try direct integer parsing
    const directNumber = parseInt(cleaned);
    if (!isNaN(directNumber) && directNumber > 0) {
      return directNumber;
    }

    // Try words-to-numbers conversion
    const converted = wordsToNumbers(cleaned);
    if (typeof converted === 'number' && converted > 0) {
      return converted;
    }

    // Fallback: find any number in the text
    const match = text.match(/\d+/);
    if (match) {
      const num = parseInt(match[0]);
      if (num > 0) return num;
    }

    return null;
  },

  updateStatus(state, message) {
    const statusDot = this.statusEl.querySelector('.status-dot');
    const statusText = this.statusEl.querySelector('.status-text');

    // Remove all state classes
    this.statusEl.className = 'voice-status';

    // Add new state class
    this.statusEl.classList.add(`status-${state}`);

    statusText.textContent = message;

    // Enable/disable toggle button based on state
    if (state === 'loading') {
      this.toggleBtn.disabled = true;
    } else {
      this.toggleBtn.disabled = false;
    }
  },

  handleError(message) {
    console.error('Voice control error:', message);
    this.updateStatus('error', message);
    this.stop();
  },

  destroyed() {
    this.stop();
    if (this.worker) {
      this.worker.terminate();
    }
  }
}
```

---

### 2. Whisper Web Worker

**File:** `assets/js/workers/whisper_worker.js`

```javascript
// Module worker; bundles via esbuild (no CDN)
import { pipeline } from "@huggingface/transformers";

let transcriber = null;
let modelLoaded = false;

// Listen for messages from main thread
self.onmessage = async (e) => {
  const { type, data } = e.data;

  switch (type) {
    case 'load_model':
      await loadModel(data.model, data.device);
      break;

    case 'transcribe':
      await transcribe(data.audio);
      break;
  }
};

async function loadModel(modelName, device) {
  try {
    // Post progress updates
    self.postMessage({
      type: 'model_loading',
      data: { progress: 0 }
    });

    transcriber = await pipeline(
      'automatic-speech-recognition',
      modelName,
      {
        device: device,
        dtype: device === 'webgpu' ? 'fp16' : 'fp32',
        progress_callback: (progress) => {
          const percent = Math.round((progress.loaded / progress.total) * 100);
          self.postMessage({
            type: 'model_loading',
            data: { progress: percent }
          });
        }
      }
    );

    modelLoaded = true;

    self.postMessage({
      type: 'model_ready',
      data: { device: device }
    });

  } catch (error) {
    self.postMessage({
      type: 'error',
      data: { message: error.message }
    });
  }
}

async function transcribe(audioArray) {
  if (!modelLoaded) {
    self.postMessage({
      type: 'error',
      data: { message: 'Model not loaded' }
    });
    return;
  }

  try {
    // Convert array back to Float32Array
    const audioData = new Float32Array(audioArray);

    // Run inference
    const result = await transcriber(audioData, {
      language: 'english',
      task: 'transcribe'
    });

    self.postMessage({
      type: 'transcript',
      data: { text: result.text }
    });

  } catch (error) {
    self.postMessage({
      type: 'error',
      data: { message: error.message }
    });
  }
}
```

---

### 3. Producer View Integration

**File:** `lib/pavoi_web/live/session_producer_live.html.heex`

```heex
<div class="session-producer-container" phx-hook="SessionProducerKeyboard">

  <!-- Voice Control (NEW) -->
  <div
    id="voice-control"
    phx-hook="VoiceControl"
    data-total-products={length(@products)}
  >
  </div>

  <!-- Existing content -->
  <div class="producer-header">
    <!-- Header content -->
  </div>

  <div class="producer-body">
    <!-- Product grid, etc. -->
  </div>

</div>
```

**No changes needed to event handlers!** Reuses existing `jump_to_product/2`.

---

### 4. CSS Styling

**File:** `assets/css/05-components/voice-control.css`

```css
/* Voice Control Panel */
.voice-control-panel {
  position: fixed;
  top: 20px;
  right: 20px;
  width: 320px;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  box-shadow: 0 4px 12px rgba(0, 0, 0, 0.15);
  z-index: 1000;
  font-family: var(--font-sans);
}

.voice-control-header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  padding: 16px;
  border-bottom: 1px solid var(--border);
}

.voice-control-header h3 {
  margin: 0;
  font-size: 16px;
  font-weight: 600;
  color: var(--text-primary);
}

.voice-toggle-btn {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 8px 16px;
  background: var(--primary);
  color: white;
  border: none;
  border-radius: 6px;
  font-size: 14px;
  font-weight: 500;
  cursor: pointer;
  transition: all 0.2s ease;
}

.voice-toggle-btn:hover:not(:disabled) {
  background: var(--primary-dark);
  transform: translateY(-1px);
}

.voice-toggle-btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.voice-toggle-btn.active {
  background: var(--danger);
}

.voice-toggle-btn.active:hover {
  background: var(--danger-dark);
}

.voice-control-body {
  padding: 16px;
}

/* Microphone Selection */
.mic-selection {
  margin-bottom: 16px;
}

.mic-selection label {
  display: block;
  margin-bottom: 6px;
  font-size: 13px;
  font-weight: 500;
  color: var(--text-secondary);
}

.mic-selection select {
  width: 100%;
  padding: 8px 12px;
  border: 1px solid var(--border);
  border-radius: 6px;
  background: var(--surface);
  color: var(--text-primary);
  font-size: 14px;
  cursor: pointer;
}

/* Status Indicator */
.voice-status {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 12px;
  border-radius: 8px;
  margin-bottom: 12px;
  transition: all 0.3s ease;
}

.status-dot {
  width: 10px;
  height: 10px;
  border-radius: 50%;
  flex-shrink: 0;
}

.status-text {
  font-size: 14px;
  font-weight: 500;
}

/* Status States */
.voice-status.status-loading {
  background: #e3f2fd;
  color: #1565c0;
}

.voice-status.status-loading .status-dot {
  background: #1565c0;
  animation: pulse 1.5s ease-in-out infinite;
}

.voice-status.status-ready {
  background: #e8f5e9;
  color: #2e7d32;
}

.voice-status.status-ready .status-dot {
  background: #2e7d32;
}

.voice-status.status-listening {
  background: #fff3e0;
  color: #e65100;
}

.voice-status.status-listening .status-dot {
  background: #e65100;
  animation: pulse 1s ease-in-out infinite;
}

.voice-status.status-processing {
  background: #e3f2fd;
  color: #1565c0;
}

.voice-status.status-processing .status-dot {
  background: #1565c0;
  animation: spin 1s linear infinite;
}

.voice-status.status-success {
  background: #e8f5e9;
  color: #2e7d32;
}

.voice-status.status-success .status-dot {
  background: #2e7d32;
  animation: bounce 0.5s ease;
}

.voice-status.status-error {
  background: #ffebee;
  color: #c62828;
}

.voice-status.status-error .status-dot {
  background: #c62828;
}

.voice-status.status-stopped {
  background: #f5f5f5;
  color: #757575;
}

.voice-status.status-stopped .status-dot {
  background: #757575;
}

/* Transcript Display */
.voice-transcript {
  padding: 10px;
  background: var(--surface-alt);
  border-radius: 6px;
  font-size: 13px;
  color: var(--text-secondary);
  min-height: 40px;
  font-family: var(--font-mono);
}

/* Animations */
@keyframes pulse {
  0%, 100% {
    opacity: 1;
    transform: scale(1);
  }
  50% {
    opacity: 0.5;
    transform: scale(0.9);
  }
}

@keyframes spin {
  from {
    transform: rotate(0deg);
  }
  to {
    transform: rotate(360deg);
  }
}

@keyframes bounce {
  0%, 100% {
    transform: translateY(0);
  }
  50% {
    transform: translateY(-4px);
  }
}

/* Responsive Design */
@media (max-width: 768px) {
  .voice-control-panel {
    top: 10px;
    right: 10px;
    left: 10px;
    width: auto;
  }
}

/* Dark Mode Support */
@media (prefers-color-scheme: dark) {
  .voice-control-panel {
    box-shadow: 0 4px 12px rgba(0, 0, 0, 0.4);
  }
}
```

---

### 5. Hook Registration

**File:** `assets/js/app.js`

```javascript
// Import voice control hook
import VoiceControl from "./hooks/voice_control"

let Hooks = {
  SessionHostKeyboard,
  SessionProducerKeyboard,
  VoiceControl  // Add this line
}

let liveSocket = new LiveSocket("/live", Socket, {
  hooks: Hooks,
  params: {_csrf_token: csrfToken}
})
```

---

## Testing Strategy

### 1. Unit Testing

**Number Extraction Tests:**
```javascript
describe('extractNumber', () => {
  test('parses direct numbers', () => {
    expect(extractNumber('23')).toBe(23);
    expect(extractNumber('5')).toBe(5);
  });

  test('converts word numbers', () => {
    expect(extractNumber('twenty three')).toBe(23);
    expect(extractNumber('one hundred five')).toBe(105);
  });

  test('handles prefixes', () => {
    expect(extractNumber('product twenty three')).toBe(23);
    expect(extractNumber('go to number five')).toBe(5);
  });

  test('returns null for invalid input', () => {
    expect(extractNumber('hello world')).toBe(null);
    expect(extractNumber('')).toBe(null);
  });
});
```

### 2. Integration Testing

**VAD + Whisper Pipeline:**
- Record sample audio clips (numbers 1-100)
- Process through VAD and Whisper
- Verify correct number extraction
- Measure latency (target: <2s)

**LiveView Integration:**
- LiveView hook tests to assert `pushEvent("jump_to_product")` with valid numbers and rejection of out-of-range inputs.
- Verify hook teardown on LV disconnect/reconnect.
- Phoenix LiveView tests asserting the presence of key DOM IDs for selectors.

**Browser automation (happy/error paths):**
- Permission granted/denied flows.
- Worker failure surfaced in UI.
- Unsupported browser message when WebGPU missing (still usable on CPU).

### 3. Long Session Testing

**4+ Hour Stress Test:**
```javascript
// Monitor memory usage
setInterval(() => {
  if (performance.memory) {
    console.log({
      usedJSHeapSize: performance.memory.usedJSHeapSize / 1048576,
      totalJSHeapSize: performance.memory.totalJSHeapSize / 1048576,
      jsHeapSizeLimit: performance.memory.jsHeapSizeLimit / 1048576
    });
  }
}, 60000); // Every minute
```

**Success Criteria:**
- ✅ No memory leaks over 4 hours
- ✅ Consistent latency (<2s)
- ✅ No degradation in accuracy
- ✅ No browser crashes or freezes

### 4. Cross-Browser Testing

**Test Matrix:**
| Browser | Version | WebGPU | CPU Fallback | VAD | Status |
|---------|---------|--------|--------------|-----|--------|
| Chrome | 113+ | ✅ | ✅ | ✅ | Primary |
| Firefox | 141+ | ✅ | ✅ | ✅ | Supported |
| Safari | 26+ | ✅ | ✅ | ✅ | Supported |
| Edge | 113+ | ✅ | ✅ | ✅ | Supported |
| Chrome | <113 | ❌ | ✅ | ✅ | Degraded |

### 5. Accuracy Testing

**Number Recognition Scenarios:**
- Single digit: "five" → 5
- Double digit: "twenty three" → 23
- Triple digit: "one hundred five" → 105
- With prefix: "product twelve" → 12
- With context: "show me number seven" → 7
- Numeric: "42" → 42

**Accent Testing:**
- US English
- UK English
- Australian English
- Indian English
- Non-native speakers

**Background Noise:**
- Quiet room (target: 95%+ accuracy)
- Office noise (target: 85%+ accuracy)
- Loud music (target: 70%+ accuracy)

---

## Risks & Mitigations

### Risk 1: Model Download Size (40MB)

**Impact:** Slow initial load on poor connections

**Mitigations:**
- Show clear loading progress bar
- Cache model aggressively (IndexedDB + HTTP cache)
- Host model with app static assets (no CDN) and document how to pre-download
- Provide "Download in background" option
- Pre-load during idle time

### Risk 2: Browser Compatibility

**Impact:** WebGPU not available in older browsers

**Mitigations:**
- Automatic CPU fallback (WASM)
- Clear browser requirements in UI
- Graceful degradation messaging
- Feature detection before initialization

### Risk 3: Microphone Permission Denied/Unavailable

**Impact:** Feature unusable

**Mitigations:**
- Clear permission request UI
- Fallback to keyboard navigation
- Instructions for granting permission
- Detect permission state before activation
- Surface “no devices” state when enumeration is empty

### Risk 4: Transcription Errors

**Impact:** Wrong product selected

**Mitigations:**
- Visual confirmation before jump (2s delay)
- Show recognized number in UI
- Allow escape/undo (press Escape key)
- Confidence threshold (reject low-confidence)
- Validation (1 <= n <= total_products)

### Risk 5: Memory Leaks in Long Sessions

**Impact:** Browser slowdown/crash after 4+ hours

**Mitigations:**
- VAD reduces processing by 80%+
- Periodic garbage collection hints
 - Audio buffer cleanup
 - Web Worker isolation
 - Memory monitoring in production

### Risk 6: Background Noise False Positives

**Impact:** Unintended product switches

**Mitigations:**
- VAD filters most background noise
- Require clear number in transcript
 - Confidence scoring
 - Optional push-to-talk mode
 - Adjustable VAD sensitivity

### Risk 7: Build Footprint / CSP Violations

**Impact:** Oversized bundle or blocked assets in production.

**Mitigations:**
- Use module worker with asset-pipeline URLs (no absolute/CDN).
- Keep CPU/WASM baseline; WebGPU opt-in.
- Measure bundle size during Week 1; set budget and strip unused locales/models.

---

## Future Enhancements

### Phase 2: Additional Voice Commands

Beyond numbers, add commands like:
- "next" / "previous" - Sequential navigation
- "first" / "last" - Jump to boundaries
- "pause" / "resume" - Control voice listening
- "repeat" - Re-announce current product
- "help" - Voice command list

### Phase 3: Host View Integration

Enable voice control in Host view:
- Independent microphone selection
- Synchronized state with Producer
- Optional voice feedback (TTS)

### Phase 4: Advanced Features

- Custom wake word ("Hey Pavoi")
- Multi-language support (Spanish, French, etc.)
- Voice macro recording ("quick action 1")
- Voice-to-text for host messages
- Analytics dashboard (most used commands)

---

## Success Metrics

### Technical Metrics
- ✅ Latency: <2s from speech end to product jump
- ✅ Accuracy: >90% for clear speech, >80% with noise
- ✅ Uptime: 4+ hours without restart
- ✅ Memory: <200MB total (model + runtime)
- ✅ Browser Support: Chrome, Firefox, Safari, Edge (113+/141+/26+)

### User Experience Metrics
- ✅ Time to first use: <30s (including model load)
- ✅ Error recovery: <5s from error to ready
- ✅ User satisfaction: >85% positive feedback
- ✅ Feature adoption: >30% of producers use voice control

---

## Appendix

### Dependencies

```json
{
  "dependencies": {
    "@huggingface/transformers": "^3.2.0",
    "@ricky0123/vad-web": "^0.0.19",
    "onnxruntime-web": "^1.20.0",
    "words-to-numbers": "^1.5.1"
  }
}
```

### Resources

**Whisper Documentation:**
- https://huggingface.co/docs/transformers.js
- https://github.com/xenova/transformers.js

**VAD Documentation:**
- https://www.vad.ricky0123.com/
- https://github.com/ricky0123/vad

**ONNX Runtime:**
- https://onnxruntime.ai/docs/tutorials/web/

**Phoenix LiveView Hooks:**
- https://hexdocs.pm/phoenix_live_view/js-interop.html#client-hooks

### Browser Support Matrix

| Feature | Chrome | Firefox | Safari | Edge |
|---------|--------|---------|--------|------|
| WebGPU | 113+ | 141+ | 26+ | 113+ |
| Web Audio API | ✅ All | ✅ All | ✅ All | ✅ All |
| IndexedDB | ✅ All | ✅ All | ✅ All | ✅ All |
| Web Workers | ✅ All | ✅ All | ✅ All | ✅ All |
| MediaDevices API | ✅ All | ✅ All | ✅ All | ✅ All |

### Glossary

- **VAD:** Voice Activity Detection - distinguishes speech from silence
- **Whisper:** OpenAI's state-of-the-art speech recognition model
- **ONNX:** Open Neural Network Exchange - ML model format
- **WebGPU:** Web standard for GPU acceleration
- **WASM:** WebAssembly - efficient bytecode for browsers
- **LiveView:** Phoenix framework for real-time web apps
- **PubSub:** Publish-Subscribe pattern for real-time updates

---

**End of Document**

*Last Updated: 2025-11-19*
*Author: Claude Code*
*Project: Pavoi Voice Control*
