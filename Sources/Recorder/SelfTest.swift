import AppKit
import AVFoundation

/// `Recorder --selftest <log>`: records a few seconds from the default input through the real
/// Session code, checks the take isn't silent, plays it back live, then checks mixer controls,
/// effects, edits, export and save/open by rendering a test tone offline and measuring the result.
enum SelfTest {
    static func start(logPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            var failures = 0
            func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
            func check(_ ok: Bool, _ what: String) { log((ok ? "ok   " : "FAIL ") + what); if !ok { failures += 1 } }
            func main<T>(_ work: () -> T) -> T { DispatchQueue.main.sync(execute: work) }
            do {
                try run(log: log, check: check, main: main)
            } catch {
                log("FAIL error: \(error)"); failures += 1
            }
            log(failures == 0 ? "RESULT: PASS" : "RESULT: \(failures) check(s) failed")
            DispatchQueue.main.async { exit(failures == 0 ? 0 : 1) }
        }
    }

    private static func run(log: (String) -> Void, check: (Bool, String) -> Void, main: (() -> Any) -> Any) throws {
        func onMain<T>(_ work: @escaping () -> T) -> T { main { work() } as! T }

        // Microphone permission (the prompt appears the first time).
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            log("asking for microphone access — click Allow")
            let sem = DispatchSemaphore(value: 0)
            AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 120)
        }
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        check(mic == .authorized, "microphone access (\(mic.rawValue); 3 = allowed)")

        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("recorder-selftest-\(getpid())")
        let folder = root.appendingPathComponent("Test Project")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        log("project folder: \(folder.path)")
        log("input devices: \(AudioDevices.inputDevices().map { "\($0.name) [\($0.channels)]" }.joined(separator: ", "))")

        let session: Session = onMain {
            let s = Session(startTimer: false)
            s.folder = folder
            s.isUntitled = false
            s.project.tracks[0].name = "Mic"
            s.project.tracks[0].armed = true
            return s
        }
        log("input: \(onMain { session.inputName }), channels \(onMain { session.inputChannels })")
        let stereoTake = onMain { session.inputChannels >= 2 }
        if stereoTake { onMain { session.project.tracks[0].stereo = true } }

        // 1. Record 3 seconds.
        let sem = DispatchSemaphore(value: 0)
        var started = false
        DispatchQueue.main.async { session.record { ok in started = ok; sem.signal() } }
        _ = sem.wait(timeout: .now() + 30)
        check(started, "recording started" + (started ? "" : " (\(onMain { session.problem ?? "" }))"))
        Thread.sleep(forTimeInterval: 1.6)
        // Simulate a crash: copy the take while it's still being written (sizes not filled in yet).
        let audioDir = folder.appendingPathComponent("Audio")
        let inProgress = (try? FileManager.default.contentsOfDirectory(at: audioDir, includingPropertiesForKeys: nil))?.first { $0.lastPathComponent.hasPrefix("Mic ") }
        let crashCopy = root.appendingPathComponent("crash.wav")
        if let inProgress { try? FileManager.default.copyItem(at: inProgress, to: crashCopy) }
        Thread.sleep(forTimeInterval: 1.6)
        let livePeaks = onMain { session.recorder.livePeaks().values.first?.count ?? 0 }
        check(livePeaks > 100, "live waveform points while recording: \(livePeaks)")
        log("state: recording=\(onMain { session.isRecording }) inputRunning=\(onMain { session.recorder.isRunning }) problem=\(onMain { session.problem ?? "none" })")
        onMain { session.stop() }
        let take = onMain { session.project.tracks[0].clips.first }
        check(take != nil, "take became a clip")
        guard let take else { return }
        let takeURL = folder.appendingPathComponent("Audio").appendingPathComponent(take.file)
        let a = try Exporter.analyze(takeURL)
        log(String(format: "take: %@, %.2f s, peak %.5f (%.1f dBFS), rms %.6f, clip starts at %.3f s",
                   take.file, Double(a.frames) / Formats.rate, a.peak, 20 * log10(max(a.peak, 1e-9)), a.rms, take.start))
        check(a.frames > Int64(Formats.rate * 2.5), "take is about 3 s long")
        check(a.channels == (stereoTake ? 2 : 1), "take has \(a.channels) channel(s) (\(stereoTake ? "stereo 1+2" : "mono"))")
        check(a.peak > 0.0001, "take is not silent")
        check(onMain { session.waveforms.peaks[take.file]?.count ?? 0 } > 100, "take has a waveform")
        check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path), "project autosaved after the take")
        onMain { session.project.tracks[0].armed = false }

        // A tone track makes the mixer and effect checks repeatable.
        let tone = folder.appendingPathComponent("Audio/tone.wav")
        try writeTone(tone, frequency: 1000, amplitude: 0.5, seconds: 2)
        onMain {
            var t = Track(name: "Tone")
            t.clips = [Clip(file: "tone.wav", fileLength: 2, start: 0, duration: 2)]
            session.project.tracks.append(t)
        }

        // 2. Live playback through the output, measured on the meters.
        func livePeak(_ seconds: Double) -> (master: Float, mic: Float) {
            onMain {
                session.playback.masterMeter.take()
                for s in session.playback.strips.values { _ = s.meter.take() }
                session.startPlayback(from: 0)
            }
            Thread.sleep(forTimeInterval: seconds)
            return onMain {
                let m = session.playback.masterMeter.take()
                let mic = session.playback.strips[session.project.tracks[0].id]?.meter.take().0 ?? 0
                session.stop()
                return (max(m.0, m.1), mic)
            }
        }
        let live = livePeak(1.0)
        log(String(format: "live playback: master peak %.4f, mic track peak %.5f, output %@", live.master, live.mic,
                   onMain { session.playback.engine.outputNode.outputFormat(forBus: 0).description }))
        check(live.master > 0.2, "live playback reaches the master meter")
        check(live.mic > 0, "recorded take plays back")
        onMain { session.project.tracks[1].volume = 0.25 }
        let quieter = livePeak(0.8)
        check(quieter.master < live.master * 0.5, String(format: "live: track fader at -12 dB lowers the output (%.3f → %.3f)", live.master, quieter.master))
        onMain { session.project.tracks[1].volume = 1; session.project.tracks[1].mute = true; session.project.tracks[0].mute = true }
        let muted = livePeak(0.8)
        check(muted.master < 0.001, String(format: "live: mute silences the output (%.5f)", muted.master))
        onMain { session.project.tracks[0].mute = false; session.project.tracks[1].mute = false }

        // Monitoring: the mic track's input should reach its strip while the transport is stopped.
        let micID = onMain { session.project.tracks[0].id }
        onMain { session.project.tracks[1].mute = true; session.project.tracks[0].volume = 0.05; session.project.tracks[0].monitor = true }
        Thread.sleep(forTimeInterval: 0.3)
        _ = onMain { session.playback.strips[micID]?.meter.take() }
        Thread.sleep(forTimeInterval: 1.0)
        let monitored = onMain { session.playback.strips[micID]?.meter.take().0 ?? 0 }
        let running = onMain { session.playback.engine.isRunning }
        let latency = onMain { session.recorder.latency + session.playback.outputLatency }
        check(running && monitored > 0, String(format: "monitoring plays the live input while stopped (level %.5f, device latency %.1f ms + ~8 ms buffers)", monitored, latency * 1000))
        // Stress: change the graph and monitoring while audio is running (this used to crash).
        for i in 0..<40 {
            onMain {
                switch i % 5 {
                case 0: session.addTrack(); session.project.tracks[session.project.tracks.count - 1].monitor = true
                case 1: session.startPlayback(from: 0)
                case 2: session.project.tracks[0].monitor.toggle(); session.project.tracks[0].stereo.toggle()
                case 3: if session.project.tracks.count > 2 { session.removeTrack(session.project.tracks.last!.id) }
                default: session.stop()
                }
            }
            Thread.sleep(forTimeInterval: 0.07)
        }
        onMain { session.stop(); while session.project.tracks.count > 2 { session.project.tracks.removeLast() }
                 session.project.tracks[0].stereo = stereoTake; session.project.tracks[0].monitor = true }
        Thread.sleep(forTimeInterval: 0.3)
        check(onMain { session.playback.strips[micID]?.isMonitoring == true }, "40 rapid graph/monitor/transport changes while running: no crash")
        onMain { session.project.tracks[0].monitor = false; session.project.tracks[0].volume = 1; session.project.tracks[1].mute = false }
        Thread.sleep(forTimeInterval: 0.2)
        check(onMain { session.playback.strips[micID]?.isMonitoring == false }, "monitoring turns off")

        // Loop: 0…0.5 s for 1.3 s should wrap around.
        onMain { session.project.loopEnabled = true; session.project.loopStart = 0; session.project.loopEnd = 0.5; session.startPlayback(from: 0) }
        var maxPos = 0.0
        for _ in 0..<26 { Thread.sleep(forTimeInterval: 0.05); maxPos = max(maxPos, onMain { session.playback.tick(); return session.playback.position }) }
        let endPos = onMain { session.playback.position }
        onMain { session.stop(); session.project.loopEnabled = false }
        check(maxPos < 0.55 && endPos < 0.5, String(format: "loop wraps (max position %.2f s)", maxPos))

        // 3. Offline renders of the tone track alone (mic take muted so room noise doesn't count).
        var base = onMain { session.project }
        base.tracks[0].mute = true
        let out = root.appendingPathComponent("render.wav")
        func render(_ change: (inout Project) -> Void) throws -> URL {
            var p = base; change(&p)
            try Exporter.render(p, audioFolder: folder.appendingPathComponent("Audio"), to: out)
            return out
        }
        func seg(_ url: URL, _ a: Double, _ b: Double) throws -> (l: Float, r: Float, rms: Double) { try segment(url, from: a, to: b) }

        let dry = try seg(try render { _ in }, 0.2, 1.8)
        log(String(format: "dry tone: L %.3f R %.3f rms %.4f", dry.l, dry.r, dry.rms))
        check(dry.l > 0.3, "tone renders")
        let half = try seg(try render { $0.tracks[1].volume = 0.5 }, 0.2, 1.8)
        check(abs(half.rms / dry.rms - 0.5) < 0.02, String(format: "volume 0.5 halves the level (%.3f)", half.rms / dry.rms))
        let boosted = try seg(try render { $0.tracks[1].volume = 0.25; $0.tracks[1].boost = 12 }, 0.2, 1.8)
        check(abs(boosted.rms / dry.rms - 1) < 0.05, String(format: "input boost +12 dB makes up a -12 dB fader (%.3f)", boosted.rms / dry.rms))
        let master = try seg(try render { $0.masterVolume = 0.5 }, 0.2, 1.8)
        check(abs(master.rms / dry.rms - 0.5) < 0.02, String(format: "master 0.5 halves the level (%.3f)", master.rms / dry.rms))
        let left = try seg(try render { $0.tracks[1].pan = -1 }, 0.2, 1.8)
        check(left.l > 0.3 && left.r < 0.001, String(format: "pan hard left (L %.3f R %.4f)", left.l, left.r))
        let solo = try seg(try render { $0.tracks[0].mute = false; $0.tracks[0].solo = true }, 0.2, 1.8)
        let micOnly = try seg(try render { $0.tracks[0].mute = false; $0.tracks[1].mute = true }, 0.2, 1.8)
        check(abs(solo.rms - micOnly.rms) < 1e-6, "solo on another track silences this one")
        let eq = try seg(try render { $0.tracks[1].eq = EQSettings(enabled: true, low: 0, mid: -12, high: 0) }, 0.2, 1.8)
        check(eq.rms < dry.rms * 0.4, String(format: "an old 3-band project's mid cut still cuts a 1 kHz tone (%.1f dB)", 20 * log10(eq.rms / dry.rms)))
        func eqBand(_ i: Int, _ db: Float) throws -> Double {
            var g = [Float](repeating: 0, count: EQSettings.bands.count); g[i] = db
            return 20 * log10(try seg(try render { $0.tracks[1].eq = EQSettings(enabled: true, bandGains: g) }, 0.2, 1.8).rms / dry.rms)
        }
        let upper = try eqBand(4, 12), presence = try eqBand(5, 12), sub = try eqBand(0, 12)
        check(upper > 4 && presence < upper - 2 && abs(sub) < 0.5,
              String(format: "9-band EQ: +12 dB on Upper mids lifts the 1 kHz tone %.1f dB; Presence only %.1f dB; Sub-bass %.2f dB", upper, presence, sub))
        let comp = try seg(try render { $0.tracks[1].comp = CompSettings(enabled: true, threshold: -30, headroom: 1, makeup: 0) }, 0.5, 1.8)
        check(comp.rms < dry.rms * 0.7, String(format: "compressor reduces a loud tone (%.1f dB)", 20 * log10(comp.rms / dry.rms)))
        let dryTail = try seg(try render { _ in }, 2.1, 2.6)
        let wetTail = try seg(try render { $0.tracks[1].reverb = ReverbSettings(enabled: true, preset: 4, mix: 60) }, 2.1, 2.6)
        check(dryTail.rms < 1e-5 && wetTail.rms > 1e-3, String(format: "reverb leaves a tail after the tone (dry %.6f, wet %.4f)", dryTail.rms, wetTail.rms))
        let faded = try seg(try render { $0.tracks[1].clips[0].fadeIn = 1 }, 0, 0.1)
        let unfaded = try seg(try render { _ in }, 0, 0.1)
        check(faded.rms < unfaded.rms * 0.15, "fade-in starts quiet")
        let fadeOut = try seg(try render { $0.tracks[1].clips[0].fadeOut = 0.5 }, 1.9, 2.0)
        check(fadeOut.rms < unfaded.rms * 0.15, "fade-out ends quiet")
        let moved = try seg(try render { $0.tracks[1].clips[0].start = 1 }, 0, 0.95)
        let movedOn = try seg(out, 1.1, 2.9)
        check(moved.rms < 1e-6 && movedOn.rms > 0.3, "moving a clip moves its sound")
        let trimmed = try seg(try render { $0.tracks[1].clips[0].offset = 0.5; $0.tracks[1].clips[0].duration = 1 }, 1.05, 1.5)
        check(trimmed.rms < 1e-6, "trimming the end shortens the clip")

        // Gate, hum filter, stereo clips.
        try writeSignal(folder.appendingPathComponent("Audio/quiet.wav"), channels: 1, seconds: 2) { _, t in 0.003 * Float(sin(2 * .pi * 1000 * t)) }
        let gated = try seg(try render { $0.tracks[1].clips[0].file = "quiet.wav"; $0.tracks[1].gate = GateSettings(enabled: true, threshold: -40) }, 0.5, 1.8)
        let ungated = try seg(try render { $0.tracks[1].clips[0].file = "quiet.wav" }, 0.5, 1.8)
        check(gated.rms < ungated.rms * 0.1, String(format: "noise gate silences a -50 dB signal (%.1f dB)", 20 * log10(max(gated.rms, 1e-9) / ungated.rms)))
        let loudGated = try seg(try render { $0.tracks[1].gate = GateSettings(enabled: true, threshold: -40) }, 0.5, 1.8)
        check(abs(20 * log10(loudGated.rms / dry.rms)) < 1, String(format: "noise gate leaves a loud signal alone (%.2f dB)", 20 * log10(loudGated.rms / dry.rms)))
        try writeSignal(folder.appendingPathComponent("Audio/hum.wav"), channels: 1, seconds: 2) { _, t in 0.3 * Float(sin(2 * .pi * 50 * t)) }
        try writeSignal(folder.appendingPathComponent("Audio/stereo.wav"), channels: 2, seconds: 2) { c, t in c == 0 ? 0.5 * Float(sin(2 * .pi * 1000 * t)) : 0 }
        func swap(_ p: inout Project, _ file: String) { p.tracks[1].clips[0].file = file }
        let hum = try seg(try render { swap(&$0, "hum.wav") }, 0.5, 1.8)
        let humCut = try seg(try render { swap(&$0, "hum.wav"); $0.tracks[1].gate.humHz = 50 }, 0.5, 1.8)
        check(humCut.rms < hum.rms * 0.1, String(format: "hum filter removes 50 Hz hum (%.1f dB)", 20 * log10(humCut.rms / hum.rms)))
        let lowCut = try seg(try render { swap(&$0, "hum.wav"); $0.tracks[1].gate.lowCut = true }, 0.5, 1.8)
        check(lowCut.rms < hum.rms * 0.7, String(format: "low cut reduces 50 Hz (%.1f dB)", 20 * log10(lowCut.rms / hum.rms)))
        let st = try seg(try render { swap(&$0, "stereo.wav") }, 0.2, 1.8)
        check(st.l > 0.3 && st.r < 0.001, String(format: "stereo clip keeps left and right apart (L %.3f R %.4f)", st.l, st.r))
        let stFade = try seg(try render { swap(&$0, "stereo.wav"); $0.tracks[1].clips[0].fadeIn = 1 }, 0, 0.1)
        check(stFade.rms < st.rms * 0.15, "fades work on stereo clips")

        // Split at 1 s must be sample-identical to the unsplit clip.
        let whole = try samples(try render { _ in })
        let parts = try samples(try render { p in
            if let (a, b) = p.tracks[1].clips[0].split(at: 1.0) { p.tracks[1].clips = [a, b] }
        })
        let diff = zip(whole, parts).map { abs($0 - $1) }.max() ?? 1
        check(whole.count == parts.count && diff < 1e-4, String(format: "split at playhead is seamless (max diff %.6f)", diff))

        // Recording over an existing clip carves out the covered part.
        let carved = Session.carve([Clip(file: "x", fileLength: 10, start: 0, duration: 10)], start: 3, end: 5)
        check(carved.count == 2 && abs(carved[0].end - 3) < 1e-9 && abs(carved[1].start - 5) < 1e-9, "a new take replaces what it covers")

        // 3b. Crash recovery of a half-written take.
        let before = (try? Exporter.analyze(crashCopy))?.frames ?? 0
        check(WAVRepair.repair(crashCopy), "repairs the header of a take cut off mid-recording")
        let repaired = (try? Exporter.analyze(crashCopy))?.frames ?? 0
        check(Double(repaired) / Formats.rate > 1.0, String(format: "cut-off take is readable after repair (%.2f s; %.2f s before)", Double(repaired) / Formats.rate, Double(before) / Formats.rate))
        let crashed = root.appendingPathComponent("Crashed Project")
        try FileManager.default.createDirectory(at: crashed.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: crashCopy, to: crashed.appendingPathComponent("Audio/lost take.wav"))
        let trackID = onMain { session.project.tracks[0].id }
        try JSONEncoder().encode(onMain { session.project }).write(to: crashed.appendingPathComponent("project.json"))
        try JSONEncoder().encode(PendingRecording(takes: [.init(trackID: trackID, file: "lost take.wav", start: 5)]))
            .write(to: crashed.appendingPathComponent(PendingRecording.fileName))
        let (recoveredCount, recoveredClip): (Int, Clip?) = onMain {
            let s = Session(startTimer: false)
            let n = s.recoverTakes(in: crashed)
            return (n, s.project.tracks.first { $0.id == trackID }?.clips.first { $0.file == "lost take.wav" })
        }
        check(recoveredCount == 1 && recoveredClip.map { abs($0.start - 5) < 0.01 } == true, "recovery puts the lost take back on its track at its position")
        check(!FileManager.default.fileExists(atPath: crashed.appendingPathComponent(PendingRecording.fileName).path), "recovery marker is cleared")
        check(onMain { !session.hasRoom(forSeconds: 1e9) }, "refuses to record when the disk can't hold it")
        onMain { session.problem = nil }

        // 3c. Undo / redo.
        onMain { session.project.tracks[1].volume = 0.3 }
        Thread.sleep(forTimeInterval: 0.7)
        let clipCount = onMain { session.project.tracks[1].clips.count }
        onMain { session.selection = ClipRef(track: session.project.tracks[1].id, clip: session.project.tracks[1].clips[0].id); session.deleteSelectedClip() }
        onMain { session.undo() }
        check(onMain { session.project.tracks[1].clips.count } == clipCount, "undo brings back a deleted clip")
        onMain { session.undo() }
        check(onMain { session.project.tracks[1].volume } == 1, "undo again restores the fader")
        onMain { session.redo() }
        check(onMain { session.project.tracks[1].volume } == 0.3, "redo reapplies it")
        onMain { session.project.tracks[1].volume = 1 }

        // 3d. Snap and metronome.
        let snapped = onMain { () -> Double in var p = session.project; p.tempo = 120; p.snap = true; return p.snapped(1.13) }
        check(abs(snapped - 1.0) < 1e-9, "snap rounds to the nearest beat (1.13 s → 1.0 s at 120 BPM)")
        onMain {
            session.project.tracks[0].mute = true; session.project.tracks[1].mute = true
            session.project.metronome = true; session.project.tempo = 120
            session.playback.masterMeter.take()
            session.startPlayback(from: 0)
        }
        Thread.sleep(forTimeInterval: 1.3)
        let clickPeak = onMain { () -> Float in let m = session.playback.masterMeter.take(); session.stop(); return max(m.0, m.1) }
        onMain { session.project.metronome = false; session.playback.masterMeter.take(); session.startPlayback(from: 0) }
        Thread.sleep(forTimeInterval: 0.8)
        let noClick = onMain { () -> Float in let m = session.playback.masterMeter.take(); session.stop(); return max(m.0, m.1) }
        check(clickPeak > 0.1 && noClick < 0.001, String(format: "metronome clicks reach the output (peak %.2f; off: %.4f)", clickPeak, noClick))

        // Count-in: one bar (2 s at 120 BPM) of clicks, then recording starts on the downbeat at the playhead.
        onMain {
            session.project.tracks[0].mute = false; session.project.tracks[1].mute = false
            session.project.countIn = true
            session.project.tracks[0].armed = true
            session.clock.position = 10
        }
        let sem2 = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { session.record { _ in sem2.signal() } }
        _ = sem2.wait(timeout: .now() + 10)
        Thread.sleep(forTimeInterval: 3.4)
        onMain { session.stop(); session.project.countIn = false; session.project.tracks[0].armed = false }
        let countInTake = onMain { session.project.tracks[0].clips.max { $0.start < $1.start } }
        check(countInTake.map { abs($0.start - 10) < 0.1 && $0.duration > 0.8 && $0.duration < 2.2 } == true,
              String(format: "count-in: take starts at the playhead after one bar (start %.2f s, %.2f s long)", countInTake?.start ?? -1, countInTake?.duration ?? -1))

        // 3e. Output device switching.
        if let usb = AudioDevices.outputDevices().first(where: \.isUSBOutput) {
            onMain { session.project.masterVolume = 0.02; session.playback.setOutputDevice(usb.objectID) }
            check(onMain { session.playback.currentOutputDevice } == usb.objectID, "output switches to \(usb.name)")
            onMain { session.playback.masterMeter.take(); session.startPlayback(from: 0) }
            Thread.sleep(forTimeInterval: 0.6)
            let usbPeak = onMain { () -> Float in let m = session.playback.masterMeter.take(); session.stop(); return max(m.0, m.1) }
            check(usbPeak > 0, "playback runs on \(usb.name)")
            onMain { session.playback.setOutputDevice(nil); session.project.masterVolume = 1 }
            check(onMain { session.playback.currentOutputDevice } == AudioDevices.defaultOutput(), "output switches back to the system output")
        } else {
            log("skip output switching: no USB output device")
        }

        // 3f. Import: a 44.1 kHz mono WAV and a stereo M4A.
        let src = root.appendingPathComponent("import-src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try writeSignal(src.appendingPathComponent("beat 44k.wav"), channels: 1, seconds: 1.5, rate: 44100) { _, t in 0.4 * Float(sin(2 * .pi * 440 * t)) }
        try Exporter.render(onMain { session.project }, audioFolder: folder.appendingPathComponent("Audio"), to: src.appendingPathComponent("song.m4a"), format: .m4a)
        let tracksBefore = onMain { session.project.tracks.count }
        let sem3 = DispatchSemaphore(value: 0)
        var imported = false
        DispatchQueue.main.async {
            session.importAudio([src.appendingPathComponent("beat 44k.wav"), src.appendingPathComponent("song.m4a")],
                                track: session.project.tracks[1].id, at: 4) { ok in imported = ok; sem3.signal() }
        }
        _ = sem3.wait(timeout: .now() + 30)
        let beatClip = onMain { session.project.tracks[1].clips.first { $0.file.hasPrefix("beat 44k") } }
        let songTrack = onMain { session.project.tracks.count > tracksBefore ? session.project.tracks.last : nil }
        check(imported && beatClip.map { abs($0.start - 4) < 1e-9 && abs($0.duration - 1.5) < 0.01 } == true,
              String(format: "imports a 44.1 kHz WAV onto the track at 4 s, converted to 48 kHz (%.3f s)", beatClip?.duration ?? -1))
        if let songClip = songTrack?.clips.first {
            let info = try Exporter.analyze(folder.appendingPathComponent("Audio").appendingPathComponent(songClip.file))
            check(info.channels == 2 && info.peak > 0.1, "imports an M4A as a stereo WAV on a new track \"\(songTrack!.name)\"")
        } else {
            check(false, "second imported file goes on a new track")
        }

        // Denoise: a tone with hiss and 50 Hz hum under it, cleaned from an automatic noise print.
        var seed: UInt64 = 42
        func noise() -> Float { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Float(seed >> 40) / Float(1 << 23) - 1 }   // top bits: the low bits of an LCG repeat
        try writeSignal(audioDir.appendingPathComponent("noisy.wav"), channels: 2, seconds: 4) { _, t in
            let hiss = 0.02 * noise(), hum = Float(0.01 * sin(2 * .pi * 50 * t) + 0.005 * sin(2 * .pi * 100 * t))
            let tone: Float = (1.5..<3.0).contains(t) ? Float(0.3 * sin(2 * .pi * 440 * t)) : 0
            return hiss + hum + tone
        }
        let noisyRef: ClipRef = onMain {
            let c = Clip(file: "noisy.wav", fileLength: 4, start: 30, duration: 4)
            session.project.tracks[0].clips.append(c)
            return ClipRef(track: session.project.tracks[0].id, clip: c.id)
        }
        let noisyURL = audioDir.appendingPathComponent("noisy.wav")
        let dnBefore = (noise: try segment(noisyURL, from: 0.3, to: 1.2).rms, tone: try segment(noisyURL, from: 1.7, to: 2.8).rms)
        let sem4 = DispatchSemaphore(value: 0)
        var denoised = false
        DispatchQueue.main.async { session.cleanUp(noisyRef, .denoise(reduction: 24, fromLoop: false)) { ok in denoised = ok; sem4.signal() } }
        _ = sem4.wait(timeout: .now() + 30)
        if let c = onMain({ session.clip(noisyRef) }), denoised, c.originalFile == "noisy.wav" {
            let url = audioDir.appendingPathComponent(c.file)
            let after = (noise: try segment(url, from: 0.3, to: 1.2).rms, tone: try segment(url, from: 1.7, to: 2.8).rms)
            let cut = 20 * log10(after.noise / dnBefore.noise)
            let toneChange = 20 * log10(after.tone / 0.2121)        // clean tone RMS is 0.3/√2
            check(cut < -15, String(format: "denoise lowers hiss + hum by %.1f dB (%@)", cut, c.file))
            check(abs(toneChange) < 1, String(format: "denoise keeps the wanted sound within %.2f dB of the clean original", toneChange))
            check(abs(try samples(url).count - samples(noisyURL).count) == 0, "denoised file is exactly as long, so the clip stays in place")
            check(!onMain { session.unusedAudio() }.contains { $0.lastPathComponent == "noisy.wav" }, "the original is kept (not offered for deletion)")
            onMain { session.removeCleanup(noisyRef) }
            check(onMain { session.clip(noisyRef)?.file } == "noisy.wav", "Remove Denoise puts the original back")
        } else {
            check(false, "denoise runs on a clip and points it at the cleaned copy")
        }
        onMain { session.project.tracks[0].clips.removeAll { $0.id == noisyRef.clip } }

        // Voice Clean: real speech (the system voice) under hiss and hum, through DeepFilterNet.
        if VoiceClean.tool == nil {
            log("skip Voice Clean: DeepFilterNet isn't bundled in this build")
        } else {
            let aiff = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-selftest-speech.aiff")
            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-o", aiff.path, "Testing one two three. This is a voice with a noisy microphone. Can you hear me clearly now?"]
            try say.run(); say.waitUntilExit()
            let speechURL = audioDir.appendingPathComponent("speech.wav")
            _ = try Importer.convert(aiff, to: speechURL)
            let speech = try samples(speechURL)
            let lead = 48000, seconds = Double(speech.count + 2 * lead) / Formats.rate
            let talkURL = audioDir.appendingPathComponent("talk.wav")
            try writeSignal(talkURL, channels: 1, seconds: seconds) { _, t in
                let i = Int(t * Formats.rate) - lead
                let voice: Float = speech.indices.contains(i) ? speech[i] * 0.5 : 0
                // Mains hum has harmonics; a pure 50 Hz sine is left alone by the model as a tone.
                let hum = 0.01 * sin(2 * .pi * 50 * t) + 0.005 * sin(2 * .pi * 100 * t) + 0.003 * sin(2 * .pi * 150 * t)
                return voice + 0.01 * noise() + Float(hum)
            }
            let talkRef: ClipRef = onMain {
                let c = Clip(file: "talk.wav", fileLength: seconds, start: 40, duration: seconds)
                session.project.tracks[0].clips.append(c)
                return ClipRef(track: session.project.tracks[0].id, clip: c.id)
            }
            let voiceSpan = (Double(lead) / Formats.rate, Double(lead + speech.count) / Formats.rate)
            let cleanVoice = 0.5 * sqrt(speech.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, speech.count)))
            let sem5 = DispatchSemaphore(value: 0)
            var cleaned = false
            let started = Date()
            DispatchQueue.main.async { session.cleanUp(talkRef, .voiceClean(strength: VoiceClean.maxStrength)) { ok in cleaned = ok; sem5.signal() } }
            _ = sem5.wait(timeout: .now() + 60)
            if let c = onMain({ session.clip(talkRef) }), cleaned, c.cleanup == .voiceClean, c.originalFile == "talk.wav" {
                let url = audioDir.appendingPathComponent(c.file)
                let quietBefore = try segment(talkURL, from: 0.5, to: 0.95).rms, quietAfter = try segment(url, from: 0.5, to: 0.95).rms
                let voiceAfter = try segment(url, from: voiceSpan.0, to: voiceSpan.1).rms
                let cut = 20 * log10(quietAfter / quietBefore), kept = 20 * log10(voiceAfter / cleanVoice)
                check(cut < -20, String(format: "Voice Clean removes hiss + hum by %.1f dB in %.1f s", cut, Date().timeIntervalSince(started)))
                check(abs(kept) < 2, String(format: "Voice Clean keeps the voice within %.2f dB", kept))
                check(try samples(url).count == samples(talkURL).count, "Voice Clean output is exactly as long as the take")
                // Aligned: the cleaned voice correlates best with the original at zero offset.
                let a = try samples(talkURL), b = try samples(url), from = lead + 12000
                func corr(_ k: Int) -> Double { stride(from: 0, to: 6000, by: 2).reduce(0.0) { $0 + Double(a[from + $1] * b[from + $1 + k]) } }
                let lag = (-480...480).max { corr($0) < corr($1) } ?? 99
                check(abs(lag) <= 2, "Voice Clean output lines up with the original (offset \(lag) samples)")
                onMain { session.removeCleanup(talkRef) }
                check(onMain { session.clip(talkRef)?.file } == "talk.wav", "Remove Voice Clean puts the original back")
            } else {
                check(false, "Voice Clean runs on a clip and points it at the cleaned copy (\(onMain { session.problem } ?? "no message"))")
            }
            onMain { session.project.tracks[0].clips.removeAll { $0.id == talkRef.clip } }
        }
        onMain {
            if let t = songTrack { session.removeTrack(t.id) }
            session.project.tracks[1].clips.removeAll { $0.file.hasPrefix("beat 44k") }
            session.project.tracks[0].clips.removeAll { $0.start >= 9.9 }
        }

        // 4. Export the real mix (take + tone) to WAV and M4A.
        let wav = root.appendingPathComponent("Mix.wav")
        let mix = onMain { session.project }
        try Exporter.render(mix, audioFolder: folder.appendingPathComponent("Audio"), to: wav, format: .wav)
        let w = try Exporter.analyze(wav)
        check(w.channels == 2 && w.peak > 0.1, String(format: "WAV export: %.2f s, 2 ch, peak %.3f at %@", Double(w.frames) / Formats.rate, w.peak, wav.path))
        let m4a = root.appendingPathComponent("Mix.m4a")
        try Exporter.render(mix, audioFolder: folder.appendingPathComponent("Audio"), to: m4a, format: .m4a)
        let m = try Exporter.analyze(m4a)
        check(m.peak > 0.1, String(format: "M4A export: peak %.3f", m.peak))
        let info = Process()
        info.executableURL = URL(fileURLWithPath: "/usr/bin/afinfo")
        info.arguments = [wav.path]
        info.standardOutput = FileHandle.nullDevice
        try info.run(); info.waitUntilExit()
        check(info.terminationStatus == 0, "afinfo reads the exported WAV")

        // 5. Save and reopen. Monitoring is saved on, and must come back off.
        onMain { session.project.tracks[0].monitor = true }
        try onMain { Result { try session.save() } }.get()
        let reopened: Project = try onMain {
            Result {
                let s = Session(startTimer: false)
                try s.open(folder)
                return s.project
            }
        }.get()
        var expected = onMain { session.project }
        for i in expected.tracks.indices { expected.tracks[i].armed = false; expected.tracks[i].monitor = false }
        check(reopened == expected, "project saves and reopens unchanged")
        check(!reopened.tracks.contains { $0.monitor }, "opening a project starts with live monitoring off")
        onMain { session.project.tracks[0].monitor = false }
    }

    static func writeTone(_ url: URL, frequency: Double, amplitude: Float, seconds: Double) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Formats.rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * Formats.rate)
        let buf = AVAudioPCMBuffer(pcmFormat: Formats.mono, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { buf.floatChannelData![0][i] = amplitude * Float(sin(2 * .pi * frequency * Double(i) / Formats.rate)) }
        try file.write(from: buf)
        file.close()
    }

    static func writeSignal(_ url: URL, channels: Int, seconds: Double, rate: Double = Formats.rate, _ f: (Int, Double) -> Float) throws {
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let n = Int(seconds * rate)
        let buf = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!,
                                   frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for c in 0..<channels { for i in 0..<n { buf.floatChannelData![c][i] = f(c, Double(i) / rate) } }
        try file.write(from: buf)
        file.close()
    }

    static func segment(_ url: URL, from a: Double, to b: Double) throws -> (l: Float, r: Float, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let start = AVAudioFramePosition(a * Formats.rate)
        let count = AVAudioFrameCount(max(0, min(Double(file.length - start), (b - a) * Formats.rate)))
        guard count > 0 else { return (0, 0, 0) }
        file.framePosition = start
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
        try file.read(into: buf, frameCount: count)
        var l: Float = 0, r: Float = 0, sum = 0.0
        let d = buf.floatChannelData!
        let right = buf.format.channelCount > 1 ? 1 : 0     // mono: both sides read the one channel
        for i in 0..<Int(buf.frameLength) {
            l = max(l, abs(d[0][i])); r = max(r, abs(d[right][i]))
            sum += Double(d[0][i] * d[0][i] + d[right][i] * d[right][i])
        }
        return (l, r, sqrt(sum / Double(2 * buf.frameLength)))
    }

    static func samples(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buf)
        return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
    }
}

/// `Recorder --inputcheck <log>`: opens every input device for a few seconds and logs the peak
/// level of each channel, so you can tell whether a mic on a given input is reaching the Mac.
enum InputCheck {
    static func start(logPath: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            func log(_ s: String) { lines.append(s); try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                log("asking for microphone access — click Allow")
                let sem = DispatchSemaphore(value: 0)
                AVCaptureDevice.requestAccess(for: .audio) { _ in sem.signal() }
                _ = sem.wait(timeout: .now() + 120)
            }
            log("microphone access: \(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "allowed" : "NOT allowed")")
            let devices = AudioDevices.inputDevices().sorted { a, _ in a.name.contains("USB") }
            for device in devices {
                let recorder = InputRecorder()
                let opened: Bool = DispatchQueue.main.sync {
                    do { try recorder.start(device: device); return true }
                    catch { log("\(device.name): couldn't open — \(error.localizedDescription)"); return false }
                }
                guard opened else { continue }
                var peaks = [Float](repeating: 0, count: recorder.channelCount)
                for _ in 0..<50 {
                    Thread.sleep(forTimeInterval: 0.1)
                    for (i, m) in recorder.meters.enumerated() { peaks[i] = max(peaks[i], m.take().0) }
                }
                DispatchQueue.main.sync { recorder.stop() }
                let desc = peaks.enumerated().map { i, p in
                    String(format: "input %d: %@", i + 1, p <= 0 ? "digital silence" : String(format: "%.1f dBFS", 20 * log10(p)))
                }
                log("\(device.name) [\(device.id)]: " + desc.joined(separator: ", "))
            }
            log("DONE")
            DispatchQueue.main.async { exit(0) }
        }
    }
}
