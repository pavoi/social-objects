// Pavoi JavaScript Hooks for LiveView

import SessionHostKeyboard from "./hooks/session_host_keyboard"
import ImageCarouselDrag from "./hooks/image_carousel_drag"
import ProductContextMenu from "./hooks/product_context_menu"
import ProductEditModalKeyboard from "./hooks/product_edit_modal_keyboard"
import ProductSortable from "./hooks/product_sortable"
import ThemeToggle from "./hooks/theme_toggle"
import MessageInput from "./hooks/message_input"
import VariantOverflow from "./hooks/variant_overflow"
import ControllerHaptic from "./hooks/controller_haptic"
import ControllerKeyboard from "./hooks/controller_keyboard"
import HostProductsScroll from "./hooks/host_products_scroll"
import ViewerChart from "./hooks/viewer_chart"
import ConfirmDelete from "./hooks/confirm_delete"
import TagPickerPosition from "./hooks/tag_picker_position"
import ColumnResize from "./hooks/column_resize"
import TagOverflow from "./hooks/tag_overflow"
import ImageLightbox from "./hooks/image_lightbox"
import SentimentChart from "./hooks/sentiment_chart"
import CategoryChart from "./hooks/category_chart"
import TemplateEditor from "./hooks/template_editor"

// Lazy-loaded VoiceControl hook wrapper
// Only loads the full voice_control.js when hook actually mounts (feature flag enabled)
let VoiceControlImpl = null
const VoiceControl = {
  async mounted() {
    if (!VoiceControlImpl) {
      const module = await import('./hooks/voice_control')
      VoiceControlImpl = module.default
    }
    // Copy all methods from the real implementation to this instance
    Object.keys(VoiceControlImpl).forEach(key => {
      if (key !== 'mounted') {
        this[key] = VoiceControlImpl[key].bind(this)
      }
    })
    // Call the real mounted
    return VoiceControlImpl.mounted.call(this)
  }
}

const Hooks = {
  SessionHostKeyboard,
  ImageCarouselDrag,
  ProductContextMenu,
  ProductEditModalKeyboard,
  ProductSortable,
  ThemeToggle,
  MessageInput,
  VoiceControl,
  VariantOverflow,
  ControllerHaptic,
  ControllerKeyboard,
  HostProductsScroll,
  ViewerChart,
  ConfirmDelete,
  TagPickerPosition,
  ColumnResize,
  TagOverflow,
  ImageLightbox,
  SentimentChart,
  CategoryChart,
  TemplateEditor,
}

export default Hooks
