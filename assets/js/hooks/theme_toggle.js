/**
 * ThemeToggle Hook
 *
 * Manages light/dark theme switching with:
 * - System preference detection on first visit
 * - User override persisted in localStorage
 * - Automatic response to OS theme changes
 * - Smooth theme transitions
 */

const ThemeToggle = {
  mounted() {
    // Verify initial theme is applied (inline script should have set it)
    this.verifyTheme();

    // Listen for clicks on the button itself
    this.el.addEventListener("click", () => {
      this.toggleTheme();
    });

    // Watch for system preference changes
    this.watchSystemPreference();
  },

  /**
   * Verify that the theme class is applied correctly on mount
   */
  verifyTheme() {
    const theme = this.getCurrentTheme();
    this.applyTheme(theme);
  },

  /**
   * Get the current theme from localStorage or system preference
   * @returns {string} 'light' or 'dark'
   */
  getCurrentTheme() {
    // Check for user preference in localStorage
    const saved = localStorage.getItem('theme');
    if (saved === 'light' || saved === 'dark') {
      return saved;
    }

    // Fall back to system preference
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  },

  /**
   * Toggle between light and dark themes
   */
  toggleTheme() {
    const current = document.documentElement.classList.contains('dark') ? 'dark' : 'light';
    const newTheme = current === 'dark' ? 'light' : 'dark';

    this.applyTheme(newTheme);
    localStorage.setItem('theme', newTheme);
  },

  /**
   * Apply the specified theme by updating the document class
   * @param {string} theme - 'light' or 'dark'
   */
  applyTheme(theme) {
    const html = document.documentElement;

    if (theme === 'dark') {
      html.classList.add('dark');
      html.classList.remove('light');
    } else {
      html.classList.add('light');
      html.classList.remove('dark');
    }

    // Update aria attribute for accessibility
    html.setAttribute('data-theme', theme);

    // Update theme-color for browser chrome (iOS Safari status bar, etc.)
    const themeColor = theme === 'dark' ? '#1A1A1A' : '#FFFFFF';
    document.querySelector('meta[name="theme-color"]')?.setAttribute('content', themeColor);
  },

  /**
   * Watch for system preference changes and auto-switch if no user preference
   */
  watchSystemPreference() {
    const darkModeQuery = window.matchMedia('(prefers-color-scheme: dark)');

    darkModeQuery.addEventListener('change', (e) => {
      // Only auto-switch if user hasn't set a manual preference
      const userPreference = localStorage.getItem('theme');
      if (!userPreference) {
        const newTheme = e.matches ? 'dark' : 'light';
        this.applyTheme(newTheme);
      }
    });
  }
};

export default ThemeToggle;
