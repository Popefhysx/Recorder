# ARCHITECTURE — Recorder

Native macOS multitrack recorder (SwiftUI + AVAudioEngine). A desktop app: no server, no database,
no network. The Windows port guide is `docs/WINDOWS-PORTING.md`.

```yaml
project: Recorder
tagline: Light multitrack recorder for one person and one audio interface
status: wip
stack: [Swift, SwiftUI, AVAudioEngine, CoreAudio, Accelerate]
host: none            # desktop app, installed to ~/Applications by build.sh
plan: free
site: app

components:
  - id: ui
    name: SwiftUI views
    kind: client
    does: Top bar, track cards, timeline, transport, inspector popovers, Denoise sheet
    status: live
  - id: session
    name: Session
    kind: service
    does: App state and every action — transport, record, edit, undo, files, devices, denoise
    status: live
    breaks: {severity: critical, effect: "App unusable", fails: [ui]}
  - id: playback
    name: Playback engine
    kind: pipeline
    does: One Strip per track (boost, gate, 9-band EQ, comp, delay, reverb, fader) to the output; metronome
    status: live
    breaks: {severity: critical, effect: "No playback, monitoring or export", fails: [export]}
  - id: input
    name: Input recorder
    kind: pipeline
    does: Opens the input device only when needed (closed when the user switches the input off); writes 48 kHz 24-bit takes; meters; monitor ring
    status: live
    breaks: {severity: critical, effect: "Cannot record", degrades: [playback]}
  - id: export
    name: Exporter
    kind: pipeline
    does: Offline render of the mix to WAV or M4A, reusing Strip
    status: live
  - id: denoise
    name: Denoise
    kind: pipeline
    does: Noise-print spectral noise reduction into a new file; original kept
    status: live
  - id: recovery
    name: Recovery
    kind: worker
    does: Disk-space limits, in-progress marker, WAV header repair, restore takes after a crash
    status: live
  - id: voiceclean
    name: Voice Clean
    kind: pipeline
    does: DeepFilterNet 3 keeps the voice and removes any noise, into a new file; original kept
    status: live
    note: Runs the bundled deep-filter CLI (Contents/MacOS) as a subprocess. Missing helper = feature off, not a crash.

dependencies:
  - {name: DeepFilterNet v0.5.6 deep-filter CLI, kind: model, tier: primary, used_by: [voiceclean]}

flows:
  - {from: input, to: session, label: takes + peaks}
  - {from: session, to: playback, label: project changes}
  - {from: playback, to: export, label: same strip code}
  - {from: session, to: denoise, label: clip file}
  - {from: session, to: voiceclean, label: clip file}
  - {from: recovery, to: session, label: recovered takes on launch}
```

**Project format:** a folder with `project.json` + `Audio/*.wav`, specified in
`docs/WINDOWS-PORTING.md` §7.

**Design tokens:** colours, sizes and shared controls are in `Sources/Recorder/Theme.swift`
(`Theme`, `Layout`, `Chip`, `RoundButton`, `LevelMeter`, `FlowPills`). Views use those, not raw
values.

**Tests:** `Recorder --selftest <log>`. It runs the real engine end to end and must end with
`RESULT: PASS`.
