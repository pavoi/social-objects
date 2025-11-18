# Hudson App Icons

This directory contains the generated icon set for the Hudson desktop application.

## Regenerating Icons

To regenerate all platform icons from the source:

```bash
cd src-tauri
cargo tauri icon app-icon.png
```

This will create:
- `icon.icns` - macOS app icon
- `icon.ico` - Windows app icon  
- Various PNG sizes for different platforms

## Source Icon

**Location:** `src-tauri/app-icon.png`

**Requirements:** 1024x1024px PNG with transparency

The current icon is a placeholder. Replace `app-icon.png` with your actual brand logo and regenerate.
