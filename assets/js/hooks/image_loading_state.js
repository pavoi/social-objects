/**
 * ImageLoadingState Hook (for future LQIP implementation)
 * Manages progressive image loading with blur-to-sharp transition.
 */
export default {
  mounted() {
    const mainImage = this.el
    const placeholderId = `placeholder-${mainImage.id}`
    const skeletonId = `skeleton-${mainImage.id}`
    const placeholder = document.getElementById(placeholderId)
    const skeleton = document.getElementById(skeletonId)

    // Handle main image load
    const handleLoad = () => {
      mainImage.setAttribute('data-js-loading', 'false')
      if (placeholder) {
        placeholder.setAttribute('data-js-placeholder-loaded', 'true')
      }
      this.pushEvent("image_loaded", {id: mainImage.id})
    }

    mainImage.addEventListener('load', handleLoad)

    // Handle placeholder load (hide skeleton)
    if (placeholder) {
      placeholder.addEventListener('load', () => {
        if (skeleton) skeleton.style.display = 'none'
      })
    }

    // Trigger load if already cached
    if (mainImage.complete) {
      handleLoad()
    }
  },

  beforeUpdate() {
    // Reset loading state when src changes
    this.el.setAttribute('data-js-loading', 'true')
  }
}
