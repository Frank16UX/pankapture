# Pankapture

A fast, native macOS menu bar app for screenshots, in-place annotation, and screen recording with **system audio + microphone**, plus a lightweight video editor and searchable capture history.

Apple Silicon · macOS 15+ · Swift 6 · no dependencies · fully offline.

> **Status:** M0 Foundations. The menu bar app, global hotkey (⇧⌘X), settings (incl. Light/Dark/System appearance), permissions, and a walking-skeleton capture (display under cursor → clipboard + file) work. See [docs/ROADMAP.md](docs/ROADMAP.md).

## Quick start

```bash
make cert   # once per machine: creates a stable local signing identity
make run    # builds build/Pankapture.app and launches it
```

1. The viewfinder icon appears in the menu bar.
2. Press **⇧⌘X**. macOS asks for **Screen & System Audio Recording** permission; grant it in System Settings, then press ⇧⌘X again.
3. The capture is copied to the clipboard and saved to `~/Pictures/Pankapture`.

## Commands

| Command | What it does |
|---|---|
| `make build` | Debug compile |
| `make test` | Unit tests (Swift Testing) |
| `make app` | Release `.app` into `build/` |
| `make run` | Build + (re)launch |
| `make cert` | Create the "Pankapture Development" signing identity |
| `make logs` | Stream the app's logs |
| `make clean` | Remove build output |

## Requirements

- Apple Silicon Mac, macOS 15 or later.
- **Xcode (recommended).** The Command Line Tools can build M0, but SwiftUI macros (`@State`, `#Preview`), SwiftUI previews, and Instruments need Xcode. See [ARCHITECTURE §9](docs/ARCHITECTURE.md#9-build-signing-toolchain).

## Project layout

```
Package.swift            SwiftPM manifest (modules + tests)
Sources/
  Pankapture/            app shell: menu bar, settings, coordinator
  AppCore/               preferences, hot keys, permissions, file naming, logging
  Capture/               ScreenCaptureKit snapshots, image output
  Annotation/            annotation model, undo, renderer
  DesignSystem/          appearance, tokens, shared UI
Tests/                   unit tests
Resources/               Info.plist, entitlements
scripts/                 bundle + signing scripts
docs/                    PRD, architecture, design, roadmap
```

## Docs

- [Product requirements](docs/PRD.md)
- [Architecture & technical foundations](docs/ARCHITECTURE.md)
- [Design](docs/DESIGN.md)
- [Roadmap](docs/ROADMAP.md)

## Troubleshooting

- **macOS keeps asking for Screen Recording permission after rebuilds.** You're on ad-hoc signing; run `make cert`, then `make run`. If it still prompts once, remove the old "Pankapture" entry in System Settings → Privacy & Security → Screen & System Audio Recording and grant it again.
- **Captures show only the wallpaper.** Screen Recording permission isn't granted (Settings → Permissions).
- **⇧⌘X does nothing.** Another app owns the shortcut; Settings → Shortcuts shows a ⚠︎ next to conflicting actions.
- **`@State` / macro errors when building.** You're on the Command Line Tools toolchain; install Xcode or keep the explicit `State(...)` workaround (ARCHITECTURE §9).
