// NavCollapse Hook
// Dynamically switches navigation between horizontal links and dropdown
// when links would overflow the available space

const NavCollapse = {
  mounted() {
    this.nav = this.el
    this.linksContainer = this.el.querySelector('[data-nav-links]')
    this.links = this.el.querySelectorAll('[data-nav-link]')

    if (!this.linksContainer || this.links.length === 0) return

    // Store original link widths (measure once when expanded)
    this.linkWidths = []
    this.measureLinks()

    // Check on mount and resize
    this.checkOverflow()

    this.resizeObserver = new ResizeObserver(() => {
      this.checkOverflow()
    })
    this.resizeObserver.observe(this.nav)
  },

  measureLinks() {
    // Temporarily ensure links are visible for measurement
    const wasCollapsed = this.nav.classList.contains('navbar--collapsed')
    this.nav.classList.remove('navbar--collapsed')

    this.linkWidths = Array.from(this.links).map(link => {
      const style = getComputedStyle(link)
      const width = link.offsetWidth
      const marginLeft = parseFloat(style.marginLeft) || 0
      const marginRight = parseFloat(style.marginRight) || 0
      return width + marginLeft + marginRight
    })

    // Get gap between links
    const containerStyle = getComputedStyle(this.linksContainer)
    this.gap = parseFloat(containerStyle.gap) || 16

    // Calculate total width needed for all links
    this.totalLinksWidth = this.linkWidths.reduce((sum, w) => sum + w, 0) +
                           (this.linkWidths.length - 1) * this.gap

    if (wasCollapsed) {
      this.nav.classList.add('navbar--collapsed')
    }
  },

  checkOverflow() {
    // Get available width for nav (between start and end sections)
    const navStart = this.nav.querySelector('.navbar__start')
    const navEnd = this.nav.querySelector('.navbar__end')

    if (!navStart || !navEnd) return

    const navRect = this.nav.getBoundingClientRect()
    const startRect = navStart.getBoundingClientRect()
    const endRect = navEnd.getBoundingClientRect()

    // Available space between start and end with some padding
    const padding = 48 // minimum breathing room on each side
    const availableWidth = endRect.left - startRect.right - (padding * 2)

    // Compare with total links width
    if (this.totalLinksWidth > availableWidth) {
      this.nav.classList.add('navbar--collapsed')
    } else {
      this.nav.classList.remove('navbar--collapsed')
    }
  },

  destroyed() {
    if (this.resizeObserver) {
      this.resizeObserver.disconnect()
    }
  }
}

export default NavCollapse
