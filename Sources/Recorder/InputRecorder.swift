import AVFoundation

/// The input side: its own engine (so the mic is only open while a track is armed), per-channel
/// input meters, and WAV writing of the armed channels. Recordings are always 48 kHz mono 24-bit.
final class InputRecorder {
    struct TakeRequest { let trackID: UUID; let channels: [Int]; let url: URL }   // 1 channel = mono, 2 = stereo
    struct TakeResult { let trackID: UUID; let url: URL; let frames: Int64; let peaks: [Float]; let startDelay: Double }

    private final class Take {
        let request: TakeRequest
        let file: AVAudioFile
        var converter: AVAudioConverter?
        var frames: Int64 = 0
        var peaks: [Float] = []
        var peakAccum: Float = 0
        var peakCount = 0
        init(request: TakeRequest, file: AVAudioFile) { self.request = request; self.file = file }
    }

    static let peakBlock = 256          // frames per waveform point at 48 kHz

    private var engine: AVAudioEngine?
    private(set) var device: InputDevice?
    private(set) var channelCount = 0
    private(set) var meters: [Meter] = []
    let monitorRing = MonitorRing()
    var onInterrupted: (() -> Void)?

    private var lock = os_unfair_lock()
    private var takes: [Take] = []
    private var startHost: UInt64 = 0
    private var firstBufferDelay: Double?
    private var writeError: Error?

    var isRunning: Bool { engine?.isRunning ?? false }
    var latency: Double { engine?.inputNode.presentationLatency ?? 0 }

    /// Opens `device` (or the system default input when nil) and starts metering.
    func start(device: InputDevice?) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device, let unit = input.audioUnit {
            var id = device.objectID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &id, UInt32(MemoryLayout<AudioObjectID>.size))
            if status != noErr { throw RecorderError.message("Couldn't open \(device.name) (\(status)).") }
        }
        // After switching device the input node still reports the old device's channel count on
        // its output; connecting it with the device's own format makes all its channels arrive.
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.channelCount > 0, hardware.sampleRate > 0,
              let deviceFormat = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount)
        else { throw RecorderError.message("No audio input is available.") }
        // A sink node gets the input in real time for monitoring; connecting it with the device's
        // format also makes all channels arrive.
        let ring = monitorRing
        ring.sampleRate = hardware.sampleRate
        let sink = AVAudioSinkNode { _, frames, abl in
            ring.write(abl, frames: Int(frames))
            return noErr
        }
        engine.attach(sink)
        engine.connect(input, to: sink, format: deviceFormat)
        IOBuffer.set(input.audioUnit, frames: 128)
        let format = input.outputFormat(forBus: 0)
        channelCount = Int(format.channelCount)
        meters = (0..<channelCount).map { _ in Meter() }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
            self?.process(buffer, time: time)
        }
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self, weak engine] _ in
            self?.configurationChanged(engine)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        self.device = device
        startedFormat = hardware
    }

    private var observer: NSObjectProtocol?
    private var startedFormat: AVAudioFormat?

    /// macOS sends a configuration change right after an interface starts, and for things like
    /// sample-rate changes. If the device is still there with the same format, restart in place
    /// (recording carries on); only a real disconnect is reported.
    private func configurationChanged(_ changed: AVAudioEngine?) {
        guard let engine, changed === engine else { return }
        let stillThere = device.map { d in AudioDevices.inputDevices().contains { $0.id == d.id } } ?? true
        let format = engine.inputNode.inputFormat(forBus: 0)
        if stillThere, format.channelCount == startedFormat?.channelCount, format.sampleRate == startedFormat?.sampleRate {
            if engine.isRunning { return }
            engine.prepare()
            if (try? engine.start()) != nil { return }
        }
        onInterrupted?()
    }

    func stop() {
        guard let engine else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        device = nil
    }

    /// Starts writing; audio captured before `host` is dropped so takes line up with playback.
    func beginRecording(_ requests: [TakeRequest], at host: UInt64) throws {
        let newTakes = try requests.map { req in
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Formats.rate, AVNumberOfChannelsKey: req.channels.count,
                AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ]
            return Take(request: req, file: try AVAudioFile(forWriting: req.url, settings: settings,
                                                            commonFormat: .pcmFormatFloat32, interleaved: false))
        }
        os_unfair_lock_lock(&lock)
        takes = newTakes
        startHost = host
        firstBufferDelay = nil
        writeError = nil
        os_unfair_lock_unlock(&lock)
    }

    var isRecording: Bool {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return !takes.isEmpty
    }

    /// Waveform points recorded so far for each track, for the live display.
    func livePeaks() -> [UUID: [Float]] {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        return Dictionary(takes.map { ($0.request.trackID, $0.peaks) }, uniquingKeysWith: { a, _ in a })
    }

    func finishRecording() -> (results: [TakeResult], error: Error?) {
        os_unfair_lock_lock(&lock)
        let done = takes
        takes = []
        let delay = firstBufferDelay ?? 0
        let error = writeError
        os_unfair_lock_unlock(&lock)
        let results = done.map { take in
            take.file.close()
            return TakeResult(trackID: take.request.trackID, url: take.request.url, frames: take.frames,
                              peaks: take.peaks, startDelay: delay)
        }
        return (results, error)
    }

    // MARK: audio thread (tap)

    private func process(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength)
        for (c, meter) in meters.enumerated() where c < Int(buffer.format.channelCount) {
            var p: Float = 0
            for i in 0..<n { p = max(p, abs(data[c][i])) }
            meter.feed(left: p, right: p)
        }

        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard !takes.isEmpty else { return }
        let rate = buffer.format.sampleRate
        var skip = 0
        if time.isHostTimeValid {
            let delta = AVAudioTime.seconds(forHostTime: time.hostTime) - AVAudioTime.seconds(forHostTime: startHost)
            if delta < 0 { skip = min(n, Int((-delta * rate).rounded())) }
            if firstBufferDelay == nil, skip < n { firstBufferDelay = max(0, delta) }
        } else if firstBufferDelay == nil {
            firstBufferDelay = 0
        }
        let count = n - skip
        guard count > 0 else { return }

        for take in takes {
            let k = take.request.channels.count
            let available = Int(buffer.format.channelCount)
            guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(k)),
                  let outFormat = AVAudioFormat(standardFormatWithSampleRate: Formats.rate, channels: AVAudioChannelCount(k)),
                  let picked = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(count)) else { continue }
            picked.frameLength = AVAudioFrameCount(count)
            for (dst, src) in take.request.channels.enumerated() {
                picked.floatChannelData![dst].update(from: data[min(src, available - 1)] + skip, count: count)
            }
            var out = picked
            if rate != Formats.rate {
                if take.converter == nil { take.converter = AVAudioConverter(from: inFormat, to: outFormat) }
                guard let conv = take.converter,
                      let converted = AVAudioPCMBuffer(pcmFormat: outFormat,
                                                       frameCapacity: AVAudioFrameCount(Double(count) * Formats.rate / rate) + 64)
                else { continue }
                var given = false
                var err: NSError?
                conv.convert(to: converted, error: &err) { _, status in
                    if given { status.pointee = .noDataNow; return nil }
                    given = true
                    status.pointee = .haveData
                    return picked
                }
                out = converted
            }
            do { try take.file.write(from: out) } catch { writeError = error; continue }
            take.frames += Int64(out.frameLength)
            let samples = out.floatChannelData!
            for i in 0..<Int(out.frameLength) {
                for c in 0..<k { take.peakAccum = max(take.peakAccum, abs(samples[c][i])) }
                take.peakCount += 1
                if take.peakCount == Self.peakBlock {
                    take.peaks.append(take.peakAccum)
                    take.peakAccum = 0
                    take.peakCount = 0
                }
            }
        }
    }
}

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

