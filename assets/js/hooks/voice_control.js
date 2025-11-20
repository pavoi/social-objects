/**
 * VoiceControl Hook - Voice-activated product navigation for Phoenix LiveView
 *
 * Enables hands-free product switching using local speech recognition.
 * Integrates Whisper (OpenAI's speech-to-text model) with Silero VAD
 * (Voice Activity Detection) for efficient, privacy-first voice control.
 *
 * @module VoiceControl
 * @requires @ricky0123/vad-web - Voice Activity Detection library
 *
 * ## Architecture
 *
 * 1. **VAD Layer** - Detects speech vs silence, segments audio into chunks
 *    - Reduces processing by 80%+ (only processes speech)
 *    - Runs Silero VAD model locally (~1.7MB)
 *
 * 2. **Whisper Worker** - Transcribes audio to text in background thread
 *    - Uses OpenAI Whisper Tiny English model (~40MB, cached)
 *    - WebGPU accelerated (2-4x faster than CPU)
 *    - Automatic CPU/WASM fallback for unsupported browsers
 *
 * 3. **Number Extraction** - Converts spoken numbers to integers
 *    - Handles words: "twenty three" → 23, "five" → 5
 *    - Handles digits: "23" → 23
 *    - Validates range: 1 to totalProducts
 *
 * 4. **LiveView Integration** - Pushes events to trigger product navigation
 *    - Event: "jump_to_product" with {position: "23"}
 *    - Reuses existing event handler (no server changes needed)
 *
 * ## Usage
 *
 * Add to your LiveView template:
 * ```heex
 * <div
 *   id="voice-control"
 *   phx-hook="VoiceControl"
 *   phx-update="ignore"
 *   data-total-products={@total_products}
 * >
 * </div>
 * ```
 *
 * Register in hooks.js:
 * ```javascript
 * import VoiceControl from "./hooks/voice_control"
 * let Hooks = { VoiceControl }
 * ```
 *
 * ## Data Attributes
 *
 * - `data-total-products` (required) - Maximum product number (for validation)
 *
 * ## Keyboard Shortcuts
 *
 * - **Ctrl/Cmd + M** - Toggle voice control on/off
 *
 * ## Privacy & Security
 *
 * - 100% local processing (no cloud/CDN dependencies at runtime)
 * - No audio sent to external servers
 * - Models cached in IndexedDB
 * - Microphone preference saved in localStorage
 *
 * ## Performance
 *
 * - Memory: ~150-200MB (models + runtime)
 * - Latency: 0.5-2s per utterance (WebGPU: 0.5-1s, CPU: 1-2s)
 * - Network: ~42MB first load (cached), 0 bytes thereafter
 *
 * ## Browser Support
 *
 * - Chrome 113+ (WebGPU) - Best performance
 * - Firefox 141+ (WebGPU)
 * - Safari 26+ (WebGPU)
 * - All browsers support CPU fallback (slower)
 *
 * @see VOICE_CONTROL_PLAN.md - Complete implementation documentation
 */

import { MicVAD } from "@ricky0123/vad-web";

/**
 * Phoenix LiveView hook for voice-activated product navigation
 * @type {Object}
 */
export default {
  mounted() {
    console.log('[VoiceControl] Hook mounted');

    // State
    this.isActive = false;
    this.totalProducts = parseInt(this.el.dataset.totalProducts);
    this.vad = null;
    this.worker = null;
    this.modelReady = false;
    this.isProcessing = false; // Back-pressure: prevent overlapping transcriptions
    this.isCollapsed = localStorage.getItem('pavoi_voice_collapsed') === 'true';

    // Waveform visualization
    this.audioContext = null;
    this.analyser = null;
    this.waveformAnimationId = null;

    // Initialize components
    this.setupWorker();
    this.setupUI();
    this.loadMicrophones();
  },

  /**
   * Initialize the Whisper Web Worker
   */
  setupWorker() {
    console.log('[VoiceControl] Setting up Whisper worker...');

    // Use the static path to the built worker file
    // The worker is built to /assets/js/workers/whisper_worker.js
    this.worker = new Worker(
      '/assets/js/workers/whisper_worker.js',
      { type: 'module' }
    );

    this.worker.onmessage = (e) => {
      const { type, data } = e.data;

      switch (type) {
        case 'model_loading':
          this.updateStatus('loading', `Loading model: ${data.progress}%`);
          break;

        case 'model_ready':
          console.log('[VoiceControl] Model ready on device:', data.device);
          this.updateStatus('ready', `Ready (${data.device})`);
          this.modelReady = true;
          break;

        case 'transcript':
          this.handleTranscript(data.text);
          this.isProcessing = false;
          break;

        case 'error':
          console.error('[VoiceControl] Worker error:', data.message);
          this.handleError(data.message);
          this.isProcessing = false;
          break;
      }
    };

    this.worker.onerror = (error) => {
      console.error('[VoiceControl] Worker crashed:', error);
      this.handleError('Worker failed to load');
    };

    // Load model with device detection
    this.worker.postMessage({
      type: 'load_model',
      data: {
        model: 'Xenova/whisper-tiny.en',
        device: this.detectDevice()
      }
    });
  },

  /**
   * Detect WebGPU support
   */
  detectDevice() {
    if ('gpu' in navigator) {
      console.log('[VoiceControl] WebGPU detected');
      return 'webgpu';
    }
    console.log('[VoiceControl] WebGPU not available, using WASM');
    return 'wasm';
  },

  /**
   * Setup UI elements and event listeners
   */
  setupUI() {
    console.log('[VoiceControl] Setting up UI...');

    // Create UI structure
    this.el.innerHTML = `
      <div class="voice-control-panel${this.isCollapsed ? ' collapsed' : ''}">
        <div class="voice-control-header">
          <div class="voice-control-title">
            <button id="voice-minimize" class="voice-minimize-btn" title="Minimize">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                <polyline points="6 9 12 15 18 9"></polyline>
              </svg>
            </button>
            <h3>Voice Control</h3>
          </div>
          <div class="voice-control-actions">
            <button id="voice-toggle" class="voice-toggle-btn" disabled>
              <span class="icon">🎤</span>
              <span class="text">Start</span>
            </button>
          </div>
        </div>

        <div class="voice-control-body">
          <!-- Microphone Selection -->
          <div class="mic-selection">
            <label for="mic-select">Microphone</label>
            <select id="mic-select">
              <option value="">Loading microphones...</option>
            </select>
          </div>

          <!-- Status Indicator -->
          <div id="voice-status" class="voice-status status-loading">
            <div class="status-dot"></div>
            <div class="status-text">Initializing...</div>
            <div class="voice-waveform">
              <canvas id="waveform-canvas"></canvas>
            </div>
          </div>
        </div>
      </div>
    `;

    // Get references to UI elements
    this.panel = this.el.querySelector('.voice-control-panel');
    this.header = this.el.querySelector('.voice-control-header');
    this.minimizeBtn = this.el.querySelector('#voice-minimize');
    this.toggleBtn = this.el.querySelector('#voice-toggle');
    this.micSelect = this.el.querySelector('#mic-select');
    this.statusEl = this.el.querySelector('#voice-status');
    this.waveformCanvas = this.el.querySelector('#waveform-canvas');
    this.waveformCtx = this.waveformCanvas.getContext('2d');

    // Setup canvas for HiDPI (defer to next frame to ensure DOM is rendered)
    requestAnimationFrame(() => this.setupCanvas());

    // Wire up event listeners
    this.minimizeBtn.addEventListener('click', (e) => {
      e.stopPropagation(); // Prevent header click from also firing
      this.toggleCollapse();
    });
    this.toggleBtn.addEventListener('click', (e) => {
      e.stopPropagation(); // Prevent header click from also firing
      this.toggle();
    });

    // Make the entire header clickable for expand/collapse
    this.header.addEventListener('click', () => this.toggleCollapse());

    this.micSelect.addEventListener('change', () => {
      const selectedMic = this.micSelect.value;
      localStorage.setItem('pavoi_voice_mic', selectedMic);

      // Restart if currently active
      if (this.isActive) {
        this.restart();
      }
    });

    // Keyboard shortcut: Ctrl/Cmd + M
    this.keyboardHandler = (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'm') {
        e.preventDefault();
        this.toggle();
      }
    };
    document.addEventListener('keydown', this.keyboardHandler);

    // Handle window resize for canvas
    this.resizeHandler = () => this.setupCanvas();
    window.addEventListener('resize', this.resizeHandler);
  },

  /**
   * Setup canvas for HiDPI displays
   */
  setupCanvas() {
    if (!this.waveformCanvas) return;

    const rect = this.waveformCanvas.getBoundingClientRect();
    const dpr = window.devicePixelRatio || 1;

    // If dimensions are 0, defer setup
    if (rect.width === 0 || rect.height === 0) {
      requestAnimationFrame(() => this.setupCanvas());
      return;
    }

    this.waveformCanvas.width = rect.width * dpr;
    this.waveformCanvas.height = rect.height * dpr;

    this.waveformCtx.scale(dpr, dpr);

    // Store dimensions for drawing
    this.canvasWidth = rect.width;
    this.canvasHeight = rect.height;

    console.log('[VoiceControl] Canvas setup:', this.canvasWidth, 'x', this.canvasHeight);
  },

  /**
   * Load and enumerate available microphones
   */
  async loadMicrophones() {
    try {
      console.log('[VoiceControl] Loading microphones...');

      // Request permission first (required for device labels)
      await navigator.mediaDevices.getUserMedia({ audio: true })
        .then(stream => {
          // Stop the stream immediately (we just needed permission)
          stream.getTracks().forEach(track => track.stop());
        });

      // Enumerate devices
      const devices = await navigator.mediaDevices.enumerateDevices();
      const audioInputs = devices.filter(d => d.kind === 'audioinput');

      if (audioInputs.length === 0) {
        this.handleError('No microphones found');
        return;
      }

      console.log(`[VoiceControl] Found ${audioInputs.length} microphones`);

      // Clear and populate dropdown
      this.micSelect.innerHTML = '';
      audioInputs.forEach((device, index) => {
        const option = document.createElement('option');
        option.value = device.deviceId;
        option.text = device.label || `Microphone ${index + 1}`;
        this.micSelect.appendChild(option);
      });

      // Restore saved preference
      const savedMic = localStorage.getItem('pavoi_voice_mic');
      if (savedMic && audioInputs.find(d => d.deviceId === savedMic)) {
        this.micSelect.value = savedMic;
      }

    } catch (error) {
      console.error('[VoiceControl] Failed to load microphones:', error);
      this.handleError('Microphone access denied');
    }
  },

  /**
   * Toggle panel collapsed/expanded
   */
  toggleCollapse() {
    this.isCollapsed = !this.isCollapsed;
    this.panel.classList.toggle('collapsed', this.isCollapsed);
    localStorage.setItem('pavoi_voice_collapsed', this.isCollapsed);
  },

  /**
   * Toggle voice control on/off
   */
  async toggle() {
    if (this.isActive) {
      this.stop();
    } else {
      await this.start();
    }
  },

  /**
   * Start voice control
   */
  async start() {
    if (!this.modelReady) {
      this.updateStatus('error', 'Model not ready - please wait');
      return;
    }

    try {
      console.log('[VoiceControl] Starting voice control...');

      // Setup audio context and analyser for waveform (do this BEFORE VAD starts)
      await this.setupAudioAnalysis();

      // Initialize VAD with custom paths for worklet and model
      this.vad = await MicVAD.new({
        // Specify paths to VAD assets (served from priv/static/assets/vad/)
        workletURL: '/assets/vad/vad.worklet.bundle.min.js',
        modelURL: '/assets/vad/silero_vad.onnx',

        // Configure ONNX Runtime paths for WASM files
        ortConfig: (ort) => {
          ort.env.wasm.wasmPaths = '/assets/js/';
        },

        // Use selected microphone (or default if not specified)
        ...(this.micSelect.value && { deviceId: this.micSelect.value }),

        // Called when speech starts
        onSpeechStart: () => {
          console.log('[VoiceControl] Speech detected');
          this.updateStatus('listening', 'Listening...');
          this.startWaveformAnimation();
        },

        // Called when speech ends (with audio data)
        onSpeechEnd: (audio) => {
          console.log('[VoiceControl] Speech ended, processing...');
          this.stopWaveformAnimation();
          this.updateStatus('processing', 'Processing...');
          this.processAudio(audio);
        },

        // Called on false positives (ignored)
        onVADMisfire: () => {
          console.log('[VoiceControl] VAD misfire (false positive)');
        }
      });

      await this.vad.start();

      this.isActive = true;
      this.toggleBtn.classList.add('active');
      this.toggleBtn.querySelector('.text').textContent = 'Stop';

      // Start waveform visualization immediately
      this.startWaveformAnimation();

      console.log('[VoiceControl] Voice control started successfully');

    } catch (error) {
      console.error('[VoiceControl] Failed to start:', error);
      this.handleError(`Failed to start: ${error.message}`);
    }
  },

  /**
   * Stop voice control
   */
  stop({ keepStatus = false } = {}) {
    console.log('[VoiceControl] Stopping voice control...');

    this.stopWaveformAnimation();
    this.cleanupAudioAnalysis();

    if (this.vad) {
      // Destroy VAD to fully release microphone (not just pause)
      this.vad.destroy();
      this.vad = null;
    }

    this.isActive = false;
    this.isProcessing = false;
    this.toggleBtn.classList.remove('active');
    this.toggleBtn.querySelector('.text').textContent = 'Start';

    if (!keepStatus) {
      this.updateStatus('stopped', 'Stopped');
    }
  },

  /**
   * Restart voice control (useful when changing microphones)
   */
  async restart() {
    console.log('[VoiceControl] Restarting voice control...');
    this.stop();
    await new Promise(resolve => setTimeout(resolve, 100));
    await this.start();
  },

  /**
   * Process audio chunk through Whisper
   */
  processAudio(audioData) {
    // Back-pressure: don't send new audio if still processing
    if (this.isProcessing) {
      console.log('[VoiceControl] Already processing, skipping chunk');
      return;
    }

    this.isProcessing = true;

    // Convert Float32Array to regular array for worker transfer
    const audioArray = Array.from(audioData);

    console.log(`[VoiceControl] Sending ${audioArray.length} samples to worker`);

    // Send to worker for transcription
    this.worker.postMessage({
      type: 'transcribe',
      data: { audio: audioArray }
    });
  },

  /**
   * Handle transcript from Whisper
   */
  handleTranscript(text) {
    console.log('[VoiceControl] Transcript:', text);
    // Transcript display removed from UI
    // this.transcriptEl.textContent = `Heard: "${text}"`;

    // Extract number from transcript
    const number = this.extractNumber(text);

    if (number !== null && number >= 1 && number <= this.totalProducts) {
      // Valid number! Jump to product
      this.updateStatus('success', `Jumping to product ${number}`);
      console.log(`[VoiceControl] Jumping to product ${number}`);

      // Push event to LiveView
      this.pushEvent("jump_to_product", {
        position: number.toString()
      });

      // Restart waveform after brief success message
      setTimeout(() => {
        if (this.isActive) {
          this.startWaveformAnimation();
        }
      }, 1500);

    } else {
      // Invalid or out of range
      const message = number === null
        ? 'No number detected'
        : `Invalid: ${number} (must be 1-${this.totalProducts})`;

      this.updateStatus('error', message);
      console.warn(`[VoiceControl] ${message}`);

      // Restart waveform after brief error message
      setTimeout(() => {
        if (this.isActive) {
          this.startWaveformAnimation();
        }
      }, 1500);
    }
  },

  /**
   * Extract product number from transcript
   * Handles:
   * - Direct numbers: "23" → 23
   * - Word numbers: "twenty three" → 23
   * - With prefixes: "product twelve" → 12
   * - Mixed: "go to number five" → 5
   */
  extractNumber(text) {
    if (!text) return null;

    // Clean transcript - remove common prefixes and Whisper artifacts
    const cleaned = text.toLowerCase()
      .trim()
      .replace(/^[>\s]+/g, '')  // Remove leading >> or whitespace
      .replace(/[.,!?;:]+$/g, '')  // Remove trailing punctuation
      .replace(/^(product|number|item|go to|goto|show|display|jump to|jump)\s+/i, '')
      .replace(/\s+/g, ' ');

    // Try direct integer parsing first
    const directNumber = parseInt(cleaned);
    if (!isNaN(directNumber) && directNumber > 0) {
      return directNumber;
    }

    // Try finding digits in the text
    const digitMatch = text.match(/\d+/);
    if (digitMatch) {
      const num = parseInt(digitMatch[0]);
      if (num > 0) return num;
    }

    // Convert spoken numbers to digits
    const converted = this.wordsToNumber(cleaned);
    if (converted !== null && converted > 0) {
      return converted;
    }

    return null;
  },

  /**
   * Simple word-to-number conversion for common spoken numbers
   * Handles numbers 1-999
   */
  wordsToNumber(text) {
    const ones = {
      'zero': 0, 'one': 1, 'two': 2, 'three': 3, 'four': 4,
      'five': 5, 'six': 6, 'seven': 7, 'eight': 8, 'nine': 9,
      'ten': 10, 'eleven': 11, 'twelve': 12, 'thirteen': 13,
      'fourteen': 14, 'fifteen': 15, 'sixteen': 16, 'seventeen': 17,
      'eighteen': 18, 'nineteen': 19
    };

    const tens = {
      'twenty': 20, 'thirty': 30, 'forty': 40, 'fifty': 50,
      'sixty': 60, 'seventy': 70, 'eighty': 80, 'ninety': 90
    };

    const scales = {
      'hundred': 100
    };

    // Check direct match first
    if (ones[text] !== undefined) return ones[text];
    if (tens[text] !== undefined) return tens[text];

    // Parse compound numbers like "twenty three" or "one hundred five"
    const words = text.split(/\s+/);
    let total = 0;
    let current = 0;

    for (let i = 0; i < words.length; i++) {
      const word = words[i];

      if (ones[word] !== undefined) {
        current += ones[word];
      } else if (tens[word] !== undefined) {
        current += tens[word];
      } else if (word === 'hundred' && current > 0) {
        current *= 100;
      }
    }

    total += current;

    return total > 0 ? total : null;
  },

  /**
   * Setup audio analysis for waveform (called once when starting voice control)
   */
  async setupAudioAnalysis() {
    try {
      // Get the microphone stream from the browser
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: {
          deviceId: this.micSelect.value ? { exact: this.micSelect.value } : undefined
        }
      });

      // Create audio context and analyser
      this.audioContext = new (window.AudioContext || window.webkitAudioContext)();
      this.analyser = this.audioContext.createAnalyser();

      // Configure analyser for responsive visualization
      this.analyser.fftSize = 256;
      this.analyser.smoothingTimeConstant = 0.8;

      // Connect microphone to analyser
      const source = this.audioContext.createMediaStreamSource(stream);
      source.connect(this.analyser);

      // Store stream reference for cleanup
      this.micStream = stream;

      console.log('[VoiceControl] Audio analysis ready');

    } catch (error) {
      console.error('[VoiceControl] Failed to setup audio analysis:', error);
    }
  },

  /**
   * Cleanup audio analysis (called when stopping voice control)
   */
  cleanupAudioAnalysis() {
    // Close audio context
    if (this.audioContext) {
      this.audioContext.close();
      this.audioContext = null;
    }

    // Stop microphone stream
    if (this.micStream) {
      this.micStream.getTracks().forEach(track => track.stop());
      this.micStream = null;
    }

    this.analyser = null;

    // Clear canvas
    if (this.waveformCtx && this.canvasWidth) {
      this.waveformCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    }
  },

  /**
   * Start waveform animation (called when speech detected)
   */
  startWaveformAnimation() {
    if (!this.analyser) {
      console.warn('[VoiceControl] Analyser not ready for waveform');
      return;
    }
    // Start animation loop immediately
    this.drawWaveform();
  },

  /**
   * Stop waveform animation (called when speech ends)
   */
  stopWaveformAnimation() {
    // Cancel animation
    if (this.waveformAnimationId) {
      cancelAnimationFrame(this.waveformAnimationId);
      this.waveformAnimationId = null;
    }

    // Clear canvas
    if (this.waveformCtx && this.canvasWidth) {
      this.waveformCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);
    }
  },

  /**
   * Draw waveform visualization
   * Creates a symmetric bar visualization similar to ElevenLabs component
   */
  drawWaveform() {
    if (!this.analyser) return;

    this.waveformAnimationId = requestAnimationFrame(() => this.drawWaveform());

    // Get frequency data
    const bufferLength = this.analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);
    this.analyser.getByteFrequencyData(dataArray);

    // Clear canvas
    this.waveformCtx.clearRect(0, 0, this.canvasWidth, this.canvasHeight);

    // Waveform settings (matching ElevenLabs style)
    const barWidth = 3;
    const barGap = 1;
    const barRadius = 1.5;
    const minBarHeight = 4;
    const fadeEdges = true;
    const fadeWidth = 24;
    const sensitivity = 1.2;

    // Calculate number of bars that fit
    const totalBarWidth = barWidth + barGap;
    const numBars = Math.floor(this.canvasWidth / totalBarWidth);

    // Sample frequency data evenly
    const step = Math.floor(bufferLength / numBars);

    // Get theme color (amber for listening state)
    const computedStyle = getComputedStyle(this.statusEl);
    const barColor = computedStyle.getPropertyValue('color').trim();

    // Draw bars
    for (let i = 0; i < numBars; i++) {
      // Get frequency value and normalize
      const index = i * step;
      let value = dataArray[index] / 255;

      // Apply sensitivity
      value = Math.min(1, value * sensitivity);

      // Calculate bar height
      const barHeight = Math.max(minBarHeight, value * this.canvasHeight);

      // Calculate position
      const x = i * totalBarWidth;
      const y = (this.canvasHeight - barHeight) / 2;

      // Apply fade at edges
      let alpha = 1;
      if (fadeEdges) {
        const distanceFromLeft = x;
        const distanceFromRight = this.canvasWidth - x;
        const minDistance = Math.min(distanceFromLeft, distanceFromRight);

        if (minDistance < fadeWidth) {
          alpha = minDistance / fadeWidth;
        }
      }

      // Draw rounded rectangle bar
      this.waveformCtx.fillStyle = barColor.replace('rgb', 'rgba').replace(')', `, ${alpha})`);
      this.roundRect(x, y, barWidth, barHeight, barRadius);
    }
  },

  /**
   * Draw rounded rectangle
   */
  roundRect(x, y, width, height, radius) {
    this.waveformCtx.beginPath();
    this.waveformCtx.moveTo(x + radius, y);
    this.waveformCtx.lineTo(x + width - radius, y);
    this.waveformCtx.quadraticCurveTo(x + width, y, x + width, y + radius);
    this.waveformCtx.lineTo(x + width, y + height - radius);
    this.waveformCtx.quadraticCurveTo(x + width, y + height, x + width - radius, y + height);
    this.waveformCtx.lineTo(x + radius, y + height);
    this.waveformCtx.quadraticCurveTo(x, y + height, x, y + height - radius);
    this.waveformCtx.lineTo(x, y + radius);
    this.waveformCtx.quadraticCurveTo(x, y, x + radius, y);
    this.waveformCtx.closePath();
    this.waveformCtx.fill();
  },

  /**
   * Update status indicator
   */
  updateStatus(state, message) {
    // Remove all state classes
    this.statusEl.className = 'voice-status';

    // Add new state class
    this.statusEl.classList.add(`status-${state}`);

    // Update text
    const statusText = this.statusEl.querySelector('.status-text');
    statusText.textContent = message;

    // Enable/disable toggle button based on state
    if (state === 'loading') {
      this.toggleBtn.disabled = true;
    } else {
      this.toggleBtn.disabled = false;
    }
  },

  /**
   * Handle errors
   */
  handleError(message) {
    console.error('[VoiceControl] Error:', message);
    this.updateStatus('error', message);

    // Auto-stop on error
    if (this.isActive) {
      this.stop({ keepStatus: true });
    }
  },

  /**
   * Cleanup when hook is destroyed
   */
  destroyed() {
    console.log('[VoiceControl] Hook destroyed, cleaning up...');

    // Stop VAD and waveform
    this.stop();

    // Terminate worker
    if (this.worker) {
      this.worker.terminate();
    }

    // Remove event listeners
    if (this.keyboardHandler) {
      document.removeEventListener('keydown', this.keyboardHandler);
    }
    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler);
    }
  }
}
