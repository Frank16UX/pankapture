# Pankapture — Roadmap

Milestones are ordered so each one leaves a **usable app**. Requirement IDs refer to [PRD.md](PRD.md). Check items off as they land.

---

## M0 · Foundations ✅

The project skeleton plus proof that the risky platform pieces work.

- [x] SwiftPM package with modules `AppCore`, `Capture`, `Annotation`, `DesignSystem`, plus the app shell
- [x] `.app` bundling + signing script, Info.plist, entitlements (hardened runtime)
- [x] Stable local signing identity script (`make cert`)
- [x] Menu bar app, single instance, Dock icon only while a standard window is open (GL-1)
- [x] Global hotkeys via Carbon; ⇧⌘X registered by default (GL-2)
- [x] Settings: Appearance System/Light/Dark (GL-4), launch at login (GL-5), output basics, permissions panel (GL-6), read-only shortcuts list
- [x] ScreenCaptureKit display snapshots, excluding the app's own windows
- [x] Walking skeleton: ⇧⌘X captures the display under the cursor → clipboard + `~/Pictures/Pankapture`
- [x] Annotation model, undo/redo, arrow geometry, CoreGraphics renderer (with tests)
- [x] Design tokens, glass/material surface, tool button style
- [x] Docs: PRD, Architecture, Design, Roadmap, README, agent guide

**Before M1:** install Xcode (see ARCHITECTURE §9), run `make cert`, grant Screen Recording. ✅ Done.

> **Status legend:** `[x]` built and covered by unit tests or checked on screen; `(needs QA)` built and compiled but not yet exercised by hand. The per-milestone **QA** lines are the manual checks still to do.

## M1 · Area capture + inline editor (daily driver) ✅

The day this lands, the old screenshot tool can be uninstalled.

- [x] `Overlay` module: per-display borderless panels showing the frozen frame (SC-1, SC-5)
- [x] Crosshair, dimming, drag-to-select, dimension badge, loupe (SC-2)
- [x] Selection handles, move, nudge, ⇧ aspect lock, ⌥ from center (SC-3)
- [x] Inline tools bar: pen, line, arrow, rectangle, highlighter, text (AN-1); color + width (AN-3); ⇧ constraints (AN-4)
- [x] Select/move/delete annotations, undo/redo (AN-5), single-key tool shortcuts (AN-6), remembered tool/style (AN-8)
- [x] Actions bar: copy, save, save as, print, share, close (OUT-1…4, SC-13); notification with Open / Show in Finder
- [x] Shortcut recorder with conflict detection (GL-3)
- [x] Signposts: `hotkey → overlay`, `render capture` (Instruments verification still to do)

**QA:** two displays with mixed scale (needs QA); capture over a full-screen app (needs QA); Esc at every stage; light and dark appearance.

## M2 · Screenshot extras ✅

- [x] Ellipse, blur, pixelate, numbered steps (AN-2). Crop: use the selection handles (no separate crop tool yet)
- [x] Window capture with shadow option (SC-6); window snapping in area mode (SC-4)
- [x] Fullscreen capture (SC-7), previous area (SC-8), self-timer (SC-9), cursor/desktop-icons options (SC-10)
- [x] Quick-access thumbnail: stack, hover actions, drag-out, auto-dismiss, swipe (QA-1…4, OUT-6, OUT-7) (needs QA)
- [x] Pin to screen: resize, opacity, click-through lock (PIN-1…4) (needs QA)
- [x] Full annotation editor window + background/beautify (ED-1, ED-2) (needs QA)
- [x] OCR capture to clipboard (SC-12)
- [x] Scrolling capture with stitching + live preview, manual or auto-scroll (SC-11) (needs QA on real pages)
- [x] Output settings: name prefix, 1× export (GL-8), after-capture thumbnail/editor (GL-9)

## M3 · Screen recording core ✅

- [x] `Recording` module: SCStream → AVAssetWriter (ADR-4, ADR-15)
- [x] Area / window / display sources (REC-1)
- [x] System audio (REC-2), mic with device picker + level meter (REC-3), separate tracks (REC-4)
- [x] MP4 H.264/HEVC, 30/60 fps, quality presets (REC-5)
- [x] HUD + menu bar timer: stop, pause/resume, restart, cancel, mute (REC-6, REC-8); countdown (REC-7)
- [x] Fragmented writing + crash recovery on next launch (REC-9)
- [x] Recording thumbnails with hover preview (QA-5)

**QA:** 30-minute recording A/V sync test; pause/resume 10×; unplug display mid-recording; CPU ≤ 10% at 1080p60; microphone capture (not yet exercised end to end).

## M4 · Recording extras ✅

- [x] Webcam bubble: shape, size, drag, mirror, camera picker (REC-10) (needs QA)
- [x] Click highlighting + click metadata sidecar (REC-11) (needs QA)
- [x] Keystroke display with Accessibility onboarding (REC-12) (needs QA)
- [x] Hide desktop icons / cursor (REC-13); GIF recording mode (REC-14); Focus reminder (REC-15)

- [x] Window recordings include the webcam/click/keystroke overlays (ADR-23)
- [x] Mixed default audio track so single-track players include the mic (REC-4, ADR-22)

## M5 · Video editor ✅

- [x] `VideoEditor` module: preview, filmstrip, per-track waveforms (VE-1)
- [x] Trim (VE-2), cut segments (VE-3)
- [x] Zoom & pan segments with eased transitions (VE-4); auto-zoom from clicks (VE-5)
- [x] Background/padding/corners/shadow (VE-6)
- [x] Per-track volume/mute (VE-7)
- [x] Export MP4/GIF with presets, size estimate, background progress (VE-8, VE-9); copy/drag result (VE-10)
- [x] Segment speed (VE-11)
- [x] Split at playhead and delete segments (VE-3); zoom duration handles, ⌫ deletes a zoom, full-frame zoom (VE-4)
- [x] Custom gradient, image, and video backgrounds; shadow no longer cut off at padding (VE-6)
- [x] Explicit save with unsaved-changes prompt and crash drafts (VE-12, ADR-24)
- [x] Editor reachable from the notification, menu bar (Edit Last Recording), and Open With (VE-1)
- [x] Webcam as its own layer: move/resize/shape/mirror/hide in the editor, unaffected by zooms; saved video composited automatically (VE-13, ADR-25)
- [x] Audio lanes labeled by source; silent tracks hidden (VE-7); 1440p and 4K export (VE-8)
- [x] Screenshots and recordings can include Pankapture's own editor/history/Settings windows (SC-11, ADR-26)

**QA:** timeline gestures with a real mouse (trim handles, zoom edges, zoom-rectangle editor); a video background playing in the preview; a recording with the webcam on (no camera dropout at start, thumbnail progress during the composite, editing the layer and its roundness); the export bottom sheet over bright and dark video; "Save camera: In the video" saves at once; closing the options panel hides the camera preview; screenshot and recording of the editor window.

## M6 · Capture history ✅

- [x] `Library` module: SwiftData index + Application Support originals (HI-1, ADR-12)
- [x] Library window: grid, filters, sort (HI-2); OCR + name search (HI-3)
- [x] Re-edit with live annotations (HI-4, ED-3); recover discarded captures (OUT-8)
- [x] Retention + storage cap (HI-5); recent captures in menu bar (HI-6)

**QA:** drag-out to Finder/other apps, Quick Look, Share from the library window.

## M7 · Polish & v1.0

- [x] Onboarding (GL-7), app icon, About
- [x] Release on every merge to `main`; in-app update check and install (UP-1, ADR-28) (needs QA: first update from one release to the next)
- [x] Export size as a percentage of the original (VE-14); Optimize for Sharing (VE-15, ADR-30) (needs QA: the export sheet by hand)
- [ ] Performance pass against every PRD §6.1 target on an M1 8 GB machine
- [ ] Accessibility audit (DESIGN §8) on every surface
- [ ] Two-week "daily driver" success-criteria run (PRD §7)
