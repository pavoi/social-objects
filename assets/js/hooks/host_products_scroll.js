// Hook for horizontal product scroll in host view
// Auto-scrolls to keep the current product visible (left-aligned) when panel expands

const HostProductsScroll = {
  mounted() {
    this.scrollToCurrentProduct();

    // Watch for panel expansion via class changes on parent
    const panel = this.el.closest(".host-products-panel");
    if (panel) {
      this.observer = new MutationObserver(() => {
        // When panel expands (collapsed class removed), scroll to current
        if (!panel.classList.contains("host-products-panel--collapsed")) {
          // Small delay to let animation start
          setTimeout(() => this.scrollToCurrentProduct(), 50);
        }
      });

      this.observer.observe(panel, {
        attributes: true,
        attributeFilter: ["class"]
      });
    }
  },

  updated() {
    this.scrollToCurrentProduct();
  },

  destroyed() {
    if (this.observer) {
      this.observer.disconnect();
    }
  },

  scrollToCurrentProduct() {
    const activeCard = this.el.querySelector(".host-product-card--active");
    if (activeCard) {
      // Scroll so active card is at the left edge with some padding
      this.el.scrollLeft = activeCard.offsetLeft - 16;
    }
  }
};

export default HostProductsScroll;
