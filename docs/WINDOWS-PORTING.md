# Porting Recorder to Windows

This is for a developer rebuilding Recorder as a native Windows app. The macOS code in `Sources/`
is the reference implementation; this guide says what each part does, the exact numbers it uses,
and what to use on Windows instead. Build and test locally on a Windows PC; no CI is assumed.

None of the Swift code compiles on Windows: SwiftUI, AVAudioEngine, CoreAudio and Accelerate are
Apple-only. Port the **behaviour and the file formats**, not the code.

---

## 1. Recommended Windows stack

| Need | Recommendation | Why |
|---|---|---|
| Language / framework | **C++17 with JUCE 8** (juce.com), built with CMake + Visual Studio 2022 | Industry standard for audio apps; gives audio I/O, an audio graph, DSP, file I/O and the UI in one library. Also builds for macOS later, if wanted. |
| Audio driver | **ASIO** first, **WASAPI (exclusive or low-latency shared)** as fallback | ASIO gives ~5 ms round trip on a Behringer UMC22 with Behringer's free UMC driver installed. WASAPI works with no driver but with more latency. JUCE supports both; ASIO needs Steinberg's ASIO SDK (free, separate licence) at build time. |
| FFT (Denoise) | `juce::dsp::FFT` or PFFFT/KissFFT | Replaces Apple's vDSP. |
| Effects | `juce::dsp` (IIR filters, Compressor, NoiseGate, DelayLine, Reverb) or hand-written biquads | Replaces Apple's AU effects. Values to match are in §4. |
| Settings | `juce::PropertiesFile` in `%APPDATA%\Recorder` | Replaces UserDefaults. |

**JUCE licence:** free under AGPLv3, or a paid licence for closed-source distribution. Decide this
before starting.

A C# / .NET route (NAudio + WPF) also works for a simpler port, but low-latency monitoring and the
effects chain take far more hand-written code. JUCE is recommended.

### Build on the PC (no CI)

1. Install Visual Studio 2022 with "Desktop development with C++", plus CMake 3.22+.
2. Get JUCE (git clone or zip) and, for ASIO, the Steinberg ASIO SDK.
3. Use a `CMakeLists.txt` with `juce_add_gui_app(Recorder ...)`, and set `JUCE_ASIO=1` plus the ASIO
   SDK include path.
4. `cmake -B build -G "Visual Studio 17 2022"`, then `cmake --build build --config Release`. The .exe
   lands in `build/Recorder_artefacts/Release/`.
5. To ship, run an installer tool (Inno Setup or WiX) over that folder. Code-sign the .exe if it
   will be given to other people, or SmartScreen will warn on first run.

---

## 2. How the app is put together

| macOS file | Responsibility | Windows equivalent |
|---|---|---|
| `Model.swift` | Project, Track, Clip and settings types, which save to `project.json` | Plain C++ structs + JSON (`juce::JSON` or nlohmann/json) |
| `Session.swift` | The app's state and every action: transport, record, edit, undo, files, devices, denoise | One controller class that owns the model and both engines |
| `PlaybackEngine.swift` | Playback graph: one Strip per track → master → output device; metronome | `juce::AudioProcessorGraph` or a single `AudioIODeviceCallback` that mixes strips |
| `Strip.swift` | One track's chain (players → boost → gate → EQ → comp → delay → reverb → fader) | A `Strip` class processing a block of floats |
| `InputRecorder.swift` | Opens the input device, writes takes to WAV, live meters and waveform peaks | `AudioIODeviceCallback` input side + a disk-writer thread (`juce::AudioFormatWriter::ThreadedWriter`) |
| `Monitor.swift` | Lock-free ring from the input callback to each strip's monitor source | Same idea: an SPSC ring (`juce::AbstractFifo`) |
| `AudioDevices.swift` | Lists inputs and outputs, defaults, change notifications | `juce::AudioDeviceManager` + `ChangeListener` |
| `Exporter.swift` | Offline render of the whole mix to WAV/M4A; waveform peaks | Same Strip code run faster than real time; WAV via `WavAudioFormat`; M4A via Windows Media Foundation (`WindowsMediaAudioFormat`) or skip it |
| `Importer.swift` | Converts WAV/AIFF/MP3/M4A/CAF/FLAC to 48 kHz WAV | `AudioFormatManager::registerBasicFormats()` + `juce::ResamplingAudioSource`/`LagrangeInterpolator` |
| `Denoise.swift` | Noise-print spectral noise reduction (§5) | Port the algorithm exactly; it's plain maths |
| `VoiceClean.swift`, `Enhance.swift`, `ProcessSheet.swift` | Voice Clean, Enhance + volume, and the Clean Up & Enhance window (§5) | DeepFilterNet's Windows .exe as a child process; port Enhance's DSP exactly |
| `SilenceRemoval.swift` | Remove Silence auto-edit (§5) | Port as is; it only reads waveform peaks |
| `Recovery.swift` | Disk-space limits, the in-progress marker, WAV header repair (§6) | Same logic; disk space via `GetDiskFreeSpaceExW` / `juce::File::getBytesFreeOnVolume` |
| `ContentView`, `Sidebar`, `TimelineView`, `Theme`, `DenoiseSheet` | UI | JUCE `Component`s. The screenshots and the colour values in `Theme.swift` give the look |
| `SelfTest.swift` | End-to-end checks behind `--selftest` | Port the checks as a test runner; they're the acceptance criteria (§8) |

**Two engines, on purpose.** Playback and input run as separate graphs, so the microphone is only
opened when needed (arming, monitoring, recording) and a disappearing USB input never stops
playback. On Windows with ASIO, one device handles both directions; keep the *logic* separate
(input taps / playback mix) even if it shares one callback.

---

## 3. Recording

- **Format:** always 48 kHz, 24-bit PCM WAV, mono or stereo. Convert if the device runs at another
  rate.
- **Input selection:** each track records one input channel (mono) or channels 1+2 (stereo). A new
  track copies the input of the track above.
- **Boost:** 0 to +24 dB per track, applied in the strip before the gate (it does *not* change the
  file). The track's input meter and waveform display multiply by it.
- **Start:** record starts at the playhead. With count-in on, playback starts one bar early
  (`bar = 60 / tempo × beatsPerBar`) and the takes begin exactly at the downbeat. Both engines start
  on the same host time.
- **Latency compensation:** when the take ends, its clip is placed at
  `recordStart + startDelay − (inputLatency + outputLatency)`. Whatever was heard at time T arrived
  at the input that much later. On ASIO, use the driver-reported input + output latency. If the start
  goes below 0, trim the head (clip offset) instead.
- **Overdubbing:** the new clip *carves* the track: existing clips overlapping its range are split
  and the overlapped parts removed (`Session.carve`).
- **Waveform peaks:** one value (max |sample| across channels) per 256 frames, computed while
  writing, so the live take draws as it records.
- **Silent-input warning:** 3 s into a take, if an armed track's input peak is under −50 dBFS while
  another input is over −34 dBFS, say "Track 2 is recording In 2, which is silent. Your sound is on
  In 1". If everything is silent, say to check the cable and gain.
- **Device loss:** if the input device disappears mid-take, stop the take, keep what was written,
  and tell the user. The UMC22 sits behind a USB hub that drops out sometimes, so this path really
  happens.

## 4. The track chain (exact settings)

Order: **players (mono + stereo) + monitor source → pan → Boost → Gate → EQ → Compressor → Delay →
Reverb → Fader → master.** Everything runs in stereo float (mono clips are panned into stereo with an
equal-power pan).

| Stage | Settings |
|---|---|
| Boost | Gain 0…+24 dB, bypassed at 0 |
| Gate | Downward expander: threshold −80…−10 dB (default −45), ratio 4:1, attack 1 ms, release 250 ms, no compression above threshold. (50:1 / 80 ms chopped word endings to silence.) |
| Hum filter (in the EQ unit) | Notches at mains frequency ×1, ×2, ×3 (50 or 60 Hz), −40 dB, bandwidth 0.08 octave |
| Low cut | 80 Hz high-pass |
| EQ | 9 bands, ±12 dB, 0.5 dB steps. Bells at the geometric centre of each range with bandwidth = range in octaves; "Air" is a high shelf at 10 kHz. Bands: Sub-bass 20–60 Hz · Bass 60–250 · Low mids 250–500 · Midrange 500–1k · Upper mids 1–2k · Presence 2–4k · High presence 4–6k · Treble 6–10k · Air 10–20k. A band at 0 dB is bypassed. |
| Compressor | Threshold −40…0 dB (default −20), "headroom" 0.5…20 dB (default 5; smaller = harder, ratio ≈ 1 + 20/headroom is a fair match), attack 3 ms, release 150 ms, makeup 0…20 dB |
| Delay | Time = note × 60/tempo (notes 1/2, 1/4, dotted 1/8, 1/8, 1/16; max 2 s), feedback 0…90 %, mix 0…100 % wet, low-pass on the repeats 1–16 kHz (default 6 kHz) |
| Reverb | Presets Small Room, Medium Room, Large Room, Medium Hall, Large Hall, Plate, Cathedral; mix 0…100 % wet. JUCE's `Reverb` with room size ≈ 0.3/0.45/0.6/0.7/0.85/0.5/0.95 is a reasonable stand-in |
| Fader | 0…+6 dB (linear 0…2); muted or not-soloed tracks get 0 |
| Master | Same fader range on the sum |

**Monitoring:** a per-track monitor source reads the input ring with a fixed lag of 192 frames and
feeds the *same* chain, so the singer hears the effects. Mono mode reads one channel; stereo mode
reads channels 1 and 2. IO buffers are set to 128 frames once, before starting. Measured on macOS:
about 11–14 ms total. Never rebuild the audio graph while it runs (that crashed the macOS version);
switch monitoring with an atomic flag instead.

**Metronome:** a 35 ms decaying sine click (`gain·sin(2πft)·e^(−90t)`) at 1760 Hz, gain 0.55, on the bar, and 1175 Hz, gain 0.40, on other
beats. It goes to the output only; it's never recorded or exported. With the metronome off and
count-in on, it clicks only during the count-in bar.

**Output device:** playback, the metronome and monitoring go to a chosen output ("System Output" by
default). Remember the choice by device ID. If the device disappears, fall back to the system output
and switch back when it returns. Warn about feedback when monitoring the built-in mic through the
built-in speakers.

## 5. Denoise (port exactly)

Offline, per recording. It writes a new file of identical length and keeps the original.

1. **Learn the noise** as the average power spectrum, either:
   - from the loop region over the clip (at least 0.2 s), or
   - automatically: split the file into 2048-sample frames, measure each frame's mean power, drop
     digital silence (< 1e-12), sort, and keep the quietest 8% (at least 8 frames).

   Frames use a sqrt-Hann window, and power is averaged across channels.
2. **Process:** STFT with N = 2048 and hop 512 (75% overlap). The window is sqrt-Hann on analysis and
   again on synthesis; overlap-add is normalised by 2 (Hann² at 75% overlap sums to 2) and by the
   FFT round-trip scale.

   For each frame:
   - `P[k]` = power averaged over channels.
   - `g[k] = max(floor, sqrt(max(0, 1 − 2·noise[k]/P[k])))`, where `floor = 10^(−reduction/20)`.
     Reduction runs 6–30 dB, default 15.
   - Frequency smoothing: average `g` over ±2 bins.
   - Time smoothing: if rising, `s = 0.3·s + 0.7·g`; if falling, `s = 0.75·s + 0.25·g`.
   - Apply the same `s[k]` to every channel's spectrum (this keeps the stereo image), then inverse
     FFT.
3. **Align:** output trails input by N − hop = 1536 samples. Drop those, and flush with zeros at the
   end so the output length equals the input length exactly.
4. **Write** 24-bit WAV `"<name> denoised.wav"` (`" denoised 2.wav"` etc. if taken).
   - Every clip using the old file points at the new one, with `originalFile` set to the untouched
     recording.
   - Running it again always starts from `originalFile`, so results never stack.
   - "Remove Denoise" puts `originalFile` back.
   - "Delete unused recordings" must treat `originalFile` as in use.

Self-test target: hiss plus a 50/100 Hz hum under a 440 Hz tone, reduction 24 dB. The noise-only
part must drop by more than 15 dB, and the tone must stay within ±1 dB.

### Voice Clean (DeepFilterNet)

Neural clean-up with DeepFilterNet 3 (MIT/Apache-2.0). It needs no noise sample, removes any noise
behind a voice, and also removes instruments, so it's for speech and singing.

- **On Windows, use the same project's official Windows build:**
  `deep-filter-0.5.6-x86_64-pc-windows-msvc.exe` from github.com/Rikorose/DeepFilterNet/releases/tag/v0.5.6.
  Ship it next to Recorder.exe and run it as a child process (`CreateProcess`, or `juce::ChildProcess`).
- **For real-time use or no child process:** link `libDF` (the project's Rust library, C API in
  `libDF/src/capi.rs`: `df_create`, `df_process_frame`, `df_free`). That needs a Rust toolchain at
  build time.
- **Exactly what the Mac version does** (`VoiceClean.swift`):
  1. Write the source as a 32-bit float WAV. The tool can't read 24-bit ("TooWide").
  2. Run `deep-filter -D -a <strength> -o <tempdir> <input.wav>`. `-D` compensates the model's delay,
     so the output lines up with the input sample for sample. `-a` is the attenuation limit in dB.
     The default is **30**. 100 (Max) turns anything the model doesn't hear as voice, like quiet word
     endings, claps and breaths, into digital silence, which sounds like sentences being cut off.
  3. The tool writes 16-bit output about 30 ms (1440 samples) shorter. Pad it with silence back to
     the input's exact length and save it as 24-bit `"<name> voice clean.wav"`.
  4. Then the same clip bookkeeping as Denoise: `originalFile`, plus `"cleanup": "voiceClean"` on the
     clip.
- **What the self-test measured:** with real speech (the system voice) under hiss and 50/100/150 Hz
  hum, noise dropped 46 dB, the voice stayed within 0.2 dB, and the offset was 0 samples. 9 s of audio
  takes about 0.6 s.
- **Known limit:** a *pure* 50 Hz sine passes through untouched, because the model hears it as a tone.
  Real mains hum has harmonics and is removed. For a pure hum, use the Gate's hum filter.

### Clean Up & Enhance chain

A clip's `processing` settings are rendered from `originalFile` in this order, each step's output
feeding the next, into one new 24-bit file `"<name> processed.wav"` of the source's exact length.
Changing settings re-renders from the original; "Remove All" restores it.

1. **Noise:** none, Denoise (above) or Voice Clean (above).
2. **Enhance voice** (`Enhance.swift`):
   - Bring the take to −3 dBFS peak.
   - EQ: 80 Hz high-pass (Q 0.707); −2.5 dB bell at 250 Hz (Q 1); +3 dB bell at 3.2 kHz (Q 1); +2.5 dB
     high shelf at 10 kHz. These are RBJ biquads.
   - Compress: a peak detector in dB, attack 5 ms, release 120 ms, 3:1 above −22 dBFS, linked across
     channels.
   - Then bring it to −1 dBFS peak.
3. **Volume:** unchanged, normalize (peak to −1 dBFS), or gain −12…+24 dB (on top of Enhance's level
   when that's on).
   - Any gain goes through a look-ahead limiter: 5 ms delay, ceiling −1 dBFS, release 80 ms, with a
     hard clamp as a final guarantee.
   - The look-ahead delay is dropped from the start and flushed at the end, so the output stays
     aligned.

### Remove Silence

Non-destructive auto-edit (`SilenceRemoval.swift`). It reads the waveform peaks (max |x| per
256 frames).

- **What counts as silence:** a run of points below the threshold, at least "shortest pause" long
  (default 0.5 s).
- **What's cut:** the silence minus the "keep" margin (default 0.15 s) on any side next to sound.
- **What remains:** each kept range becomes a clip over the same file. Cut edges get a 10 ms fade-in
  and a 30 ms fade-out. Pieces shorter than 50 ms are dropped.
- **Default threshold:** the 10th-percentile peak + 12 dB, clamped to −70…−25 dB.
- **"Close the gaps":** moves every clip on the track earlier by the total silence removed before it.
- **Undo:** it is a single undo step.

### Master plugins and Also Send To

- **Master plugins:** up to 6 effects between the master mix and the output, in order, each with
  bypass, its own editor window and its state saved in the project. On Windows host **VST3** with
  `juce::AudioPluginFormatManager` (Waves and SonoBus ship VST3) and save `getStateInformation()`
  as base64. Live only; exports don't include them yet.
- **Also Send To:** a copy of the final output (after the plugins) goes to a second output
  device while the main output keeps playing. The Mac app copies each buffer into a lock-free ring
  in the real-time callback and a second device plays it, resampling and absorbing clock drift
  (about 256 frames behind). On Windows, open a second `juce::AudioIODevice` for the send device and
  feed it from the same kind of ring. With **VB-Cable** as the send device, vMix (or OBS) picks
  "CABLE Output" as an audio input.

## 6. Safety and recovery

- **Before recording:** refuse unless free space ≥ 2 minutes of audio for the armed channels
  (48000 × 3 bytes per channel per second) + a 300 MB reserve. Warn when fewer than 30 minutes remain.
- **During a take:** check every second, and stop cleanly if free space drops below 150 MB.
- **Crash recovery:**
  - When a take starts, write `recording-in-progress.json` in the project folder,
    `{"takes":[{"trackID":"<uuid>","file":"<name>.wav","start":<seconds>}]}`, and remember the
    project folder in settings.
  - When the take ends normally, delete both.
  - On the next launch, if they still exist: repair each WAV header (below), add the takes to their
    tracks at `start`, save, and tell the user how many were recovered.
- **WAV repair:** a writer that died never fills in its sizes. Walk the chunks from offset 12. At
  `data`, set its size to `fileSize − dataStart` (rounded down to the block align from `fmt `), and
  set the RIFF size at offset 4 to `fileSize − 8`.
- **Autosave:** save on quit, and after every take, import and denoise.

## 7. Project format

A project is a folder:

```
My Song/
  project.json
  Audio/
    Track 1 2026-11-25 8.11.58 PM.wav
    Track 1 2026-11-25 8.11.58 PM denoised.wav
  recording-in-progress.json      (only while recording / after a crash)
```

`project.json` (fields marked † are optional; treat missing as the default shown):

```json
{
  "version": 1,
  "sampleRate": 48000,
  "masterVolume": 1.0,
  "loopEnabled": false, "loopStart": 0, "loopEnd": 8,
  "tempoValue": 120,          "beatsPerBarValue": 4,          // †
  "metronomeValue": false,    "countInValue": false,  "snapValue": false,   // †
  "masterPluginsValue": [{                                   // † Audio Unit effects on the master output, in order
    "id": "UUID", "name": "SonoBus", "maker": "Sonosaurus",
    "type": 1635083896, "subtype": 0, "manufacturer": 0,     // AudioComponentDescription (FourCCs as UInt32)
    "bypass": false, "state": "base64 binary plist"          // the plugin's fullState; on Windows use VST3 and skip AU entries
  }],
  "tracks": [{
    "id": "UUID", "name": "Track 1",
    "inputChannel": 0, "stereoInput": false,                  // † stereo = channels 1+2
    "armed": false, "monitorOn": false,                       // † monitorOn
    "volume": 1.0, "pan": 0.0, "mute": false, "solo": false,
    "boostValue": 12,                                          // † dB, 0…24
    "gateSettings": {"enabled": false, "threshold": -45, "humHz": 0, "lowCut": false},   // †
    "eq": {"enabled": false, "low": 0, "mid": 0, "high": 0,
           "bandGains": [0,0,0,0,0,0,0,0,0]},                 // † bandGains; if missing, use [0,low,0,mid,mid,0,0,high,high]
    "comp": {"enabled": false, "threshold": -20, "headroom": 5, "makeup": 0},
    "delaySettings": {"enabled": false, "note": 2, "feedback": 30, "mix": 20, "tone": 6000},   // †
    "reverb": {"enabled": false, "preset": 1, "mix": 25},
    "clips": [{
      "id": "UUID", "file": "Track 1 ... .wav", "fileLength": 20.99,
      "start": 0.0, "offset": 0.0, "duration": 20.99,
      "fadeIn": 0, "fadeOut": 0,
      "originalFile": "...",                                   // † set when file is a cleaned copy
      "cleanup": "denoise",                                    // † first version only: "denoise" | "voiceClean"
      "processingValue": {"noise": "voiceClean", "denoiseReduction": 15, "voiceStrength": 30,
                          "enhance": true, "volume": "gain", "gain": 6}   // † unchanged | normalize | gain
    }]
  }]
}
```

All times are seconds. `start` is the timeline position, `offset` is where in the file the clip
begins, and `duration` is its length. Fades are linear and sit inside the clip. Keep reading
unknown/missing fields leniently, so projects move between the Mac and Windows versions both ways.

## 8. Acceptance checklist (from `--selftest`)

Port these as automated tests. The Windows build is done when all of them pass:

- **Recording:** a take records from the selected input and has the right length. A stereo take has
  2 channels. A count-in take starts exactly on the downbeat.
- **Live engine:**
  - Playback reaches the master meter.
  - A −12 dB fader lowers the level; mute silences.
  - Monitoring produces sound and survives 40 rapid on/off toggles.
  - A gapless loop works.
- **Offline render** matches the expected level for:
  - volume 0.5, master 0.5, hard-left pan, solo
  - Boost +12 dB making up a −12 dB fader
  - an EQ band cut/boost, the compressor, the reverb tail
  - fades, moved and trimmed clips
  - the gate on a quiet signal, the hum notch, low cut, stereo clips
- **Denoise / Voice Clean:** the targets in §5. The output is the same length. The original is kept, and Remove
  Denoise restores it.
- **Recovery and limits:**
  - A take cut off mid-write is unreadable before repair and plays after; it is put back on its track.
  - Recording is refused with too little disk.
- **Editing:** undo/redo of a clip delete and a fader move. Snap rounds to beats. Split is seamless
  (no click or gap at the cut).
- **Metronome:** clicks reach the output when on, and are silent when off.
- **Output device:** switches to another device and back.
- **Import:** a 44.1 kHz WAV is converted to 48 kHz at the drop position; an M4A arrives as stereo.
- **Files:** export WAV/M4A; save and reopen gives an identical project.

## 9. Things that bit on macOS (so they don't bite twice)

- **Never connect, disconnect or re-route nodes while audio runs.** Pause, change, resume, or design
  it so nothing structural changes (the monitor sources exist permanently and are switched by a flag).
- **Some USB interfaces send a "configuration changed" event right after starting.** Restart in
  place unless the device is actually gone or its format changed; otherwise the first take dies.
- **After switching input device, re-read the channel count from the device.** A cached format
  reported 1 channel for a 2-channel interface.
- **The UMC22's input 1 (XLR) is the only mic preamp.** Input 2 is a line/instrument jack. A
  low-output dynamic mic (e.g. Shure PGA57) needs nearly full gain, hence Boost.
- **50 Hz mains hum appeared on input 1** through a ground loop (charger/dock). The hum filter and
  Denoise handle it in software; a ground-loop fix handles it at the source.
