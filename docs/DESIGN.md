# Pankapture — Design

**Direction:** clean, modern, unmistakably macOS-native. Pankapture should look like it shipped with the OS: quiet chrome, content first, and every surface correct in **Light, Dark, and System** appearance.

Tokens live in `Sources/DesignSystem/Tokens.swift`; shared components live in `Sources/DesignSystem/`.

## 1. Principles

1. **Native over novel.** Use system controls, materials, SF Symbols, and SF Pro before inventing anything. If a system component exists, use it.
2. **Chrome recedes, content leads.** Toolbars are compact, translucent, and appear only when needed. The capture is the hero.
3. **Theme-correct by construction.** Chrome uses only semantic colors and materials, never hard-coded hex. Light/dark/high-contrast then work automatically.
4. **Motion explains, never decorates.** Short, springy, purposeful; disabled under Reduce Motion.
5. **Keyboard parity.** Every visible action has a shortcut, shown in tooltips and menus.

## 2. Appearance (theming)

| Setting | Behavior |
|---|---|
| **System** (default) | Follows macOS light/dark, including automatic switching. |
| **Light** | Forces Aqua for all Pankapture windows, panels, and menus. |
| **Dark** | Forces Dark Aqua. |

- Implemented with one line: `NSApp.appearance = mode.nsAppearance` (`AppearanceMode.apply()`), applied at launch and live when changed in Settings. Every AppKit and SwiftUI view inherits it, so no per-view theme code is needed.
- **Never theme content.** Annotation colors, captured pixels, and exported images are identical in light and dark.
- **Overlay exception.** The selection dim (`PK.Overlay.dimOpacity`, black 45%), selection stroke (white with a dark hairline), and handles stay constant so they're legible over *any* screen content, regardless of app appearance.

### Color rules
| Use | Token / API |
|---|---|
| Primary/secondary text | `.primary`, `.secondary`, `.tertiary` |
| Selected tool, focus, primary buttons | `Color.accentColor` (respects the user's system accent) |
| Separators/hairlines | `.separator` |
| Subtle fills (hover, badges) | `.quaternary` |
| Floating surfaces | `pkSurface()`: glass on macOS 26+, `.regularMaterial` + hairline + soft shadow on macOS 15 |
| Destructive | `.red` (system red adapts per appearance) |
| Status | system `.green` / `.yellow` / `.red` |

Brand color is reserved for the app icon and the onboarding illustration, never for chrome.

## 3. Typography

SF Pro via system text styles only (`.body`, `.callout`, `.caption`, …) so Dynamic Type and accessibility sizes work. Numbers that change live (dimensions, timers, file sizes) use `.monospacedDigit()` to avoid jitter. Shortcut badges use the rounded design.

## 4. Iconography

SF Symbols only, hierarchical rendering, medium weight, 15 pt in toolbars (`PK.Metrics.toolIcon`). The menu bar icon is the template symbol `viewfinder` (it switches to a recording indicator with a timer while recording).

## 5. Layout tokens

| Token | Value | Use |
|---|---|---|
| `Spacing.xxs…xxl` | 2 · 4 · 8 · 12 · 16 · 24 · 32 | 4-pt grid |
| `Radius.control` | 6 | tool buttons, swatches |
| `Radius.thumbnail` | 8 | thumbnails, cards |
| `Radius.toolbar` | 12 | floating toolbars, HUDs |
| `Radius.panel` | 16 | panels, pinned image corners |
| `Metrics.toolButton` | 28 | toolbar hit target |
| `Metrics.toolbarOffset` | 8 | gap between selection and toolbars |
| `Metrics.railWidth` / `railItemHeight` | 64 / 46 | inspector pane rail and its items |
| `Metrics.railIconHeight` / `railLabelSize` | 20 / 10 | a rail item's icon box and label |
| `Metrics.badgeDot` | 5 | dot marking a pane with edits |
| `Metrics.inspectorWidth` | 320 | inspector pane content |
| `Metrics.paneHeaderHeight` | 40 | title bar above an inspector pane |
| `Metrics.sliderValueWidth` | 38 | value label beside an inspector slider |
| `Metrics.inlineProgressWidth` | 120 | progress bar beside its status text |
| `Metrics.floatingPanelWidth` | 248 | floating options panel beside a canvas |

All rounded shapes use `.continuous` corners (squircles), like the system.

Segmented pickers in fixed-width panels (inspector, recording options, toolbar popovers, sheets) use `FittingSegmentedPicker`, which steps down to the small control size when the regular segments don't fit, so every option stays visible. A segmented control never shrinks below its minimum size, and the system draws segments larger on newer releases, so one that fits today can overflow and clip on the next. Don't fall back to a menu: it hides the options.

## 6. Motion

| Token | Spec | Use |
|---|---|---|
| `Motion.quick` | ease-out 120 ms | hover, press |
| `Motion.standard` | spring 250 ms, bounce 0.1 | toolbars appear, appearance change |
| `Motion.emphasized` | spring 350 ms, bounce 0.15 | thumbnail fly-in, editor open |

The overlay itself appears **instantly** (no fade): speed is the feature. With Reduce Motion on, springs become ≤ 100 ms cross-fades.

## 7. Key surfaces

### Inline editor layout

The spatial model users already know, with modern visuals:

```
            ┌───────────┐
            │ 671 × 211 │  ← dimension badge (top-left, outside; flips inside near the screen edge)
 ┌ ─ ─ ─ ─ ─┴─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐ ┌────┐
 │                                                    │ │ ✎  │  tools bar (vertical, right edge)
 │                                                    │ │ ╱  │  pen · line · arrow · rect · ellipse
 │                 selection (live capture,           │ │ ↗  │  highlighter · text · blur · pixelate
 │                 outside is dimmed 45%)             │ │ ▭  │  steps · ── · color · width · ── · undo
 │                                                    │ │ ●  │
 │                                                    │ │ ↶  │
 └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┘ └────┘
                          ┌──────────────────────────────────┐
                          │ 📌  ⤴︎  🖨  ⧉  ⬇︎  │  ✕           │  actions bar (horizontal, under bottom-right)
                          └──────────────────────────────────┘
                            pin share print copy save   close
```

- Both bars use `pkSurface()`, `PKToolButtonStyle`, and tooltips with shortcuts ("Arrow — A").
- **Smart placement:** prefer right/below; flip to left/above or inside the selection when there's no room; never cross a display edge.
- Selection: 1 pt white stroke + 0.5 pt dark outer hairline (visible on any background), 8 square handles (`Overlay.handleSize`).
- Loupe (during drag): 120 pt circle, 8× pixel grid, center pixel outlined, hex color and coordinates below.

### Image editor
The canvas fills the window under a full-width toolbar; two `pkSurface()` panels float on it, top-aligned with `Spacing.m` margins: the tools bar on the leading edge and the background panel (`Metrics.floatingPanelWidth`) on the trailing edge. The background panel shows only its Background switch while the background is off and grows to its Fill and Layout options when it's on (`Motion.standard`). Inside, options are plain rows (label on the leading edge, control on the trailing edge) in one grid, so every label lines up, under small secondary section titles, split by dividers: no grouped `Form`, so there are no cards inside the panel. Fill has the same styles as the video editor's background (Color with Transparent first, Gradient with editable colors and angle, Media for a picture, also by drop); switching styles restores the last fill of that style. The canvas stays fitted to the window as the background, padding, aspect, or window size change, until the user zooms by hand.

### Video editor inspector
One pane at a time, so each kind of edit is scanned and applied on its own. A rail on the trailing edge (`Metrics.railWidth`) lists the panes as an SF Symbol over a short label; the current one is tinted with the accent color, and a small accent dot marks panes with edits in the video. The pane (`Metrics.inspectorWidth`) has a title bar and a grouped `Form` split into small titled sections (Fill / Frame, Selected Zoom / Add Zooms…). Selecting something on the timeline opens the pane that edits it.

Auto-Edit has two steps, Setup and Review, in a segmented control in the title bar. The review is a list of cards: kind icon in its group color, title, time, and the words around the suggestion with the removed part struck through. Only the selected card opens up (reason, choices, Play); the rest stay one or two lines. Filter chips by kind and up / down arrows step through them one at a time.

### Loading and opening
A window opens at once, as a skeleton of what it will show: the editor's layout in `.quaternary` rounded shapes (radius `Radius.control`), the preview black like the player. Content replaces it without a transition. A wait under a second shows nothing more; past 400 ms a single spinner with a one-line status ("Loading the recording…") fades in (`Motion.standard`) where the content will appear, in the preview, never as a separate sheet or alert. A screenshot shows the capture itself instead of a skeleton. Choosing something that's already open brings its window forward.

### Camera layouts
The camera lane sits under the zoom lane and uses its block style: Camera Only in teal, Screen Only in gray, each with its symbol and title. In the preview the camera eases between its bubble and the full frame over 0.4 s with the zoom curve: the rect, corner radius and shadow change together, so it reads as one object growing, not a cut.

### Quick-access thumbnail
A rounded (`Radius.thumbnail`) image card with a soft shadow, sliding in from the chosen corner (`Motion.emphasized`). On hover: material scrim with icon buttons. It's draggable as a file.

### Recording HUD
A compact horizontal `pkSurface()` bar: red record dot + monospaced timer, pause, restart, mic mute, stop. It's excluded from the recording. The menu bar icon mirrors the timer.

### Settings
A native `Settings` scene with `Form` and `.formStyle(.grouped)` (System Settings look). Tabs: General, Shortcuts, Permissions, then Screenshots, Recording, History, and AI as features land.

The AI tab is a list of the added providers, one grouped section (card) each: the name and what it offers, Remove, the key ("Saved in your Keychain" with Replace) or server URL, and Test Connection. **Add Provider…** is the tab's one prominent button and opens a sheet: a provider picker, the key or URL, and a link to get a key. A Defaults section at the end holds the same Judged by, Reasoning effort and Transcription pickers as the editor's Auto-Edit pane. Model menus list names only; the chosen model's price is the Price row under its picker (input and output per 1M tokens, or per hour of audio, and an estimate per 15-minute recording). More Models… compares prices: a sortable table (model, input, output, per 15 minutes) with search and a field for any model ID.

### Library
`NavigationSplitView`: sidebar filters (All, Screenshots, Recordings, GIFs, date groups), adaptive grid of thumbnails, `.searchable` for OCR search, inspector for metadata.

## 8. Accessibility checklist (every surface)

- [ ] VoiceOver label + hint on every icon-only button (`.help` doubles as tooltip).
- [ ] Fully keyboard-operable; visible focus ring.
- [ ] Legible in Light, Dark, and Increase Contrast.
- [ ] Reduce Transparency: materials fall back to solid (automatic with system materials).
- [ ] Reduce Motion: springs → short fades.
- [ ] Hit targets ≥ 28 pt in toolbars.
