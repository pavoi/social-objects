// ProductSortable Hook
// Enables drag-and-drop reordering of products within session cards

import Sortable from "../../vendor/sortable"

export default {
  mounted() {
    const hook = this

    // Initialize SortableJS on this element
    const sortable = new Sortable(this.el, {
      animation: 150,           // Smooth animation duration in ms
      delay: 0,                 // No delay on desktop
      delayOnTouchOnly: true,   // Small delay on touch devices to prevent accidental drags
      touchStartThreshold: 5,   // px before drag starts on touch devices

      // CSS classes applied during drag states
      dragClass: "sortable-drag",      // Class on item being dragged
      ghostClass: "sortable-ghost",    // Class on placeholder/ghost element
      chosenClass: "sortable-chosen",  // Class when item is selected

      forceFallback: false,     // Use native HTML5 DnD when available

      // Callback fired when item is clicked (not dragged)
      onClick: (evt) => {
        // Find the clicked product item
        const productItem = evt.item
        const productId = productItem.querySelector('[data-product-id]')?.dataset.productId

        if (productId) {
          // Send event to LiveView to open the product modal
          hook.pushEventTo(hook.el, "show_edit_product_modal", {
            "product-id": productId
          })
        }
      },

      // Callback fired when drag operation ends
      onEnd: (evt) => {
        // evt.oldIndex = original position (0-based index)
        // evt.newIndex = new position (0-based index)

        // Don't send event if position didn't actually change
        if (evt.oldIndex === evt.newIndex) {
          return
        }

        // Collect all session_product IDs in their new order
        // Filter out elements without data-id (like the add button)
        const productIds = Array.from(this.el.children)
          .map(el => el.dataset.id)
          .filter(id => id !== undefined && id !== null)

        // Get session ID from the container's data attribute
        const sessionId = this.el.dataset.sessionId

        // Send reorder event to LiveView
        this.pushEventTo(this.el, "reorder_products", {
          session_id: sessionId,
          product_ids: productIds,
          old_index: evt.oldIndex,
          new_index: evt.newIndex
        })
      }
    })

    // Store sortable instance for cleanup
    this.sortable = sortable
  },

  // Cleanup when LiveView disconnects temporarily
  disconnected() {
    if (this.sortable) {
      this.sortable.destroy()
      this.sortable = null
    }
  },

  // Reinitialize when LiveView reconnects
  reconnected() {
    // Re-mount the sortable on reconnection
    this.mounted()
  },

  // Cleanup when the element is removed from the DOM permanently
  destroyed() {
    if (this.sortable) {
      this.sortable.destroy()
      this.sortable = null
    }
  }
}
