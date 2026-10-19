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

All rounded shapes use `.continuous` corners (squircles), like the system.

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

### Quick-access thumbnail
A rounded (`Radius.thumbnail`) image card with a soft shadow, sliding in from the chosen corner (`Motion.emphasized`). On hover: material scrim with icon buttons. It's draggable as a file.

### Recording HUD
A compact horizontal `pkSurface()` bar: red record dot + monospaced timer, pause, restart, mic mute, stop. It's excluded from the recording. The menu bar icon mirrors the timer.

### Settings
A native `Settings` scene with `Form` and `.formStyle(.grouped)` (System Settings look). Tabs: General, Shortcuts, Permissions, then Screenshots, Recording, and History as features land.

### Library
`NavigationSplitView`: sidebar filters (All, Screenshots, Recordings, GIFs, date groups), adaptive grid of thumbnails, `.searchable` for OCR search, inspector for metadata.

## 8. Accessibility checklist (every surface)

- [ ] VoiceOver label + hint on every icon-only button (`.help` doubles as tooltip).
- [ ] Fully keyboard-operable; visible focus ring.
- [ ] Legible in Light, Dark, and Increase Contrast.
- [ ] Reduce Transparency: materials fall back to solid (automatic with system materials).
- [ ] Reduce Motion: springs → short fades.
- [ ] Hit targets ≥ 28 pt in toolbars.
