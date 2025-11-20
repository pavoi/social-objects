// Whisper Web Worker - Module worker for speech recognition
// Bundles via esbuild (no CDN dependencies - CSP compliant)
// Uses Transformers.js with WebGPU acceleration and CPU/WASM fallback

import { pipeline, env } from "@huggingface/transformers";

// Configure Transformers.js environment for local hosting
// All models will be served from the app's static assets
env.allowLocalModels = false; // We'll use HuggingFace hub but cache locally
env.useBrowserCache = true; // Enable IndexedDB caching
env.allowRemoteModels = true; // Allow initial download from HF hub

let transcriber = null;
let modelLoaded = false;
let currentDevice = null;

console.log('[Whisper Worker] Worker initialized');

// Listen for messages from main thread
self.onmessage = async (e) => {
  const { type, data } = e.data;

  console.log('[Whisper Worker] Received message:', type);

  try {
    switch (type) {
      case 'load_model':
        await loadModel(data.model, data.device);
        break;

      case 'transcribe':
        await transcribe(data.audio);
        break;

      case 'ping':
        // Health check
        self.postMessage({
          type: 'pong',
          data: {
            modelLoaded,
            device: currentDevice
          }
        });
        break;

      default:
        console.warn('[Whisper Worker] Unknown message type:', type);
    }
  } catch (error) {
    console.error('[Whisper Worker] Error handling message:', error);
    self.postMessage({
      type: 'error',
      data: { message: error.message, stack: error.stack }
    });
  }
};

/**
 * Load the Whisper model with device selection and progress reporting
 * @param {string} modelName - HuggingFace model identifier (e.g., 'Xenova/whisper-tiny.en')
 * @param {string} device - 'webgpu' or 'wasm' (CPU fallback)
 */
async function loadModel(modelName, device) {
  try {
    console.log(`[Whisper Worker] Loading model: ${modelName} on device: ${device}`);

    // Report initial loading state
    self.postMessage({
      type: 'model_loading',
      data: {
        progress: 0,
        status: 'Initializing model...',
        device
      }
    });

    // Detect and validate device support
    const detectedDevice = await detectDevice(device);
    currentDevice = detectedDevice;

    console.log(`[Whisper Worker] Using device: ${detectedDevice}`);

    // Create the pipeline with progress callback
    transcriber = await pipeline(
      'automatic-speech-recognition',
      modelName,
      {
        device: detectedDevice,
        // Use fp16 for WebGPU (faster), fp32 for CPU/WASM (more compatible)
        dtype: detectedDevice === 'webgpu' ? 'fp16' : 'fp32',

        // Progress callback for model download/loading
        progress_callback: (progress) => {
          console.log('[Whisper Worker] Progress:', progress);

          // Calculate percentage if we have loaded/total
          let percent = 0;
          let status = 'Loading...';

          if (progress.status === 'progress' && progress.total) {
            percent = Math.round((progress.loaded / progress.total) * 100);
            status = `Downloading ${progress.file || 'model'}...`;
          } else if (progress.status === 'done') {
            percent = 100;
            status = `Loaded ${progress.file || 'model'}`;
          } else if (progress.status === 'ready') {
            percent = 100;
            status = 'Model ready';
          }

          self.postMessage({
            type: 'model_loading',
            data: {
              progress: percent,
              status,
              file: progress.file,
              loaded: progress.loaded,
              total: progress.total
            }
          });
        }
      }
    );

    modelLoaded = true;

    console.log('[Whisper Worker] Model loaded successfully');

    self.postMessage({
      type: 'model_ready',
      data: {
        device: detectedDevice,
        model: modelName
      }
    });

  } catch (error) {
    console.error('[Whisper Worker] Failed to load model:', error);

    // If WebGPU fails, try falling back to WASM
    if (device === 'webgpu' && !modelLoaded) {
      console.log('[Whisper Worker] WebGPU failed, falling back to WASM...');

      self.postMessage({
        type: 'model_loading',
        data: {
          progress: 0,
          status: 'WebGPU failed, falling back to CPU...',
          device: 'wasm'
        }
      });

      // Retry with WASM
      return loadModel(modelName, 'wasm');
    }

    self.postMessage({
      type: 'error',
      data: {
        message: `Failed to load model: ${error.message}`,
        details: error.stack
      }
    });
  }
}

/**
 * Detect and validate device support
 * @param {string} requestedDevice - 'webgpu' or 'wasm'
 * @returns {Promise<string>} - Actual device to use
 */
async function detectDevice(requestedDevice) {
  // If WASM is requested, use it directly
  if (requestedDevice === 'wasm') {
    return 'wasm';
  }

  // Check for WebGPU support
  if (requestedDevice === 'webgpu') {
    // Check if navigator.gpu exists (WebGPU API)
    if (typeof navigator !== 'undefined' && 'gpu' in navigator) {
      try {
        // Try to request a GPU adapter to verify WebGPU actually works
        const adapter = await navigator.gpu.requestAdapter();

        if (adapter) {
          console.log('[Whisper Worker] WebGPU is supported and available');
          return 'webgpu';
        } else {
          console.warn('[Whisper Worker] WebGPU API exists but no adapter available, falling back to WASM');
          return 'wasm';
        }
      } catch (error) {
        console.warn('[Whisper Worker] WebGPU detection failed:', error);
        return 'wasm';
      }
    } else {
      console.log('[Whisper Worker] WebGPU not supported in this browser, using WASM');
      return 'wasm';
    }
  }

  // Default to WASM
  console.log('[Whisper Worker] Unknown device requested, defaulting to WASM');
  return 'wasm';
}

/**
 * Transcribe audio using the loaded Whisper model
 * @param {Array<number>} audioArray - Audio samples as Float32 array values
 */
async function transcribe(audioArray) {
  if (!modelLoaded || !transcriber) {
    self.postMessage({
      type: 'error',
      data: { message: 'Model not loaded. Please load the model first.' }
    });
    return;
  }

  try {
    console.log(`[Whisper Worker] Transcribing audio chunk (${audioArray.length} samples)`);

    // Convert array back to Float32Array
    const audioData = new Float32Array(audioArray);

    // Validate audio data
    if (audioData.length === 0) {
      self.postMessage({
        type: 'error',
        data: { message: 'Empty audio data received' }
      });
      return;
    }

    // Run inference
    // Note: For English-only models (.en), don't specify language/task parameters
    const result = await transcriber(audioData, {
      // Return timestamps is optional - we mainly care about the text
      return_timestamps: false,
      // Chunk length in seconds (for long audio)
      chunk_length_s: 30,
      // Stride length for overlapping chunks
      stride_length_s: 5
    });

    console.log('[Whisper Worker] Transcription result:', result);

    // Extract text from result
    const text = typeof result === 'string' ? result : result.text || '';

    self.postMessage({
      type: 'transcript',
      data: {
        text: text.trim(),
        // Include any additional metadata if available
        chunks: result.chunks || null
      }
    });

  } catch (error) {
    console.error('[Whisper Worker] Transcription failed:', error);

    self.postMessage({
      type: 'error',
      data: {
        message: `Transcription failed: ${error.message}`,
        details: error.stack
      }
    });
  }
}

// Error handler for uncaught errors in worker
self.onerror = (error) => {
  console.error('[Whisper Worker] Uncaught error:', error);
  self.postMessage({
    type: 'error',
    data: {
      message: 'Worker error: ' + error.message,
      details: error.filename + ':' + error.lineno
    }
  });
};

console.log('[Whisper Worker] Ready to receive messages');
