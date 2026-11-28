import AVFoundation

/// The live output engine: one Strip per track, a master meter, and sample-accurate scheduling
/// with gapless looping.
final class PlaybackEngine {
    let engine = AVAudioEngine()
    private(set) var strips: [UUID: Strip] = [:]
    let masterMeter = Meter()
    private(set) lazy var master = MasterChain(engine: engine)
    let send = SendOutput()

    /// Sends a copy of the output to `device` as well (nil = stop sending).
    func setSend(_ device: AudioObjectID?) throws {
        guard let device else { send.stop(); master.setSend(nil); return }
        if send.device == device, send.isRunning { return }
        try send.start(device: device)
        master.setSend(send.ring)
    }
    var onConfigurationChange: (() -> Void)?
    var onDeviceLost: (() -> Void)?

    private struct Iteration { var startFrame: Int64; var position: Int64; var length: Int64? }
    private var iterations: [Iteration] = []
    private var startHost: UInt64 = 0
    private var loop: (start: Int64, end: Int64)?
    private var clips: [UUID: [Clip]] = [:]
    private var audioFolder: URL?
    private(set) var isPlaying = false

    // MARK: metronome
    /// When clicks sound: never, always, or only before a timeline time (the count-in).
    enum Clicks: Equatable { case none, always, before(Double) }
    private let clickPlayer = AVAudioPlayerNode()
    private lazy var accentClick = Self.click(frequency: 1760, gain: 0.55)
    private lazy var beatClick = Self.click(frequency: 1175, gain: 0.4)
    private var clicks: Clicks = .none
    private var beatFrames: Double = 24000
    private var beatsPerBar = 4
    private var clickScheduledUntil: Int64 = 0     // player frame

    static func click(frequency: Double, gain: Float) -> AVAudioPCMBuffer {
        let n = Int(Formats.rate * 0.035)
        let buf = AVAudioPCMBuffer(pcmFormat: Formats.stereo, frameCapacity: AVAudioFrameCount(n))!
        buf.frameLength = AVAudioFrameCount(n)
        for i in 0..<n {
            let t = Double(i) / Formats.rate
            let v = gain * Float(sin(2 * .pi * frequency * t) * exp(-t * 90))
            buf.floatChannelData![0][i] = v; buf.floatChannelData![1][i] = v
        }
        return buf
    }

    /// Queues clicks up to `limit` (player frames), following loop passes.
    private func scheduleClicks(until limit: Int64) {
        guard clicks != .none, limit > clickScheduledUntil else { return }
        for it in iterations {
            let itEnd = it.length.map { it.startFrame + $0 } ?? Int64.max
            let from = max(clickScheduledUntil, it.startFrame), to = min(limit, itEnd)
            guard from < to else { continue }
            // Timeline frame of `from`, then the first beat at or after it.
            let timeline = Double(it.position + (from - it.startFrame))
            var beat = Int64((timeline / beatFrames).rounded(.up))
            while true {
                let beatTimeline = Double(beat) * beatFrames
                let frame = it.startFrame + Int64(beatTimeline.rounded()) - it.position
                if frame >= to { break }
                if case .before(let end) = clicks, beatTimeline / Formats.rate >= end - 0.001 { break }
                let accent = ((beat % Int64(beatsPerBar)) + Int64(beatsPerBar)) % Int64(beatsPerBar) == 0
                clickPlayer.scheduleBuffer(accent ? accentClick : beatClick, at: AVAudioTime(sampleTime: frame, atRate: Formats.rate))
                beat += 1
            }
        }
        clickScheduledUntil = limit
    }
    private(set) var isMonitoring = false

    /// Turns each track's live-input feed on or off and keeps the engine running while any is on.
    func updateMonitoring(_ project: Project, inputRunning: Bool) {
        sync(project)
        var any = false
        for track in project.tracks {
            let on = track.monitor && inputRunning
            strips[track.id]?.setMonitor(on ? track : nil)
            any = any || on
        }
        isMonitoring = any
        if any {
            if !engine.isRunning { engine.prepare(); try? engine.start() }
        } else if !isPlaying, engine.isRunning {
            engine.pause()
        }
    }

    let monitorRing: MonitorRing

    init(monitorRing: MonitorRing) {
        self.monitorRing = monitorRing
        IOBuffer.set(engine.outputNode.audioUnit, frames: 128)   // set once, before the engine runs
        engine.attach(clickPlayer)
        engine.connect(clickPlayer, to: engine.mainMixerNode, format: Formats.stereo)
        let meter = masterMeter
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    private(set) var outputDeviceID: AudioObjectID?

    /// The device the output unit is really using right now.
    var currentOutputDevice: AudioObjectID {
        guard let unit = engine.outputNode.audioUnit else { return 0 }
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return id
    }

    /// Sends playback, clicks and monitoring to `device` (nil = the system default output).
    /// The engine is stopped while the device changes; the caller restarts the transport.
    func setOutputDevice(_ device: AudioObjectID?) {
        let target = device ?? AudioDevices.defaultOutput()
        guard target != 0, target != currentOutputDevice else { outputDeviceID = target; return }
        let wasRunning = engine.isRunning
        for strip in strips.values { strip.stop() }
        clickPlayer.stop()
        isPlaying = false
        engine.stop()
        if let unit = engine.outputNode.audioUnit {
            var id = target
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, UInt32(MemoryLayout<AudioObjectID>.size))
        }
        outputDeviceID = target
        IOBuffer.set(engine.outputNode.audioUnit, frames: 128)
        master.wire()
        if wasRunning && isMonitoring { engine.prepare(); try? engine.start() }
    }

    /// The output device changed or disappeared (e.g. the dock's USB hub dropped out).
    private func configurationChanged() {
        let wasPlaying = isPlaying
        for strip in strips.values { strip.stop() }
        isPlaying = false
        engine.stop()
        master.wire()
        onDeviceLost?()
        if isMonitoring { engine.prepare(); try? engine.start() }
        if wasPlaying { onConfigurationChange?() }
    }

    /// Adds and removes strips to match the tracks, then applies every mix setting.
    func sync(_ project: Project) {
        let ids = Set(project.tracks.map(\.id))
        let structural = strips.keys.contains { !ids.contains($0) } || ids.contains { strips[$0] == nil }
        // Never rewire a running graph: the audio thread may be inside a node being removed.
        let resume = structural && engine.isRunning
        if resume { engine.pause() }
        for (id, strip) in strips where !ids.contains(id) {
            strip.detach(from: engine)
            strips[id] = nil
        }
        for track in project.tracks {
            let strip = strips[track.id] ?? {
                let s = Strip(engine: engine, meterTap: true, monitorRing: monitorRing)
                strips[track.id] = s
                return s
            }()
            strip.apply(track, audible: project.isAudible(track), tempo: project.tempo)
        }
        if resume { engine.prepare(); try? engine.start() }
        engine.mainMixerNode.outputVolume = project.masterVolume
        master.sync(project.masterPlugins)
    }

    /// Starts every track at host time `at` from timeline `position`.
    func play(_ project: Project, audioFolder: URL?, from position: Double, loop loopRange: (Double, Double)?, at host: UInt64,
              clicks: Clicks = .none) throws {
        stop()
        sync(project)
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        let rate = Formats.rate
        let pos = Int64((position * rate).rounded())
        self.audioFolder = audioFolder
        clips = Dictionary(uniqueKeysWithValues: project.tracks.map { ($0.id, $0.clips) })
        if let (a, b) = loopRange, b - a > 0.05, position < b {
            loop = (Int64((a * rate).rounded()), Int64((b * rate).rounded()))
        } else {
            loop = nil
        }
        let first = Iteration(startFrame: 0, position: pos, length: loop.map { $0.end - pos })
        iterations = [first]
        schedule(first)
        startHost = host
        self.clicks = clicks
        beatFrames = project.beatLength * rate
        beatsPerBar = project.beatsPerBar
        clickScheduledUntil = 0
        scheduleClicks(until: Int64(4 * rate))
        let when = AVAudioTime(hostTime: host)
        for strip in strips.values { strip.play(at: when) }
        clickPlayer.play(at: when)
        isPlaying = true
    }

    private func schedule(_ it: Iteration) {
        guard let folder = audioFolder else { return }
        for (id, strip) in strips {
            strip.schedule(clips[id] ?? [], audioFolder: folder, from: it.position,
                           to: it.length.map { it.position + $0 }, base: it.startFrame)
        }
    }

    func stop() {
        clickPlayer.stop()
        for strip in strips.values { strip.stop() }
        if isPlaying, !isMonitoring { engine.pause() }
        isPlaying = false
        iterations = []
    }

    /// Seconds since the transport's start time (negative before it).
    private var elapsed: Double {
        AVAudioTime.seconds(forHostTime: mach_absolute_time()) - AVAudioTime.seconds(forHostTime: startHost)
    }

    var position: Double {
        let rate = Formats.rate
        guard isPlaying, let firstIt = iterations.first else { return 0 }
        let e = max(0, elapsed)
        let it = iterations.last(where: { Double($0.startFrame) / rate <= e }) ?? firstIt
        return Double(it.position) / rate + (e - Double(it.startFrame) / rate)
    }

    /// Called often from the UI; queues the next loop pass about a second before it is due.
    func tick() {
        guard isPlaying else { return }
        defer { scheduleClicks(until: Int64((max(0, elapsed) + 3) * Formats.rate)) }
        guard let loop, let last = iterations.last, let length = last.length else { return }
        let end = last.startFrame + length
        if elapsed > Double(end) / Formats.rate - 1.0 {
            let next = Iteration(startFrame: end, position: loop.start, length: loop.end - loop.start)
            iterations.append(next)
            if iterations.count > 4 { iterations.removeFirst() }
            schedule(next)
        }
    }

    var outputLatency: Double { engine.outputNode.presentationLatency }
}
