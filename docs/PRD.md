# Pankapture — Product Requirements Document

| | |
|---|---|
| **Status** | v1 feature-complete (M0–M6, M7 partly); manual QA and performance pass pending. M8 (smart editing) planned |
| **Owner** | Franklin Perez |
| **Last updated** | 2026-10-26 |
| **Platform** | macOS 15 Sequoia or later, Apple Silicon only |
| **Distribution** | Personal use: GitHub release DMG + one-line Terminal installer, self-signed (not notarized), no App Store, no accounts, no network except the update check and AI providers the user configures (§5.12) |

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
- **G7: Private by default.** Everything is local. Nothing leaves the Mac unless the user explicitly shares it, or sends it to an AI provider they configured themselves (§5.12).
- **G8: Edit by speech.** A rough recording becomes a tight, captioned video in minutes: dead air, filler words, and retakes are suggested for removal and stay one click away from undo.

### Non-goals (v1)
- Cloud upload, share links, team workspaces, accounts, payments.
- Paying for, proxying, or metering anyone's AI inference. AI features use the user's own key or a local model (§5.12).
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
| U10 | Clean up a walkthrough without scrubbing through it: drop dead air, "um"s, and retakes, keep the deliberate pauses, add captions in English or Spanish, make the voice clear | Several per week |

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
| UP-1 | **Software updates:** Settings ▸ Updates shows the version, checks GitHub Releases (automatically once a day, can be turned off, or Check Now), and installs a newer release in place: it downloads and verifies it in the background, shows progress, then asks to restart (menu bar dot, menu item, notification), or installs on the next quit. Every merge to `main` publishes a release. | Must | M7 ✅ |

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
| REC-10 | **Webcam overlay:** a floating camera bubble (circle, rounded square, or rounded rectangle), resizable, draggable, mirror toggle, camera picker. The camera is recorded as its own layer (editable in the video editor); the saved video gets a copy with the camera drawn where the bubble was, made in the background with its progress on the thumbnail (its size is a setting). Alternatively the camera is recorded into the video, saved at once. | Must | M4 ✅ |
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
| VE-13 | **Camera layer:** move and resize the webcam in the preview; shape (circle, square, rectangle) with adjustable corner roundness, size, mirror, show/hide. Zooms leave it in place unless the zoom fills the frame. | Must | M5 ✅ |
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

### 5.11 Smart editing

Requires **macOS 26 or later**, because it relies on the on-device speech recognizer introduced there. On macOS 15 the editor doesn't offer these tools.

Everything runs on the Mac unless the user configured an AI provider (§5.12). Every automatic edit is a **suggestion**: it can be reviewed, switched off one at a time or by kind, and never touches the user's own cuts. The technical design is in [AUTO-EDIT.md](AUTO-EDIT.md).

**Auto-edit**

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| AE-1 | **Transcript:** on-device transcription of the microphone track with word timings, in **English or Spanish**. The language is chosen per recording and defaults to the system language. Speech models download on first use, with progress. | Must | M8 ✅ |
| AE-2 | **Pauses:** every pause of 0.3 s or more on the microphone track is detected and judged by **intent**:<br>• *hesitation* (mid-thought)<br>• *sentence break*<br>• *section break* (deliberate separation between parts)<br>• *emphasis* (deliberate dramatic pause)<br>• *screen action* (silent while the screen changes or the user clicks)<br>With a provider configured (§5.12), the model judges intent from the transcript and the screen activity; otherwise rules do. | Must | M8 ✅ |
| AE-3 | **Pacing:** each pause is shortened to a target length for its kind, set by a pacing preset: **Tight / Natural / Relaxed** (default Natural). Deliberate breaks keep their breathing room, so the result doesn't run everything together. Pauses are never lengthened. Screen-action pauses are never cut; speeding them up (2× or 4×) is an option. | Must | M8 ✅ |
| AE-4 | **Filler words:** "um", "uh", "er", "ah", "hmm" (English) and "eh", "em", "mmm", "este", "o sea", "pues" (Spanish). Ambiguous ones ("like", "you know", "bueno", "este" before a noun) count only when set apart by pauses, and are off by default. | Must | M8 ✅ |
| AE-5 | **Repeats and stutters:** for repeated words and phrases ("let me, let me"), the last one is kept. Stutters the transcript merges into one word are found from the audio and offered as lower-confidence suggestions. | Should | M8 ✅ |
| AE-6 | **Mistakes and retakes:** for false starts, corrections ("April. Wait, sorry, I meant May") and sentences said twice, the last take is kept. Rules catch correction phrases and repeated sentence openings; a configured provider catches the rest. | Must | M8 ✅ |
| AE-7 | **Review:** automatic edits sit on their own layer, struck through in the transcript and shown on a separate timeline lane, colored by kind. They can be toggled by kind (Pauses, Fillers, Repeats, Mistakes) or one at a time, and each says why it was suggested. Re-running the analysis replaces only automatic edits the user hasn't adjusted. | Must | M8 ✅ |
| AE-8 | **Adjust any segment:** drag either edge of any cut or kept clip, automatic or manual, to extend or shorten it (timeline handles, plus nudge keys at the playhead). The user can restore a removed part or mark a pause "keep as is". An automatic edit the user adjusts becomes theirs and survives re-runs. | Must | M8 ✅ |
| AE-9 | **Clean joins:** cut points snap to the quietest moment within ±80 ms, and every join gets a short audio fade (5–10 ms), so cuts don't click or clip words. | Must | M8 ✅ |
| AE-10 | **Edit by transcript:** a transcript panel next to the preview. Click a word to jump there; select words and press ⌫ to cut them; add a zoom over the selection. | Must | M8 ✅ |

**Captions**

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| CAP-1 | **Captions** from the transcript (English or Spanish), grouped into readable cues (at most 2 lines of about 42 characters, 0.8–6 s each). They follow cuts and speed changes. | Must | M8 ✅ |
| CAP-2 | **Correct the transcript** in place. Captions use the corrected text and keep their timing; corrections are saved with the project (VE-12). | Must | M8 ✅ |
| CAP-3 | **Burn captions** into MP4 and GIF exports, with a few style presets (position, size, background). | Must | M8 ✅ |
| CAP-4 | Save an **.srt / .vtt** file next to the exported video. | Should | M8 ✅ |
| CAP-5 | Embedded, switchable subtitle track in the MP4. | Could | later |

**Audio**

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| AU-1 | **Noise removal** on the microphone track: Off / Min / Medium / Max. It's non-destructive (a processed copy is cached), and system audio is never processed. | Must | M8 ✅ |
| AU-2 | **Normalize** the voice to a consistent loudness (−16 LUFS, peaks at or below −1 dBFS). | Must | M8 ✅ |
| AU-3 | The preview and the waveform use the processed audio. Processing runs in the background and shows progress. | Must | M8 ✅ |

**Camera**

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| CAM-1 | **Camera background:** none, blur (adjustable strength), replace (color or picture), or remove (the person cut out over the screen). Editable after recording. | Must | M8 |
| CAM-2 | **Green screen** key: pick the color, set the tolerance, remove spill. | Should | M8 |
| CAM-3 | A **default camera background** in Settings ▸ Recording, also applied to the automatic camera composite (REC-10). | Should | M8 |
| CAM-4 | A **Video Effects…** button in the recording options opens the system camera effects (portrait blur, background replacement). That's the only option when the camera is saved in the video. | Could | M8 |

### 5.12 AI providers (bring your own key)

Pankapture never pays for, proxies, or meters AI inference. A provider is optional:
- It improves pause judgment (AE-2) and mistake detection (AE-6).
- It enables verbatim cloud transcription (AI-5).

Everything else works without one.

| ID | Requirement | Priority | Milestone |
|---|---|---|---|
| AI-1 | **Off by default.** Without a provider, every smart-editing feature still works; pause judgment and mistake detection use rules. | Must | M8 ✅ |
| AI-2 | **Any provider, not one vendor:** presets for Anthropic, OpenAI, Google Gemini, Groq, OpenRouter, LM Studio and Ollama, plus any OpenAI-compatible endpoint (base URL + model). The model name is always editable. | Must | M8 ✅ |
| AI-3 | API keys live in the **Keychain** only, never in settings files, projects or logs. Settings ▸ AI has **Test connection**. | Must | M8 ✅ |
| AI-4 | For auto-edit, only **transcript text and pause timings** are sent, never audio or video, and only when the user starts the action. The button says what will be sent. | Must | M8 ✅ |
| AI-5 | **Cloud transcription (optional):** send the microphone audio to a configured speech-to-text provider (e.g. ElevenLabs Scribe, AssemblyAI) for a verbatim transcript that keeps fillers and stutters. Off by default, and marked as sending audio. | Should | M8 ✅ |
| AI-6 | Model answers are **checked** before they become suggestions: schema, word ranges, and a cap on how much may be removed. If any check fails, the rules' suggestions stand and a notice says why. | Must | M8 ✅ |
| AI-7 | **Evaluation harness:** `make eval` scores providers and prompts against the maintainer's labeled sample recordings (§11). It's a developer tool, not part of the app. | Must | M8 ✅ |

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
| On-device transcription of a 15 min recording | ≤ 90 s |
| Auto-edit analysis of a 15 min recording, excluding the AI provider's response time | ≤ 15 s |
| Noise removal + normalization of a 15 min microphone track | ≤ 45 s |
| Preview with a camera background effect | 30 fps, no dropped frames |

### 6.2 Reliability
- Recordings are written incrementally (fragmented) so a crash loses at most ~2 s.
- No capture is lost when the editor is closed if history is enabled.
- Graceful handling of display connect/disconnect, sleep, and permission revocation mid-session.

### 6.3 Privacy and security
- No telemetry or crash uploads. Network requests are limited to:
  - the update check (UP-1): an anonymous request for the latest GitHub release (once a day, can be turned off), plus the download when you install it;
  - requests to an AI provider, only when the user configured one and starts an action that uses it (§5.12). These carry transcript text, or microphone audio for cloud transcription (AI-5).
- AI provider keys are stored in the Keychain.
- Pankapture's own windows are excluded from every capture.
- OCR, transcription and all media processing run on device, except optional cloud transcription (AI-5).

### 6.4 Accessibility
- All controls are VoiceOver-labelled; full keyboard operation; respects Reduce Motion, Reduce Transparency, Increase Contrast, and the user's accent color.

### 6.5 Compatibility
- macOS 15.0+ on Apple Silicon. Some visuals (e.g. glass materials) are richer on macOS 26+ and gracefully fall back on 15.
- Smart editing (§5.11–5.12) needs macOS 26 or later. It isn't offered on macOS 15, and there is no fallback; everything else works there.

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
| On-device transcripts drop stutters and Spanish "eh" | Missed suggestions | Audio-based detection offered as suggestions; optional verbatim cloud transcription (AI-5). |
| A model suggests cutting real content | Lost content, lost trust | Suggestions only, checked answers, a cap on removal (AI-6), and a "content lost" bar in the evaluation (§11). |
| Hundreds of cuts make the preview stutter | Choppy editing | Performance test at 400 cuts on a 15 min recording; merge near-adjacent cuts. |
| AI model names and prices change every few months | Stale presets | Presets are data and the model field is editable; re-run the evaluation before changing the default. |

## 9. Open questions

1. Default after-capture flow: is **inline editor** the default for ⇧⌘X, with the thumbnail used only for window/fullscreen captures? (Current assumption: yes.)
2. Should a plain click (no drag) in area mode capture the hovered window (snapping), or the whole display?
3. Default save folder: `~/Pictures/Pankapture` (current) or `~/Desktop`?
4. Video editor: open automatically after every recording, or only from the thumbnail?
5. Keystroke display default: modifier combos only (more private), or all keys?
6. App icon and visual identity: any brand direction?
7. Default AI provider preset: decided by the evaluation (§11).
8. Default pause lengths for each pacing preset (AE-3): tuned on the evaluation recordings.

## 10. Appendix: reference

The inline editor follows the classic "annotate on the selection" layout: a dashed selection with a size badge at top-left, a vertical tool bar on the right edge (pen, line, arrow, rectangle, marker, text, color, undo), and a horizontal action bar under the bottom-right corner (upload, share, search, print, copy, save, close). Pankapture keeps that spatial model and modernizes the visuals; see [DESIGN.md](DESIGN.md).

## 11. Appendix: auto-edit evaluation

This is a small, repeatable test. It decides whether a model is worth using over the rules alone, and which AI provider and prompt the app recommends. It scores the two judgments a model makes:
- **mistakes** (AE-6);
- **pause intent** (AE-2).

The harness (`make eval`, AI-7) is ready. Prepare the samples and set up the providers, then run it (§11.5).

### 11.1 Questions it answers

1. Does a model beat the rules alone, without cutting real content?
2. Which provider and model should be the default preset? Quality comes first, then cost and speed.
3. Is the free local model (Qwen3.5 9B in LM Studio) good enough to recommend?
4. Did a prompt change help or hurt? Re-run after every prompt change.

### 11.2 Your part: the sample set

**Where.** Keep the samples outside the repository: it's public, and these are recordings of your voice.

```
~/PankaptureEval/
├── samples/
│   ├── dev/                      ← used while tuning prompts
│   │   ├── en-01-settings-tour/
│   │   │   ├── recording.mp4     ← the file Pankapture saved, untouched
│   │   │   └── labels.tsv
│   │   └── es-01-…/
│   └── test/                     ← held out: scored once, at the end
└── results/                      ← written by the harness
```

- Each sample folder's name starts with its language: `en-` or `es-`.
- Record with the **microphone on** and the camera off. The camera doesn't matter for this test, and a camera recording's saved copy is a composite.
- System audio can be on. Use your usual mic and room.

**How many.** 16 recordings: 8 in English and 8 in Spanish, 2–8 minutes each, about 60–90 minutes in total. Put 12 in `dev/`. Put 4 in `test/`: 2 per language, one of which is a control.

**What to record, per language:**

| Count | Kind | What to do |
|---|---|---|
| 3 | Natural | Real walkthroughs, recorded the way you normally would. Don't stage mistakes, and don't redo the ones that happen. |
| 2 | Staged mistakes | At least 4 mistakes each, of different types:<br>• a correction with a cue ("wait, sorry, I meant…", "perdón, digo…")<br>• a false start you abandon mid-sentence<br>• a sentence repeated whole, with no cue<br>• a stutter ("the the", "vamos a, vamos a") |
| 1 | Pacing | Clear sections separated by deliberate 2–3 s pauses, one dramatic pause for emphasis, a silent stretch where you click around without talking, and some natural hesitations mid-sentence. |
| 2 | Controls | Clean takes with **no mistakes**. Include lines that look like mistakes but aren't:<br>• emphasis ("very, very important", "no, no, no lo hagas así")<br>• quoted corrections ("people say April, but it's May")<br>• a deliberate repeat for teaching<br>These catch false positives. |

Ask your friend to record 2–4 of them, so the set has a second voice.

### 11.3 Your part: labeling

Each sample gets a `labels.tsv`: tab-separated values, one header row, times written as `m:ss.s`. To find the times, open the recording in Pankapture's editor; the playhead time shows tenths of a second. Within ±0.3 s is accurate enough, because the harness scores by overlap.

```
start	end	kind	note
0:12.4	0:15.1	retake	"April. Wait, sorry, I meant" → keeps "May"
1:02.0	1:04.8	false_start	"So what we're going to—"
1:30.2	1:33.9	repeat	first of two identical sentences
2:10.5	2:13.0	section_pause	intro → settings
2:41.0	2:42.6	emphasis_pause	before the reveal
3:40.0	3:52.0	action_pause	clicking through the menu without talking
```

| Kind | What it marks | Expected outcome |
|---|---|---|
| `retake` | The abandoned part of a correction, including the cue words | Removed |
| `false_start` | A sentence started and abandoned | Removed |
| `repeat` | The earlier copy of something said twice, or a stutter | Removed |
| `section_pause` | A deliberate break between parts | Kept; shortened at most to the section length |
| `emphasis_pause` | A deliberate dramatic pause | Kept; shortened at most to the emphasis length |
| `action_pause` | Silence while you do something on screen | Not cut |

- Label what should **disappear**, not what stays. For "the numbers for April. Wait, sorry, I meant May", label from the start of "April" to the end of "meant".
- When two takes are both fine, the last one is the keeper.
- Pauses you don't label count as hesitations or sentence breaks, which are fine to shorten.
- Filler words don't need labels: rules handle them, and they aren't scored here.
- A control gets a `labels.tsv` with only the header row, plus any deliberate pauses.
- If you're unsure about a spot, put `?` in its note. The harness lists those separately instead of scoring them.

### 11.4 Setting up the providers

Start with two providers:
- **Qwen3.5 9B in LM Studio:** local, free and private.
- **OpenAI gpt-6-luna:** cloud, about $0.001 per recording.

The harness always scores the **rules alone** too, as the baseline.

**LM Studio + Qwen3.5 9B.** You need a 16 GB Mac; the model needs about 7 GB of memory. The `lms` command-line tool comes with LM Studio, in `~/.lmstudio/bin`.

1. Download the model in MLX format, picking the 4-bit variant when asked (about 6 GB):
   ```
   lms get qwen/qwen3.5-9b --mlx -a
   ```
2. **Turn thinking off.** Qwen3.5 reasons before answering by default, which is slow and gets in the way of strict JSON. LM Studio's OpenAI-compatible endpoint has no per-request switch for it, so set it on the model: open its settings (My Models → Qwen3.5 9B → ⚙︎) and turn **Enable Thinking** off. The smoke test below shows whether it worked.
3. Load the model with room for long transcripts. A 15-minute transcript plus instructions is about 6–8K tokens.
   ```
   lms load qwen/qwen3.5-9b --context-length 32768 --identifier qwen3.5-9b
   ```
4. Start the server. It listens on `http://localhost:1234/v1`, on this Mac only, and keeps running until you run `lms server stop` or quit LM Studio. Don't add `--bind 0.0.0.0` or `--cors`.
   ```
   lms server start
   ```

**OpenAI gpt-6-luna.**

1. Create an API key in the OpenAI dashboard (platform.openai.com → API keys). Prefer a project key used only for this.
2. Set a monthly budget limit for that project, e.g. $5. The whole evaluation costs cents.
3. Put the key in your shell for the session only. Never put it in a file inside the repository. (The app stores keys in the Keychain, per AI-3; the harness reads environment variables.)
   ```
   export OPENAI_API_KEY="sk-…"
   ```
4. Request settings the harness uses:
   - model `gpt-6-luna`;
   - strict JSON-schema output;
   - no temperature;
   - `reasoning_effort` at both `none` and `low`, to see whether thinking helps. The model's default is `medium`, which bills more thinking tokens.

**Smoke test, for both providers, today.** It checks that each endpoint returns valid JSON for a tiny transcript. Save the request once:

```
mkdir -p ~/PankaptureEval
cat > ~/PankaptureEval/smoke.json <<'EOF'
{
  "messages": [
    {"role": "system", "content": "You edit screen recordings. Given numbered words, list the word ranges to cut: retakes, false starts, repeats. Keep the last take."},
    {"role": "user", "content": "[0]The [1]numbers [2]for [3]April. [4]Wait, [5]sorry, [6]I [7]meant [8]May [9]are [10]on [11]target."}
  ],
  "response_format": {
    "type": "json_schema",
    "json_schema": {
      "name": "cuts",
      "strict": true,
      "schema": {
        "type": "object",
        "properties": {
          "cuts": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "from": {"type": "integer"},
                "to": {"type": "integer"},
                "kind": {"type": "string", "enum": ["retake", "false_start", "repeat"]}
              },
              "required": ["from", "to", "kind"],
              "additionalProperties": false
            }
          }
        },
        "required": ["cuts"],
        "additionalProperties": false
      }
    }
  }
}
EOF
```

LM Studio:

```
jq '. + {model: "qwen3.5-9b"}' ~/PankaptureEval/smoke.json \
  | curl -s http://localhost:1234/v1/chat/completions \
      -H "Content-Type: application/json" -d @- \
  | jq -r '.choices[0].message.content'
```

OpenAI:

```
jq '. + {model: "gpt-6-luna", reasoning_effort: "none"}' ~/PankaptureEval/smoke.json \
  | curl -s https://api.openai.com/v1/chat/completions \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $OPENAI_API_KEY" -d @- \
  | jq -r '.choices[0].message.content'
```

Both should print something like `{"cuts":[{"from":3,"to":7,"kind":"retake"}]}`.
- If it prints `null`, run the command without the last `| jq …` to see the error.
- If LM Studio shows reasoning text, or takes more than a few seconds, thinking is still on.

### 11.5 Running it

```
export OPENAI_API_KEY="sk-…"
make eval EVAL_DIR=~/PankaptureEval \
  PROVIDERS="lmstudio:qwen3.5-9b openai:gpt-6-luna@none openai:gpt-6-luna@low" \
  RUNS=3
```

- `EVAL_DIR` defaults to `~/PankaptureEval`.
- Leave `PROVIDERS` out to score the rules alone. That's a quick way to check your labels before spending anything.
- Each provider is `preset[:model][@effort]`. The presets are `anthropic`, `openai`, `gemini`, `groq`, `openrouter`, `lmstudio`, `ollama` and `custom` (set `CUSTOM_BASE_URL`).
- Keys come from `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, `GROQ_API_KEY` and `OPENROUTER_API_KEY`.
- `SPLIT=all` scores both splits.
- `ONLY=en-01` runs only the samples whose folder name contains `en-01`.
- `TRANSCRIBER=elevenLabs` (or `openAI`, `groq`) transcribes in the cloud instead of on device, to measure whether a verbatim transcript catches more fillers and stutters. It sends the recordings' audio; the key comes from `ELEVENLABS_API_KEY`, `OPENAI_API_KEY` or `GROQ_API_KEY`. Each engine's transcripts are cached separately.
- If LM Studio or Ollama isn't answering, that provider is skipped with a note instead of failing every sample.

For each sample, the harness:
1. Transcribes the microphone track on device and detects pauses, with the same code the app uses. The transcript is cached, so later runs skip this step.
2. Sends each provider the same prompt the app sends, `RUNS` times, because model answers vary between runs.
3. Turns the answers into time ranges and scores them against `labels.tsv`, next to the rules-only baseline.
4. Writes `results/<date-time>/report.md` (scores, plus each disagreement with its timestamp) and the raw answers as JSON.

It scores `dev/` by default. `SPLIT=test` scores the held-out set; run that once, when choosing the default. A full run over the whole set costs well under $1 on OpenAI, and nothing on LM Studio.

### 11.6 Scores and pass bar

| Metric | How it's measured | Bar |
|---|---|---|
| Mistake recall | Share of labeled `retake` / `false_start` / `repeat` ranges that suggested cuts cover by at least 70% | ≥ 80% |
| Mistake precision | Share of suggested mistake-cut time that falls inside labeled ranges | ≥ 90% |
| Content lost | Seconds of suggested cuts over words outside any removal label, per 10 min of audio | ≤ 1 s |
| Control false positives | Mistake cuts suggested on a control recording | ≤ 1 per control |
| Deliberate pauses kept | Share of labeled section, emphasis and action pauses judged deliberate (not shortened to hesitation length) | ≥ 85% |
| Hesitations shortened | Share of unlabeled pauses of 1 s or more judged a hesitation or sentence break | ≥ 80% |
| Valid answers | Share of answers that match the schema on the first try (one retry allowed) | 100% cloud, ≥ 95% local |
| Stability | Share of decisions that change between runs of the same sample | ≤ 10% |
| Speed and cost | Median seconds and dollars per 10 minutes of recording | Reported only |

A model must beat the rules-only baseline on mistake recall or on deliberate pauses kept, and meet every bar.

### 11.7 Deciding

1. Open the latest `report.md`. For each disagreement, play that spot in the editor. If your label was wrong, fix `labels.tsv` (labels are data too) and run again.
2. Tune prompts on `dev/` only. After each change, re-run and compare with the previous report.
3. When the prompt is settled, run `SPLIT=test` once.
   - The best provider that meets every bar on the test set becomes the default preset. Ties go to the cheaper, faster or local option.
   - If Qwen3.5 9B meets every bar, it becomes the recommended free preset.
4. Record the result in §9 (question 7) and as an ADR.
