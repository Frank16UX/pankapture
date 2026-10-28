# Smart editing: technical assessment

| | |
|---|---|
| **Status** | Decided 2026-10-26 (§9). Requirements are in [PRD §5.11–5.12](PRD.md#511-smart-editing), the evaluation in [PRD §11](PRD.md#11-appendix-auto-edit-evaluation), and the plan in [ROADMAP M8](ROADMAP.md#m8--smart-editing). Built in M8; ROADMAP M8 lists what remains. |
| **Branch** | `feature/auto-edit` |
| **Date** | 2026-10-26 |
| **Scope** | Auto-edit (pauses, fillers, stutters, mistakes), editable captions (English, Spanish), noise removal and loudness normalization, camera background effects |

This document assesses what the four features need, what the platform already gives us, where AI is actually required, and what it costs. The PRD says *what* to build; this document says *how*. ADRs go into ARCHITECTURE §2 as each phase lands.

Facts marked *(probe)* were measured on this Mac (macOS 27.0.1, M4 Pro) with small throwaway programs. The filler and stutter probes used synthesized voices, so treat what they say about real speech as indicative only.

---

## 1. Summary

- **Most of this runs on device for free.** The pieces come from system frameworks:
  - **Transcription:** `SpeechAnalyzer` + `SpeechTranscriber` (macOS 26+) gives word timings in English and Spanish, runs at about 50× real time, and needs no permission prompt.
  - **Noise removal:** `AUSoundIsolation` is public and runs offline at about 90× real time. Its wet/dry control maps directly to min, medium and max presets.
  - **Person segmentation:** Vision's segmentation takes about 9 ms per 720p frame at the balanced level.
  - **Silence detection and loudness measurement:** plain DSP that we write ourselves.
- **AI inference is needed for two judgments only:** spotting mistakes and retakes ("April. Wait, sorry, I meant May"), and telling a deliberate pause from a hesitation. Both are about meaning, so rules alone can't make them reliably.
  - Both judgments are made in one call that sends **transcript text and pause timings** (not audio) to a provider the user configures: bring your own key, or a local model. Without a provider, rules make both judgments.
  - It costs about **$0.001 per 15-minute recording** on the cheap tiers.
  - Apple's on-device model failed a small retake test, so it isn't the default.
- **The current architecture fits these features well.** Each feature builds on something we already have:
  - The microphone is its own track (ADR-16), so detection only ever hears the voice.
  - The camera is its own track (ADR-25), so background effects can be applied after recording, non-destructively.
  - Cuts are stored in source seconds, which is exactly what a transcript produces.
  - Every frame already goes through our Core Image compositor, which can also draw captions and camera effects.
- **The hard part is fillers and stutters, not silences.** On-device speech recognition tidies speech:
  - It keeps "um" and "uh" in English and "este" in Spanish.
  - It drops Spanish "eh", and it merges stutters ("the the" becomes one "the", stretched over both).
  - So stutters must be found from the audio, with lower confidence. An optional verbatim cloud transcriber (BYOK) fixes this for users who want it.
- **Rough effort is 10–12 weeks for one developer, in six phases (§7).** The analysis engine and an evaluation harness come first, so prompts are tuned on real recordings before any editor UI is built.

## 2. Constraints

- **No paid inference, no single vendor.** The project never pays for anyone's AI use, and no feature depends on one provider. Every feature works without a key. A key, or a local model, improves the two judgments above and unlocks optional cloud transcription.
- **Privacy (PRD G7, §6.3).** Nothing leaves the Mac unless the user configured a provider *and* asked for that action. Even then, only the transcript text is sent; audio is sent only for the optional cloud transcriber. The PRD's "the only network request is the update check" wording must change.
- **No third-party dependencies (ADR-10).** Everything below uses system frameworks. The open-source alternatives evaluated in §5.3 don't solve fillers better, so they don't justify a dependency.
- **Smart editing needs macOS 26.** The whole feature set is gated with `#available(macOS 26, *)` and isn't offered on macOS 15. There is no fallback recognizer; the rest of the app keeps its macOS 15 minimum. CI builds on `macos-26` with the newest Xcode. Gate any macOS 27-only API (such as `AssetInputSequenceProvider`) so the build doesn't depend on the runner's SDK.
- **No SwiftPM resources.** Filler-word lists and prompts live in code.

## 3. What we build on

| Existing piece | Why it matters |
|---|---|
| Separate "Microphone" track (ADR-16) | Silence, filler and speech detection read the voice only. System audio (music, notification sounds) never confuses them. |
| Separate "Camera" track (ADR-25) | Segmentation runs after recording, on clean frames, and stays editable. The automatic camera composite uses `VideoEditProject.initial(for:)`, so a default effect flows into it for free. |
| `VideoEditProject.cuts` in source seconds, and `Timeline` | Auto-cuts are just more ranges. Source↔output time mapping already exists (`outputTime(forSource:)`), and captions reuse it. |
| `VideoEditCompositor` + `FrameRenderer` (Core Image) | Caption and camera-effect drawing slot into the same render path, so the preview matches the export. |
| `WaveformExtractor` | Already decodes a track to PCM. A finer-grained loudness (RMS) envelope for silence detection is a small extension. |
| `ZoomSegment.isAutomatic` / `applyAutoZooms` | Precedent for "suggested edits that a re-run replaces, while manual edits stay". |
| Sidecar clicks (`RecordingSidecar`) | Shows where on-screen activity happens. That protects silent-but-busy stretches from being cut (§4.1). |
| Project save + drafts (ADR-24) | Auto-edits and transcript corrections get explicit save and crash safety for free. |

---

## 4. Features

### 4.1 Auto-edit: pauses, fillers, stutters, mistakes

```
Microphone track ─┬─▶ loudness envelope (10 ms frames) ──▶ pauses (where, how long)
                  └─▶ SpeechTranscriber (word timings) ──▶ fillers (word lists)
                                                       ├─▶ repeats (n-gram rules)
                                                       └─▶ stutters (word length vs. audio bursts)
     sidecar clicks + frame diffs ──▶ screen activity per pause
  transcript + pauses + activity ──▶ intent: rules, or one model call ──▶ mistakes + pause kinds
  pause kinds × pacing preset ──▶ pause cuts ┐
  fillers, repeats, stutters, mistakes ──────┴▶ snap to quiet points ──▶ automatic-edit layer ──▶ Timeline
```

**Pauses: where they are** (DSP)
- Compute the microphone's level in 10 ms frames.
- Estimate the noise floor adaptively (around the 10th percentile, in dB). Treat audio more than about 10 dB above the floor as speech, with hysteresis, and ignore blips under 80 ms.
- A pause must also be a gap between transcribed words. This stops breaths and room noise from counting as speech.
- Every pause of 0.3 s or more is kept as a candidate, along with its screen activity. Activity means clicks from the sidecar, plus visible change: the mean frame difference over 4 fps low-resolution frames, generated like the filmstrip.

**Pauses: what they're for** (PRD AE-2)
- A silence is not automatically waste. A break between sections, or a beat before a reveal, is deliberate; running everything together sounds rushed.
- Each pause gets one of five kinds:
  - *hesitation*: mid-thought;
  - *sentence break*;
  - *section break*: a deliberate separation between parts;
  - *emphasis*: a deliberate dramatic pause;
  - *screen action*: silent while the screen changes or the user clicks.
- With a provider configured, the model assigns the kinds (see "Model pass" below). Without one, rules do:
  - screen activity during the pause → screen action;
  - no sentence-ending punctuation before the pause → hesitation;
  - sentence end, pause of 1.5 s or more, and the next sentence opens with a transition ("now", "next", "let's", "okay", "ahora", "vamos a", "bueno", "pasemos") → section break;
  - anything else → sentence break.
  - Rules can't recognize emphasis; that's one reason to use a model.

**Pauses: how long they become** (PRD AE-3)
- Each pause is shortened to a target length for its kind and the pacing preset. Pauses are never lengthened. The model only judges intent; the app decides the lengths, so changing the preset is instant and needs no new model call.
- Starting targets, in seconds, to be tuned on the evaluation recordings (PRD §9, question 8):

  | Kind | Tight | Natural (default) | Relaxed |
  |---|---|---|---|
  | Hesitation | 0.10 | 0.15 | 0.25 |
  | Sentence break | 0.25 | 0.40 | 0.60 |
  | Section break | 0.60 | 1.00 | 1.50 |
  | Emphasis | 0.50 | 0.80 | 1.20 |
  | Screen action | not cut | not cut | not cut |

- Screen-action pauses are never cut, so a walkthrough keeps its clicks and typing. Speeding them up (2× or 4×, via the existing `SpeedSegment`) is an option. This is the main difference from tools built for talking heads.
- The kept part of a pause is centered on the quietest stretch, with at least 0.1 s on each side of speech, so words don't sound clipped.

**Transcription**: see §5.3 for the engine comparison. Default: `SpeechTranscriber`.
- Set `attributeOptions: [.audioTimeRange, .transcriptionConfidence]` to get one run per word, with its time range and confidence. Times come in 60 ms steps *(probe)*.
- Supported locales include en-US/GB/AU/CA/IN/IE/NZ/SG/ZA and es-ES/MX/US/CL.
- There's no language detection, so the user picks English or Spanish (default from the system locale, remembered per recording).
- **Language models:** about 380 MB (English) and 340 MB (Spanish). They download on first use through `AssetInventory`; they're system-managed and shared with other apps, but progress isn't reported in bytes. A 9.6-minute file transcribed in 11 s *(probe)*.
- No TCC prompt is needed. Apple's permission flow applies only to `SFSpeechRecognizer`.

**Fillers**
- Match words against per-language lists:
  - English: um, uh, er, ah, hmm.
  - Spanish: eh, em, mmm, este, o sea, pues.
- Ambiguous fillers ("like", "you know", "so", "bueno", "este" before a noun) count only when isolated by a pause of at least 150 ms or by punctuation. They're lower confidence and off by default.
- What on-device recognition keeps *(probe)*:
  - English: keeps "um" and "uh" ("uh" sometimes comes out as "ah").
  - Spanish: keeps "este", drops "eh".
- **Dropped fillers** show up as either:
  - a voiced gap (the loudness envelope says speech, but no word covers it), which becomes a filler candidate; or
  - a neighbouring word stretched over the filler, which is handled like a stutter.

**Stutters and repeats**
- **Repeated phrases still in the transcript** ("let me, let me"): an n-gram rule finds them and cuts the earlier copy.
- **Single-word stutters are merged by the recognizer** *(probe)*:
  - "the the" becomes "the", and "I I I" becomes "I".
  - In Spanish, the "a" of "vamos a, vamos a" was stretched to 0.78 s.
- **Detecting merged stutters:**
  - Estimate the speaker's typical duration per character.
  - Flag short words that last more than about 2× the expected time *and* contain two or more loudness bursts separated by dips.
  - Suggest cutting the earlier bursts and keeping the last.
- This is a heuristic. It needs tuning on real voices and is shown as a suggestion, not applied silently.
- The optional verbatim cloud transcriber (§5) removes the guesswork.

**Mistakes and retakes**
- **Rules first:**
  - A sentence whose opening words largely repeat an earlier sentence's means a retake: keep the last take.
  - Correction cues ("wait", "sorry", "I mean", "let me start over", "perdón", "digo", "mejor dicho", "espera") mean: cut from the start of the abandoned clause to the end of the cue.
**Model pass** (when a provider is configured)
- One call makes both judgments: mistakes, and the kind of every pause.
- **Input:** the transcript as numbered words, with each pause inline, marked by its length and screen activity:

  ```
  [41]so [42]that's [43]the [44]dashboard. ⟨p7 2.4s screen:still⟩ [45]Now [46]let's [47]open [48]settings
  [49]and [50]the [51]numbers [52]for [53]April. [54]Wait, [55]sorry, [56]I [57]meant [58]May …
  ⟨p8 6.1s screen:3 clicks, changing⟩ …
  ```

- **Output:** strict JSON with two lists:
  - `cuts`: `[{from, to, kind: retake | false_start | repeat, reason}]`
  - `pauses`: `[{id, kind: hesitation | sentence | section | emphasis | action}]`
- **The system prompt** explains why pauses matter. Deliberate breaks between sections and beats for emphasis are part of a good edit, so when unsure, the model should pick the longer kind. It also asks the model to keep the last take, and never to cut meaning.
- **Long transcripts:** cloud models have context to spare. Local models get chunks of about 1,500 words that overlap by about 100 words.
- **Checks before use** (PRD AI-6):
  - word indices are in range;
  - cuts don't overlap;
  - every pause ID is known;
  - total removed time stays under a cap.
  - If any check fails, the rule-based results stand. The prompt and schema are the same in the app and in `make eval`.

**Edit model**
- Add an automatic-edit layer to `VideoEditProject`, next to the user's `cuts`. It holds:
  - `pauses`: each pause's range, kind, who decided the kind (rules, model or user), and an optional "keep as is" override;
  - `pacing`: the preset;
  - `suggestions: [AutoCut]`: fillers, repeats, stutters and mistakes. Each `AutoCut` holds its `range` (source seconds), `kind`, `isEnabled`, `confidence`, `reason` and `isUserAdjusted`.
- `Timeline` subtracts the enabled suggestions, plus the pause cuts computed from each pause's kind and the pacing.
- **Adjusting any segment** (PRD AE-8): the timeline gets handles on both edges of every cut and every kept clip, automatic or manual, plus nudge keys at the playhead.
  - Dragging an automatic edit turns it into a fixed range with `isUserAdjusted` set.
  - Re-running analysis replaces only automatic edits that are neither adjusted nor overridden. The user's own cuts, trims and splits are never touched (the same pattern as `applyAutoZooms`).
- New keys use `decodeIfPresent`, so older projects still open.

**Making cuts sound clean**
- **Snap each boundary** to the quietest 10 ms frame within ±80 ms. Recognizer timings are only 60 ms-grained, and a cut mid-consonant is audible.
- **Short audio fades (5–10 ms) at every join**, via `setVolumeRamp` on the audio mix. Without them, joins click. Today the mix sets one constant volume, so this changes `CompositionBuilder.build` and the preview's `audioMix(for:)`.
- **Hundreds of cuts:** a 15-minute recording can produce 200–400 of them.
  - The `Timeline` math stays fast.
  - Each kept piece is inserted into every track: 400 pieces × 4 tracks ≈ 1,600 insertions.
  - We need a preview-smoothness test at that scale before shipping. The fallback is to merge cuts closer than about 0.1 s.

**UI**: a transcript panel in the editor.
- Words in an auto-cut are struck through and tinted by kind.
- Toggle chips: Pauses, Fillers, Repeats, Mistakes, plus the pacing preset.
- Clicking a word seeks there. Selecting words and pressing ⌫ cuts them; that's manual editing on the transcript.
- A selection popover offers Cut and Zoom: a zoom over the selection's time range uses the existing `addZoom`.
- Implement it with `NSTextView` (TextKit 2) and per-word attributes, not a SwiftUI flow of thousands of views. Hit-testing, selection and in-place correction then come built in, and the text stays fast for a 2,000-word transcript.
- The timeline shows auto-cuts as a separate, dimmer lane, so they can be told apart from manual cuts and toggled.

### 4.2 Captions (English, Spanish; editable)

- **Data:** `Transcript { locale, engine, words: [{text, start, end, confidence}] }`, in source seconds.
  - Stored at `Application Support/Pankapture/Transcripts/<video>.json`.
  - Corrections follow ADR-24: explicit save, plus a crash draft.
- **Corrections:**
  - Editing a word keeps its timing.
  - Retyping a phrase with a different word count spreads the original time span over the new words, weighted by character count.
  - Captions use the corrected text.
- **Cue builder** (pure and unit-tested):
  - At most 2 lines of 42 characters (fewer for portrait aspect ratios).
  - Each cue lasts 0.8–6 s.
  - Cues break at sentence ends, commas and pauses of ≥ 0.35 s.
  - Times map to output time through `Timeline`; words inside cuts are dropped, and a cue that spans a cut is split.
- **Burned-in rendering:** `FrameRenderer` draws the current cue.
  - Each cue is rendered once with Core Text into a `CGImage`, cached by cue, style and render size, then composited as a `CIImage`. The per-frame cost is negligible.
  - It needs the custom compositor; `needsCustomCompositor` becomes true while captions are on.
  - Caption styles are content, like annotation colors, so fixed colors are fine.
  - Start with a few style presets. Highlighting the current word comes later.
- **Captions file:** optionally save `.srt` / `.vtt` next to the exported MP4 (trivial).
- **Embedded subtitle track:** a soft track inside the MP4 (`tx3g`) is better for accessibility, but `AVAssetExportSession` can't add one; it needs a passthrough `AVAssetWriter` step. Defer it.
- **GIF export** uses burned-in captions.

### 4.3 Noise removal (min / medium / max) and normalization

- **Process the microphone track only.** Voice isolation applied to system audio would destroy music and app sounds.
- **Offline render** with `AVAudioEngine` in manual rendering mode:
  - Chain: decoded mic track → high-pass filter at about 80 Hz (`AVAudioUnitEQ`) → `AUSoundIsolation` → gain → `kAudioUnitSubType_PeakLimiter`.
  - It processes about 90× faster than real time *(probe: 9.6 min in 6.2 s)*. It has zero reported latency and works with mono Float32 at 22.05 and 48 kHz.
- **Presets**, the wet/dry mix of `AUSoundIsolation`:

  | Preset | Mix | Mode |
  |---|---|---|
  | Min | about 40% | Voice |
  | Medium | about 70% | Voice |
  | Max | 100% | High-quality voice (macOS 15+) |

  Tune the values by ear on real recordings.
- **Normalization** has no Apple loudness meter, so we implement ITU-R BS.1770 integrated loudness ourselves. It's pure and testable:
  - K-weighting biquads (`LoudnessMeter`).
  - 400 ms blocks with 75% overlap.
  - An absolute gate at −70 LUFS and a relative gate at −10 LU.
  - Target **−16 LUFS** with a −1 dBFS ceiling.
  - The limiter is sample-peak only (no true-peak is documented); 4× oversampling is optional.
  - The gain must be **baked into the processed file**, because audio-mix volume can't go above 1.0.
- **Cache:** `Application Support/Pankapture/ProcessedAudio/<video>-<path hash>.<setting>.m4a`, deletable and regenerated on demand. A JSON sidecar holds the pipeline version, the recording's fingerprint (size and date) and the track's start time.
- **Isolation delay:** `AUSoundIsolation` delays its output by about 57 ms (92 ms at Max) without reporting it; it's measured per render and removed (ADR-38).
  - `CompositionBuilder` swaps it in for the microphone track and keeps the original track's start offset.
  - The waveform lane shows the processed audio.
  - A 15-minute recording takes about 20 s for the two passes (isolate and measure, then gain and limit), with progress shown.
- **System "Voice Isolation" mic mode is not an option:** apps can only read it or open its menu, and it probably doesn't apply to ScreenCaptureKit's microphone capture (unverified). Post-processing is the reliable path anyway.

### 4.4 Camera: blur, remove, or replace the background

- **Modes:**
  - **None.**
  - **Blur**, with a strength setting.
  - **Replace** with a color or an image.
  - **Remove:** a transparent cut-out of the person over the screen, with the bubble shape optional.
  - **Green screen:** a chroma key for users who have one; deterministic and needs no ML.
- **Segmentation:**
  - Vision `VNGeneratePersonSegmentationRequest` produces the mask:

    | Level | Time per 720p frame *(probe)* | Mask size |
    |---|---|---|
    | fast | 2–4 ms | 256×192 |
    | balanced | about 9 ms | 512×384 |
    | accurate | 32–39 ms | — |

  - The mask is upsampled guided by the camera frame (`CIEdgePreserveUpsampleFilter`), its soft band narrowed (25–75 % coverage ramps to 0–100 %) and feathered by about a pixel, then the result is built with `CIBlendWithMask` from the camera frame plus the blurred background, the replacement image, or a clear background (CAM-5).
  - Blur blurs the background without the person: cut out with alpha 1 − mask, blurred with its alpha, unpremultiplied. Blurring the whole frame smeared the person's colors around them.
  - Measured after building it (ADR-39): fast about 5 ms and balanced about 9 ms per 720p frame on the development Mac, a mask on every frame; the edge refinement adds about 1 ms. The accurate level (2016×1512 mask, about 30 ms) is too slow for exports and takes in the chair behind the person.
  - Apple has no public video-matting API; `CIFilter.personSegmentation` just wraps Vision. The newer person and foreground instance masks are no sharper; they're for telling several people or objects apart.
- **What video-call apps publish about their background effects:** a small segmentation model, refined with a joint bilateral filter guided by the frame (what the edge-preserving upsample does), a blur weighted so the person doesn't bleed into it, and light wrapping for replacements.
- **Open-source models** (checked October 2026, licenses from each repository):

  | Model | License | Core ML | Verdict |
  |---|---|---|---|
  | Robust Video Matting | GPL-3.0 | official, 4–8 MB, about 13 ms at 720p on an M4 Pro | best fit for video (temporal, cleaner edges), but GPL |
  | MODNet | Apache-2.0 | not official; plain CNN, conversion likely easy | the permissive option, per frame; try only with the matte track, if the fixes above fall short |
  | MediaPipe Selfie | Apache-2.0 | TFLite only | same class as Vision's fast level |
  | BiRefNet | MIT | not official | too slow for video (1024², hundreds of MB) |
  | RMBG 1.4 / 2.0, MatAnyone | non-commercial | — | excluded |
  | BackgroundMattingV2 | MIT | no | needs a clean background shot |

- **Done since:** the mask is steadied over time in the compositor: averaged with the previous frame's where the picture didn't move, taken as is where it did (ARCHITECTURE ADR-39). About half the edge flicker on a test recording. Reusing one Vision request turned out to steady only the fast level, not the balanced one exports use.
- **Next steps, in order:** a matte track (offline, motion-compensated smoothing both ways in time, cached like the processed voice); then edge color cleanup for Replace and Remove; a model only if those fall short.
- **Where it runs:** inside `FrameRenderer`, on the camera frame, before the shape mask is applied.
  - The compositor is called from several queues and out of order while scrubbing, so the requests stay stateless: a new request per frame (Vision keeps the model loaded). Steadying over time lives in the compositor, which sees its frames in order.
  - The preview uses fast; export uses balanced.
- **Risk on the slowest machine:**
  - Edge flicker, measured on a test recording, is about half what a new mask per frame gives; the rest needs the matte track.
  - An M1 is probably 2–3× slower (an estimate). At 60 fps that leaves little headroom.
  - If preview or export misses the budget, precompute a matte track once (offline, smoothed over time, cached like the processed audio) and have the compositor only read it.
- **Chroma key:** a color-difference key (how far the key channel rises above the other two) in an alpha `CIColorCube`, plus spill suppression.
- **Model:** `CameraOverlay.background`, decoded with `decodeIfPresent`.
- **Default effect:** Settings ▸ Recording ▸ Camera gets a default background. `VideoEditProject.initial` seeds it, so the automatic camera composite (ADR-25) applies it with no extra work.
- **"Save camera: In the video" mode:** the bubble is part of the screen capture, so post effects are impossible there.
  - Add a **Video Effects…** button (`AVCaptureDevice.showSystemUserInterface(.videoEffects)`) that opens the system's Portrait, Studio Light and background-replacement menu (background replacement since macOS 15).
  - These effects are baked in at capture time and can't be undone. The app can read their state but can't set them.

---

## 5. AI, bring your own key

### 5.1 Where a model is actually needed

| Task | On device, free | Model |
|---|---|---|
| Where pauses are | ✅ DSP | — |
| Whether a pause is deliberate | ⚠️ rules (punctuation, length, transition words, screen activity); can't recognize emphasis | **BYOK model (text + pause timings)** |
| Fillers ("um", "uh", "este") | ✅ word lists + transcript | — |
| Repeated phrases | ✅ n-gram rules | — |
| Merged single-word stutters, Spanish "eh" | ⚠️ audio heuristic, lower confidence | optional verbatim cloud transcriber |
| Mistakes and retakes | ⚠️ cue-word and overlap rules catch the obvious ones | **BYOK model (text only)** |
| Captions | ✅ | — |
| Noise and loudness | ✅ | — |
| Camera background | ✅ | — |

### 5.2 Models for retake detection (prices as of 2026-10-26)

A 15-minute recording is about 2,300 words, or roughly 5k input tokens with word numbers and 1k output tokens.

| Provider / model | $ per 1M in / out | Cost per recording | Notes |
|---|---|---|---|
| Anthropic **Claude Haiku 5.5** (`claude-haiku-5-5`) | $0.10 / $0.50 (prompts ≤ 100K) | **≈ $0.001** | Structured outputs (`output_config.format`). Thinking is on by default, so set effort `low`; thinking tokens bill as output. No Swift SDK, so raw HTTP. |
| OpenAI **gpt-6-luna** | $0.10 / $0.50 | **≈ $0.001** | Strict structured outputs. Defaults to `medium` reasoning, so set `none`/`low`. |
| Google Gemini 2.5 Flash-Lite | $0.10 / $0.40 | ≈ $0.0009 | OpenAI-compatible endpoint. Has a free tier, but Google may use that data to improve its products and it isn't allowed for EEA/UK users. |
| Google Gemini 3.5 Flash-Lite | $0.30 / $2.50 | ≈ $0.004 | Newer and pricier. |
| Groq gpt-oss-20b / 120b | $0.075 / $0.30 · $0.15 / $0.60 | ≈ $0.0007 / $0.0014 | Strict JSON schema, OpenAI-compatible. Free plan: about 1 run per minute. |
| **Local:** LM Studio or Ollama + Qwen3.5 9B | $0 | $0 | OpenAI-compatible `localhost` endpoint with JSON schema. Needs a 16 GB Mac and a 6.6–7.6 GB download. Fully private. |
| Apple Foundation Models (on device, macOS 26+) | $0 | $0 | **Not recommended.** Wrong on every run of a small English/Spanish retake test *(probe)*. Context is 4K tokens (8K on macOS 27). |
| Apple Private Cloud Compute model (macOS 27) | $0, with a quota | $0 | 32K context. Unevaluated; worth a test later. |

**Recommendation:**
- Ship provider presets, not a single model. A heavy user (100 recordings a month) pays about **$0.10 a month** on any of the cheap tiers, so the choice is about quality and privacy, not price.
- Pick the default preset with the evaluation in [PRD §11](PRD.md#11-appendix-auto-edit-evaluation): 16 labeled recordings in English and Spanish, scored on mistakes and pause intent against the rules-only baseline.
  - The first candidates are Qwen3.5 9B in LM Studio and gpt-6-luna (at `none` and `low` reasoning).
  - Claude Haiku 5.5 and Gemini 2.5 Flash-Lite can be added with a key each.
  - A full run costs well under $1.
- Point "free" users to the local preset.

### 5.3 Speech-to-text options

| Engine | Cost | Word timings | Keeps fillers / stutters | Spanish | Verdict |
|---|---|---|---|---|---|
| `SpeechTranscriber` (macOS 26+) | free, on device | ✅ (60 ms) | um/uh/este yes; "eh" and stutters no *(probe)* | ✅ | **Default** |
| `DictationTranscriber` / `SFSpeechRecognizer` on device | free | ✅ | drops all fillers *(probe)* | weaker | Not used: there's no macOS 15 fallback (§9). It would also need the Speech Recognition permission. |
| ElevenLabs Scribe v2 (BYOK) | $0.22 / h ≈ $0.055 per 15 min | ✅ | **✅ by default** (best verbatim score in a vendor benchmark) | ✅ | Best optional upgrade for fillers and stutters; ships in the BYOK work (PRD AI-5). **Sends audio.** |
| AssemblyAI Universal-3.5 Pro (BYOK) | $0.21 / h | ✅ | partly (the docs conflict) | ✅ | Second choice. |
| Groq Whisper large-v3-turbo (BYOK) | $0.04 / h | ✅ | ❌ | ✅ | Cheap, but no help with fillers. |
| OpenRouter speech-to-text (BYOK) | the model's price (Scribe v2 $0.22 / h) | ✅ for Scribe, AssemblyAI, Whisper, Parakeet, Deepgram; ❌ GPT Transcribe, Chirp 3, Voxtral *(probe, 2026-10-27)* | Scribe and AssemblyAI ✅; Parakeet kept "um"; Whisper and Deepgram ❌ | ✅ | One key for language models and several transcribers (ADR-45). **Sends audio.** |
| WhisperKit, whisper.cpp, Parakeet v3 (FluidAudio) | free, local, **dependency** | ✅ | mostly drop fillers | ✅ | Doesn't beat the built-in engine on the problem that matters. Breaks ADR-10. |
| CrisperWhisper (verbatim) | — | ✅ | ✅ | not confirmed | Weights have a **non-commercial license**. Excluded. |

### 5.4 Provider layer

- **Two wire protocols cover everything above.**
  - The Anthropic Messages API.
  - OpenAI-compatible Chat Completions. That covers OpenAI, Gemini's compatibility endpoint, Groq, OpenRouter, LM Studio and Ollama; a base URL and a model name are enough.
  - Both are implemented over `URLSession` with JSON-schema structured output.
- **Keys:**
  - Stored in the **Keychain** (a generic password per provider), never in `UserDefaults`, never logged, never in project files.
  - A "Test connection" button checks a key.
  - The app isn't sandboxed (ADR-7), so it needs no network entitlement.
- **Settings ▸ AI:** the added providers, each with its key or base URL, Add Provider, and the defaults (model, effort, transcription). Nothing is used until a provider is added (ADR-45, PRD AI-8).
  - The Auto-Edit pane picks the model, effort and transcription for that recording, with prices, and says when the built-in rules judge because no provider is added.
- **Every network call is user-initiated**, and the UI states what is sent: "transcript text" or "audio, for cloud transcription".

---

## 6. Architecture changes

- **New modules** (built in phase 1; ARCHITECTURE §3, ADR-31–34):
  - **`Transcription`** (→ AppCore): the transcript model and `OnDeviceTranscriber` (locale choice, model install, word timings).
  - **`AIProviders`** (→ AppCore): presets, `LanguageModelClient` (Anthropic + OpenAI-compatible), `APIKeyStore` (Keychain), `JSONValue`.
  - **`AutoEdit`** (→ AppCore, Transcription, AIProviders): `MicrophoneAudio`, `LoudnessEnvelope`, `PauseDetector`, `ScreenActivityProbe`, `RuleBasedEditor` + `Lexicon`, `ModelPass`, `AutoEditAnalyzer`. It's its own module rather than a folder in `VideoEditor`, so the evaluation harness doesn't pull in the editor UI.
  - **`pankapture-eval`**: the `make eval` executable; not bundled.
  - `TimeRange`, `AudioRole` and `RecordingTracks` moved to AppCore, so these modules don't depend on the editor.
- **Inside `VideoEditor`** (phases 2–6): the automatic-edit layer and pacing in the project model; `Audio/` (voice processing, loudness meter); `Rendering/CaptionRenderer`, `Rendering/CameraMatte`; `UI/TranscriptView` (`NSTextView`) and inspector sections.
- **App target:** the Settings ▸ AI pane and the default camera background in Recording settings.
- **AppCore:** `PreferenceKey`s for every new default, and `AppPaths.transcripts` / `AppPaths.processedAudio`. Deleting a recording, or library retention, also removes its transcript and processed audio.
- **Project model:** `autoCuts`, `autoEditSettings`, `captions`, `audioProcessing` and `camera.background`, all decoded with `decodeIfPresent`.
- **ADRs to record:**
  - On-device transcription, with transcript features gated to macOS 26+.
  - BYOK AI: off by default, keys in the Keychain, text only unless cloud transcription is chosen.
  - Auto-cuts as a separate, re-runnable layer.
  - Processed audio rendered once and swapped into the composition.
  - Camera segmentation in the compositor, with a cached matte as the fallback.
- **PRD and ROADMAP (done):** §5.11–5.12 with requirement IDs (AE-, CAP-, AU-, CAM-, AI-), G7 and §6.3 reworded for opt-in provider traffic, macOS 26 in §6.5, the evaluation in §11, and milestone M8.
- **Info.plist:** nothing new for `SpeechTranscriber`. A `SFSpeechRecognizer` fallback would need `NSSpeechRecognitionUsageDescription` and a new row in the permissions panel.

## 7. Phases and rough effort

The phases follow the requested priority. Each one leaves the app usable.

| # | Phase | Needs | Size |
|---|---|---|---|
| 1 | **Engine + evaluation**, no UI: transcription, pause detection and screen activity, filler, repeat and retake rules, pause-intent rules, provider layer (Anthropic + OpenAI-compatible), prompt and checks, `make eval` | your labeled samples | 2–2.5 wk |
| 2 | **Auto-edit in the editor:** automatic-edit layer, pacing presets, review chips and timeline lane, adjustable segment edges, snapped joins and fades, Settings ▸ AI (presets, Keychain, Test connection) | phase 1 | 2–2.5 wk |
| 3 | **Transcript:** panel (seek, struck-through edits, select-to-cut, zoom from selection, corrections), stutters from audio, optional cloud transcription | phase 2 | 2–2.5 wk |
| 4 | **Captions:** cue builder, burned-in styles, SRT/VTT export, GIF | phase 3 | 1.5–2 wk |
| 5 | **Audio:** noise removal presets + loudness normalization | — | about 1 wk |
| 6 | **Camera:** blur, replace, remove, green screen; default in Recording settings; Video Effects button | — | 1.5–2 wk |

All phases need macOS 26. Phases 5 and 6 are independent, so either can move earlier for a quick win. The total is roughly 10–12 weeks. The evaluation runs as soon as phase 1 lands and your samples are labeled; the default provider is chosen from its test split.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Stutters and Spanish "eh" vanish from the on-device transcript | Audio heuristic shown as suggestions; optional verbatim cloud transcriber; tune on real voices (the probes used synthetic speech). |
| Shortening pauses removes on-screen action or deliberate breaks | Screen-action pauses are never cut; pauses are judged by intent and shortened by pacing; any segment edge can be adjusted (§4.1). |
| Clipped words at cuts | Snap to the quietest point within ±80 ms, keep padding, add 5–10 ms fades. |
| Preview stutters with hundreds of edits | Test at 400 cuts on a 15-minute recording; merge near-adjacent cuts. |
| Models download on first transcription (about 350 MB per language) | Clear progress and a cancel option. The download is system-managed and shared. |
| Retake model makes wrong cuts | Validate the JSON, cap total removed time, always show cuts for review; the rules work without a model. |
| Segmentation flicker or speed on M1 | Fast level for preview; cached, time-smoothed matte if needed. |
| Privacy promise changes | Off by default, Keychain keys, explicit per-action sending, PRD/ADR updates. |
| Prices and model names change quickly | Provider presets are data; the model field is editable. |

## 9. Decisions (2026-10-26)

1. **macOS 26 or later for all of smart editing.** There's no `SFSpeechRecognizer` fallback, and macOS 15 doesn't get these tools.
2. **No third-party dependencies, and no single LLM vendor.** Provider presets cover two wire protocols; any OpenAI-compatible endpoint works.
3. **Optional cloud transcription ships in the BYOK work** (PRD AI-5).
4. **Pauses are judged by intent, not removed wholesale.** The model (or rules) classifies each pause; pacing presets set the lengths; the user can adjust any segment's edges (PRD AE-2, AE-3, AE-8).
5. **Still open:** the default provider preset, chosen by the evaluation (PRD §11), and the pacing targets in §4.1, tuned on the same recordings.

## Sources

- SpeechTranscriber: [supported locales](https://developer.apple.com/documentation/speech/speechtranscriber/supportedlocales), [WWDC25 session 277](https://developer.apple.com/videos/play/wwdc2025/277/), [permission scope](https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition), [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- Foundation Models context window: [TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- Vision person segmentation: [WWDC21 session 10040](https://developer.apple.com/videos/play/wwdc2021/10040/)
- Microphone modes: [WWDC23 session 10235](https://developer.apple.com/videos/play/wwdc2023/10235/)
- System video effects: [Apple Support 105117](https://support.apple.com/en-us/105117)
- `AUSoundIsolation` and `PeakLimiter`: macOS SDK headers (AudioToolbox `AUComponent.h`, `AudioUnitParameters.h`)
- Pricing pages:
  - [OpenAI](https://developers.openai.com/api/docs/pricing) and its [deprecations](https://developers.openai.com/api/docs/deprecations)
  - [Gemini](https://ai.google.dev/gemini-api/docs/pricing) and its [terms](https://ai.google.dev/gemini-api/terms)
  - [Groq](https://console.groq.com/docs/models)
  - [ElevenLabs](https://elevenlabs.io/pricing/api)
  - [AssemblyAI](https://www.assemblyai.com/llms/pricing.md)
  - [Deepgram](https://deepgram.com/pricing)
  - Anthropic model table (cached 2026-10-06)
- Local runtimes: [LM Studio structured output](https://lmstudio.ai/docs/developer/openai-compat/structured-output), [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs), [Qwen3.5 9B](https://huggingface.co/Qwen/Qwen3.5-9B)
- Open speech-to-text:
  - [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift)
  - [FluidAudio](https://github.com/FluidInference/FluidAudio)
  - [Parakeet v3](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3)
  - [CrisperWhisper](https://github.com/nyrahealth/CrisperWhisper) and its [verbatim benchmark](https://www.nyra-labs.com/research/nyra-verbatim-speech-benchmark)
