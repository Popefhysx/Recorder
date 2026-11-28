# Redesigning Recorder: a guide for the frontend designer

Recorder is a native Mac app. Its whole interface is **SwiftUI** code in this repository, in the
same project as the audio engine. There is no separate web frontend, so you redesign it by editing
the SwiftUI view files listed below.

## What you need

- A Mac with Apple silicon, running macOS 15 or later.
- Xcode 16 or later (free from the App Store).
- This repository: https://github.com/Popefhysx/Recorder

## Run it

```sh
git clone https://github.com/Popefhysx/Recorder.git
cd Recorder
./build.sh                       # builds build.noindex/Recorder.app (first build ~1 min)
open build.noindex/Recorder.app
```

Or open `Package.swift` in Xcode and press Run (⌘R). Rebuild after each change to see it.

To get something on screen to style, record a few seconds, or use Save menu › Import Audio… to put
any audio file on a track.

## The files you edit (interface only)

| File | What it draws |
|---|---|
| `Sources/Recorder/Theme.swift` | **Start here.** Colors (`Theme`), main sizes (`Layout`), the card style, and shared controls: `Chip` (M / S / FX), `RoundButton`, `LevelMeter`. Changing these restyles most of the app. |
| `Sources/Recorder/ContentView.swift` | Window layout and the top bar: `ModeTabs` (Editor / Split / Export), `SaveControls`, `InputPicker`, `InputSwitch` (mic on/off), `OutputPicker`, `SettingsPopover`, `ProblemToast` (message banner), `TransportBar` (record, play, stop, time, tempo, master volume, loop), `MasterPanel`, `VerticalFader` |
| `Sources/Recorder/Sidebar.swift` | Track cards on the left (`TrackCard`) and the track effects panel (`TrackInspector`, `GraphicEQ`, `BandSlider`) |
| `Sources/Recorder/TimelineView.swift` | The timeline: `Ruler`, `Playhead`, `Lane` (one per track), `LiveTake` (the take while recording), `ClipView` (waveform clips and their right-click menu) |
| `Sources/Recorder/ProcessSheet.swift` | Custom Clean Up window |
| `Sources/Recorder/SilenceRemoval.swift` | Only `SilenceSheet` at the bottom (Remove Silence options window) |
| `Sources/Recorder/Plugins.swift` | Only `MasterPluginsView` at the bottom (Master Plugins list) |
| `Sources/Recorder/Shortcuts.swift` | Only `ShortcutsEditor` at the bottom (Keyboard Shortcuts window) |
| `Resources/AppIcon.icns` | App icon. Send a 1024×1024 PNG and the developer will convert it. |

## Don't change

- **The audio and data files:** `Session.swift`, `Model.swift`, `PlaybackEngine.swift`,
  `InputRecorder.swift`, `Strip.swift`, `Monitor.swift`, `Denoise.swift`, `VoiceClean.swift`,
  `Enhance.swift`, `Exporter.swift`, `Importer.swift`, `Recovery.swift`, `AudioDevices.swift`,
  `SelfTest.swift`, and the non-view parts of the files above.
- **What a control does.** Inside the views, lines like `session.toggleRecord()`,
  `track.mute.toggle()` or `session.addPlugin(c)` are the button's action. Move, restyle or
  regroup controls freely, but keep each action call attached to its control, and don't drop a
  control without agreeing it first.
- **Help text meaning.** `.help("…")` is the tooltip. Reword it if you like, but keep what it says
  (several mention a keyboard shortcut).

## Good to know

- **Icons** are Apple SF Symbols (`Image(systemName: "mic.fill")`). Browse them in Apple's free
  SF Symbols app. Custom icons can go in `Resources/` as PDF or SVG.
- **The app is light mode only today.** Dark mode means giving each `Theme` color a dark
  variant.
- **Window size:** the layout should work from about 1100×650 up to full screen.
- **States to design:**
  - Record armed and recording (red).
  - Mute (orange) and Solo (yellow) on.
  - Headphones (monitoring) on.
  - Mic switched off.
  - Selected track and selected clip.
  - A clip with clean-up applied (it shows a badge).
  - Loop on, and plugins on.
- **Before handing back,** run the self-test. It must end with `RESULT: PASS`:
  ```sh
  build.noindex/Recorder.app/Contents/MacOS/Recorder --selftest /tmp/selftest.txt; tail -1 /tmp/selftest.txt
  ```
- **Hand back** a branch or pull request on GitHub, or a zip of the changed files.
