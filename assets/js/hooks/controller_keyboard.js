/**
 * ControllerKeyboard Hook
 * Handles keyboard navigation for the session controller view.
 *
 * Navigation:
 * - Arrow keys (←→) for previous/next product (wraps around)
 * - Type number digits (0-9) to build a product number
 * - Automatically jumps after 500ms (allows double-digit entry)
 * - Press Enter to jump immediately
 * - Press Escape to cancel pending jump
 */
export default {
  mounted() {
    this.jumpBuffer = ""
    this.jumpTimeout = null

    this.handleKeydown = (e) => {
      // Pause keyboard control when any modal is open
      if (document.querySelector(".preset-modal-overlay")) return

      // Pause keyboard control when typing in input fields
      const activeElement = document.activeElement
      const isTyping =
        activeElement &&
        (activeElement.tagName === "INPUT" ||
          activeElement.tagName === "TEXTAREA" ||
          activeElement.isContentEditable)
      if (isTyping) return

      // Prevent default for navigation keys to avoid scrolling
      const navKeys = ["ArrowLeft", "ArrowRight"]
      if (navKeys.includes(e.code)) {
        e.preventDefault()
      }

      switch (e.code) {
        // Product navigation with left/right arrow keys (wraps around)
        case "ArrowRight":
          this.pushEvent("next_product", {})
          break

        case "ArrowLeft":
          this.pushEvent("previous_product", {})
          break

        default:
          // Number input for jump-to-product
          if (e.key >= "0" && e.key <= "9") {
            this.handleNumberInput(e.key)
          } else if (e.code === "Enter" && this.jumpBuffer) {
            this.executeJump()
          } else if (e.code === "Escape" && this.jumpBuffer) {
            this.clearJumpBuffer()
          }
      }
    }

    this.handleNumberInput = (digit) => {
      this.jumpBuffer += digit
      this.showJumpIndicator(this.jumpBuffer)

      // Auto-jump after 500ms debounce (allows double-digit entry)
      clearTimeout(this.jumpTimeout)
      this.jumpTimeout = setTimeout(() => {
        if (this.jumpBuffer) {
          this.executeJump()
        }
      }, 500)
    }

    this.executeJump = () => {
      this.pushEvent("jump_to_product", { position: this.jumpBuffer })
      this.clearJumpBuffer()
    }

    this.clearJumpBuffer = () => {
      this.jumpBuffer = ""
      clearTimeout(this.jumpTimeout)
      this.hideJumpIndicator()
    }

    this.showJumpIndicator = (value) => {
      let indicator = document.getElementById("controller-jump-indicator")
      if (!indicator) {
        indicator = document.createElement("div")
        indicator.id = "controller-jump-indicator"
        indicator.className = "controller-jump-indicator"
        document.body.appendChild(indicator)
      }
      indicator.textContent = value
      indicator.classList.add("visible")
    }

    this.hideJumpIndicator = () => {
      const indicator = document.getElementById("controller-jump-indicator")
      if (indicator) {
        indicator.classList.remove("visible")
      }
    }

    window.addEventListener("keydown", this.handleKeydown)
  },

  destroyed() {
    window.removeEventListener("keydown", this.handleKeydown)
    clearTimeout(this.jumpTimeout)
    const indicator = document.getElementById("controller-jump-indicator")
    if (indicator) {
      indicator.remove()
    }
  },
}
