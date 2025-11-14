/**
 * ProductEditModalKeyboard Hook
 * Handles keyboard navigation for the Edit Product modal.
 *
 * Arrow Keys:
 * - Left arrow (←) for previous image
 * - Right arrow (→) for next image
 */
export default {
  mounted() {
    this.handleKeydown = (e) => {
      // Only handle if the modal is visible (checking parent element existence)
      const modal = document.getElementById('edit-product-modal')
      if (!modal) return

      switch (e.code) {
        case 'ArrowLeft':
          e.preventDefault()
          this.pushEvent("previous_image", {})
          break

        case 'ArrowRight':
          e.preventDefault()
          this.pushEvent("next_image", {})
          break
      }
    }

    window.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeydown)
  }
}
