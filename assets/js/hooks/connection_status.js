/**
 * ConnectionStatus Hook
 * Shows connection status indicator for real-time sync.
 */
export default {
  mounted() {
    window.addEventListener("phx:page-loading-start", () => {
      this.el.innerHTML = '<span class="reconnecting">● Reconnecting...</span>'
    })

    window.addEventListener("phx:page-loading-stop", () => {
      this.el.innerHTML = '<span class="connected">● Connected</span>'
    })

    // Handle disconnection
    window.addEventListener("phx:disconnected", () => {
      this.el.innerHTML = '<span class="disconnected">● Disconnected</span>'
    })

    // Handle successful connection
    window.addEventListener("phx:connected", () => {
      this.el.innerHTML = '<span class="connected">● Connected</span>'
    })
  }
}
