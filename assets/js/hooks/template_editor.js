/**
 * TemplateEditor Hook
 *
 * Provides a visual block-based email template editor using GrapesJS
 * with the newsletter preset optimized for email HTML output.
 *
 * GrapesJS is lazy-loaded when this hook mounts to reduce main bundle size.
 */

// Lazy-loaded modules (cached after first load)
let grapesjs = null
let newsletterPlugin = null
let cssLoaded = false

/**
 * Load GrapesJS and its dependencies on demand
 */
async function loadGrapesJS() {
  if (grapesjs && newsletterPlugin) return

  const [grapes, newsletter] = await Promise.all([
    import('grapesjs'),
    import('grapesjs-preset-newsletter')
  ])

  grapesjs = grapes.default
  newsletterPlugin = newsletter.default

  // Inject CSS if not already loaded
  if (!cssLoaded) {
    await import('grapesjs/dist/css/grapes.min.css')
    cssLoaded = true
  }
}

/**
 * Extract body content from a full HTML document.
 */
function extractBodyContent(html) {
  if (!html || typeof html !== 'string') return ''

  const bodyMatch = html.match(/<body[^>]*>([\s\S]*)<\/body>/i)
  if (bodyMatch) {
    return bodyMatch[1].trim()
  }

  if (html.includes('<!DOCTYPE') || html.includes('<html')) {
    const htmlTagMatch = html.match(/<html[^>]*>([\s\S]*)<\/html>/i)
    if (htmlTagMatch) {
      let content = htmlTagMatch[1]
      content = content.replace(/<head[^>]*>[\s\S]*<\/head>/i, '')
      return content.trim()
    }
  }

  return html.trim()
}

/**
 * Wrap body content in a full HTML email document.
 */
function wrapInHtmlDocument(bodyContent) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <meta http-equiv="X-UA-Compatible" content="IE=edge">
  <title>Email</title>
</head>
<body style="margin: 0; padding: 0; background-color: #f5f5f5;">
${bodyContent}
</body>
</html>`
}

function debounce(fn, delay) {
  let timer = null
  return (...args) => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => fn(...args), delay)
  }
}

export default {
  async mounted() {
    // Lazy load GrapesJS (reduces main bundle by ~200-300KB)
    await loadGrapesJS()

    const rawHtml = this.el.dataset.htmlContent || ''
    const initialContent = extractBodyContent(rawHtml)

    // Default email template if no content
    const defaultContent = `
      <table style="width: 100%; max-width: 600px; margin: 0 auto; background-color: #ffffff;">
        <tr>
          <td style="padding: 40px 20px; text-align: center;">
            <h1 style="margin: 0 0 20px 0; color: #333333;">Welcome!</h1>
            <p style="margin: 0; color: #666666;">Start building your email template by dragging blocks from the right panel.</p>
          </td>
        </tr>
      </table>
    `

    // Initialize GrapesJS with newsletter preset
    this.editor = grapesjs.init({
      container: this.el,
      height: '100%',
      width: 'auto',
      fromElement: false,
      storageManager: false,

      // Newsletter preset plugin
      plugins: [newsletterPlugin],
      pluginsOpts: {
        [newsletterPlugin]: {
          inlineCss: true,
        }
      },

      // Load initial content
      components: initialContent || defaultContent,

      // Asset manager
      assetManager: {
        embedAsBase64: true,
        upload: false,
      },
    })

    // Debounced update function
    const pushHtmlUpdate = debounce(() => {
      if (!this.editor) return

      try {
        let html = null
        const hasCommand = this.editor.Commands.has('gjs-get-inlined-html')
        if (hasCommand) {
          html = this.editor.runCommand('gjs-get-inlined-html')
        }

        if (!html) {
          const bodyHtml = this.editor.getHtml()
          const css = this.editor.getCss()
          html = css ? `<style>${css}</style>${bodyHtml}` : bodyHtml
        }

        if (html && html.trim()) {
          const fullDocument = wrapInHtmlDocument(html)
          this.pushEvent('template_html_updated', { html: fullDocument })
        }
      } catch (err) {
        console.error('[TemplateEditor] Error exporting HTML:', err)
      }
    }, 800)

    // Listen for content changes
    this.editor.on('component:update', pushHtmlUpdate)
    this.editor.on('component:add', pushHtmlUpdate)
    this.editor.on('component:remove', pushHtmlUpdate)
    this.editor.on('component:clone', pushHtmlUpdate)
    this.editor.on('component:drag:end', pushHtmlUpdate)
    this.editor.on('style:update', pushHtmlUpdate)
  },

  destroyed() {
    if (this.editor) {
      this.editor.destroy()
      this.editor = null
    }
  }
}
