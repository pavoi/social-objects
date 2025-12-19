// TagOverflow Hook
// Detects when tags overflow the container and shows a "+N" indicator

export default {
  mounted() {
    this.indicator = null
    this.resizeObserver = null

    this.updateOverflow = this.updateOverflow.bind(this)

    // Use ResizeObserver to detect size changes
    this.resizeObserver = new ResizeObserver(() => {
      this.updateOverflow()
    })

    this.resizeObserver.observe(this.el)

    // Initial update after a brief delay to let layout settle
    requestAnimationFrame(() => this.updateOverflow())
  },

  updated() {
    // Re-check after LiveView updates (e.g., tags added/removed)
    requestAnimationFrame(() => this.updateOverflow())
  },

  updateOverflow() {
    const container = this.el.querySelector(".tag-pills--table")
    if (!container) return

    const totalTags = parseInt(container.dataset.totalTags || "0", 10)
    const tags = container.querySelectorAll("[data-tag]")

    if (tags.length === 0) {
      if (this.indicator) {
        this.indicator.remove()
        this.indicator = null
      }
      return
    }

    // Remove existing indicator if any
    if (this.indicator) {
      this.indicator.remove()
      this.indicator = null
    }

    // Get the tag-cell (this.el) bounds for overflow detection
    const cellRect = this.el.getBoundingClientRect()
    const cellRight = cellRect.right - 8 // Account for padding

    // Count visible tags (those whose right edge is within the cell)
    let visibleCount = 0

    tags.forEach((tag) => {
      const tagRect = tag.getBoundingClientRect()
      // Tag is visible if its right edge is within the cell
      if (tagRect.right <= cellRight) {
        visibleCount++
      }
    })

    // Calculate hidden count (includes both clipped rendered tags and unrendered tags beyond max_visible)
    const hiddenCount = totalTags - visibleCount

    if (hiddenCount > 0) {
      // Create the indicator - append to tag-cell (this.el) so it's not clipped
      this.indicator = document.createElement("span")
      this.indicator.className = "tag-pill tag-pill--more tag-overflow-indicator"
      this.indicator.textContent = `+${hiddenCount}`

      // Append to the tag-cell element
      this.el.appendChild(this.indicator)
    }
  },

  disconnected() {
    this.cleanup()
  },

  destroyed() {
    this.cleanup()
  },

  cleanup() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
      this.resizeObserver = null
    }
    if (this.indicator) {
      this.indicator.remove()
      this.indicator = null
    }
  }
}
