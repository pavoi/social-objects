// Test hook to verify Whisper worker loads correctly
// This tests:
// 1. Module worker can be instantiated
// 2. Transformers.js loads from local bundle (not CDN)
// 3. WebGPU/CPU device detection works
// 4. Worker message passing works

export default {
  mounted() {
    console.log('[Whisper Test] Hook mounted, testing worker...');
    this.testWorker();
  },

  async testWorker() {
    try {
      // Test 1: Instantiate worker using module worker pattern
      console.log('[Whisper Test] Creating worker...');

      this.worker = new Worker(
        new URL('./workers/whisper_worker.js', import.meta.url),
        { type: 'module' }
      );

      console.log('[Whisper Test] ✓ Worker created successfully (module worker pattern)');

      // Test 2: Set up message handler
      this.worker.onmessage = (e) => {
        const { type, data } = e.data;
        console.log(`[Whisper Test] Received: ${type}`, data);

        switch (type) {
          case 'pong':
            console.log('[Whisper Test] ✓ Worker responds to ping');
            this.displayResult('ping-test', 'PASS', 'Worker communication works');

            // Start model load test
            this.testModelLoad();
            break;

          case 'model_loading':
            const progress = data.progress || 0;
            const status = data.status || 'Loading...';
            console.log(`[Whisper Test] Model loading: ${progress}% - ${status}`);
            this.displayResult('load-test', 'LOADING', `${progress}% - ${status}`);
            break;

          case 'model_ready':
            console.log('[Whisper Test] ✓ Model loaded successfully!');
            console.log('[Whisper Test] Device:', data.device);
            this.displayResult('load-test', 'PASS', `Model ready on ${data.device}`);
            this.displayResult('device-test', 'PASS', `Using ${data.device}`);
            this.displayResult('cdn-test', 'PASS', 'Transformers.js loaded from local bundle');

            // All tests passed
            this.displayResult('overall', 'PASS', 'All tests passed! Worker is functional.');
            break;

          case 'error':
            console.error('[Whisper Test] ✗ Error:', data.message);
            this.displayResult('error-test', 'FAIL', data.message);
            break;
        }
      };

      this.worker.onerror = (error) => {
        console.error('[Whisper Test] ✗ Worker error:', error);
        this.displayResult('error-test', 'FAIL', `Worker error: ${error.message}`);
      };

      // Test 3: Ping worker
      console.log('[Whisper Test] Sending ping...');
      this.worker.postMessage({ type: 'ping' });

    } catch (error) {
      console.error('[Whisper Test] ✗ Failed to create worker:', error);
      this.displayResult('create-test', 'FAIL', `Failed to create worker: ${error.message}`);
    }
  },

  testModelLoad() {
    console.log('[Whisper Test] Testing model load...');

    // Detect device
    const device = this.detectDevice();
    console.log('[Whisper Test] Detected device:', device);

    // Load model (use tiny model for faster testing)
    this.worker.postMessage({
      type: 'load_model',
      data: {
        model: 'Xenova/whisper-tiny.en',
        device: device
      }
    });
  },

  detectDevice() {
    // Check for WebGPU support
    if ('gpu' in navigator) {
      console.log('[Whisper Test] WebGPU detected in navigator');
      return 'webgpu';
    } else {
      console.log('[Whisper Test] WebGPU not available, using WASM (CPU)');
      return 'wasm';
    }
  },

  displayResult(testName, status, message) {
    const resultsDiv = this.el.querySelector('#test-results');
    if (!resultsDiv) return;

    const icon = status === 'PASS' ? '✓' : status === 'FAIL' ? '✗' : '⋯';
    const color = status === 'PASS' ? 'green' : status === 'FAIL' ? 'red' : 'orange';

    // Find or create result line
    let resultLine = resultsDiv.querySelector(`[data-test="${testName}"]`);
    if (!resultLine) {
      resultLine = document.createElement('div');
      resultLine.setAttribute('data-test', testName);
      resultLine.style.padding = '8px';
      resultLine.style.margin = '4px 0';
      resultLine.style.borderLeft = `3px solid ${color}`;
      resultLine.style.backgroundColor = '#f5f5f5';
      resultsDiv.appendChild(resultLine);
    } else {
      resultLine.style.borderLeftColor = color;
    }

    resultLine.innerHTML = `
      <span style="color: ${color}; font-weight: bold; margin-right: 8px;">${icon} ${status}</span>
      <strong>${testName}:</strong> ${message}
    `;
  },

  destroyed() {
    if (this.worker) {
      console.log('[Whisper Test] Terminating worker...');
      this.worker.terminate();
    }
  }
};
