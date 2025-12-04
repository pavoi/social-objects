/**
 * ControllerHaptic Hook
 * Provides haptic feedback for touch interactions on controller view.
 *
 * Uses the Vibration API (navigator.vibrate) which is widely supported
 * on Android and partially on iOS (via system haptics).
 */
export default {
  mounted() {
    // Check for haptic support
    this.supportsHaptic = "vibrate" in navigator

    // Bind click handler
    this.handleClick = this.handleClick.bind(this)
    this.el.addEventListener("click", this.handleClick, true)
  },

  handleClick(event) {
    // Find closest element with data-haptic attribute
    const hapticElement = event.target.closest('[data-haptic="true"]')

    if (hapticElement && this.supportsHaptic) {
      // Light haptic feedback (10ms vibration)
      navigator.vibrate(10)
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick, true)
  },
}
