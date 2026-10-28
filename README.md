# Pankapture

A fast, native macOS menu bar app for screenshots, in-place annotation, and screen recording with **system audio + microphone**, plus a lightweight video editor and searchable capture history.

Apple Silicon · macOS 15+ · Swift 6 · no dependencies · offline by default (optional cloud transcription and AI providers use the network, only when you add them).

> **Status:** v1 feature-complete: area/window/fullscreen/scrolling/text capture with inline annotation, full editor with backgrounds, pins, quick-access thumbnails, screen recording with system audio + mic (webcam, clicks, keystrokes), video editor, and searchable history. Manual QA and the performance pass are tracked in [docs/ROADMAP.md](docs/ROADMAP.md).

## Install

No Xcode needed. Paste this in Terminal (installs or updates to the latest release):

```bash
curl -fsSL https://raw.githubusercontent.com/Frank16UX/pankapture/main/scripts/install.sh | bash
```

Or download **Pankapture.dmg** from [Releases](https://github.com/Frank16UX/pankapture/releases/latest) and drag the app to Applications. The app isn't notarized by Apple, so the first launch from the DMG is blocked: open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** (or run `xattr -dr com.apple.quarantine /Applications/Pankapture.app`). The Terminal installer doesn't need this step.

## Build from source

```bash
make cert   # once per machine: creates a stable local signing identity
make run    # builds build/Pankapture.app and launches it
```

## First run

1. The viewfinder icon appears in the menu bar and a welcome window explains the basics.
2. Press **⇧⌘X**, drag an area, annotate with the tools bar, then **↩** (copy + save per Settings), **⌘C**, or **⌘S**. macOS asks for **Screen & System Audio Recording** the first time.
3. **⌥⇧⌘X** opens the recording options (system audio, microphone, camera, click highlights, keystrokes).

### Shortcuts in the overlay

| Key | Action |
|---|---|
| drag / click | select an area / the window under the pointer (click on empty desktop = whole display) |
| ⇧ / ⌥ / Space while dragging | square · from center · move the selection |
| P L A R O H T B X N | pen, line, arrow, rectangle, ellipse, highlighter, text, blur, pixelate, numbered step |
| ↩ · ⌘C · ⌘S · ⇧⌘S · ⌘P · ⌘E · ⌥P | done · copy · save · save as · print · open in editor · pin |
| ⌘Z / ⇧⌘Z · ⌫ · arrows (⇧ = 10 pt) | undo / redo · delete selected annotation · nudge |
| Esc | close |

Video editor (after a recording: the thumbnail, the notification, or **Edit Last Recording** in the menu bar):

| Key | Action |
|---|---|
| Space · J K L · ← → | play/pause · back, pause, faster · step a frame (⇧ = 1 s) |
| S · drag on the filmstrip · ⌫ | split at the playhead · select a range · delete the selected part or zoom |
| I · O · Z | trim start / end at the playhead · add a zoom |
| ⌘S · ⌘E · ⌘Z / ⇧⌘Z | save edits · export · undo / redo |

`pankapture://capture/area` (and `/previous`) open the overlay from launchers; non-interactive URL commands are off by default.

## Commands

| Command | What it does |
|---|---|
| `make build` | Debug compile |
| `make test` | Unit tests (Swift Testing) |
| `make eval` | Score auto-edit on labeled recordings ([PRD §11](docs/PRD.md#11-appendix-auto-edit-evaluation)) |
| `make app` | Release `.app` into `build/` |
| `make run` | Build + (re)launch |
| `make dmg` | Release `.app` packaged as `build/Pankapture.dmg` |
| `make release` | Test, build the DMG, and publish a release now (merges to `main` do this automatically) |
| `make ci-secrets` | Once: give the release workflow the signing identity, as encrypted secrets in the `release` environment |
| `make cert` | Create the "Pankapture Development" signing identity |
| `make icon` | Regenerate the app icon |
| `make logs` | Stream the app's logs |
| `make clean` | Remove build output |

## Requirements

- Apple Silicon Mac, macOS 15 or later.
- To build from source: **Xcode** selected as the developer toolchain (`sudo xcode-select -s /Applications/Xcode.app`). See [ARCHITECTURE §9](docs/ARCHITECTURE.md#9-build-signing-toolchain).

## Project layout

```
Package.swift            SwiftPM manifest (modules + tests)
Sources/
  Pankapture/            app shell: menu bar, settings, coordinators, onboarding
  AppCore/               preferences, hot keys, permissions, file naming, paths, logging
  Capture/               ScreenCaptureKit stills/windows/areas, OCR, scroll stitcher, image output
  Annotation/            annotation model, undo, geometry, renderer, beautify
  DesignSystem/          appearance, tokens, shared UI
  Overlay/               selection overlay, inline editor, editor window
  QuickAccess/           thumbnails and pinned images
  Recording/             screen recording engine, HUD, webcam/clicks/keys
  VideoEditor/           timeline, composition, export
  Library/               capture history
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

## Contributing

Issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md). Report security problems privately ([SECURITY.md](SECURITY.md)).

## Troubleshooting

- **macOS keeps asking for Screen Recording permission after rebuilds.** You're on ad-hoc signing; run `make cert`, then `make run`. If it still prompts once, remove the old "Pankapture" entry in System Settings → Privacy & Security → Screen & System Audio Recording and grant it again.
- **Captures show only the wallpaper.** Screen Recording permission isn't granted (Settings → Permissions).
- **⇧⌘X does nothing.** Another app owns the shortcut; Settings → Shortcuts shows a ⚠︎ next to conflicting actions.
- **`@State` / macro errors when building.** The Command Line Tools are selected; select Xcode (ARCHITECTURE §9).
- **`make cert` says "MAC verification failed".** Fixed in the script (it now uses the system LibreSSL); pull and rerun.

## License

[MIT](LICENSE)
