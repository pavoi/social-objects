/**
 * ImageCarouselDrag Hook
 * Enables drag/swipe navigation for image carousels.
 * Supports touch events only (mouse drag disabled).
 */
export default {
  mounted() {
    this.isDragging = false
    this.startX = 0
    this.currentX = 0
    this.threshold = 50 // Minimum drag distance (px) to trigger navigation

    // Get current index and total images from data attributes
    this.getCurrentState = () => {
      const currentIndex = parseInt(this.el.dataset.currentIndex || '0')
      const totalImages = parseInt(this.el.dataset.totalImages || '0')
      const mode = this.el.dataset.mode || 'compact'
      const target = this.el.dataset.target || null
      return { currentIndex, totalImages, mode, target }
    }

    // Prevent default drag behavior on images
    this.handleDragStart = (e) => {
      e.preventDefault()
      return false
    }

    // Touch events
    this.handleTouchStart = (e) => {
      this.isDragging = true
      this.startX = e.touches[0].clientX
      this.currentX = this.startX
    }

    this.handleTouchMove = (e) => {
      if (!this.isDragging) return
      this.currentX = e.touches[0].clientX

      // Prevent default to stop page scrolling during horizontal drag
      const deltaX = Math.abs(this.currentX - this.startX)
      if (deltaX > 10) {
        e.preventDefault()
      }
    }

    this.handleTouchEnd = (e) => {
      if (!this.isDragging) return

      const deltaX = this.currentX - this.startX
      this.isDragging = false

      this.handleDragEnd(deltaX)
    }

    // Handle drag end logic
    this.handleDragEnd = (deltaX) => {
      const { currentIndex, totalImages, target } = this.getCurrentState()

      // Determine direction and check if threshold met
      if (Math.abs(deltaX) < this.threshold) {
        return // Not enough movement to trigger navigation
      }

      let newIndex = currentIndex

      if (deltaX > 0) {
        // Dragged right = previous image
        newIndex = Math.max(0, currentIndex - 1)
      } else {
        // Dragged left = next image
        newIndex = Math.min(totalImages - 1, currentIndex + 1)
      }

      // Only send event if index changed
      if (newIndex !== currentIndex) {
        if (target) {
          // Send to specific LiveComponent using integer CID
          const cid = parseInt(target)
          this.pushEventTo(cid, "goto_image", { index: newIndex })
        } else {
          // Send to LiveView
          this.pushEvent("goto_image", { index: newIndex })
        }
      }
    }

    // Handle scroll events to update dots based on visible image
    this.handleScroll = () => {
      const wrapper = this.el.querySelector('.image-carousel__image-wrapper')
      if (!wrapper) return

      const images = wrapper.querySelectorAll('.image-carousel__image')
      if (!images || images.length === 0) return

      // Calculate which image is currently centered
      const scrollLeft = wrapper.scrollLeft
      const containerWidth = wrapper.offsetWidth
      const centerX = scrollLeft + containerWidth / 2

      let currentIndex = 0
      images.forEach((img, index) => {
        const imgLeft = img.offsetLeft
        const imgCenter = imgLeft + img.offsetWidth / 2

        // Find the image whose center is closest to the container center
        if (Math.abs(imgCenter - centerX) < containerWidth / 2) {
          currentIndex = index
        }
      })

      // Update data attribute and dots
      this.el.dataset.currentIndex = currentIndex
      this.updateDots(currentIndex)
    }

    // Update dot active states
    this.updateDots = (activeIndex) => {
      const dots = this.el.querySelectorAll('.image-carousel__dot')
      dots.forEach((dot, index) => {
        if (index === activeIndex) {
          dot.classList.add('image-carousel__dot--active')
          dot.setAttribute('aria-current', 'true')
        } else {
          dot.classList.remove('image-carousel__dot--active')
          dot.setAttribute('aria-current', 'false')
        }
      })
    }

    // Add event listeners
    this.el.addEventListener('dragstart', this.handleDragStart)

    // Listen to scroll events on the image wrapper
    const wrapper = this.el.querySelector('.image-carousel__image-wrapper')
    if (wrapper) {
      wrapper.addEventListener('scroll', this.handleScroll, { passive: true })
    }

    // Touch events with passive: false to allow preventDefault()
    this.el.addEventListener('touchstart', this.handleTouchStart, { passive: false })
    this.el.addEventListener('touchmove', this.handleTouchMove, { passive: false })
    this.el.addEventListener('touchend', this.handleTouchEnd, { passive: false })
  },

  updated() {
    // Scroll to current image in both compact and full modes
    const { currentIndex, mode } = this.getCurrentState()
    const wrapper = this.el.querySelector('.image-carousel__image-wrapper')
    const images = wrapper?.querySelectorAll('.image-carousel__image')

    if (images && images[currentIndex]) {
      images[currentIndex].scrollIntoView({
        behavior: 'smooth',
        block: 'nearest',
        inline: 'center'
      })
    }
  },

  destroyed() {
    // Clean up event listeners
    this.el.removeEventListener('dragstart', this.handleDragStart)

    const wrapper = this.el.querySelector('.image-carousel__image-wrapper')
    if (wrapper) {
      wrapper.removeEventListener('scroll', this.handleScroll)
    }

    this.el.removeEventListener('touchstart', this.handleTouchStart)
    this.el.removeEventListener('touchmove', this.handleTouchMove)
    this.el.removeEventListener('touchend', this.handleTouchEnd)
  }
}
