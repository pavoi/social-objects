// Hook to position the tag picker and handle interactions
const TagPickerPosition = {
  colors: ['amber', 'blue', 'green', 'red', 'purple', 'gray'],

  mounted() {
    this.positionPicker()
    this.focusInput()

    const picker = this.el.querySelector('.tag-picker')
    const input = this.el.querySelector('#tag-picker-input')
    const source = this.el.dataset.source // 'table' or 'modal'

    // Handle input keydown for Enter and arrow keys
    this.handleInputKeydown = (e) => {
      if (e.key === 'Enter') {
        e.preventDefault()
        this.pushEvent('tag_picker_enter', {})
      } else if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
        e.preventDefault()
        this.cycleColor(e.key === 'ArrowRight' ? 1 : -1)
      }
    }
    if (input) {
      input.addEventListener('keydown', this.handleInputKeydown)
    }

    // Close on Escape key (force close even in modal mode)
    this.handleKeydown = (e) => {
      if (e.key === 'Escape') {
        this.pushEvent('close_tag_picker', { force: true })
      }
    }
    document.addEventListener('keydown', this.handleKeydown)

    // Close on click outside the picker
    // Query picker fresh each time since LiveView may have re-rendered it
    this.handleClick = (e) => {
      const currentPicker = document.querySelector('#tag-picker')
      if (currentPicker && !currentPicker.contains(e.target)) {
        this.pushEvent('close_tag_picker', {})
      }
    }
    // Use setTimeout to avoid catching the click that opened the picker
    setTimeout(() => {
      document.addEventListener('click', this.handleClick)
    }, 10)

    // Close on any scroll (except within the picker) - only for table source
    if (source !== 'modal') {
      this.handleScroll = (e) => {
        if (picker && picker.contains(e.target)) return
        this.pushEvent('close_tag_picker', {})
      }
      window.addEventListener('scroll', this.handleScroll, true)
    }
  },

  destroyed() {
    const input = this.el.querySelector('#tag-picker-input')

    if (input) {
      input.removeEventListener('keydown', this.handleInputKeydown)
    }
    document.removeEventListener('keydown', this.handleKeydown)
    document.removeEventListener('click', this.handleClick)
    if (this.handleScroll) {
      window.removeEventListener('scroll', this.handleScroll, true)
    }
  },

  updated() {
    this.positionPicker()
  },

  cycleColor(direction) {
    const selected = this.el.querySelector('.tag-picker__quick-color--selected')
    if (!selected) return

    const currentColor = this.colors.find(c => selected.classList.contains(`color-accent--${c}`))
    if (!currentColor) return

    const currentIndex = this.colors.indexOf(currentColor)
    const newIndex = (currentIndex + direction + this.colors.length) % this.colors.length
    const newColor = this.colors[newIndex]

    this.pushEvent('select_new_tag_color', { color: newColor })
  },

  positionPicker() {
    const picker = this.el.querySelector('.tag-picker')
    if (!picker) return

    const creatorId = picker.dataset.creatorId
    const source = this.el.dataset.source
    if (!creatorId) return

    // Find target based on source
    let target
    if (source === 'modal') {
      target = document.querySelector(`[data-modal-tag-target="${creatorId}"]`)
    } else {
      target = document.querySelector(`[data-tag-cell-id="${creatorId}"]`)
    }

    if (!target) return

    const rect = target.getBoundingClientRect()
    picker.style.position = 'fixed'
    picker.style.top = `${rect.bottom + 4}px`
    picker.style.left = `${rect.left}px`
  },

  focusInput() {
    const input = this.el.querySelector('#tag-picker-input')
    if (input) {
      // Small delay to ensure DOM is ready
      setTimeout(() => input.focus(), 10)
    }
  }
}

export default TagPickerPosition
