/**
 * VoiceControl Hook - Voice-activated product navigation for Phoenix LiveView
 *
 * Enables hands-free product switching using local speech recognition.
 * Integrates Whisper (OpenAI's speech-to-text model) with Silero VAD
 * (Voice Activity Detection) for efficient, privacy-first voice control.
 *
 * Designed for continuous 4+ hour recording sessions where the host can
 * say "show number [N]" at any time during natural conversation to switch
 * to product N. Uses a specific trigger phrase to avoid false positives
 * from numbers spoken in other contexts.
 *
 * @module VoiceControl
 * @requires @ricky0123/vad-web - Voice Activity Detection library
 *
 * ## Architecture
 *
 * 1. **VAD Layer** - Real-time speech probability detection (~30x/sec)
 *    - Uses onFrameProcessed for continuous frame-level access
 *    - Runs Silero VAD model locally (~1.7MB)
 *
 * 2. **Rolling Buffer** - Maintains last 5 seconds of audio
 *    - Continuously collects frames regardless of speech boundaries
 *    - Enables number detection within continuous speech
 *
 * 3. **Periodic Processing** - Transcribes buffer every 2.5 seconds during speech
 *    - Starts when speech probability exceeds threshold
 *    - Stops after extended silence (~1 second)
 *    - Includes deduplication to prevent repeated jumps
 *
 * 4. **Whisper Worker** - Transcribes audio to text in background thread
 *    - Uses OpenAI Whisper Tiny English model (~40MB, cached)
 *    - WebGPU accelerated (2-4x faster than CPU)
 *    - Automatic CPU/WASM fallback for unsupported browsers
 *
 * 5. **Command Extraction** - Detects "show number [N]" voice commands
 *    - Trigger phrase: "show number" followed by a number
 *    - Handles words: "show number twenty three" → 23
 *    - Handles digits: "show number 23" → 23
 *    - Works mid-sentence: "...talking about show number 5 and then..." → 5
 *    - Ignores numbers without the trigger phrase (reduces false positives)
 *    - Validates range: 1 to 99 (backend validates against actual product count)
 *    - 5-second deduplication window prevents repeated jumps
 *
 * 6. **LiveView Integration** - Pushes events to trigger product navigation
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
 * - `data-total-products` (optional) - Total product count (not used for validation; backend handles range checking)
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
    this.isStarting = false;
    this.totalProducts = parseInt(this.el.dataset.totalProducts);
    this.vad = null;
    this.worker = null;
    this.modelReady = false;
    this.isProcessing = false; // Back-pressure: prevent overlapping transcriptions
    this.isCollapsed = localStorage.getItem('pavoi_voice_collapsed') === 'true';
    this.microphonesLoaded = false; // Track if microphones have been enumerated

    // Ring buffer for continuous speech processing (avoids GC pressure)
    this.bufferMaxSamples = 80000;      // ~5 seconds at 16kHz
    this.audioBuffer = new Float32Array(this.bufferMaxSamples);
    this.bufferWriteIndex = 0;          // Next write position in ring buffer
    this.bufferLength = 0;              // Current number of valid samples
    this.processInterval = null;        // Timer for periodic processing
    this.processingIntervalMs = 2500;   // Process every 2.5 seconds
    this.speechActive = false;          // Track if speech is currently detected
    this.speechThreshold = 0.5;         // VAD probability threshold
    this.silenceFrameCount = 0;         // Count consecutive silence frames
    this.silenceFrameThreshold = 30;    // ~1 second of silence to stop (30 frames at ~30fps)

    // Number deduplication
    this.lastDetectedNumber = null;
    this.lastDetectionTime = 0;
    this.deduplicationWindowMs = 5000;  // Ignore same number within 5 seconds

    // Waveform visualization
    this.audioContext = null;
    this.analyser = null;
    this.waveformAnimationId = null;

    // Mobile reliability: error recovery
    this.consecutiveErrors = 0;
    this.maxConsecutiveErrors = 3;

    // Mobile reliability: periodic worker restart (mitigates WebGPU memory leak)
    this.transcriptionCount = 0;
    this.maxTranscriptionsBeforeRestart = 500; // ~20 min at 2.5s intervals

    // Mobile reliability: wake lock
    this.wakeLock = null;

    // Initialize components
    this.setupWorker();
    this.setupUI();
    this.preloadAssets();

    // Check permission state and only load microphones if already granted
    // (defers permission prompt to when user clicks Start)
    this.checkMicrophonePermission().then(async (permState) => {
      if (permState === 'granted') {
        await this.loadMicrophones();
      } else {
        // Show placeholder - microphones will load when user clicks Start
        this.micSelect.innerHTML = '<option value="">Click Start to enable microphone</option>';
      }
    });

    // Disable Start until the model is ready
    this.updateStatus('loading', 'Loading model...');
    this.toggleBtn.disabled = true;
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
        case 'progress':
          this.updateStatus('loading', `Loading model: ${data.progress}%`);
          this.toggleBtn.disabled = true;
          break;

        case 'model_ready':
          this.updateStatus('ready', 'Ready');
          this.modelReady = true;
          this.toggleBtn.disabled = false;
          this.toggleBtn.querySelector('.text').textContent = 'Start';
          this.waveformContainer.style.display = '';
          break;

        case 'transcript':
          // Reset error counter on success
          this.consecutiveErrors = 0;

          // Track transcription count for periodic worker restart
          this.transcriptionCount++;
          if (this.transcriptionCount >= this.maxTranscriptionsBeforeRestart) {
            console.log('[VoiceControl] Preventive worker restart for memory management');
            this.restartWorker();
          }

          this.handleTranscript(data.text);
          this.isProcessing = false;
          break;

        case 'error':
          this.consecutiveErrors++;
          console.error('[VoiceControl] Worker error:', data.message);

          if (this.consecutiveErrors >= this.maxConsecutiveErrors) {
            console.warn('[VoiceControl] Too many consecutive errors, attempting recovery...');
            this.restartWorker();
          } else {
            this.handleError(data.message);
          }
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
   * Check microphone permission state without triggering a prompt
   * @returns {Promise<string>} 'granted', 'prompt', or 'denied'
   */
  async checkMicrophonePermission() {
    try {
      const result = await navigator.permissions.query({ name: 'microphone' });
      return result.state;
    } catch {
      // Firefox doesn't support this query, assume prompt needed
      return 'prompt';
    }
  },

  /**
   * Setup UI elements and event listeners
   */
  setupUI() {
    console.log('[VoiceControl] Setting up UI...');

    // Create UI structure using shared controller-panel classes
    // Note: header is a div (not button) because it contains the toggle button
    this.el.innerHTML = `
      <div class="voice-control-panel${this.isCollapsed ? ' controller-panel--collapsed' : ''}">
        <div class="controller-panel__header" id="voice-header">
          <span class="controller-panel__title">Voice Control</span>
          <span class="voice-control-hint">Say "show number ..." to jump to a product</span>
          <div class="voice-control-actions">
            <button type="button" id="voice-toggle" class="voice-toggle-btn" disabled>
              <span class="text">Loading model...</span>
            </button>
          </div>
          <svg class="controller-panel__chevron" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <polyline points="6 9 12 15 18 9"></polyline>
          </svg>
        </div>

        <div class="controller-panel__body">
          <!-- Microphone Selection -->
          <div class="mic-selection">
            <select id="mic-select">
              <option value="">Loading microphones...</option>
            </select>
          </div>

          <!-- Status Indicator -->
          <div id="voice-status" class="voice-status status-loading">
            <div class="status-dot"></div>
            <div class="status-text">Initializing...</div>
            <div class="voice-waveform" style="display: none;">
              <canvas id="waveform-canvas"></canvas>
            </div>
          </div>
        </div>
      </div>
    `;

    // Get references to UI elements
    this.panel = this.el.querySelector('.voice-control-panel');
    this.header = this.el.querySelector('#voice-header');
    this.toggleBtn = this.el.querySelector('#voice-toggle');
    this.micSelect = this.el.querySelector('#mic-select');
    this.statusEl = this.el.querySelector('#voice-status');
    this.waveformContainer = this.el.querySelector('.voice-waveform');
    this.waveformCanvas = this.el.querySelector('#waveform-canvas');
    this.waveformCtx = this.waveformCanvas.getContext('2d');
    this.vadWorkletUrl = this.el.dataset.vadWorkletUrl || '/assets/vad/vad.worklet.bundle.min.js';
    this.vadModelUrl = this.el.dataset.vadModelUrl || '/assets/vad/silero_vad.onnx';
    this.ortWasmUrl = this.el.dataset.ortWasmUrl || '/assets/js/ort-wasm-simd-threaded.wasm';
    this.ortJsepUrl = this.el.dataset.ortJsepUrl || '/assets/js/ort-wasm-simd-threaded.jsep.wasm';

    // Setup canvas for HiDPI (defer to next frame to ensure DOM is rendered)
    requestAnimationFrame(() => this.setupCanvas());

    // Wire up event listeners
    this.toggleBtn.addEventListener('click', (e) => {
      e.stopPropagation(); // Prevent header click from also firing
      this.toggle();
    });

    // Make the entire header clickable for expand/collapse
    this.header.addEventListener('click', (e) => {
      // Don't collapse if clicking the toggle button
      if (e.target.closest('#voice-toggle')) return;
      this.toggleCollapse();
    });

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

    // Mobile reliability: handle visibility changes (iOS AudioContext recovery)
    this.visibilityHandler = () => this.handleVisibilityChange();
    document.addEventListener('visibilitychange', this.visibilityHandler);
  },

  /**
   * Handle page visibility changes for mobile reliability
   * iOS Safari: AudioContext enters "interrupted" state when backgrounded
   * Wake Lock: auto-releases when page hidden, re-acquire when visible
   */
  handleVisibilityChange() {
    if (document.visibilityState === 'visible' && this.isActive) {
      console.log('[VoiceControl] Page became visible, checking state...');

      // iOS Safari: AudioContext may be "interrupted" or "suspended" after returning
      if (this.audioContext &&
          (this.audioContext.state === 'interrupted' || this.audioContext.state === 'suspended')) {
        console.log('[VoiceControl] AudioContext state:', this.audioContext.state, '- attempting resume');
        this.audioContext.resume().then(() => {
          console.log('[VoiceControl] AudioContext resumed successfully');
        }).catch(err => {
          console.warn('[VoiceControl] Failed to resume AudioContext:', err);
          // Attempt full restart as fallback
          this.restart();
        });
      }

      // Re-acquire wake lock (it auto-releases when page hidden)
      if (!this.wakeLock) {
        this.requestWakeLock();
      }
    }
  },

  /**
   * Request screen wake lock to prevent device sleep during recording
   * Supported in all major browsers since May 2024
   */
  async requestWakeLock() {
    if ('wakeLock' in navigator) {
      try {
        this.wakeLock = await navigator.wakeLock.request('screen');
        this.wakeLock.addEventListener('release', () => {
          console.log('[VoiceControl] Wake lock released');
          this.wakeLock = null;
        });
        console.log('[VoiceControl] Wake lock acquired');
      } catch (err) {
        // Can fail if battery is low, power saver mode, or tab not visible
        console.warn('[VoiceControl] Wake lock failed:', err.message);
      }
    }
  },

  /**
   * Release screen wake lock
   */
  releaseWakeLock() {
    if (this.wakeLock) {
      this.wakeLock.release();
      this.wakeLock = null;
    }
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

      this.microphonesLoaded = true;

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
    this.panel.classList.toggle('controller-panel--collapsed', this.isCollapsed);
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
      this.updateStatus('loading', 'Model not ready yet...');
      return;
    }

    if (this.isStarting) {
      return;
    }

    try {
      console.log('[VoiceControl] Starting voice control...');
      this.isStarting = true;
      this.toggleBtn.disabled = true;
      this.updateStatus('loading', 'Starting...');

      // Load microphones if not already loaded (will trigger permission prompt for new users)
      if (!this.microphonesLoaded) {
        await this.loadMicrophones();
        if (!this.microphonesLoaded) {
          // Permission denied or no microphones found
          this.isStarting = false;
          this.toggleBtn.disabled = false;
          return;
        }
      }

      // Setup audio context and analyser for waveform (do this BEFORE VAD starts)
      await this.setupAudioAnalysis();

      // Initialize VAD with custom paths for worklet and model
      this.vad = await MicVAD.new({
        // Specify paths to VAD assets (served from priv/static/assets/vad/)
        workletURL: this.vadWorkletUrl,
        modelURL: this.vadModelUrl,

        // Configure ONNX Runtime paths for WASM files
        ortConfig: (ort) => {
          const wasmBase = this.ortWasmUrl.replace(/[^/]+$/, '');
          ort.env.wasm.wasmPaths = wasmBase || '/assets/js/';
        },

        // Use selected microphone (or default if not specified)
        ...(this.micSelect.value && { deviceId: this.micSelect.value }),

        // Frame-level callback for continuous processing (called ~30x/sec)
        // This is the primary mechanism for rolling buffer + periodic processing
        onFrameProcessed: (probabilities, frame) => {
          this.handleFrame(probabilities, frame);
        },

        // Called when VAD detects speech start (kept for logging)
        onSpeechStart: () => {
          console.log('[VoiceControl] VAD speech start event');
          // Note: actual speech handling now done in handleFrame()
        },

        // Called when VAD detects speech end (backup processing)
        onSpeechEnd: (audio) => {
          console.log('[VoiceControl] VAD speech end event');
          // Process the VAD-segmented audio as a backup
          // (periodic processing should have already caught any numbers)
          if (!this.isProcessing && audio.length > 8000) {
            this.processAudio(audio);
          }
        },

        // Called on false positives (ignored)
        onVADMisfire: () => {
          console.log('[VoiceControl] VAD misfire (false positive)');
        }
      });

      await this.vad.start();

      this.isActive = true;
      this.isStarting = false;
      this.toggleBtn.classList.add('active');
      this.toggleBtn.querySelector('.text').textContent = 'Stop';
      this.toggleBtn.disabled = false;

      // Update status and start waveform visualization immediately
      this.updateStatus('listening', 'Listening...');
      this.startWaveformAnimation();

      // Request wake lock to prevent screen sleep during recording
      await this.requestWakeLock();

      console.log('[VoiceControl] Voice control started successfully');

    } catch (error) {
      console.error('[VoiceControl] Failed to start:', error);
      this.handleError(`Failed to start: ${error.message}`);
      this.isStarting = false;
      this.toggleBtn.disabled = false;
    }
  },

  /**
   * Stop voice control
   */
  stop({ keepStatus = false } = {}) {
    console.log('[VoiceControl] Stopping voice control...');

    // Stop periodic processing
    this.stopPeriodicProcessing();

    this.stopWaveformAnimation();
    this.cleanupAudioAnalysis();

    // Release wake lock
    this.releaseWakeLock();

    if (this.vad) {
      // Destroy VAD to fully release microphone (not just pause)
      this.vad.destroy();
      this.vad = null;
    }

    // Reset state
    this.isActive = false;
    this.isProcessing = false;
    this.speechActive = false;
    this.silenceFrameCount = 0;

    // Reset ring buffer (just reset indices, no allocation)
    this.bufferWriteIndex = 0;
    this.bufferLength = 0;

    // Reset deduplication (allow fresh detection on restart)
    this.lastDetectedNumber = null;
    this.lastDetectionTime = 0;

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
   * Restart the Whisper worker to reclaim GPU memory
   * Mitigates the WebGPU memory leak in Transformers.js v3
   * Model reloads from IndexedDB cache (~1-2s)
   */
  async restartWorker() {
    console.log('[VoiceControl] Restarting worker to reclaim GPU memory...');

    // Terminate old worker
    if (this.worker) {
      this.worker.terminate();
      this.worker = null;
    }

    // Reset state
    this.modelReady = false;
    this.transcriptionCount = 0;
    this.consecutiveErrors = 0;

    // Create new worker - model will reload from IndexedDB cache (fast)
    this.setupWorker();

    // Wait for model to be ready before continuing
    await new Promise((resolve) => {
      const checkReady = () => {
        if (this.modelReady) {
          resolve();
        } else {
          setTimeout(checkReady, 100);
        }
      };
      checkReady();
    });

    console.log('[VoiceControl] Worker restarted successfully');
  },

  /**
   * Process audio chunk through Whisper (VAD fallback path)
   */
  processAudio(audioData) {
    // Back-pressure: don't send new audio if still processing
    if (this.isProcessing) {
      console.log('[VoiceControl] Already processing, skipping chunk');
      return;
    }

    this.isProcessing = true;
    // Keep showing waveform during background processing (don't show "Processing...")

    // Convert Float32Array to regular array for worker transfer
    const audioArray = Array.from(audioData);

    console.log(`[VoiceControl] Sending ${audioArray.length} samples to worker (VAD fallback)`);

    // Send to worker for transcription
    this.worker.postMessage({
      type: 'transcribe',
      data: { audio: audioArray }
    });
  },

  /**
   * Append audio frame to ring buffer
   * Uses fixed-size Float32Array to avoid GC pressure over long sessions
   */
  appendToBuffer(frame) {
    for (let i = 0; i < frame.length; i++) {
      this.audioBuffer[this.bufferWriteIndex] = frame[i];
      this.bufferWriteIndex = (this.bufferWriteIndex + 1) % this.bufferMaxSamples;
      if (this.bufferLength < this.bufferMaxSamples) {
        this.bufferLength++;
      }
    }
  },

  /**
   * Handle each audio frame from VAD (called ~30x/sec)
   * Implements continuous speech detection with rolling buffer
   */
  handleFrame(probabilities, frame) {
    // Always append to rolling buffer
    this.appendToBuffer(frame);

    const isSpeaking = probabilities.isSpeech > this.speechThreshold;

    if (isSpeaking) {
      // Reset silence counter when speech detected
      this.silenceFrameCount = 0;

      if (!this.speechActive) {
        // Speech just started
        console.log('[VoiceControl] Continuous speech started');
        this.speechActive = true;
        this.updateStatus('listening', 'Listening...');
        this.startWaveformAnimation();
        this.startPeriodicProcessing();
      }
    } else {
      // Silence detected
      if (this.speechActive) {
        this.silenceFrameCount++;

        // Check if silence has persisted long enough to stop processing
        if (this.silenceFrameCount >= this.silenceFrameThreshold) {
          console.log('[VoiceControl] Extended silence detected, pausing periodic processing');
          this.speechActive = false;
          this.stopPeriodicProcessing();

          // Process any remaining buffer one final time
          if (this.bufferLength > 8000) {
            this.processBufferedAudio();
          }
        }
      }
    }
  },

  /**
   * Start periodic processing timer
   * Processes audio buffer every N milliseconds during speech
   */
  startPeriodicProcessing() {
    if (this.processInterval) return;

    console.log(`[VoiceControl] Starting periodic processing every ${this.processingIntervalMs}ms`);

    this.processInterval = setInterval(() => {
      if (this.bufferLength < 8000) {
        // Skip if less than 0.5 seconds of audio
        return;
      }
      this.processBufferedAudio();
    }, this.processingIntervalMs);
  },

  /**
   * Stop periodic processing timer
   */
  stopPeriodicProcessing() {
    if (this.processInterval) {
      console.log('[VoiceControl] Stopping periodic processing');
      clearInterval(this.processInterval);
      this.processInterval = null;
    }
  },

  /**
   * Process the current audio buffer through Whisper
   */
  processBufferedAudio() {
    if (this.isProcessing || this.bufferLength < 8000) {
      if (this.isProcessing) {
        console.log('[VoiceControl] Already processing, skipping buffer');
      }
      return;
    }

    // Extract samples from ring buffer in correct order
    const audioData = new Float32Array(this.bufferLength);
    const startIndex = (this.bufferWriteIndex - this.bufferLength + this.bufferMaxSamples) % this.bufferMaxSamples;

    for (let i = 0; i < this.bufferLength; i++) {
      audioData[i] = this.audioBuffer[(startIndex + i) % this.bufferMaxSamples];
    }

    console.log(`[VoiceControl] Processing buffer: ${audioData.length} samples (~${(audioData.length / 16000).toFixed(1)}s)`);

    this.isProcessing = true;
    // Keep showing waveform during background processing (don't show "Processing...")

    this.worker.postMessage({
      type: 'transcribe',
      data: { audio: Array.from(audioData) }
    });
  },

  /**
   * Handle transcript from Whisper
   * Includes deduplication to prevent repeated jumps during continuous speech
   */
  handleTranscript(text) {
    console.log('[VoiceControl] Transcript:', text);

    // Extract number from transcript
    const number = this.extractNumber(text);

    // Support all two-digit numbers (1-99) to match keyboard shortcuts
    // Backend will validate against actual product count
    if (number !== null && number >= 1 && number <= 99) {
      // Deduplication: check if this is the same number detected recently
      const now = Date.now();
      const isDuplicate = (
        number === this.lastDetectedNumber &&
        (now - this.lastDetectionTime) < this.deduplicationWindowMs
      );

      if (isDuplicate) {
        console.log(`[VoiceControl] Ignoring duplicate: ${number} (within ${this.deduplicationWindowMs}ms window)`);
        // Resume listening without showing error
        if (this.isActive && this.speechActive) {
          this.updateStatus('listening', 'Listening...');
        }
        return;
      }

      // Update deduplication tracking
      this.lastDetectedNumber = number;
      this.lastDetectionTime = now;

      // Keep waveform showing while we send request
      console.log(`[VoiceControl] Requesting jump to product ${number}`);

      // Push event to LiveView with reply callback
      this.pushEvent("jump_to_product", { position: number.toString() }, (reply) => {
        if (reply.success) {
          // Briefly show success, then return to listening
          this.updateStatus('success', `→ ${reply.position}`);
          console.log(`[VoiceControl] Successfully jumped to product ${reply.position}`);
        } else {
          this.updateStatus('error', reply.error || `Product ${number} not found`);
          console.warn(`[VoiceControl] Jump failed: ${reply.error}`);
        }

        // Return to listening quickly (waveform keeps running)
        setTimeout(() => {
          if (this.isActive) {
            this.updateStatus('listening', 'Listening...');
          }
        }, 1000);
      });

    } else {
      // No valid number detected - this is normal during continuous speech
      // Only log, don't show error to user (too noisy during continuous mode)
      if (text && text.trim()) {
        console.log(`[VoiceControl] No number in transcript: "${text.substring(0, 50)}..."`);
      }

      // Resume listening state if still active
      if (this.isActive && this.speechActive) {
        this.updateStatus('listening', 'Listening...');
      }
    }
  },

  /**
   * Extract product number from "show number [N]" command in transcript
   *
   * Only triggers on the specific phrase "show number" followed by a number.
   * This allows the command to be embedded in continuous speech without
   * false positives from numbers spoken in other contexts.
   *
   * Handles:
   * - "show number 5" → 5
   * - "show number twenty three" → 23
   * - "...talking about something show number 12 and then more talking..." → 12
   * - "show number five" → 5
   *
   * Does NOT trigger on:
   * - "the price is 5 dollars" (no "show number" prefix)
   * - "I have 23 items" (no "show number" prefix)
   * - "show me the product" (no number following)
   */
  extractNumber(text) {
    if (!text) return null;

    // Normalize the text for pattern matching
    const normalized = text.toLowerCase()
      .replace(/[.,!?;:]+/g, ' ')  // Replace punctuation with spaces
      .replace(/\s+/g, ' ')        // Normalize whitespace
      .trim();

    // Pattern: "show number" followed by digits or number words
    // The (?:^|\\s) ensures we match "show" as a word boundary
    // Looking for: "show number 5" or "show number five" or "show number twenty three"

    // First, try to find "show number" followed by digits
    const digitPattern = /(?:^|\s)show\s+number\s+(\d+)/i;
    const digitMatch = normalized.match(digitPattern);
    if (digitMatch) {
      const num = parseInt(digitMatch[1]);
      if (num > 0) {
        console.log(`[VoiceControl] Matched "show number ${num}" (digit)`);
        return num;
      }
    }

    // Next, try to find "show number" followed by word numbers
    // We need to extract the text after "show number" and parse it
    const wordPattern = /(?:^|\s)show\s+number\s+([a-z][a-z\s]*)/i;
    const wordMatch = normalized.match(wordPattern);
    if (wordMatch) {
      // Extract just the number words (stop at non-number words)
      const afterShowNumber = wordMatch[1].trim();
      const numberWords = this.extractNumberWords(afterShowNumber);

      if (numberWords) {
        const num = this.wordsToNumber(numberWords);
        if (num !== null && num > 0) {
          console.log(`[VoiceControl] Matched "show number ${numberWords}" → ${num}`);
          return num;
        }
      }
    }

    return null;
  },

  /**
   * Extract number words from the beginning of a string
   * Stops when encountering non-number words
   *
   * "twenty three and then" → "twenty three"
   * "five more things" → "five"
   * "hello world" → null
   */
  extractNumberWords(text) {
    const numberWordSet = new Set([
      'zero', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine',
      'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen',
      'seventeen', 'eighteen', 'nineteen',
      'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety',
      'hundred'
    ]);

    const words = text.split(/\s+/);
    const numberWords = [];

    for (const word of words) {
      if (numberWordSet.has(word)) {
        numberWords.push(word);
      } else {
        // Stop at first non-number word
        break;
      }
    }

    return numberWords.length > 0 ? numberWords.join(' ') : null;
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

    this.isStarting = false;
    this.toggleBtn.disabled = false;
  },

  /**
   * Preload heavy assets (WASM + VAD model/worklet) to reduce first-start delay
   */
  async preloadAssets() {
    const assets = [
      this.ortJsepUrl,
      this.ortWasmUrl,
      this.vadModelUrl,
      this.vadWorkletUrl
    ];

    try {
      await Promise.all(
        assets.map(async (url) => {
          const res = await fetch(url, { cache: 'force-cache' });
          if (!res.ok) throw new Error(`Failed to preload ${url}: ${res.status}`);
          // Read body to ensure cache population (ignore content)
          await res.arrayBuffer();
        })
      );
      console.log('[VoiceControl] Preloaded WASM/VAD assets');
    } catch (error) {
      console.warn('[VoiceControl] Asset preload failed:', error);
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

    // Release wake lock
    this.releaseWakeLock();

    // Remove event listeners
    if (this.keyboardHandler) {
      document.removeEventListener('keydown', this.keyboardHandler);
    }
    if (this.resizeHandler) {
      window.removeEventListener('resize', this.resizeHandler);
    }
    if (this.visibilityHandler) {
      document.removeEventListener('visibilitychange', this.visibilityHandler);
    }
  }
}
