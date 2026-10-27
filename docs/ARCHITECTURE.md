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

**ADR-12: Capture history is a SwiftData index plus per-capture folders.** The index (`CaptureItem`, versioned schema `LibrarySchemaV2` since ADR-47) lives at `Application Support/Pankapture/Library/Library.store`; each capture has `Library/Captures/<uuid>/` with `original.png`, `annotations.json`, `thumbnail.heic` (512 px). Only the `LibraryStore` model actor touches models; the main-actor `CaptureLibrary` facade and UI work with `CaptureSnapshot` values. Recordings and GIFs aren't copied: they're referenced at their exported location by a plain bookmark and flagged missing when moved to the Trash or deleted.

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

**ADR-31: Smart editing transcribes on device with `SpeechTranscriber`, on macOS 26+.** The microphone track (ADR-16) is decoded once to 16 kHz mono (`MicrophoneAudio`) and transcribed by `SpeechAnalyzer` + `SpeechTranscriber` with a time range and confidence per word. It needs no permission prompt and no network, and runs at about 50× real time. Language models download on first use through `AssetInventory` and are shared with other apps. The user picks English or Spanish (there's no language detection). There is no macOS 15 fallback: the older recognizer drops every filler and needs the Speech Recognition permission. So smart editing is gated with `#available(macOS 26, *)` while the app keeps its macOS 15 minimum. The recognizer merges stutters ("the the" becomes one stretched word) and drops Spanish "eh". The rules treat untranscribed sound between words as a possible filler, and verbatim cloud transcription is an option (PRD AI-5). `TimeRange` and the recorder's track conventions (`RecordingTracks`, `AudioRole`) moved to AppCore so the new modules don't depend on the editor.

**ADR-32: AI is bring-your-own-key, works with any provider, and is off by default.** The project never pays for inference. `AIProviders` speaks two wire protocols over plain HTTPS, without SDKs (ADR-10):
- Anthropic Messages: `anthropic-version: 2026-10-21`, structured output through `output_config.format`.
- OpenAI-compatible Chat Completions: a strict `response_format` JSON schema. This covers OpenAI, Gemini's compatibility endpoint, Groq, OpenRouter, LM Studio and Ollama.

Presets are data, and the model name is always editable. Keys live in the Keychain (`APIKeyStore`), never in UserDefaults or project files. A request goes out only when the user starts an action, and for auto-edit it carries transcript text and pause timings, never audio or video. Schemas are built with an order-preserving `JSONValue`, because constrained decoding generates fields in schema order (`reason` before `from`/`to`).

**ADR-33: Auto-edit runs the rules first, then one checked model call.** `AutoEditAnalyzer`:
1. Finds pauses: silence on the mic between words, including the tail of a word the recognizer stretched over the silence after it.
2. Measures screen activity per pause: sidecar clicks, plus pixel change between a few small frames (`ScreenActivityProbe`).
3. Runs `RuleBasedEditor`:
   - fillers from word lists;
   - repeats and stutters;
   - cue-based retakes ("I meant", "digo", "let me start over") and sentence restarts;
   - pause intent from punctuation, length, transition words and activity.

The rules are tuned for precision, and they're the result when no provider is configured (AI-1).

`ModelPass` then sends one prompt: numbered words, with markers like `⟨p3 2.4s screen: still⟩` for pauses of 0.6 s or more. It gets back cuts and a kind for each pause. The model judges intent and the app decides lengths (pacing, AE-3), so changing pacing needs no new call.

Answers are checked: schema, word ranges, overlaps, and a cap of 35% removed. An unusable answer is retried once; after that, the rules' results stand. Rule mistakes with confidence 0.7 or more (explicit cues) stay next to the model's: a model leaving one out isn't evidence against it.

**ADR-35: Auto-edit's suggestions are a layer of the project, applied on top of the user's cuts.**
- **Where they live:** `VideoEditProject.autoEdit` (`AutoEditLayer`) holds:
  - each pause with its kind and the user's overrides ("keep as is", dragged edges, their own kind);
  - each removal with its enabled state;
  - the pacing preset, the group toggles, and an optional speed for silent screen actions.
- **How the timeline uses them:** `Timeline` subtracts `effectiveCuts` (the user's cuts plus the layer's enabled ones) and adds `effectiveSpeedSegments`. Auto-edit is ignored if it would leave almost nothing, and nothing in `cuts` changes.
- **How a pause is shortened:** its cut is the middle of the pause, keeping half of the pacing target next to each word, so both join points sit in silence.
- **Clean joins:** removal edges snap to the quietest 10 ms within ±80 ms when the layer is built. Every join where footage was removed gets an 8 ms fade out and in on each audio track (`CompositionBuilder.mixParameters`), in the preview and in exports (AE-9).
- **Re-running the analysis** replaces only items the user hasn't changed.
- **Rebuilds:** the editor decides whether to rebuild the preview by comparing `Timeline`s, since the layer's derived cuts and speeds aren't stored.

**ADR-36: The transcript is part of the project; the panel is a read-only text view with in-place corrections.**
- **Where it lives:** the working transcript (recognized words plus the user's corrections, CAP-2) is stored in `VideoEditProject.transcript`. Corrections therefore follow Save, drafts and undo (ADR-24). Arrays are copy-on-write, so undo snapshots share the words.
- **Re-runs:** auto-edit reuses the project's transcript, so a re-run keeps corrections. "Transcribe again" ignores it.
- **Corrections:** a corrected phrase keeps its time span. Each new word gets a share of the span in proportion to its length, so captions stay in sync.
- **The panel:** an `NSTextView` with TextKit 1, not a SwiftUI flow of thousands of views. Selection and hit-testing come for free; word ranges map characters to words; the playing word is a temporary attribute, so playback never rebuilds the text.
- **Keys:** the editor's key monitor treats the read-only text view as not editing text, so space, ⌫ and undo keep working; ⌫ on selected words cuts them, or restores them if they're already removed. Return on selected words opens the correction popover.
- **Correcting (CAP-2):** double-click, Return or the context menu opens an `NSPopover` anchored to the words' first line. **Correct All** finds every other run that reads the same (`TranscriptWord.bare`, so case and punctuation don't matter) and keeps each one's own trailing punctuation. **Edit Text** swaps in a plain text editor; on Done, `TranscriptEditing` diffs the old and new words (`CollectionDifference`): unchanged words keep their times, each changed run takes the span of the run it replaced, and added words go into the silence beside them or share the previous word's time. Deleting text removes words from the transcript, never footage. Either way it's one undo step.
- **Cloud transcription (AI-5):** `CloudTranscriber` compresses the microphone track to 16 kHz AAC and posts it to ElevenLabs (`scribe_v2`, verbatim by default), an OpenAI-compatible Whisper endpoint (OpenAI, Groq), or OpenRouter, with the model chosen (ADR-45). Whisper's word list lacks punctuation, so punctuation is aligned back from its full text.
- **Stutters from audio (AE-5):** short words the recognizer stretched far beyond the speaker's pace, with a silence inside, are offered (switched off) as possible merged repeats.

**ADR-37: Captions are burned in by the compositor, from the corrected transcript.**
- **Settings:** `VideoEditProject.captions` holds on/off, style, position, size and the sidecar file format.
- **Cues:** `CaptionBuilder` turns the project's transcript into cues on the **output** timeline.
  - Removed words are dropped.
  - A cue breaks at sentence ends, at pauses of 0.35 s or more, and wherever footage was spliced out.
  - Each cue is at most two balanced lines of about 42 characters (32 for portrait) and lasts 0.8–6 s.
- **Rendering:** `RenderPlan` carries the cues, so the preview, MP4 and GIF all draw them through `VideoEditCompositor`. The active cue is rasterized once with Core Text (`CaptionRasterizer`, a small cache behind a `Mutex`) and composited on the canvas after the camera layer, unaffected by zooms.
- **Sidecar file:** after an MP4 export, an `.srt` or `.vtt` with the same cues is written next to it.
- **Deferred:** an embedded, switchable subtitle track (CAP-5) needs an `AVAssetWriter` pass and waits.

**ADR-38: Voice cleanup renders a processed copy of the microphone, offline.**
- **Settings:** `VideoEditProject.voice` holds the noise-removal preset (Off/Min/Medium/Max) and whether to normalize.
- **Pipeline** (`VoiceProcessor`, two offline `AVAudioEngine` passes, faster than real time):
  1. Decode the microphone track to 48 kHz mono.
  2. An 80 Hz high-pass, then `AUSoundIsolation` at the preset's wet/dry mix (Max uses the high-quality voice model). This pass measures the BS.1770 integrated loudness with our own `LoudnessMeter`; the SDK has none.
  3. Isolation delays its output (about 57 ms for Min and Medium, 92 ms for Max at 48 kHz) and doesn't report it. The delay is measured by lining up the loudness envelopes of the input and output (1 ms resolution, with the measured values as the fallback), and the next pass starts that late, so the voice stays in sync and keeps its last word.
  4. `AUPeakLimiter` with a pre-gain to −16 LUFS (−12…+24 dB) and a −1 dBFS ceiling, its reported look-ahead dropped, written as AAC.
- **Why offline, not a live tap:** an audio mix can't raise volume above 1.0, so the gain has to be baked into a file. Rendering once also makes the preview and the export identical, and scrubbing stays cheap.
- **Cache:** one file per recording and setting in `ProcessedAudio`, named by the recording and a hash of its path, with a sidecar holding the pipeline version, the recording's fingerprint and the track's start time. The two most recent settings per recording are kept. Files are rendered aside and moved into place, so the preview and an export can process the same voice at once.
- **Loading:** `ProcessedVoice` keeps the file's `AVURLAsset` alongside its track: a track only holds its asset weakly, and a composition built from an orphaned track fails.
- **Use:** the editor processes in the background on load and on every change, then swaps the file in for the microphone (`LoadedTracks.processedVoice`, offset by the start time) and redraws its waveform. The original plays until the processed copy for the current setting is ready; each change gets a run number, so a late result from an older setting is dropped. MP4 export builds through `CompositionBuilder.build(source:project:options:)`, which processes first (or reuses the cache) in the first quarter of the progress. GIFs have no audio.
- **Not processed:** system audio. Auto-edit keeps analyzing the original microphone.

**ADR-39: Camera backgrounds are drawn by the compositor, per frame.**
- **Settings:** `CameraOverlay.background` (`CameraBackground`): None, Blur, Replace (a color or a picture) or Remove, and how the person is separated (person detection or a green screen).
- **Where:** `FrameRenderer.cameraLayer` hands the upright, mirrored camera frame to `CameraMatte` before cropping it to the shape, so a replacement picture is never turned or mirrored. The preview, MP4 and GIF all go through it, so the background stays editable after recording.
- **Person detection:** Vision person segmentation, a new request per frame; Vision loads the model once (about 0.2 s, so the editor loads it in the background when a recording that needs it opens). The preview uses the fast level (256×192 mask), exports the balanced one (512×384): about 5 ms and 9 ms per 720p frame on the development Mac. The accurate level (about 30 ms) stays out of exports: a minute at 60 fps would take 2 minutes longer, and it also takes in the chair behind the person. If segmentation fails on a frame, that frame shows the camera unchanged.
- **Steady edges over time (CAM-5):** Vision finds the person in each frame on its own, so the outline wobbles by one to three mask pixels from frame to frame (3 to 10 pixels in a full-frame camera): a flickering edge. Each compositor (the preview, each export) owns a `MatteSmoother` holding the previous frame's luminance and mask at mask size. Where the luminance stayed put, the new mask is averaged in at a quarter weight; where it changed (spread two mask pixels), the new mask is taken as is, so the outline keeps up with the person. A seek, a cut, a frame out of order or another size starts over. A paused frame drawn again reuses its mask without running Vision. About 3 ms per export frame.
  - **Measured** on a recording with blur at full frame, as the flicker of the effect (composite minus the original frame): about half the back-and-forth in the band where it was worst. The noise threshold matters most: at a lower one, a high-contrast edge (hair against a wall) counts as moving on any small head movement, which is exactly where the edge flickers, and the smoother stood aside there: at 2.5 % instead of 6 %, a little over a third less flicker instead of nearly half. A softer edge for Blur took off only a few points more, and let a little blur into the person's face, so every effect keeps the narrowed edge below.
  - **Reusing one Vision request** across frames smooths its masks only at the fast level (about 30 % steadier); balanced and accurate give the same masks either way. So it doesn't help exports.
  - **Motion-compensated smoothing** (the previous mask moved along the optical flow before averaging) would keep smoothing at moving edges too, but Vision's optical flow takes about 25 ms per frame at mask size, too slow for the preview.
- **Edges (CAM-5):** the mask is read as raw coverage (not color-managed) and upsampled with `CIEdgePreserveUpsampleFilter`, guided by the camera frame, so its edge follows the person's instead of a stretched low-resolution outline. Then the soft band is narrowed (under 25 % coverage is background, over 75 % the person) and feathered by about a pixel. Scaling the mask and blurring it, as before, left a wide half-transparent band where the old background showed through as a halo. About 1 ms per frame.
- **Blur leaves the person out:** blurring the whole frame smeared the person's colors into the background around them. The background is cut out instead (alpha 1 − mask, floored at 2 % so the division stays defined), blurred with its alpha, and unpremultiplied: the blurred color divided by the blurred coverage.
- **Green screen:** a color-difference key in a 64³ `CIColorCubeWithColorSpace` (sRGB), built once per key setting under a lock. A color counts as screen when its key channel rises above the other two as much as the picked color's does, relative to its own brightness, so shadows on the screen key too and near-black never does. Spill removal pulls that channel back toward the others. The table holds straight (not premultiplied) colors: Core Image applies the alpha itself. A key color too gray to key on is flagged in the controls.
- **Replacement pictures** are copied into the app's backgrounds folder, like video backgrounds, so moving the original doesn't lose them.
- **Remove:** shows only the person, with a shadow from their outline, unless "Keep the Shape" is on.
- **Default (CAM-3):** `PreferenceKey.recordingCameraBackground` holds a JSON `CameraBackground`. `VideoEditProject.initial` seeds the camera with it, so the automatic camera composite (ADR-25) gets it too.
- **Camera saved in the video:** post effects are impossible. The recording options open the system's Video Effects menu instead (CAM-4).
- **Next, if edges still flicker:** a matte track computed once per recording, offline, where motion-compensated smoothing (optical flow) can afford its cost and frames can be smoothed both ways in time, cached like the processed voice; the compositor would only read it. Also the fallback if the preview is too slow on the M1. After that, edge color cleanup for Replace and Remove.
- **Models considered (October 2026):** no open-source model clearly beats Vision plus these fixes within the license rules. The best fit for video, a recurrent matting model, is GPL-3.0; the one permissive real-time portrait matting model (Apache-2.0) has no Core ML version yet and would need the matte track. Higher-quality still-image models are too slow for video or not licensed for redistribution. Details in [AUTO-EDIT.md](AUTO-EDIT.md) §4.4.

**ADR-40: The inspector shows one pane at a time; the timeline has its own viewport.**
- **Panes (VE-17):** `InspectorSection` lists the panes; `VideoEditorModel.inspectorSection` is the one on screen, chosen from a labeled icon rail on the trailing edge. Labels make the panes readable at a glance; the rail replaces the long stack of form sections and the old Inspector / Transcript switch. A dot marks panes with edits in the video.
- **Selection opens its pane:** the timeline's gestures set the pane (zoom → Zoom, cut → Cuts, auto-edit item → Auto-Edit's review). `selectAutoItem` is the single path for both the lane and the review list, so each shows what the other picked: the review scrolls to the card, and the timeline reveals the item.
- **Review is a step of Auto-Edit (AE-7):** `autoEditPage` switches Setup and Review; a finished analysis opens Review. The review is a lazy list of cards (hundreds of items stay cheap) with the words around each suggestion, found by binary search over the transcript.
- **Timeline viewport (VE-16):** `TimelineViewport` (zoom, start) is view state, not part of the project or undo. `TimelineScale` maps the visible window, so every lane and drag keeps working in seconds; lanes skip and mask items outside it. Blocks are drawn through `TimelineScale.block`, cut a little past the lane's ends (with grips only on ends that are on screen), and the lanes are stacked leading-aligned at exactly the timeline's width: a zoomed-in block drawn whole was thousands of points wide, which widened its lane and centered every other lane off its times, over the inspector. Scroll-wheel and pinch events come from a local event monitor owned by a background view of the timeline, because SwiftUI has no modifier-aware scroll hook and an overlay would take clicks and drags from the lanes. ⌘-scroll zooms by the physical direction (`isDirectionInvertedFromDevice`), so "away from you" zooms in whatever the scrolling setting.
- **Playback paging:** the player's time observer moves the viewport only when the playhead leaves it, so the lanes don't re-render 30 times a second.

**ADR-41: API keys are read only when a request is made, once per launch.**
- **Why:** without a Team ID, a Keychain item's partition is the code hash of the build that saved it. A rebuilt or updated app is a different program to the Keychain, so reading the key makes macOS ask for the login password. The editor's Auto-Edit pane read the provider and cloud keys on every render, so opening an editor after an update asked twice, and blocked the main thread until it was answered.
- **What reads what:** `APIKeyStore.hasKey(for:)` reads attributes only, which never prompts; Settings, the Auto-Edit pane and `AISettings` (ADR-45) use it. `APIKeyStore.key(for:)` reads the secret, off the main actor, when an analysis, cloud transcription or Test Connection is about to send it, and keeps it in memory for the rest of the launch.
- **Saving replaces the item** (delete, then add) rather than updating it, so the current build owns it and reading it back never prompts.
- **Rejected keys:** a 401 or 403 says the key was rejected and to save a new one in Settings ▸ AI.

**ADR-42: Editors open at once: a skeleton first, warmed up after launch.**
- **Measured:** the first editor of a launch took about 0.4 s to show a recording, mostly the main thread setting up AppKit, SwiftUI and AVKit for the first time; later ones about 0.2 s. With the old Keychain reads (ADR-41) waiting on prompts, nothing appeared for seconds.
- **Skeleton (VE-18):** the window opens with `EditorWindowContent`, a skeleton of the editor's layout, and starts loading the recording at once. The editor itself is mounted a couple of frames later, once the skeleton is on screen. If the editor was built before in this launch, the window skips the skeleton. A status line ("Opening the editor…", "Loading the recording…") fades in over the preview only after 400 ms, so quick opens don't flash it. Screenshots show the capture itself while the tools build.
- **Warm-up:** about 4 s after launch, when nothing is being captured or recorded, no window of ours is key and no menu is open, each editor is built once off screen and thrown away (about 0.2 s each). That makes the first real open as fast as later ones. Idle memory goes from about 24 MB to 55 MB, within the 80 MB budget.
- **One window per item:** reopening a recording or a capture-history screenshot that's already open brings its window forward.
- **Timing:** `openVideoEditor` / `loadRecording` / `openImageEditor` signposts, and an "Editor ready … in N ms" log line once the editor shows the recording.

**ADR-43: Camera layouts are time ranges evaluated per frame.**
- **Model (CAM-6):** `VideoEditProject.cameraLayouts`, `CameraLayoutSegment`s in source seconds (like zooms, so cuts and speed changes keep them on the same footage), never overlapping: Camera Only (`fullFrame`) or Screen Only (`hidden`). Outside them the camera is drawn as `CameraOverlay` says.
- **Rendering:** `CameraLayoutMath.state(at:)` gives a fullness (bubble → whole canvas) and a visibility, easing over 0.4 s at each end with the zoom curve. `FrameRenderer.cameraLayer` interpolates the layer's rect from the bubble (moved by a full-frame zoom) to the canvas, takes the corner radius and shadow down to zero, and crops the camera to the rect's shape as it changes. Background effects apply at every size, so Remove at full frame puts the person over the screen.
- **Show Camera off** means hidden outside the layouts; a Camera Only layout then fades the full-frame camera in instead of growing it from a bubble that isn't there. The plan includes the camera track whenever it shows anywhere.
- **Editing:** a lane under the zoom lane (only with a camera track) and a Layout section in the Camera pane. Adding fits the layout into the free space at the playhead; moving and resizing stop at neighbors. The preview's drag-to-move frame shows only while the camera is in its usual place.

**ADR-44: The camera track starts with the screen.**
- **Why (CAM-7):** the writer started its session on the first screen frame and dropped camera frames from before it, and camera delivery began only after the screen stream had started. The camera track began 0.1–0.15 s late, with an empty edit; with Remove, and with the editor parked on its first frame, the camera seemed to pop in.
- **Recording:** camera delivery starts before the screen stream. The writer keeps the newest camera frame from before the first screen frame and writes it at time zero; if none came, the first one after is held back to zero.
- **Older recordings:** `CameraTrackInfo.firstFrameTime` is where the track's first non-empty segment starts; `CompositionBuilder` inserts that frame, stretched, over the gap.

**ADR-45: Settings ▸ AI manages providers; each editor picks its own model and transcriber.**
- **Why (AI-8):** Settings held one provider, its model and its effort, and a separate transcription service with its own key. The editor read them through static UserDefaults wrappers, which SwiftUI doesn't observe, so a change in Settings didn't reach an open editor's pane, and trying another model or effort meant a trip to Settings.
- **Providers:** `AIProvider` (AutoEdit) describes each vendor or local server: its language-model preset (`ProviderPreset`), its speech-to-text API (`CloudTranscriptionService`), curated models, and where to get a key. One key per vendor serves both: an OpenAI, Groq or OpenRouter key transcribes too. Keys stay in the Keychain under the preset IDs as before; keys cloud transcription saved apart (`stt.*`) are read as a fallback and removed when a new key is saved.
- **One observable store:** `AISettings.shared` (`@MainActor @Observable`) holds the added providers (`ProviderAccount`: the provider and, for local servers, its URL), which have a key (attribute reads only, ADR-41), and the defaults: a `Judge` (rules or a `ModelChoice` of provider, model and effort) and a `Transcriber` (on device or a cloud provider and model). Settings and every editor observe it, so changes show everywhere at once.
- **Per editor:** `VideoEditorModel.judgeOverride` / `transcriberOverride` are the editor's own choices; `nil` follows the default, live. A choice whose provider was removed, or lost its key, falls back to the rules and on-device transcription (`AISettings.usable`).
- **Migration:** on first launch without `ai.providers`, the old provider becomes an added provider (and the default judge, if it was switched on), every saved key becomes an added provider, and the old transcription service becomes the default transcriber.
- **Prices:** `OpenRouterCatalog` reads OpenRouter's public `/api/v1/models` (no key, nothing about the user) once a day, only after a cloud provider is added, and caches it in `~/Library/Caches/Pankapture`. It prices OpenRouter's models live, and the curated models their makers sell directly (OpenAI, Anthropic, Google). Groq's prices are its own and are kept in the curated list. The model browser lists every OpenRouter model that supports structured output.
- **OpenRouter transcription:** its `/api/v1/audio/transcriptions` takes the same multipart form as Whisper's and answers in Whisper's shape, with word times, for the curated models. On a probe clip (2026-10-27), Scribe v2 and AssemblyAI kept "um" and a stutter; GPT Transcribe, Chirp 3 and Voxtral don't return word times.

**ADR-46: The app binary records the SDK it was built with.**
- **Why:** `swift build` stamps the deployment target (15.0) as the binary's SDK version (`LC_BUILD_VERSION`), and macOS picks an app's appearance from that field. Pankapture therefore ran in the macOS 15 compatibility look on newer systems: legacy toolbars and split views, and broken chrome around SwiftUI inspectors (an empty toolbar section over the history inspector, a divider that appeared only on hover, content showing through above the toolbar line).
- **Fix:** `scripts/bundle.sh` rewrites the build version with `vtool` (minimum unchanged, SDK from `xcrun --show-sdk-version`) before signing. Every window then gets the current system design. Code keeps gating newer APIs with `#available`; the deployment target is still macOS 15.
- **Check:** `otool -l build/Pankapture.app/Contents/MacOS/Pankapture | grep -A4 LC_BUILD_VERSION` shows the SDK. Test and eval binaries aren't stamped; they have no UI.

**ADR-47: Library names, tags, and folders live in the index only (HI-7…HI-9).**
- **Names:** `CaptureItem.customName` (empty when not renamed) is what the library, recent captures menu, Save As, and drags show; the file on disk keeps its name, so renaming works the same for unsaved captures, and bookmarks keep following moved files (`title` still tracks the file name).
- **Tags:** stored as one string, `"\nbug\ndesign\n"` (`TagCoding`), so `#Predicate` can filter with a substring match; SwiftData can't query arrays of values, and a tag relationship would make every query join. Tags are unique ignoring case and accents, and a new tag reuses an existing one's spelling. A tag exists while some capture has it.
- **Folders:** `CaptureFolder` (id, name) plus `CaptureItem.folderID`; one folder per capture, deleting a folder leaves its captures in the library. Folders never touch Finder.
- **Schema:** `LibrarySchemaV2` adds those attributes (with defaults) and `CaptureFolder`; `LibrarySchemaV1` is the shipped model, frozen in its own file so existing stores are recognized and migrated by a lightweight stage. Future model changes add a V3 the same way.
- **Drag and drop:** cards also offer `com.franklinperez.pankapture.capture-ids` (declared in Info.plist, own process only) carrying every dragged capture, so dropping on a sidebar folder moves them and on a tag tags them.

**ADR-34: Prompts and the default provider are chosen by an offline evaluation.** `pankapture-eval` (`make eval`) is a separate executable target, not part of the app bundle. It runs the app's analysis and prompt over labeled recordings kept outside the repo (PRD §11), caching each sample's transcript. It scores mistakes (by overlap, ±0.3 s), content lost, false positives on controls, and pause intent against a pass bar. The report carries a fingerprint of the prompt and schema, so runs can be compared.

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
 ├── Library        SwiftData history, OCR index, library window (M6)
 │
 │  smart editing (M8, macOS 26+), service modules
 ├── Transcription  on-device speech-to-text, transcript model                      → AppCore
 ├── AIProviders    BYOK clients (Anthropic, OpenAI-compatible), Keychain keys      → AppCore
 └── AutoEdit       mic extraction, pauses, screen activity, rules, model pass     → AppCore, Transcription, AIProviders

pankapture-eval (executable, developer tool, not bundled)                           → AutoEdit, Transcription, AIProviders
```

**Rules**
- Dependencies point **down**: app → feature modules → `AppCore`/`DesignSystem`. Feature modules never import the app target or each other's internals. Shared types move down a layer.
- Service modules (`Capture`, `Transcription`, `AIProviders`, `AutoEdit`) have no UI and sit between features and `AppCore`; features may depend on them, never the reverse.
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
| History index | `~/Library/Application Support/Pankapture/Library/Library.store` | SwiftData (`CaptureItem`: id, kind, createdAt, size/duration, exportURL, ocrText, customName, tags, folderID, …; `CaptureFolder`) |
| Recordings in progress | `~/Library/Application Support/Pankapture/Recordings/InProgress/` | fragmented MP4 + manifest JSON (crash recovery) |
| Recording metadata | `~/Library/Application Support/Pankapture/Sidecars/<video>.json` | `RecordingSidecar` (clicks for auto-zoom) |
| Video edits | `~/Library/Application Support/Pankapture/Edits/<video>.json`, unsaved edits in `<video>.draft.json` | `VideoEditProject` (ADR-24) |
| Layered recordings | `~/Library/Application Support/Pankapture/Recordings/Sources/<video>.mp4` | MP4 with the "Camera" track; the save folder has the composite (ADR-25) |
| Video backgrounds | `~/Library/Application Support/Pankapture/Backgrounds/<uuid>.<ext>` | copies of pictures/movies used as editor backgrounds |
| Transcripts | `~/Library/Application Support/Pankapture/Transcripts/<video>.<language>.json` | `Transcript` (words with times), cached by auto-edit (ADR-31) |
| Processed voice | `~/Library/Application Support/Pankapture/ProcessedAudio/<video>-<path hash>.<setting>.m4a` (+ `.json`) | Cleaned-up microphone audio, regenerated on demand (ADR-38) |
| Auto-edit suggestions | inside the video's project (`Edits/<video>.json`, key `autoEdit`) | `AutoEditLayer`: pauses, removals, pacing, user overrides (ADR-35) |
| AI provider | `UserDefaults["ai.providerConfiguration"]`; the key in the Keychain (service `com.franklinperez.Pankapture.ai-provider`) | `ProviderConfiguration` JSON, no secrets (ADR-32) |

File names use `CaptureFileNamer`: `Pankapture 2026-10-19 at 14.27.05.png`, with ` (2)`, ` (3)` on collision.

## 8. Permissions (TCC)

| Permission | Needed for | API | When requested |
|---|---|---|---|
| Screen & System Audio Recording | everything | `CGRequestScreenCaptureAccess` / first SCK call | first capture or onboarding |
| Microphone | REC-3 | `AVCaptureDevice.requestAccess(.audio)` | first recording with mic on |
| Camera | REC-10 | `AVCaptureDevice.requestAccess(.video)` | first time webcam is enabled |
| Accessibility | REC-12 keystrokes | `AXIsProcessTrustedWithOptions` | first time keystroke display is enabled |

Global hot keys and click highlighting (mouse-down global monitor) need no permission. Neither does on-device transcription: `SpeechTranscriber` runs without the Speech Recognition permission (ADR-31).

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
