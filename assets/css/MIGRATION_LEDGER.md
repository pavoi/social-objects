# Tailwind Migration Ledger

## Rule Classification (current state)

- `theme token`: `assets/css/tailwind.css` (`@theme` + `.dark` token overrides)
- `base reset/element`: `assets/css/02-generic/reset.css`, `assets/css/02-generic/animations.css`, `assets/css/03-elements/base.css`, `assets/css/03-elements/typography.css`
- `component abstraction`: all files in `assets/css/05-components/*.css`
- `page-specific`: all files in `assets/css/04-pages/*.css`
- `utility`: `assets/css/06-utilities/utilities.css` (`@utility color-accent--*`)

## Removed CSS

- `assets/css/01-settings/tokens.css`
  - Removed because token values are now centralized in `assets/css/tailwind.css` `@theme`.
- `assets/css/04-layouts/compositions.css`
  - Removed after replacing `.container*` and `.app-content` spacing behavior with Tailwind utilities in templates.
- `assets/css/app.css`
  - Removed as dead legacy entrypoint (build uses `assets/css/tailwind.css`).
- Moved `@utility scrollbar-none` and `@utility scrollbar-thin` from `assets/css/03-elements/base.css` to `assets/css/06-utilities/utilities.css`.
  - This keeps utility declarations top-level while preserving existing `@apply` usage.

## Kept Legacy CSS (and why)

- `assets/css/04-pages/*.css`
  - Kept as page-scoped abstractions for complex views with dense interaction state.
- `assets/css/05-components/*.css`
  - Kept where abstractions are still justified (modals, tables, cards, nav, editor/third-party overrides, complex pseudo-element/animation behavior).
- `assets/css/02-generic/animations.css`
  - Kept for shared keyframes/animation utilities not practical to inline per-template.
- `assets/css/03-elements/typography.css`
  - Kept for global semantic element defaults (`h1`-`h6`, `p`, `small`).
