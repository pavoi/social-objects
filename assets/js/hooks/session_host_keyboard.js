/**
 * SessionHostKeyboard Hook
 * Handles keyboard navigation for the session host view.
 *
 * Primary Navigation (Direct Jumps):
 * - Type number digits (0-9) to build a product number
 * - Press Enter to jump to that product
 * - Home/End to jump to first/last
 *
 * Convenience Navigation (Sequential):
 * - Arrow keys (↑↓) for previous/next product
 * - Arrow keys (←→) for previous/next image
 * - Space for next product
 */
export default {
  mounted() {
    this.jumpBuffer = ""
    this.jumpTimeout = null

    this.handleKeydown = (e) => {
      // Pause keyboard control when any modal is open
      if (document.getElementById('edit-product-modal')) return

      // Prevent default for navigation keys to avoid scrolling
      const navKeys = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Space', 'Home', 'End']
      if (navKeys.includes(e.code)) {
        e.preventDefault()
      }

      switch (e.code) {
        // PRIMARY NAVIGATION: Jump to first/last
        case 'Home':
          this.pushEvent("jump_to_first", {})
          break

        case 'End':
          this.pushEvent("jump_to_last", {})
          break

        // CONVENIENCE: Sequential product navigation with arrow keys
        case 'ArrowDown':
        case 'KeyJ':
          this.pushEvent("next_product", {})
          break

        case 'ArrowUp':
        case 'KeyK':
          this.pushEvent("previous_product", {})
          break

        case 'Space':
          e.preventDefault() // Prevent page scroll
          this.pushEvent("next_product", {})
          break

        // IMAGE navigation (always sequential)
        case 'ArrowRight':
        case 'KeyL':
          this.pushEvent("next_image", {})
          break

        case 'ArrowLeft':
        case 'KeyH':
          this.pushEvent("previous_image", {})
          break

        default:
          // PRIMARY NAVIGATION: Number input for jump-to-product
          if (e.key >= '0' && e.key <= '9') {
            this.handleNumberInput(e.key)
          } else if (e.code === 'Enter' && this.jumpBuffer) {
            this.pushEvent("jump_to_product", {position: this.jumpBuffer})
            this.jumpBuffer = ""
            this.updateJumpDisplay("")
            clearTimeout(this.jumpTimeout)
          } else if (e.code === 'Escape' && this.jumpBuffer) {
            // Clear buffer on Escape
            this.jumpBuffer = ""
            this.updateJumpDisplay("")
            clearTimeout(this.jumpTimeout)
          }
      }
    }

    this.handleNumberInput = (digit) => {
      this.jumpBuffer += digit
      this.updateJumpDisplay(this.jumpBuffer)

      // Clear buffer after 2 seconds of inactivity
      clearTimeout(this.jumpTimeout)
      this.jumpTimeout = setTimeout(() => {
        this.jumpBuffer = ""
        this.updateJumpDisplay("")
      }, 2000)
    }

    this.updateJumpDisplay = (_value) => {
      // Update display (could be enhanced with a visible indicator)
      // Parameter prefixed with _ to indicate intentionally unused (reserved for future enhancement)
    }

    window.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeydown)
    clearTimeout(this.jumpTimeout)
  }
}
