# Pankapture — Roadmap

Milestones are ordered so each one leaves a **usable app**. Requirement IDs refer to [PRD.md](PRD.md). Check items off as they land.

---

## M0 · Foundations ✅

The project skeleton plus proof that the risky platform pieces work.

- [x] SwiftPM package with modules `AppCore`, `Capture`, `Annotation`, `DesignSystem`, plus the app shell
- [x] `.app` bundling + signing script, Info.plist, entitlements (hardened runtime)
- [x] Stable local signing identity script (`make cert`)
- [x] Menu bar app with no Dock icon (GL-1)
- [x] Global hotkeys via Carbon; ⇧⌘X registered by default (GL-2)
- [x] Settings: Appearance System/Light/Dark (GL-4), launch at login (GL-5), output basics, permissions panel (GL-6), read-only shortcuts list
- [x] ScreenCaptureKit display snapshots, excluding the app's own windows
- [x] Walking skeleton: ⇧⌘X captures the display under the cursor → clipboard + `~/Pictures/Pankapture`
- [x] Annotation model, undo/redo, arrow geometry, CoreGraphics renderer (with tests)
- [x] Design tokens, glass/material surface, tool button style
- [x] Docs: PRD, Architecture, Design, Roadmap, README, agent guide

**Before M1:** install Xcode (see ARCHITECTURE §9), run `make cert`, grant Screen Recording.

## M1 · Area capture + inline editor (daily driver)

The day this lands, the old screenshot tool can be uninstalled.

- [ ] `Overlay` module: per-display borderless panels showing the frozen frame (SC-1, SC-5)
- [ ] Crosshair, dimming, drag-to-select, dimension badge, loupe (SC-2)
- [ ] Selection handles, move, nudge, ⇧ aspect lock, ⌥ from center (SC-3)
- [ ] Inline tools bar: pen, line, arrow, rectangle, highlighter, text (AN-1); color + width (AN-3); ⇧ constraints (AN-4)
- [ ] Select/move/delete annotations, undo/redo (AN-5), single-key tool shortcuts (AN-6), remembered tool/style (AN-8)
- [ ] Actions bar: copy, save, save as, print, share, close (OUT-1…4, SC-13)
- [ ] Shortcut recorder with conflict detection (GL-3)
- [ ] Signposts: hotkey→overlay ≤ 150 ms, verified in Instruments

**QA:** two displays with mixed scale; capture over a full-screen app; capture menus and hover states; Esc at every stage; light and dark appearance.

## M2 · Screenshot extras

- [ ] Ellipse, blur, pixelate, numbered steps, crop (AN-2)
- [ ] Window capture with shadow/background options (SC-6); window snapping in area mode (SC-4)
- [ ] Fullscreen capture (SC-7), previous area (SC-8), self-timer (SC-9), cursor/desktop-icons options (SC-10)
- [ ] Quick-access thumbnail: stack, hover actions, drag-out, auto-dismiss (QA-1…4, OUT-6, OUT-7)
- [ ] Pin to screen: resize, opacity, click-through lock (PIN-1…4)
- [ ] Full annotation editor window + background/beautify (ED-1, ED-2)
- [ ] OCR capture to clipboard (SC-12)
- [ ] Scrolling capture with stitching + live preview (SC-11)
- [ ] Remaining output settings: name pattern, 1× export (GL-8), after-capture combos (GL-9)

## M3 · Screen recording core

- [ ] `Recording` module: SCStream → AVAssetWriter (ADR-4)
- [ ] Area / window / display sources (REC-1)
- [ ] System audio (REC-2), mic with device picker + level meter (REC-3), separate tracks (REC-4)
- [ ] MP4 H.264/HEVC, 30/60 fps, quality presets (REC-5)
- [ ] HUD + menu bar timer: stop, pause/resume, restart, cancel, mute (REC-6, REC-8); countdown (REC-7)
- [ ] Fragmented writing + crash recovery on next launch (REC-9)
- [ ] Recording thumbnails with hover preview (QA-5)

**QA:** 30-minute recording A/V sync test; pause/resume 10×; unplug display mid-recording; CPU ≤ 10% at 1080p60.

## M4 · Recording extras

- [ ] Webcam bubble: shape, size, drag, mirror, camera picker (REC-10)
- [ ] Click highlighting + click metadata sidecar (REC-11)
- [ ] Keystroke display with Accessibility onboarding (REC-12)
- [ ] Hide desktop icons / cursor (REC-13); GIF recording mode (REC-14); Focus reminder (REC-15)

## M5 · Video editor

- [ ] `VideoEditor` module: preview, filmstrip, per-track waveforms (VE-1)
- [ ] Trim (VE-2), cut segments (VE-3)
- [ ] Zoom & pan segments with eased transitions (VE-4); auto-zoom from clicks (VE-5)
- [ ] Background/padding/corners/shadow (VE-6)
- [ ] Per-track volume/mute (VE-7)
- [ ] Export MP4/GIF with presets, size estimate, background progress (VE-8, VE-9); copy/drag result (VE-10)
- [ ] Segment speed (VE-11, Could)

## M6 · Capture history

- [ ] `Library` module: SwiftData index + Application Support originals (HI-1)
- [ ] Library window: grid, filters, sort (HI-2); OCR + name search (HI-3)
- [ ] Re-edit with live annotations (HI-4, ED-3); recover discarded captures (OUT-8)
- [ ] Retention + storage cap (HI-5); recent captures in menu bar (HI-6)

## M7 · Polish & v1.0

- [ ] Onboarding (GL-7), app icon, About window
- [ ] Performance pass against every PRD §6.1 target on an M1 8 GB machine
- [ ] Accessibility audit (DESIGN §8) on every surface
- [ ] Two-week "daily driver" success-criteria run (PRD §7)
