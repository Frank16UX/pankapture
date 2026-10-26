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

**ADR-5: Webcam, clicks, and keystrokes are on-screen overlays.** *(The webcam part is superseded by ADR-25.)* Each is a floating window that ScreenCaptureKit records like any other content (explicitly *included*, while our control bar is *excluded*). This keeps the recorder simple and WYSIWYG. Click positions are also logged to a sidecar JSON for editor auto-zoom (VE-5).

**ADR-6: SwiftPM + bundle script instead of an Xcode project.** It's diff-friendly, scriptable, and has no `.pbxproj` merge pain. `scripts/bundle.sh` assembles `Pankapture.app`, copies Info.plist and entitlements, and code-signs it. Xcode can still open `Package.swift` for debugging and Instruments.

**ADR-7: Not sandboxed, hardened runtime on.** Global hotkeys, capturing other apps, and writing anywhere the user chooses are simpler without the sandbox, and App Store distribution is a non-goal. Hardened runtime stays on with the `audio-input` and `camera` entitlements.

**ADR-8: Stable local signing identity.** macOS ties privacy grants (Screen Recording, etc.) to the code signature. Ad-hoc signatures change every build, which would re-prompt constantly. `make cert` creates a self-signed "Pankapture Development" identity once per machine; the bundle script uses it automatically.

**ADR-9: Carbon hot keys.** `RegisterEventHotKey` is still the only API that registers a true global shortcut, swallows the key event, and needs **no** Accessibility/Input Monitoring permission. It's wrapped in `HotKeyCenter`; nothing else touches Carbon.

**ADR-10: No third-party dependencies (for now).** Everything needed is in the SDK. Add a dependency only when it saves weeks, not hours; document it here.

**ADR-11: Overlay = one borderless panel per display, chrome in Core Animation.** Each panel shows its display's frozen frame as GPU layer contents; dimming, selection border, handles, badge, crosshair, and loupe are `CAShapeLayer`/`CATextLayer`s, so mouse moves only update paths. Panels sit just above the status bar level (below pop-up menus, so the share menu and tooltips still show). The annotation canvas is a subview framed to the selection whose bounds origin equals the selection origin: it draws in display-local points and clips for free, and resizing the selection never moves annotations relative to the content (AN-7). Tool interactions (`AnnotationInteraction`) are shared by the overlay and the editor window.

**ADR-12: Capture history is a SwiftData index plus per-capture folders.** The index (`CaptureItem`, versioned schema `LibrarySchemaV1`) lives at `Application Support/Pankapture/Library/Library.store`; each capture has `Library/Captures/<uuid>/` with `original.png`, `annotations.json`, `thumbnail.heic` (512 px). Only the `LibraryStore` model actor touches models; the main-actor `CaptureLibrary` facade and UI work with `CaptureSnapshot` values. Recordings and GIFs aren't copied: they're referenced at their exported location by a plain bookmark and flagged missing when moved to the Trash or deleted.

**ADR-13: Non-destructive re-edit.** A screenshot is stored as the un-annotated original, its `AnnotationDocument` (capture-local points), its scale, and an optional crop. The exported file is a by-product; re-editing loads these, and saving rewrites annotations and thumbnail. Captures closed without saving are kept too (OUT-8, configurable).

**ADR-14: Retention never touches user files.** Retention (forever/30/90 days) and the optional storage cap remove library items oldest first; the cap counts only library-owned bytes. Exported files are moved to the Trash only when the user explicitly asks.

**ADR-15: The recording writer is an actor on the capture queue.** `RecordingWriter`'s executor is the serial queue ScreenCaptureKit delivers samples on, so samples are appended synchronously; the main actor awaits pause/resume/finish. Pause is modelled as host-clock intervals (`PauseTimeline`) and each sample is retimed by its own timestamp, so late frames land on the right side of a pause and output time stays monotonic.

**ADR-16: Audio tracks are identified by order and title.** System audio is the first audio track ("System"), the microphone the second ("Microphone"), each with a title in metadata. A muted mic is written as silence, so tracks never have gaps.

**ADR-17: Own source picker, not the system content picker.** Window and display picking use our hover-to-pick overlay: plain window/display IDs, no system sharing indicator, same look as screenshots. Area selection for recording reuses the screenshot overlay in pick mode.

**ADR-18: Scrolling capture stitches by row signatures.** Each frame becomes a 64-column grayscale row signature; a detailed block near the top of the new frame is located in the previous frame to find the scroll offset, which is then verified over the whole overlap. Rows that stay fixed at the top/bottom are treated as sticky header/footer and kept once. Only downward scrolling is stitched. Auto-scroll posts scroll-wheel events and needs Accessibility; manual scrolling needs nothing.

**ADR-19: `pankapture://` runs only interactive commands by default.** Any web page can open a custom URL, so URLs may open the overlay (which needs the user to finish the capture) but can't capture silently unless the user enables URL automation.

**ADR-20: Distribute as a GitHub release DMG, signed with the ADR-8 identity, not notarized.** `make release` builds `Pankapture.dmg` locally and attaches it to a GitHub release; `scripts/install.sh` (curl | bash) installs the latest one into `/Applications`. Every release is signed with the same "Pankapture Development" identity, so the designated requirement stays the same and users keep their privacy grants across updates; the release script refuses to publish an ad-hoc build. Without a Developer ID and notarization, Gatekeeper blocks a browser-downloaded DMG until the user clicks "Open Anyway". curl downloads aren't quarantined, which is why the Terminal installer is the primary path. Releases are built locally rather than in CI because CI would need the signing identity as a secret and an image with the current Xcode. Switching to a Developer ID later changes the signature, so users would re-grant permissions once.

**ADR-21: Dock icon only while a standard window is open; one instance.** The app runs as an accessory (menu bar only) and `DockPresence` switches it to a regular app while any titled, non-panel window is visible or minimized: Settings, the image and video editors, history, and the welcome window. Accessory apps open windows behind other apps, and those windows don't appear in Cmd-Tab or the Dock, so they were easy to lose. Panels (overlay, HUDs, thumbnails, pins, recording options) never show the Dock icon. Settings opens through `SettingsWindow.show()`, which shows the Dock icon and activates the app before calling SwiftUI's `openSettings` action. That action is captured from the menu bar label, which exists for the whole session. A second launch from another location (a dev build next to the installed app) would register the same global hot keys, so it yields activation to the running instance, asks it to show Settings over a distributed notification, and exits before creating any scene.

**ADR-22: Recordings carry a mixed default audio track.** System audio and mic stay on separate tracks for the editor (ADR-16), but most players (browsers, chat apps, Quick Look) play only the first audio track, so the mic was missing wherever the file was shared. When a recording with both sources finishes (or is recovered), `AudioMixdown` rewrites it once: video passthrough, a **"Mix"** track (system + mic, AAC stereo) first and enabled as the alternate group's default, then the original "System" and "Microphone" tracks, disabled. This costs an audio encode and a file copy at stop (about a second for a few minutes), plus about 128 kbps. If it fails, the separate-track file is kept. The editor ignores the "Mix" track.

**ADR-23: Window recordings with overlays capture the window's area of the display.** A single-window filter (`desktopIndependentWindow`) renders only that window, so click rings and the keystroke pill were missing. When any overlay is on, the stream instead uses a display filter that *includes* only the target window and the overlay windows, cropped (`sourceRect`) to the window's frame when recording starts. Other apps' windows stay out, as before; the trade-off is that the area doesn't follow the window if it moves. Without overlays, window recordings keep the single-window filter, which does follow it. The webcam bubble is moved inside the recorded frame if it's outside.

**ADR-24: Editor edits are saved explicitly, with a draft for crashes.** The project file (`Edits/<video>.json`) changes only on Save (⌘S, the toolbar button, or Save in the close/quit prompt). Every edit is autosaved to `<video>.draft.json`, which is deleted on Save or Don't Save. Reopening a recording with a leftover draft shows it as unsaved changes, so neither closing nor a crash loses work silently. Background pictures and movies are copied into `Backgrounds/` and the project points at the copy. A background movie is a second, looped video track in the composition (inserted after speed changes so it isn't retimed), and `VideoEditCompositor` receives its frame alongside the recording's.

**ADR-25: The webcam is its own track; the saved video is a composite.** The bubble stays on screen as a preview but out of the screen capture. Its frames (`AVCaptureVideoDataOutput`, converted to the host clock) go through the same writer and pause timeline as the screen, into a second video track titled "Camera" (H.264, ≤ 1280 px wide), disabled so players show only the screen. The sidecar records where the bubble was (normalized to the recorded frame), its shape, and mirroring; the track itself is never mirrored. The editor draws it as a layer (`CameraOverlay` in the project) above the video, so zooms leave it in place; a full-frame zoom moves it with everything else. Because shared files must show the camera, after recording the layered file moves to `Application Support/Pankapture/Recordings/Sources/` and the save folder gets `CameraComposite`'s export (camera where the bubble was) under the same name. That costs one re-encode at the recording's size after stop, bound by the hardware encoder (about 85 frames/s at 3024 × 1964 on an M4 Pro, so roughly real time for 60 fps Retina footage), so nothing waits for it: the thumbnail appears at once with a progress bar (only Edit and Close until it's done), the editor opens on the layered file, and the menu shows the percentage. Such recordings skip the ADR-22 audio mixdown at stop, since the composite mixes the audio itself; on failure the layered file gets the mixdown and is kept in the save folder instead. The composite's size is a setting (Recording ▸ Camera: Original down to 720p, never upscaled), since encode time scales with the pixel count; the progress card shows even with thumbnails turned off. The options panel's "Save camera: In the video" skips all of this: the bubble is then recorded like the other overlays (ADR-5's original behavior), into one file that's saved as soon as you stop but can't be moved later. The camera's frame output is part of the capture session from the moment the bubble opens; adding it when recording starts reconfigured the running camera, which blanked the bubble and lost about the first second of frames. Anything that opens a recording in the editor resolves it to the layered original (`AppPaths.editableRecording`); deleting a recording from its thumbnail trashes both.

**ADR-27: The compositor renders into the source's color space.** `VideoEditCompositor` reads each source frame through Core Image in the color space attached to the buffer (Rec. 709 for recordings) and renders the output back into that same space. It used to render into sRGB while the output stays tagged Rec. 709, so every frame through the compositor came out brighter than the same frame through the built-in compositor or the original file: toggling the camera layer visibly changed the screen, and saved composites didn't match their recordings. Backgrounds and the shadow are still drawn from sRGB colors and converted.

**ADR-28: Every merge to main is a release, and the app updates itself.** `.github/workflows/release.yml` runs on each push to `main` (docs-only changes excepted): the `check` job tests, then the `release` job's `scripts/release.sh` builds the DMG, checks it's signed by the "Pankapture Development" certificate (pinned by SHA-1), and publishes `v<next>` with generated notes. Pull requests run only the `check` job: the same tests and a DMG build, without secrets or publishing. The version is automatic (`scripts/next-version.sh`): one patch above the newest tag, unless `CFBundleShortVersionString` in Info.plist is higher (raise it for a minor or major release). CI signs with the same self-signed identity as local builds (ADR-8), imported from two encrypted secrets in the `release` environment (`make ci-secrets`, ADR-29) into a throwaway keychain, because privacy grants are tied to that certificate. Release bundles carry `PKReleaseBuild`. `UpdateController` asks the GitHub API for the latest release (anonymously, at launch and daily when enabled, or on Check Now). When it finds a newer release it downloads the DMG in the background, mounts it, and refuses the app inside unless it satisfies the running app's designated requirement (same identifier and certificate). It copies the app next to the current one and waits: the menu bar icon gets a dot, the menu leads with "Restart to Update", and a notification offers Restart. Nothing restarts without the user: Restart quits, and a shell script swaps the two bundles by renaming and relaunches; quitting normally runs the same swap without relaunching (`applicationWillTerminate`). The new app moves the old bundle to the Trash. A recording blocks the restart. Local `make app` builds aren't release builds; they check but open the release page instead of replacing themselves. If the app's folder isn't writable, the update is offered and its DMG opens for a manual drag.

**ADR-29: Contributions land only through reviewed pull requests; signing keys stay on `main`.** The repo is public and every merge to `main` ships to users (ADR-28), and `scripts/install.sh` is served straight from `main`, so `main` is the trust boundary. A repository ruleset on the default branch requires a pull request and a passing `check` job from GitHub Actions, and blocks force pushes and deletion; admins may bypass only through a pull request. `.github/CODEOWNERS` makes the maintainer the owner of every path. Collaborators get the Triage role (issues and PRs, no push) unless trusted with Write. The signing secrets live in a `release` environment whose deployment branches are limited to `main`, so a workflow pushed on another branch can't read them, and fork pull requests never get secrets. Workflows from all outside contributors wait for approval before running. Only GitHub-owned and verified actions are allowed, and they must be pinned to a commit SHA; Dependabot keeps the pins current. On pull requests the `check` job always runs and reports success without building when only `docs/` or Markdown changed, so it can be a required check without blocking docs-only PRs. Security reports go through private vulnerability reporting (`SECURITY.md`).

**ADR-26: Pankapture's standard windows are capturable.** Captures exclude the app so its capture UI never leaks in, which also hid the editors, history, and Settings, so the app couldn't be shown in its own screenshots or recordings. `OwnWindows.capturableIDs()` (visible, titled, non-panel windows) are excepted from that exclusion in screenshots, window snapping and picking, and recordings. Display and area recordings re-check the set every 2 s and update the stream filter when it changes, so an editor opened mid-recording appears.

**ADR-30: Sharing exports tune the built-in H.264 encoder instead of bundling a codec.** The export sheet's "Optimize for Sharing" (VE-15) makes an MP4 that uploads quickly and plays inline in chat apps and mail clients. It keeps the system's hardware H.264 encoder and changes only its inputs (`MP4Encoding.sharing`): shorter side at most 1080 px, at most 30 fps, 0.045 bits per pixel per frame (between Low and Medium), a keyframe every 10 s instead of 2 s, and 96 kbps AAC. Screen recordings are mostly still, so keyframes are a large share of their size: the longer interval alone cut a mostly-still 100 s recording by 29%. On three real recordings the profile made files 55–60% smaller than the High preset, with text unchanged to the eye, and encoded in half the time at 30 fps. Rejected: HEVC (hardware-encoded and smaller still, but it doesn't play in every browser and mail client yet, which defeats "send it anywhere"); AV1 (Apple Silicon decodes it but has no encoder, and the open-source software encoders, libaom, SVT-AV1, and rav1e, are BSD-licensed but slow and would be the app's first third-party dependency); x264 (compresses better than the hardware encoder, but it's GPL, which an MIT-licensed app can't ship without relicensing, and it's far slower). H.264 plays everywhere and costs nothing to license (the OS encoder covers it).

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

`AVMutableComposition` (trim/cut by inserting time ranges; per-track audio mix volumes) + custom `AVVideoCompositing` that applies zoom/pan keyframes and background/padding with Core Image on the GPU → `AVAssetReader` → `AVAssetWriter` (MP4: H.264 at the bitrate of the quality preset or the sharing profile, ADR-30) or frame extraction → ImageIO GIF encoder. The MP4 size is a resolution preset (exact shorter side) or a percentage of the canvas; sharing then caps the shorter side at 1080 px.

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
| Re-editable originals | `~/Library/Application Support/Pankapture/Library/Captures/<uuid>/` | `original.png`, `annotations.json` (`AnnotationDocument`), `thumbnail.heic` |
| History index | `~/Library/Application Support/Pankapture/Library/Library.store` | SwiftData (`CaptureItem`: id, kind, createdAt, size/duration, exportURL, ocrText, …) |
| Recordings in progress | `~/Library/Application Support/Pankapture/Recordings/InProgress/` | fragmented MP4 + manifest JSON (crash recovery) |
| Recording metadata | `~/Library/Application Support/Pankapture/Sidecars/<video>.json` | `RecordingSidecar` (clicks for auto-zoom) |
| Video edits | `~/Library/Application Support/Pankapture/Edits/<video>.json`, unsaved edits in `<video>.draft.json` | `VideoEditProject` (ADR-24) |
| Layered recordings | `~/Library/Application Support/Pankapture/Recordings/Sources/<video>.mp4` | MP4 with the "Camera" track; the save folder has the composite (ADR-25) |
| Video backgrounds | `~/Library/Application Support/Pankapture/Backgrounds/<uuid>.<ext>` | copies of pictures/movies used as editor backgrounds |

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
make dmg    # release .app → build/Pankapture.dmg
make release  # test + DMG + GitHub release (see ADR-20)
```

### Toolchain notes (important)

- **Xcode is required** (selected with `sudo xcode-select -s /Applications/Xcode.app`). The macOS 27 SDK implements `@State`, `@Entry`, `@Model`, and `#Preview` as macros whose plugins ship only with Xcode. Instruments (for the performance targets) also needs Xcode.
- With only the Command Line Tools selected, `make test` still passes the swift-testing `-plugin-path` so pure-logic tests run, but the app target won't compile.
- **No SwiftPM resources.** The generated `Bundle.module` accessor looks next to the executable, not in `Contents/Resources`, so it breaks inside the hand-assembled `.app`. Assets are drawn in code or come from SF Symbols.

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
