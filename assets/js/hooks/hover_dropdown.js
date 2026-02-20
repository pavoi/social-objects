const HoverDropdown = {
  mounted() {
    this.handleTriggerClick = this.handleTriggerClick.bind(this)
    this.handleTriggerPointerUp = this.handleTriggerPointerUp.bind(this)
    this.handleDocumentClick = this.handleDocumentClick.bind(this)
    this.handleMenuClick = this.handleMenuClick.bind(this)
    this.handleEscape = this.handleEscape.bind(this)
    this.handleSearchInput = this.handleSearchInput.bind(this)
    this.handleSearchKeydown = this.handleSearchKeydown.bind(this)
    this.lastPointerTriggerAt = 0

    this.rebindInteractiveElements()

    document.addEventListener("click", this.handleDocumentClick)
    document.addEventListener("keydown", this.handleEscape)

    this.wasOpen = this.el.classList.contains("is-open")
    this.refreshSearchElements()
  },

  updated() {
    this.rebindInteractiveElements()
    this.refreshSearchElements()
    this.syncOpenState()
  },

  destroyed() {
    this.teardownInteractiveElements()

    document.removeEventListener("click", this.handleDocumentClick)
    document.removeEventListener("keydown", this.handleEscape)
    this.teardownSearchInput()
  },

  rebindInteractiveElements() {
    const nextTrigger = this.el.querySelector(".hover-dropdown__trigger")
    const nextMenu = this.el.querySelector(".hover-dropdown__menu")

    if (nextTrigger !== this.trigger) {
      if (this.trigger) {
        this.trigger.removeEventListener("click", this.handleTriggerClick)
        this.trigger.removeEventListener("pointerup", this.handleTriggerPointerUp)
      }

      this.trigger = nextTrigger

      if (this.trigger) {
        this.trigger.addEventListener("click", this.handleTriggerClick)
        this.trigger.addEventListener("pointerup", this.handleTriggerPointerUp)
      }
    }

    if (nextMenu !== this.menu) {
      if (this.menu) {
        this.menu.removeEventListener("click", this.handleMenuClick)
      }

      this.menu = nextMenu

      if (this.menu) {
        this.menu.addEventListener("click", this.handleMenuClick)
      }
    }
  },

  teardownInteractiveElements() {
    if (this.trigger) {
      this.trigger.removeEventListener("click", this.handleTriggerClick)
      this.trigger.removeEventListener("pointerup", this.handleTriggerPointerUp)
    }

    if (this.menu) {
      this.menu.removeEventListener("click", this.handleMenuClick)
    }
  },

  handleTriggerPointerUp(event) {
    // Use pointerup for tap reliability and ignore the synthetic click that follows.
    this.lastPointerTriggerAt = Date.now()
    this.handleTriggerClick(event)
  },

  handleTriggerClick(event) {
    if (event.type == "click" && Date.now() - this.lastPointerTriggerAt < 350) {
      return
    }

    const trigger = event.target.closest(".hover-dropdown__trigger") || this.trigger

    if (!trigger) {
      return
    }

    if (trigger.hasAttribute("phx-click")) {
      return
    }

    if (event.target.closest(".hover-dropdown__clear")) {
      return
    }

    event.preventDefault()
    this.el.classList.toggle("is-open")
    this.syncOpenState()
  },

  handleMenuClick(event) {
    if (event.target.closest(".hover-dropdown__item")) {
      this.el.classList.remove("is-open")
      this.resetSearch()
      this.wasOpen = false
    }
  },

  handleDocumentClick(event) {
    if (!this.el.contains(event.target)) {
      this.closeMenu()
    }
  },

  handleEscape(event) {
    if (event.key == "Escape") {
      this.closeMenu()
    }
  },

  handleSearchInput(event) {
    this.filterOptions(event.target.value || "")
  },

  handleSearchKeydown(event) {
    if (event.key == "Escape") {
      this.closeMenu()

      if (this.trigger) {
        this.trigger.focus()
      }
    }
  },

  closeMenu() {
    this.el.classList.remove("is-open")
    this.resetSearch()
    this.wasOpen = false
  },

  syncOpenState() {
    const isOpen = this.el.classList.contains("is-open")

    if (isOpen && !this.wasOpen) {
      this.focusSearchInput()
    }

    if (!isOpen && this.wasOpen) {
      this.resetSearch()
    }

    this.wasOpen = isOpen
  },

  refreshSearchElements() {
    const nextInput = this.el.querySelector("[data-hover-dropdown-search]")
    const nextEmptyState = this.el.querySelector("[data-hover-dropdown-empty]")
    this.optionElements = Array.from(this.el.querySelectorAll("[data-hover-dropdown-option]"))

    if (this.searchInput && this.searchInput !== nextInput) {
      this.teardownSearchInput()
    }

    this.searchInput = nextInput
    this.emptyState = nextEmptyState

    if (!this.searchInput) {
      return
    }

    this.searchInput.removeEventListener("input", this.handleSearchInput)
    this.searchInput.removeEventListener("keydown", this.handleSearchKeydown)
    this.searchInput.addEventListener("input", this.handleSearchInput)
    this.searchInput.addEventListener("keydown", this.handleSearchKeydown)

    this.filterOptions(this.searchInput.value || "")
  },

  teardownSearchInput() {
    if (!this.searchInput) {
      return
    }

    this.searchInput.removeEventListener("input", this.handleSearchInput)
    this.searchInput.removeEventListener("keydown", this.handleSearchKeydown)
  },

  resetSearch() {
    if (!this.searchInput) {
      return
    }

    if (this.searchInput.value != "") {
      this.searchInput.value = ""
    }

    this.filterOptions("")
  },

  focusSearchInput() {
    if (!this.searchInput) {
      return
    }

    window.requestAnimationFrame(() => {
      if (!this.el.classList.contains("is-open")) {
        return
      }

      this.searchInput.focus()
      this.searchInput.select()
    })
  },

  filterOptions(rawQuery) {
    if (!this.searchInput || !this.optionElements) {
      return
    }

    const query = rawQuery.trim().toLowerCase()
    let visibleCount = 0

    this.optionElements.forEach(option => {
      const label = option.dataset.label || option.textContent.toLowerCase()
      const matches = query == "" || label.includes(query)
      option.hidden = !matches

      if (matches) {
        visibleCount += 1
      }
    })

    if (this.emptyState) {
      this.emptyState.hidden = visibleCount > 0
    }
  }
}

export default HoverDropdown
