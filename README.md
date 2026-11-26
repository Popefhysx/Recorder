# Recorder

A light multitrack recorder for macOS: record several tracks from an audio interface, edit and mix
them, and export a WAV or M4A. A smaller Studio One, built for one person with one interface.

- **Record:** per-track input (mono or stereo pair), arm, count-in, metronome, live monitoring,
  per-track input Boost for quiet mics, and a warning when an armed track hears nothing.
- **Edit:** move, trim, split, fades, delete, snap to beats, undo/redo, import audio files.
- **Mix:** volume, pan, mute, solo, master. Per track: noise gate + hum filter + low cut, a 9-band EQ
  (20 Hz – 20 kHz), compressor, delay (tempo-synced) and reverb.
- **Clean up:** Denoise learns a noise print (automatically, or from the loop region) and removes
  steady hiss and hum. Voice Clean uses DeepFilterNet (a neural model) to keep the voice and remove
  any noise behind it. Both keep the original recording.
- **Keys:** Space play/pause, Return back to the start (also mid-take), ⇧Return to the end, ← / → 5 s,
  R record, I listen (soundcheck), L loop, K metronome, G snap, S split, Delete. All changeable in
  Keyboard Shortcuts (⌘,).
- **Safe:** refuses to record without disk space, stops cleanly when the disk fills, and recovers a
  take cut off by a crash or power loss on the next launch.

## Build and run

Needs macOS 15+ on Apple silicon and Xcode's command-line tools (Swift 5.10+). The first build
downloads DeepFilterNet's `deep-filter` tool (28 MB, checked by SHA-256) into `Vendor/` for Voice
Clean. Offline, the app still builds without it. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

```sh
./build.sh              # builds build.noindex/Recorder.app
./build.sh --install    # and copies it to ~/Applications
```

The app is signed with the local "Pope Local Code Signing" certificate when it exists (so macOS keeps
the microphone permission across rebuilds), otherwise ad-hoc.

## Tests

```sh
build.noindex/Recorder.app/Contents/MacOS/Recorder --selftest /tmp/selftest.txt
build.noindex/Recorder.app/Contents/MacOS/Recorder --inputcheck /tmp/inputcheck.txt
```

`--selftest` runs the real engine end to end (recording from the current input, live playback,
offline renders of every effect, denoise, recovery, undo, import, export, save/reopen) and ends the
log with `RESULT: PASS`. `--inputcheck` logs each input channel's level for a few seconds.

## Projects on disk

A project is a folder: `project.json` plus an `Audio/` folder of 48 kHz 24-bit WAVs. The format is
described in [docs/WINDOWS-PORTING.md](docs/WINDOWS-PORTING.md#project-format), so a port can open the
same projects.

## Windows

This app uses Apple-only frameworks. [docs/WINDOWS-PORTING.md](docs/WINDOWS-PORTING.md) is the guide
for a developer rebuilding it for Windows: every subsystem, the exact signal chain and settings, the
file formats, and what to use on Windows for each piece.
