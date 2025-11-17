// Hook for message input textarea
// Handles Enter key to submit the form instead of adding a newline

const MessageInput = {
  mounted() {
    this.el.addEventListener("keydown", (e) => {
      // If Enter is pressed without Shift, submit the form
      if (e.key === "Enter" && !e.shiftKey) {
        e.preventDefault();
        // Find the parent form and submit it
        const form = this.el.closest("form");
        if (form) {
          // Trigger the form submit event which will call phx-submit
          form.dispatchEvent(new Event("submit", { bubbles: true, cancelable: true }));
        }
      }
      // Shift+Enter allows newlines (default behavior)
    });
  }
};

export default MessageInput;
