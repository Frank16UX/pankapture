# Pankapture — Product Requirements Document

| | |
|---|---|
| **Status** | v1 feature-complete (M0–M6, M7 partly); manual QA and performance pass pending |
| **Owner** | Franklin Perez |
| **Last updated** | 2026-10-19 |
| **Platform** | macOS 15 Sequoia or later, Apple Silicon only |
| **Distribution** | Personal use: GitHub release DMG + one-line Terminal installer, self-signed (not notarized), no App Store, no accounts, no network |

---

## 1. Summary

Pankapture is a fast, native macOS menu bar app for **screenshots, annotation, and screen recording with system audio and microphone**, plus a lightweight **video editor** and a searchable **capture history**.

It replaces three separate tools in one daily workflow:

1. A quick "drag an area → annotate right on it → copy / save" screenshot tool (the original tool is Intel-only and no longer a good fit for Apple Silicon).
2. A premium all-in-one capture suite (scrolling capture, OCR, pinning, quick-access thumbnails, recording extras, video editing).
3. A screen recorder that **can't capture system audio or the microphone**, the main gap for recording tutorials and client walkthroughs.

## 2. Goals and non-goals

### Goals
- **G1: Instant.** Hotkey to an interactive selection overlay in ≤ 150 ms. It should feel instantaneous.
- **G2: Annotate in place.** Annotation tools appear right on the selection, with no extra window or extra click.
- **G3: Record walkthroughs with sound.** Record screen + system audio + mic (separate tracks) + optional webcam, reliably, with low CPU.
- **G4: Edit just enough.** Trim, cut, zoom, add a background, and export MP4/GIF without opening a pro video editor.
- **G5: Find anything later.** Every capture is in a searchable history, including text inside screenshots (OCR).
- **G6: Feel native.** It follows the system's look and feel, light / dark / system appearance, accessibility settings, and keyboard-first workflows.
- **G7: Private by default.** Everything is local. Nothing leaves the Mac unless the user explicitly shares it.

### Non-goals (v1)
- Cloud upload, share links, team workspaces, accounts, payments.
- Windows/Linux/Intel builds.
- Mac App Store distribution (the sandbox would constrain global hotkeys and capture).
- Live streaming, multi-camera production, or timeline editing beyond the features below.
- Telemetry or analytics of any kind.

## 3. Users and use cases

**Primary user:** a product designer / front-end developer who captures UI constantly, annotates bugs and feedback, and records tutorials and client walkthroughs.

| # | Use case | Frequency |
|---|---|---|
| U1 | Grab part of the screen, draw an arrow + box, paste into Slack/Jira/Figma | Many times a day |
| U2 | Capture a window cleanly (with shadow, or on a background) for docs or a deck | Daily |
| U3 | Blur sensitive data before sharing | Daily |
| U4 | Copy text from a screenshot, image, or video frame (OCR) | Weekly |
| U5 | Capture a long scrolling page or list | Weekly |
| U6 | Keep a reference image floating on top while working (pin) | Weekly |
| U7 | Record a 2–15 min walkthrough with voice and system sounds, webcam optional | Several per week |
| U8 | Trim the start/end, cut mistakes, zoom into details, export MP4 or GIF | Several per week |
| U9 | Find "that screenshot from last Tuesday with the error message" | Weekly |

## 4. Experience principles

1. **Zero-wait.** Capture first, ask later. Never block the hotkey on network, disk, or a window opening.
2. **Edit where you capture.** Tools live on the selection; full editors are optional escalations.
3. **Keyboard-first, mouse-friendly.** Every tool and action has a shortcut; everything is also one click away.
4. **Never lose work.** Recordings survive crashes; captures are in history even if you closed the editor.
5. **Native, calm, and themeable.** System materials, SF Symbols, semantic colors, light/dark/system, and respect for Reduce Motion / Reduce Transparency / Increase Contrast. See [DESIGN.md](DESIGN.md).

## 5. Functional requirements

Priority: **Must** = v1 blocker · **Should** = v1 target · **Could** = if time permits. Milestones refer to [ROADMAP.md](ROADMAP.md).

### 5.1 Global: menu bar, shortcuts, settings

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| GL-1 | Menu bar app, single instance; no Dock icon except while a standard window (Settings, editors, history) is open; the menu lists all capture/record actions with their shortcuts. | Must | M0 ✅ |
| GL-2 | Global shortcuts that work in any app. Defaults: **⇧⌘X → Capture Area**, **⌥⇧⌘X → Record Screen**. All other actions are unassigned by default. | Must | M0 ✅ |
| GL-3 | Shortcut recorder in Settings: assign, clear, reset to defaults, with conflict detection (warn if another app owns the shortcut). | Must | M1 ✅ |
| GL-4 | Appearance setting: **System / Light / Dark**, applied app-wide and live. | Must | M0 ✅ |
| GL-5 | Launch at login. | Must | M0 ✅ |
| GL-6 | Permissions panel showing status and a fix action for Screen Recording (required), Microphone, Camera, and Accessibility. | Must | M0 ✅ |
| GL-7 | First-run onboarding: explain and request Screen Recording; optional permissions are requested only when a feature first needs them. | Should | M7 ✅ |
| GL-8 | Output settings: save folder (default `~/Pictures/Pankapture`), file name pattern, image format (PNG/JPEG/HEIC), Retina-scale toggle (save at 1×), sounds on/off. | Must | M0 / M2 ✅ |
| GL-9 | After-capture behavior is configurable: any combination of *copy to clipboard*, *save to folder*, *show quick-access thumbnail*, *open full editor*. | Must | M1–M2 ✅ |

### 5.2 Screenshot capture

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| SC-1 | **Area capture.** The screen freezes on trigger (the capture is a crop of the frozen frame, so what you see is what you get); a crosshair cursor; drag to select; outside the selection is dimmed. | Must | M1 ✅ |
| SC-2 | Live **dimension badge** (W×H in points) and a **magnifier loupe** with pixel grid and color value near the cursor. | Must | M1 ✅ |
| SC-3 | Selection refinement: 8 resize handles, drag to move, arrow keys nudge 1pt (⇧ = 10pt), **⇧ locks aspect ratio**, **⌥ resizes from center**, Space+drag moves while drawing. | Must | M1 ✅ |
| SC-4 | **Window snapping:** hovering highlights the window or UI element under the cursor; click captures it. | Should | M2 ✅ |
| SC-5 | **Multi-display:** the overlay spans every display; the selection works per display; mixed Retina/non-Retina scales handled correctly. | Must | M1 ✅ |
| SC-6 | **Window capture:** pick a window; optional shadow; transparent or solid background; excludes other windows. | Must | M2 ✅ |
| SC-11 | Pankapture's own standard windows (image and video editors, history, Settings) can be captured and recorded like any app; its capture UI (overlay, HUD, thumbnails, pins, options panel) never is. | Should | M5 ✅ |
| SC-7 | **Fullscreen capture:** the display under the cursor, or all displays. | Must | M2 ✅ |
| SC-8 | **Capture previous area** repeats the last selection rectangle. | Should | M2 ✅ |
| SC-9 | **Self-timer** (3/5/10 s) for capturing menus and hover states. | Should | M2 ✅ |
| SC-10 | Option to include or hide the cursor; option to hide desktop icons during capture. | Could | M2 ✅ |
| SC-11 | **Scrolling capture:** select an area, scroll (auto or manual), and frames are stitched into one tall image with overlap detection; live preview while scrolling. | Must | M2 ✅ |
| SC-12 | **Capture text (OCR):** select an area → recognized text goes to the clipboard; on-device, multi-language, a toast confirms. | Must | M2 ✅ |
| SC-13 | Esc cancels at any point; Pankapture's own UI never appears in captures. | Must | M1 ✅ |

### 5.3 Inline annotation editor (on the selection)

After the drag, toolbars appear **attached to the selection**: a vertical tools bar on one side and a horizontal actions bar below. They reposition to stay on screen near edges (see the reference layout in [DESIGN.md](DESIGN.md#inline-editor-layout)).

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| AN-1 | Tools: **pen, line, arrow, rectangle, highlighter (marker), text**. | Must | M1 ✅ |
| AN-2 | Tools: **ellipse, blur, pixelate, numbered steps (auto-increment), crop**. | Must | M2 ✅ |
| AN-3 | Color picker: 8 swatches + custom color; stroke width (S/M/L); text size. | Must | M1 ✅ |
| AN-4 | ⇧ constrains lines/arrows to 45° and rectangles/ellipses to squares/circles. | Must | M1 ✅ |
| AN-5 | Select / move / restyle / delete an existing annotation; **undo / redo** (⌘Z / ⇧⌘Z). | Must | M1 ✅ |
| AN-6 | Single-key tool shortcuts while editing (P pen, L line, A arrow, R rectangle, O ellipse, H highlighter, T text, B blur, X pixelate, N steps). | Must | M1 ✅ |
| AN-7 | The selection can still be resized/moved after annotating (annotations keep their position relative to screen content). | Should | M1 ✅ |
| AN-8 | Tool, color, and width persist between captures. | Must | M1 ✅ |

### 5.4 Output actions

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| OUT-1 | **Copy** (⌘C) the flattened image to the clipboard (PNG). | Must | M1 ✅ |
| OUT-2 | **Save** (⌘S) to the default folder; **Save As…** (⇧⌘S) picks a location. | Must | M1 ✅ |
| OUT-3 | **Print** (⌘P) through the standard macOS print dialog. | Must | M1 ✅ |
| OUT-4 | **Share** through the macOS share sheet (Messages, Mail, AirDrop, Notes, etc.). | Must | M1 ✅ |
| OUT-5 | **Pin to screen** (see 5.6). | Must | M2 ✅ |
| OUT-6 | **Open in full editor** / **send to quick-access thumbnail** to finish later. | Must | M2 ✅ |
| OUT-7 | **Drag and drop** the capture directly from the thumbnail or editor into any app. | Must | M2 ✅ |
| OUT-8 | Close (Esc) discards the capture; it is still recoverable from history if history keeps unsaved captures (setting). | Should | M6 ✅ |

### 5.5 Quick-access thumbnail

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| QA-1 | After capture (if enabled), a floating thumbnail slides in at a screen corner (left or right, configurable). | Must | M2 ✅ |
| QA-2 | Hover reveals actions: copy, save, annotate (full editor), pin, delete, close. | Must | M2 ✅ |
| QA-3 | Drag the thumbnail into any app to drop the file. | Must | M2 ✅ |
| QA-4 | Multiple captures stack; auto-dismiss after N seconds (configurable, or never); swipe to dismiss. | Should | M2 ✅ |
| QA-5 | Recordings also land as thumbnails with play-preview on hover and trim/edit actions. | Must | M3 ✅ |

### 5.6 Pinned screenshots

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| PIN-1 | Pin any capture as an always-on-top borderless window. | Must | M2 ✅ |
| PIN-2 | Resize (pinch / scroll / drag corner), adjust opacity, move with drag. | Must | M2 ✅ |
| PIN-3 | Lock mode: click-through, so you can work underneath it. | Should | M2 ✅ |
| PIN-4 | Close with Esc or a hover close button; copy or save from its context menu. | Must | M2 ✅ |

### 5.7 Full annotation editor (window)

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| ED-1 | Window with all inline tools, zoom/pan canvas, and the same shortcuts. | Must | M2 ✅ |
| ED-2 | **Background / beautify:** padding, background (solid, gradient, wallpaper, image), corner radius, shadow, aspect-ratio presets (16:9, 4:3, 1:1, social formats). | Should | M2 ✅ |
| ED-3 | Non-destructive: annotations remain editable when re-opened from history. | Must | M6 ✅ |

### 5.8 Screen recording

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| REC-1 | Record an **area**, **window** (click it on screen, or choose it from a list that also reaches windows behind a full-screen app or in another Space), or **fullscreen** (any display). | Must | M3 ✅ |
| REC-2 | **System audio** capture (toggle), with Pankapture's own sounds excluded. | Must | M3 ✅ |
| REC-3 | **Microphone** capture with device picker and an input level meter before starting. | Must | M3 ✅ |
| REC-4 | System audio and mic are recorded as **separate audio tracks** (independent volume in the editor) and mixed down on export. The saved recording also carries a mixed default track, so players that play a single audio track (browsers, chat apps) include the mic. | Must | M3 ✅ |
| REC-5 | Output: **MP4 (H.264 or HEVC)**, 30 or 60 fps, quality presets; hardware encoding. | Must | M3 ✅ |
| REC-6 | Recording controls: menu bar timer + stop; floating control bar (stop, pause/resume, restart, cancel, mute mic) that is never captured. | Must | M3 ✅ |
| REC-7 | **Countdown** (0/3/5 s) before recording starts. | Should | M3 ✅ |
| REC-8 | **Pause / resume** produces one continuous file. | Must | M3 ✅ |
| REC-9 | Crash-safe: a recording interrupted by a crash or power loss is recoverable up to the last few seconds. | Must | M3 ✅ |
| REC-10 | **Webcam overlay:** a floating camera bubble (circle / rounded rectangle), resizable, draggable, mirror toggle, camera picker. The camera is recorded as its own layer (editable in the video editor); the saved video gets a copy with the camera drawn where the bubble was. | Must | M4 ✅ |
| REC-11 | **Click highlighting:** a visual ring on mouse clicks (color/size configurable). | Must | M4 ✅ |
| REC-12 | **Keystroke display:** shows pressed shortcuts/keys on screen (modifier combos only or all keys). Requires Accessibility. | Must | M4 ✅ |
| REC-13 | Option to hide desktop icons and to hide the cursor. | Should | M4 ✅ |
| REC-14 | **GIF recording** mode (direct to GIF, size/fps limits). | Should | M4 ✅ |
| REC-15 | Do-not-disturb hint: remind the user to enable Focus before recording (macOS doesn't allow toggling it programmatically). | Could | M4 ✅ |

### 5.9 Video editor

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| VE-1 | Opens after recording (configurable), from the quick-access thumbnail, the "Recording saved" notification, **Edit Last Recording** in the menu bar, history, or Open With on a movie file; scrubbable preview with filmstrip timeline and waveform per audio track. | Must | M5 ✅ |
| VE-2 | **Trim** start/end. | Must | M5 ✅ |
| VE-3 | **Cut** one or more middle segments: drag-select a range, or **split** at the playhead (S) and delete a segment (⌫). Video and audio are cut together. | Must | M5 ✅ |
| VE-4 | **Zoom & pan segments:** select a time range and a target rectangle; smooth eased zoom in/out. Drag the segment's end handles to change its duration; delete with ⌫. Optional **full-frame zoom** zooms past the padding and background until the zoomed area fills the video. | Must | M5 ✅ |
| VE-5 | Automatic zoom suggestions that follow clicks (from recorded click metadata). | Could | M5 ✅ |
| VE-6 | **Background:** padding, rounded corners, shadow, and a fill: color, preset or **custom gradient** (two colors + angle), **image**, or **video** (muted, looped). | Should | M5 ✅ |
| VE-7 | Per-track **volume and mute** (system / mic), labeled by source; a track that recorded only silence is hidden. | Must | M5 ✅ |
| VE-8 | **Export MP4** (resolution: original, 4K, 1440p, 1080p, 720p; fps, quality presets, estimated size) and **GIF** (width, fps, loop). | Must | M5 ✅ |
| VE-9 | Export runs in the background with progress; the editor stays responsive. | Must | M5 ✅ |
| VE-10 | Copy the exported file to the clipboard; drag the exported file out. | Should | M5 ✅ |
| VE-11 | Speed change for segments (e.g. 2× during boring parts). | Could | M5 ✅ |
| VE-13 | **Camera layer:** move and resize the webcam in the preview; shape, size, mirror, show/hide. Zooms leave it in place unless the zoom fills the frame. | Must | M5 ✅ |
| VE-12 | **Edit projects:** edits are saved explicitly (⌘S); closing or quitting with unsaved edits asks to Save / Don't Save / Cancel; unsaved edits survive a crash as a draft. Reopening the recording restores the saved project. | Must | M5 ✅ |

### 5.10 Capture history (library)

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| HI-1 | Every screenshot and recording is recorded in a local library, with thumbnail, type, date, dimensions/duration, and file location. | Must | M6 ✅ |
| HI-2 | Library window: grid view; filter by type (screenshot / recording / GIF) and date; sort. | Must | M6 ✅ |
| HI-3 | **Search** by OCR text inside screenshots, and by file name. | Must | M6 ✅ |
| HI-4 | Actions: open, re-edit (annotations still editable), copy, reveal in Finder, share, delete. | Must | M6 ✅ |
| HI-5 | Retention: keep forever / 30 / 90 days; optional storage cap. | Should | M6 ✅ |
| HI-6 | Recent captures submenu in the menu bar (last 5–10). | Should | M6 ✅ |

## 6. Non-functional requirements

### 6.1 Performance (measured on the slowest supported machine, M1 with 8 GB)

| Metric | Target |
|---|---|
| Hotkey → selection overlay visible | ≤ 150 ms p95 (goal 100 ms) |
| Release mouse → toolbars visible | ≤ 50 ms |
| Copy of an annotated 5K capture | ≤ 200 ms |
| Idle CPU | ~0% (no timers or polling while idle) |
| Idle memory | ≤ 80 MB |
| 1080p60 recording CPU | ≤ 10% (hardware encoder) |
| 4K60 recording | 0 dropped frames on M1 Pro or newer |
| App launch to ready | ≤ 1 s |
| Export of 1 min 1080p MP4 | ≤ 30 s |

### 6.2 Reliability
- Recordings are written incrementally (fragmented) so a crash loses at most ~2 s.
- No capture is lost when the editor is closed if history is enabled.
- Graceful handling of display connect/disconnect, sleep, and permission revocation mid-session.

### 6.3 Privacy and security
- No network access. No telemetry, crash uploads, or update checks in v1.
- Pankapture's own windows are excluded from every capture.
- OCR and all processing run on device.

### 6.4 Accessibility
- All controls are VoiceOver-labelled; full keyboard operation; respects Reduce Motion, Reduce Transparency, Increase Contrast, and the user's accent color.

### 6.5 Compatibility
- macOS 15.0+ on Apple Silicon. Some visuals (e.g. glass materials) are richer on macOS 26+ and gracefully fall back on 15.

## 7. Success criteria

v1 is done when, for two consecutive weeks, it has fully replaced the three existing tools in daily work:
- 100% of daily screenshots go through Pankapture (no fallback to the system screenshot tool).
- At least 5 client/tutorial recordings with voice + system audio were recorded and exported with no audio-sync issues.
- No lost recordings, and no hotkey-to-overlay latency noticeably slower than the old screenshot tool.

## 8. Risks and mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Privacy permissions reset after every rebuild (ad-hoc signing) | Dev friction | Stable local signing identity (`make cert`), documented in README. |
| macOS periodically re-confirms Screen Recording access for third-party capture apps | Occasional prompt | Accept; document in README; consider the system content picker for window recording. |
| Scrolling capture stitching errors (sticky headers, animations) | Broken tall images | Image registration with overlap detection + sticky-region detection; manual mode fallback. |
| Audio drift between mic and system tracks on long recordings | Out-of-sync videos | Single capture clock (ScreenCaptureKit timestamps for both), and long-recording tests. |
| Global shortcut conflicts with other apps | Hotkey not firing | Conflict detection in the shortcut recorder; few default shortcuts. |
| Scope: v1 includes every feature group | Long time-to-useful | M1 is a usable daily driver on its own; later milestones ship incrementally. |

## 9. Open questions

1. Default after-capture flow: is **inline editor** the default for ⇧⌘X, with the thumbnail used only for window/fullscreen captures? (Current assumption: yes.)
2. Should a plain click (no drag) in area mode capture the hovered window (snapping), or the whole display?
3. Default save folder: `~/Pictures/Pankapture` (current) or `~/Desktop`?
4. Video editor: open automatically after every recording, or only from the thumbnail?
5. Keystroke display default: modifier combos only (more private), or all keys?
6. App icon and visual identity: any brand direction?

## 10. Appendix: reference

The inline editor follows the classic "annotate on the selection" layout: a dashed selection with a size badge at top-left, a vertical tool bar on the right edge (pen, line, arrow, rectangle, marker, text, color, undo), and a horizontal action bar under the bottom-right corner (upload, share, search, print, copy, save, close). Pankapture keeps that spatial model and modernizes the visuals; see [DESIGN.md](DESIGN.md).
