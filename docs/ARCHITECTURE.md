# Pankapture — Architecture & Technical Foundations

Companion to [PRD.md](PRD.md) (what) and [DESIGN.md](DESIGN.md) (how it looks). This document covers **how it's built**.

## 1. Stack at a glance

| Concern | Choice |
|---|---|
| Language | Swift 6 (strict concurrency, `swift-tools-version: 6.0`) |
| UI | SwiftUI for chrome (menus, settings, toolbars, library); AppKit + Core Animation for hot paths (overlay, canvas, floating panels) |
| Min OS / arch | macOS 15.0, arm64 only |
| Screen capture | ScreenCaptureKit: `SCScreenshotManager` (stills), `SCStream` (recording) |
| Audio | ScreenCaptureKit system audio + microphone (`captureMicrophone`, macOS 15+) on one clock |
| Camera | AVFoundation `AVCaptureSession` |
| Encoding | AVFoundation `AVAssetWriter` → VideoToolbox hardware H.264/HEVC; ImageIO for PNG/JPEG/HEIC/GIF |
| Image processing | Core Graphics (annotations), Core Image (blur, pixelate, backgrounds), Vision (OCR, image registration for scrolling capture) |
| Video editing | `AVMutableComposition` + custom `AVVideoCompositing` (zoom/pan, background) |
| Persistence | UserDefaults (settings), files (captures), SwiftData (history index) |
| Global shortcuts | Carbon `RegisterEventHotKey` (no permission needed) |
| Build | Swift Package Manager + `scripts/bundle.sh` → signed `.app` (no `.xcodeproj`) |
| Tests | Swift Testing (`import Testing`) |
| Third-party dependencies | **None.** Every capability above is a system framework. |

## 2. Key decisions

Short ADRs. If a decision changes, update it here; don't delete it.

**ADR-1: Native Swift, not web/cross-platform.** The performance targets (≤ 150 ms to overlay, ≤ 10% CPU while recording, ~0% idle) and deep OS integration (ScreenCaptureKit, hotkeys, TCC, floating panels across Spaces) rule out Electron/Tauri. Native also gives light/dark, accessibility, and system materials for free.

**ADR-2: macOS 15 minimum.** Microphone capture through ScreenCaptureKit (`SCStreamConfiguration.captureMicrophone`) and `SCRecordingOutput` arrived in macOS 15. Capturing mic and system audio in the same stream puts them on one clock, which is the cleanest fix for A/V drift. Richer visuals (glass) light up on macOS 26+ via `#available`.

**ADR-3: Freeze-frame area capture.** On hotkey, every display is snapshotted immediately and the overlay shows that frozen image. The final capture is a **crop of the snapshot**, not a second capture. That makes it WYSIWYG, avoids races with changing content (hover states, menus), and makes post-selection instant.

**ADR-4: Recording via `SCStream` → `AVAssetWriter`, not `SCRecordingOutput`.** `SCRecordingOutput` is simpler but doesn't give us pause/resume in one file, fragmented (crash-safe) MP4, or a side channel for cursor/click metadata. A custom writer does: we drop samples while paused and offset timestamps, set `movieFragmentInterval` for crash safety, and keep system audio and mic on **separate tracks**.

**ADR-5: Webcam, clicks, and keystrokes are on-screen overlays.** Each is a floating window that ScreenCaptureKit records like any other content (explicitly *included*, while our control bar is *excluded*). This keeps the recorder simple and WYSIWYG. Click positions are also logged to a sidecar JSON for editor auto-zoom (VE-5).

**ADR-6: SwiftPM + bundle script instead of an Xcode project.** It's diff-friendly, scriptable, and has no `.pbxproj` merge pain. `scripts/bundle.sh` assembles `Pankapture.app`, copies Info.plist and entitlements, and code-signs it. Xcode can still open `Package.swift` for debugging and Instruments.

**ADR-7: Not sandboxed, hardened runtime on.** Global hotkeys, capturing other apps, and writing anywhere the user chooses are simpler without the sandbox, and App Store distribution is a non-goal. Hardened runtime stays on with the `audio-input` and `camera` entitlements.

**ADR-8: Stable local signing identity.** macOS ties privacy grants (Screen Recording, etc.) to the code signature. Ad-hoc signatures change every build, which would re-prompt constantly. `make cert` creates a self-signed "Pankapture Development" identity once per machine; the bundle script uses it automatically.

**ADR-9: Carbon hot keys.** `RegisterEventHotKey` is still the only API that registers a true global shortcut, swallows the key event, and needs **no** Accessibility/Input Monitoring permission. It's wrapped in `HotKeyCenter`; nothing else touches Carbon.

**ADR-10: No third-party dependencies (for now).** Everything needed is in the SDK. Add a dependency only when it saves weeks, not hours; document it here.

## 3. Module map

```
Pankapture (executable, app shell)
 ├── AppCore        settings keys, hot keys, permissions, file naming, logging      [no UI]
 ├── Capture        ScreenCaptureKit stills, image encode/save/clipboard            → AppCore
 ├── Annotation     document model, undo, arrow geometry, CG renderer               [pure]
 ├── DesignSystem   appearance, tokens, surfaces, tool buttons                      [SwiftUI]
 │
 │  planned
 ├── Overlay        selection overlay, loupe, inline editor canvas + toolbars (M1)  → Capture, Annotation, DesignSystem
 ├── Recording      SCStream → AVAssetWriter, HUD, webcam/clicks/keys overlays (M3–M4)
 ├── VideoEditor    timeline, composition, zoom compositor, export (M5)
 └── Library        SwiftData history, OCR index, library window (M6)
```

**Rules**
- Dependencies point **down**: app → feature modules → `AppCore`/`DesignSystem`. Feature modules never import the app target or each other's internals. Shared types move down a layer.
- `Annotation` stays pure (CoreGraphics/CoreImage only, no AppKit windows) so it's fully unit-testable and reused by the inline editor, full editor, and history re-edit.
- The app target is a thin composition root: `AppDelegate` wires services; `CaptureCoordinator` routes intents (shortcuts, menu items) to flows.
- New modules are added when their milestone starts, not before (no empty placeholder targets).

## 4. Key flows

### 4.1 Area screenshot (M1 target)

```
⇧⌘X (Carbon) ─▶ HotKeyCenter ─▶ CaptureCoordinator.perform(.captureArea)
    ─▶ ScreenshotService.snapshotDisplays()        // all displays, own app excluded
    ─▶ OverlayController.present(snapshots)        // one borderless panel per display,
                                                   // frozen image as CALayer contents
    user drags ─▶ selection rect (display-local points)
    ─▶ inline editor: AnnotationDocument + live CALayer drawing
    action (copy/save/print/share/pin/thumbnail)
    ─▶ AnnotationRenderer.render(document, onto: snapshot.crop(rect), scale)
    ─▶ ImageOutput / NSPrintOperation / NSSharingServicePicker / PinController
    ─▶ Library.record(...)                         // M6
```

Latency budget (≤ 150 ms): shareable-content query ~20–60 ms; per-display capture ~15–40 ms; overlay show < 16 ms. Optimizations held in reserve: pre-create (hidden) overlay panels at launch, cache `SCShareableContent` and refresh it on display/app changes, capture displays concurrently.

### 4.2 Screen recording (M3 target)

```
Record ─▶ source picker (area/window/display) + audio/mic/camera options
    ─▶ countdown ─▶ SCStream(filter excluding control HUD, including webcam/click/key overlays)
         config: capturesAudio, captureMicrophone, excludesCurrentProcessAudio, fps, pixel format
    sample handler queue ─▶ RecordingWriter (AVAssetWriter, serial queue)
         video  → H.264/HEVC (hardware), IOSurface-backed buffers passed through untouched
         audio  → AAC track "System"
         mic    → AAC track "Microphone"
         pause  → drop buffers, accumulate time offset, retime subsequent buffers
         movieFragmentInterval = 2 s (crash safety)
    stop ─▶ finishWriting ─▶ thumbnail ─▶ (optional) VideoEditor
```

### 4.3 Video export (M5 target)

`AVMutableComposition` (trim/cut by inserting time ranges; per-track audio mix volumes) + custom `AVVideoCompositing` that applies zoom/pan keyframes and background/padding with Core Image on the GPU → `AVAssetExportSession` (MP4) or frame extraction → ImageIO GIF encoder.

## 5. Coordinate systems

Three spaces exist and bugs live at their borders. Convert in one place per boundary and name variables by space.

| Space | Origin | Unit | Used by |
|---|---|---|---|
| AppKit global | bottom-left of the primary display | points | `NSEvent.mouseLocation`, `NSScreen.frame`, `NSWindow` |
| Quartz / ScreenCaptureKit global | top-left of the primary display | points | `SCDisplay.frame`, `CGWindowList`, `CGDisplayBounds` |
| Capture-local | top-left of the captured image | points (annotations) / pixels (`CGImage`) | `AnnotationDocument`, `DisplaySnapshot.crop` |

`DisplaySnapshot.scale` converts capture points ↔ pixels. Annotations are always stored in capture-local **points** so they render identically at any scale.

## 6. Concurrency model

- Swift 6 strict concurrency, no `@preconcurrency` escape hatches without a comment explaining why.
- UI, coordinators, `HotKeyCenter`, and `Permissions` are `@MainActor`.
- Capture/recording pipelines run on dedicated serial `DispatchQueue`s owned by their writer (ScreenCaptureKit delivers sample buffers on a queue we provide). They hop to the main actor only to publish state.
- `@unchecked Sendable` is allowed only for immutable wrappers around CF types (e.g. `DisplaySnapshot` holding a `CGImage`), with a comment.

## 7. Persistence and files

| Data | Where | Format |
|---|---|---|
| Preferences | `UserDefaults` (keys in `AppCore/Preferences.swift`) | plist |
| Shortcuts | `UserDefaults["shortcuts.v1"]` | JSON `{action: KeyCombo?}` |
| Exported captures | user's save folder (default `~/Pictures/Pankapture`) | PNG/JPEG/HEIC/MP4/GIF |
| Re-editable originals (M6) | `~/Library/Application Support/Pankapture/Captures/<uuid>/` | `original.png` / `recording.mp4`, `annotations.json` (`AnnotationDocument`), `edits.json`, `thumbnail.heic` |
| History index (M6) | `~/Library/Application Support/Pankapture/Library.store` | SwiftData (`CaptureItem`: id, kind, createdAt, size/duration, exportURL, ocrText, …) |

File names use `CaptureFileNamer`: `Pankapture 2026-10-19 at 14.27.05.png`, with ` (2)`, ` (3)` on collision.

## 8. Permissions (TCC)

| Permission | Needed for | API | When requested |
|---|---|---|---|
| Screen & System Audio Recording | everything | `CGRequestScreenCaptureAccess` / first SCK call | first capture or onboarding |
| Microphone | REC-3 | `AVCaptureDevice.requestAccess(.audio)` | first recording with mic on |
| Camera | REC-10 | `AVCaptureDevice.requestAccess(.video)` | first time webcam is enabled |
| Accessibility | REC-12 keystrokes | `AXIsProcessTrustedWithOptions` | first time keystroke display is enabled |

Global hot keys and click highlighting (mouse-down global monitor) need no permission.

## 9. Build, signing, toolchain

```
make cert   # once per machine: stable self-signed identity (see ADR-8)
make test   # unit tests
make run    # release build → build/Pankapture.app → launch
make logs   # stream os_log for the app
```

### Toolchain notes (important)

- **Xcode is strongly recommended from M1.** The macOS 27 SDK implements `@State`, `@Entry`, and `#Preview` as SwiftUI macros whose plugin ships **only with Xcode**, not with the Command Line Tools. Instruments (needed to verify the performance targets) and SwiftUI previews also need Xcode.
- Until Xcode is installed, the code uses an explicit `State(initialValue:)` property instead of `@State` (search for "SwiftUIMacros"). After installing Xcode (`sudo xcode-select -s /Applications/Xcode.app`), switch those back to `@State` and drop the workaround.
- With CLT, `swift test` intermittently fails to find the swift-testing macro plugin; `make test` passes `-plugin-path` explicitly when CLT is the active toolchain.

## 10. Performance strategy

- **Measure, don't guess.** Wrap hot paths in `os_signpost` intervals (`hotkey→overlay`, `selection→toolbar`, `render+copy`, recording frame drops) and check them in Instruments against PRD §6.1.
- **Zero-copy imagery.** Frozen frames are shown as `CALayer.contents` (GPU-backed); recording passes ScreenCaptureKit's IOSurface-backed `CVPixelBuffer`s straight to the hardware encoder.
- **No idle work.** No timers or polling when idle; observe display/app changes via notifications only.
- **Hot paths in AppKit/Core Animation**, chrome in SwiftUI. The overlay and canvas must not pay SwiftUI diffing costs per mouse-move.
- **Pre-warm** what's expensive and invariant (overlay panels, CIContext, encoder settings).

## 11. Testing strategy

| Layer | How |
|---|---|
| Pure logic (naming, shortcuts, annotation model, geometry, timeline math, stitching offsets) | Swift Testing unit tests, run on every change |
| Rendering | Pixel-probe tests on small synthetic images (see `AnnotationRendererTests`) |
| Capture / recording / UI flows | Manual QA checklist per milestone in [ROADMAP.md](ROADMAP.md), plus signpost timings |
| Long-recording A/V sync | Scripted 30-min recording with a clap/flash test pattern, checked per release |
