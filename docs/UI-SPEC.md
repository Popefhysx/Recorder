# Recorder: interface spec for redesign

This file is everything a visual designer needs to redesign Recorder's look **without access to
the code**. It describes every screen, control and state as the app is today, plus the rules a
new design has to keep. The developer builds the new design into the app afterwards.

## 1. What Recorder is

A simple multitrack audio recorder for one person with one audio interface: a smaller, friendlier
Studio One. You record voice or instruments onto tracks, edit and clean up the clips, mix, and
export one audio file.

**It runs on macOS and Windows.** One design must work on both:

- **Window buttons:** top-left on Mac (red/yellow/green), top-right on Windows (minimize / maximize /
  close). Leave room for both, or design the top bar so either fits.
- **Fonts:** Mac uses SF Pro and Windows uses Segoe UI. Design with one of them, and don't rely on
  a font only one platform has unless it's supplied as a file (e.g. a Google font).
- **Shortcuts** are shown with ⌘ / ⌥ / ⇧ on Mac and Ctrl / Alt / Shift on Windows. Leave room for
  the longer Windows labels.
- **Icons:** today they are Apple SF Symbols, which Windows doesn't have. **The new design should
  supply its own icon set as SVG**, used on both platforms.
- **Menus:** on Mac the menu bar is at the top of the screen; on Windows it is inside the window,
  under the title bar (File, Track, Transport, Help). The design should show the Windows one.

## 2. Window layout today

```
┌──────────────────────────────────────────────────────────────────────────┐
│ TOP BAR (64 px)                                                          │
│ [window btns]  (Editor|Split|Export)   [Save ▾] [🎤 Input name ▮▮ ▾] [mic] [speaker] [⚙] │
├───────────────┬───────────────────────────────────────────┬──────────────┤
│ TRACKS        │ RULER (64 px): 0:00  0:01  0:02 …         │  MASTER      │
│ "Tracks" [+Add]│                                          │  [Plugins]   │
│ ┌───────────┐ │ LANE: clips with waveforms ▬▬▬▬▬           │   fader  ▮▮  │
│ │Track card │ │                                           │   0.0 dB     │
│ └───────────┘ │ LANE …                                    │              │
│ (250 px wide) │ playhead: purple line with a handle on top │ (132 px)     │
├───────────────┴───────────────────────────────────────────┴──────────────┤
│ TRANSPORT BAR (84 px)                                                    │
│ ● record  [⏮ ▶ ⏭ ■]  | 0:00.000 / 0:12.345 | ♩ 120 BPM 4/4 ① ▦ | 🔊 ──○── | 🔁 │
└──────────────────────────────────────────────────────────────────────────┘
          ↑ message banner (toast) appears here, bottom centre, above the transport
```

- The window works from about **1100 × 650** up to full screen.
- Track cards on the left line up with their lanes on the right and scroll up and down together.
  The lanes also scroll sideways (time).
- Each track row is **112 px** tall.

## 3. Current look (design tokens)

| Token | Value | Used for |
|---|---|---|
| `purple` (accent) | `#5E45F5` | Selected / on states, play button, waveforms, playhead |
| `purple-soft` | `#5E45F5` at 12% | "Add" button background |
| `lavender` | `#F0EDFF` | Clip background, effect settings panels |
| `background` | `#F9F9FB` | Window background, grouped control backgrounds |
| `card` | `#FFFFFF` | Track cards, master panel, buttons |
| `border` | black at 8% | Hairlines, button outlines |
| `text` | `#1C1C29` | Main text and icons |
| `text-secondary` | `#737385` | Hints, labels, units |
| `record` | `#F2292E` | Record button, armed, recording time, live take, Delete, mic off |
| `mute` | `#FF9500` | M chip when on |
| `solo` | `#F2B31A` | S chip when on |
| Meter | green `#33CC59` → yellow `#FAD91A` → red `#F2292E` | Level meters, bottom to top (−60…0 dB) |

- **Cards:** white, 14 px corners, 1 px border, soft shadow (4% black, 6 px blur, 2 px down).
  A selected card gets a 1.5 px purple border.
- **Clips:** 12 px corners, lavender fill, purple waveform drawn as thin rounded vertical bars.
- **Buttons:** round (transport), pill-shaped (top bar), or 8–10 px rounded squares (chips, toggles).
- **Type sizes:** 18 bold (section titles), 15–17 semibold (names), 13–14 medium (buttons),
  11–12 (labels), 10 (small hints). The time display is 20 medium with fixed-width digits.
- **Light mode only today.** Dark mode is welcome. If designed, give a dark value for every token.

## 4. Every area and control

### 4.1 Top bar
| Control | What it does | States |
|---|---|---|
| Editor / Split / Export group | Editor: current view (always on). Split: splits the clip at the playhead. Export ▾: Export Mix as WAV… / as M4A… | Editor shown selected |
| Save ▾ | Saves the project. Arrow menu: New Project, Open Project…, Save As…, Show Project in Finder (Explorer on Windows), Import Audio…, Delete Unused Recordings…, Keyboard Shortcuts… | Label "Save" (unsaved changes) or "Saved" with a tick |
| Input ▾ | Picks the audio input device. Shows the device name and small live meters for inputs 1 and 2 | Normal; "Input missing — using default"; mic-off icon when input is off |
| Mic on/off | Switches the input off so the interface makes no noise | On: white with mic icon. Off: red with crossed-out mic |
| Output ▾ (speaker icon) | Picks where sound plays (headphones / speakers). Submenu **Also Send To (vMix, OBS…)**: Off, or a second device that gets a copy of the output | Menu with a tick on the current one. While sending: purple ring and a purple dot on the button |
| Settings (gear) | Popover: timeline zoom slider; loop range (Start at Playhead, End at Playhead, and the times) | — |

### 4.2 Tracks column
- **Header:** "Tracks" title, and an **Add** pill button (+).
- **Track card**, one per track:
  - **Row 1:**
    - Editable **name**.
    - **Input chip** ("In 1", "In 2", "In 1+2", plus "+12" when boosted). Its menu: Mono Input 1/2…, Stereo Inputs 1 + 2, Boost Off / +6 / +12 / +18 / +24 dB.
    - **Arm** (record circle: grey when off, red when armed).
    - **⋯** opens the Track settings popover.
  - **Row 2:**
    - **M** (mute, orange when on), **S** (solo, yellow when on).
    - **FX**, which opens the track settings. It gets a purple outline when any effect is on.
    - **Headphones** (hear this input live: purple when on).
    - **Volume** slider.
  - **Row 3:** a thin **level meter**. It shows the input level when armed, otherwise the playback level.
  - **States:** normal, selected (purple border), armed, recording.
- **Track settings popover** (268 px wide):
  - **Header:** track name, plus a red **trash** button that asks "Delete …?".
  - **Effect pills:** None · Gate · EQ · Comp · Verb · Delay. Tap once to turn an effect on and show its settings; tap again to turn it off. Pills are purple when on, and outlined when their settings are showing.
  - **Settings panel** (lavender box) for the chosen effect:
    - **Gate:** on/off, Threshold slider, Hum filter (Off / 50 Hz / 60 Hz), Low cut toggle.
    - **EQ:** 9 vertical band sliders (Sub-bass … Air, 20 Hz–20 kHz) with a centre line. A caption above them shows the band name, its range and dB, and what it does to the sound.
    - **Comp:** Threshold, Headroom, Makeup.
    - **Verb:** Room picker, Mix.
    - **Delay:** Time (1/2, 1/4, dotted 1/8, 1/8, 1/16), Repeats, Mix, Tone.
  - **Rows:** Boost (Off … +24 dB), Vol (dB), Pan (L100 … C … R100).

### 4.3 Timeline
- **Ruler:** times (0:00, 0:01 …), or bar numbers when snap or the metronome is on. Click to move the playhead. When looping, a purple bar on the ruler shows the loop range.
- **Playhead:** a 2 px purple line with a small handle at the top. It is red while recording.
- **Lane** (one per track): selected lane has a faint purple tint. Shows bar lines when snap or the metronome is on. A dashed purple outline appears while a file is dragged onto it.
- **Clip:**
  - Rounded lavender block with a purple waveform.
  - **Drag** to move it; **drag the edges** to trim.
  - **Two small white dots with purple rings** at the top corners: drag to fade in/out. The fade shows as a dashed diagonal line.
  - **Selected:** purple outline.
  - **Clean-up badge:** a small white pill with ✨ and text (e.g. "Voice Clean + Enhance") when clean-up is applied.
- **Live take:** the waveform of what is being recorded, in red on a light red block, growing as you record.
- **Clip right-click menu:**
  - Split at Playhead · Delete Clip · Remove Fades (only if it has fades)
  - Clean Up Voice · Remove Hiss & Hum · Make Louder · Remove Silence
  - Custom Clean Up… · Remove Silence Options… · Undo All Clean-Up (only if cleaned)

### 4.4 Master panel (right)
- "Master" title.
- **Plugins** pill: shows "Plugins" or "Plugins 2" (the number on). It is purple when any plugin is on, and opens the Master Plugins popover.
- **Tall vertical fader** with a round white thumb (double-click resets to 0 dB), and **two level meters** (L, R).
- **dB readout** under the fader.

### 4.5 Transport bar (bottom)
- **Record:** big red round button. Shows a white dot; becomes a white square inside a ring while recording.
- **Grouped round buttons:** Back to start, **Play/Pause** (largest, purple), Forward 5 s, Stop.
- **Time:** current time `0:00.000` / total length. It is red while recording; the total is hidden when narrow.
- **Tempo group:**
  - Metronome toggle.
  - BPM number field with a time signature menu (2/4 … 7/4).
  - Count-in toggle (①).
  - Snap-to-beats toggle.
  - Toggles are purple when on.
- **Master volume** (speaker icon + slider).
- **Loop toggle** (purple when on).

### 4.6 Message banner (toast)
A white card with an orange ⚠ icon, a message (up to 3 lines) and ✕. It sits at the bottom centre,
above the transport. Used for warnings and confirmations, e.g. "Cut 4 silent parts (3.2 s). ⌘Z to undo".

### 4.7 Dialogs
| Dialog | Contents |
|---|---|
| **Custom Clean Up** (420 px) | ✨ title. Three lavender sections: **Noise** (None / Denoise / Voice Clean segmented, with options: learn-from radio buttons, Reduction or Strength slider, hint text), **Voice** (Enhance voice toggle and explanation), **Volume** (Unchanged / Normalize / Gain, Gain slider −12…+24 dB). A note, a progress bar while processing, then buttons: Remove All (left), Cancel, **Apply** |
| **Remove Silence** (400 px) | ✂ title, explanation. Three sliders (Silence is quieter than … dB, Shortest pause to cut … s, Keep around the sound … s), each with a hint. Toggles: Close the gaps, All clips on this track. Live purple summary ("Cuts 4 silent parts, 3.2 s in total."). Cancel, **Remove Silence** |
| **Master Plugins** (340 px popover) | Title, explanation. One row per plugin: on/off switch, name, maker (or "Loading…"), **Open** button, ⋯ menu (Move Up, Move Down, Remove). Empty state: "No plugins yet." Then **+ Add Plugin** menu, grouped by maker (Waves, Sonosaurus, Apple…). Plugins open in their own windows, which the plugin maker designs |
| **Keyboard Shortcuts** | A list of actions, each with its key and Change / Clear buttons; a "press a key…" waiting state; Restore Defaults; Done |
| **Delete track** | Confirmation: "Delete “Track 1”?", with an explanation and a red Delete Track button |
| **Open / Save / Export** | The system's own file dialogs (not designed) |

## 5. Every state to design

- **Idle:** nothing armed, input on.
- **Armed track:** red arm icon, meter shows input.
- **Recording:**
  - Red record button with square.
  - Red time and playhead.
  - Live red take growing in the lane.
- **Playing:** play button shows pause; the view follows the playhead.
- **Monitoring:** the headphones button is on.
- **Mic off:** red mic switch, crossed-out mic in the input picker, no input meters.
- **Mute / solo / FX** on, on a track card.
- **Selected** track and selected clip.
- **Clip with fades** and **clip with clean-up badge**.
- **Processing:** progress bar in Custom Clean Up, or the banner "Cleaning up…".
- **Loop on:** loop button purple, loop bar on the ruler.
- **Snap / metronome on:** bar numbers on the ruler and bar lines in the lanes.
- **Empty project:** one empty track, no clips.
- **Many tracks:** 8 or more, scrolling.
- **Narrow window** (1100 px) and **full screen**.
- **Message banner** visible.
- **Every dialog,** in normal and disabled (button greyed) states.

## 6. Rules the new design must keep

- **Keep every control listed in section 4.** It can be moved, regrouped, restyled or renamed,
  but not dropped without agreeing it first.
- **Track cards must stay lined up with their lanes.** Any design must keep them aligned.
- **Record stays red and unmistakable.** Recording must be obvious from across the room.
- **Hover tooltips exist on most controls.** Keep space for them; their text can be rewritten.
- **Minimum click target 24 px.** Small chips are 28 px today.
- **Level meters** must read −60…0 dB with a clear red zone at the top.
- **Waveforms** must stay readable at small heights and on long clips.

## 7. What to send back

1. **Screens** of the main window (normal, recording, narrow) and each dialog, at 1x and 2x, as
   PNG. Also each state from section 5 that looks different.
2. **The token table from section 3, filled in with the new values:** colors (hex, light and dark
   if designed), fonts, type sizes, corner radii, spacing, shadows.
3. **Icons** as SVG (24 × 24 grid, single color so the app can tint them), named by what they do:
   `record.svg`, `play.svg`, `pause.svg`, `mic-off.svg`, `headphones.svg`, `loop.svg`, …
4. **App icon:** 1024 × 1024 PNG.
5. **Any spacing or sizes not obvious from the screens,** written next to them.
