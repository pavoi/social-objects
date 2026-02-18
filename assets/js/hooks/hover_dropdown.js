const HoverDropdown = {
  mounted() {
    this.trigger = this.el.querySelector(".hover-dropdown__trigger")
    this.menu = this.el.querySelector(".hover-dropdown__menu")

    if (!this.trigger || !this.menu) {
      return
    }

    this.handleTriggerClick = this.handleTriggerClick.bind(this)
    this.handleDocumentClick = this.handleDocumentClick.bind(this)
    this.handleMenuClick = this.handleMenuClick.bind(this)
    this.handleEscape = this.handleEscape.bind(this)

    this.trigger.addEventListener("click", this.handleTriggerClick)
    this.menu.addEventListener("click", this.handleMenuClick)
    document.addEventListener("click", this.handleDocumentClick)
    document.addEventListener("keydown", this.handleEscape)
  },

  destroyed() {
    if (!this.trigger || !this.menu) {
      return
    }

    this.trigger.removeEventListener("click", this.handleTriggerClick)
    this.menu.removeEventListener("click", this.handleMenuClick)
    document.removeEventListener("click", this.handleDocumentClick)
    document.removeEventListener("keydown", this.handleEscape)
  },

  handleTriggerClick(event) {
    if (this.trigger.hasAttribute("phx-click")) {
      return
    }

    if (event.target.closest(".hover-dropdown__clear")) {
      return
    }

    event.preventDefault()
    this.el.classList.toggle("is-open")
  },

  handleMenuClick(event) {
    if (event.target.closest(".hover-dropdown__item")) {
      this.el.classList.remove("is-open")
    }
  },

  handleDocumentClick(event) {
    if (!this.el.contains(event.target)) {
      this.el.classList.remove("is-open")
    }
  },

  handleEscape(event) {
    if (event.key == "Escape") {
      this.el.classList.remove("is-open")
    }
  }
}

export default HoverDropdown
