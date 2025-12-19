// ColumnResize Hook
// Enables drag-to-resize columns in tables, with localStorage persistence
//
// Usage: Add phx-hook="ColumnResize" and data-table-id="unique-id" to the <table> element
// Optionally add data-resizable="false" to any <th> to disable resizing for that column

const STORAGE_PREFIX = "table-columns-"
const MIN_COLUMN_WIDTH = 50

export default {
  mounted() {
    this.tableId = this.el.dataset.tableId
    if (!this.tableId) {
      console.warn("ColumnResize: Missing data-table-id attribute")
      return
    }

    this.resizing = null
    this.resizeHandles = []

    // Debounce save to avoid excessive localStorage writes
    this.saveTimeout = null

    // Bind event handlers for cleanup
    this.handleMouseMove = this.onMouseMove.bind(this)
    this.handleMouseUp = this.onMouseUp.bind(this)
    this.handleTouchMove = this.onTouchMove.bind(this)
    this.handleTouchEnd = this.onTouchEnd.bind(this)

    // Initialize
    this.initializeColumns()
    this.restoreColumnWidths()
    this.createResizeHandles()
  },

  initializeColumns() {
    const headers = this.getResizableHeaders()

    // Set table-layout to fixed for predictable sizing
    this.el.style.tableLayout = "fixed"

    // Assign column IDs if not present
    headers.forEach((th, index) => {
      if (!th.dataset.columnId) {
        th.dataset.columnId = `col-${index}`
      }
      // Make headers position relative for handle positioning
      th.style.position = "relative"
    })
  },

  getResizableHeaders() {
    const allHeaders = Array.from(this.el.querySelectorAll("thead th"))
    return allHeaders.filter(th => th.dataset.resizable !== "false")
  },

  getAllHeaders() {
    return Array.from(this.el.querySelectorAll("thead th"))
  },

  restoreColumnWidths() {
    const saved = this.getSavedWidths()
    if (!saved) return

    const headers = this.getAllHeaders()
    headers.forEach(th => {
      const columnId = th.dataset.columnId
      if (columnId && saved[columnId]) {
        th.style.width = `${saved[columnId]}px`
      }
    })
  },

  getSavedWidths() {
    try {
      const stored = localStorage.getItem(STORAGE_PREFIX + this.tableId)
      return stored ? JSON.parse(stored) : null
    } catch (e) {
      console.warn("ColumnResize: Failed to read from localStorage", e)
      return null
    }
  },

  saveColumnWidths() {
    // Debounce saves
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout)
    }

    this.saveTimeout = setTimeout(() => {
      const headers = this.getAllHeaders()
      const widths = {}

      headers.forEach(th => {
        const columnId = th.dataset.columnId
        if (columnId) {
          widths[columnId] = th.offsetWidth
        }
      })

      try {
        localStorage.setItem(STORAGE_PREFIX + this.tableId, JSON.stringify(widths))
      } catch (e) {
        console.warn("ColumnResize: Failed to save to localStorage", e)
      }
    }, 100)
  },

  createResizeHandles() {
    // Clean up any existing handles first
    this.removeResizeHandles()

    const headers = this.getResizableHeaders()

    headers.forEach((th, index) => {
      const handle = document.createElement("div")
      handle.className = "column-resize-handle"
      handle.addEventListener("mousedown", (e) => this.onMouseDown(e, th, handle))
      handle.addEventListener("touchstart", (e) => this.onTouchStart(e, th, handle), { passive: false })

      th.appendChild(handle)
      this.resizeHandles.push(handle)
    })
  },

  removeResizeHandles() {
    this.resizeHandles.forEach(handle => handle.remove())
    this.resizeHandles = []
  },

  onMouseDown(e, th, handle) {
    e.preventDefault()
    e.stopPropagation()
    this.startResize(e.clientX, th, handle)

    document.addEventListener("mousemove", this.handleMouseMove)
    document.addEventListener("mouseup", this.handleMouseUp)
  },

  onTouchStart(e, th, handle) {
    if (e.touches.length !== 1) return
    e.preventDefault()
    e.stopPropagation()

    this.startResize(e.touches[0].clientX, th, handle)

    document.addEventListener("touchmove", this.handleTouchMove, { passive: false })
    document.addEventListener("touchend", this.handleTouchEnd)
  },

  startResize(clientX, th, handle) {
    this.resizing = {
      th: th,
      handle: handle,
      startX: clientX,
      startWidth: th.offsetWidth
    }

    // Add resizing class to table for visual feedback
    this.el.classList.add("is-resizing")
    // Add active class only to the handle being dragged
    handle.classList.add("is-active")
    document.body.style.cursor = "col-resize"
    document.body.style.userSelect = "none"
  },

  onMouseMove(e) {
    if (!this.resizing) return
    this.updateResize(e.clientX)
  },

  onTouchMove(e) {
    if (!this.resizing || e.touches.length !== 1) return
    e.preventDefault()
    this.updateResize(e.touches[0].clientX)
  },

  updateResize(clientX) {
    const { th, startX, startWidth } = this.resizing
    const delta = clientX - startX
    const newWidth = Math.max(MIN_COLUMN_WIDTH, startWidth + delta)

    th.style.width = `${newWidth}px`
  },

  onMouseUp() {
    document.removeEventListener("mousemove", this.handleMouseMove)
    document.removeEventListener("mouseup", this.handleMouseUp)
    this.endResize()
  },

  onTouchEnd() {
    document.removeEventListener("touchmove", this.handleTouchMove)
    document.removeEventListener("touchend", this.handleTouchEnd)
    this.endResize()
  },

  endResize() {
    if (!this.resizing) return

    this.el.classList.remove("is-resizing")
    // Remove active class from the handle
    if (this.resizing.handle) {
      this.resizing.handle.classList.remove("is-active")
    }
    document.body.style.cursor = ""
    document.body.style.userSelect = ""

    this.saveColumnWidths()
    this.resizing = null
  },

  // Handle LiveView updates - recreate handles if DOM changes
  updated() {
    this.createResizeHandles()
    this.restoreColumnWidths()
  },

  disconnected() {
    this.cleanup()
  },

  destroyed() {
    this.cleanup()
  },

  cleanup() {
    if (this.saveTimeout) {
      clearTimeout(this.saveTimeout)
    }

    document.removeEventListener("mousemove", this.handleMouseMove)
    document.removeEventListener("mouseup", this.handleMouseUp)
    document.removeEventListener("touchmove", this.handleTouchMove)
    document.removeEventListener("touchend", this.handleTouchEnd)

    this.removeResizeHandles()

    if (this.resizing) {
      document.body.style.cursor = ""
      document.body.style.userSelect = ""
    }
  }
}
