import AVFoundation

enum ExportFormat: String, CaseIterable { case wav, m4a }

/// Renders the mix offline through the same Strip chain the live engine uses.
enum Exporter {
    struct Stats { var frames: Int64 = 0; var peak: [Float] = [0, 0]; var sumSquares: Double = 0
        var rms: Double { frames > 0 ? sqrt(sumSquares / Double(frames * 2)) : 0 } }

    @discardableResult
    static func render(_ project: Project, audioFolder: URL, to url: URL, format: ExportFormat = .wav,
                       range: ClosedRange<Double>? = nil) throws -> Stats {
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: Formats.stereo, maximumFrameCount: 4096)
        var strips: [(Strip, Track)] = []
        for track in project.tracks {
            let strip = Strip(engine: engine, meterTap: false)
            strip.apply(track, audible: project.isAudible(track), tempo: project.tempo)
            strips.append((strip, track))
        }
        engine.mainMixerNode.outputVolume = project.masterVolume
        try engine.start()
        defer { engine.stop() }

        let rate = Formats.rate
        let start = range?.lowerBound ?? 0
        let reverbTail = project.tracks.contains { $0.reverb.enabled && project.isAudible($0) } ? 3.0 : 0.05
        let end = range?.upperBound ?? (project.duration + reverbTail)
        let from = Int64((start * rate).rounded())
        for (strip, track) in strips {
            strip.schedule(track.clips, audioFolder: audioFolder, from: from, to: nil, base: 0)
            strip.play(at: nil)
        }

        let settings: [String: Any]
        switch format {
        case .wav:
            settings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                        AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        case .m4a:
            settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                        AVEncoderBitRateKey: 256_000]
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: engine.manualRenderingMaximumFrameCount)!
        var remaining = max(0, Int64(((end - start) * rate).rounded()))
        var stats = Stats()
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(buffer.frameCapacity), remaining))
            let status = try engine.renderOffline(n, to: buffer)
            guard status == .success else {
                if status == .error { throw RecorderError.message("Rendering failed.") }
                continue
            }
            try file.write(from: buffer)
            let data = buffer.floatChannelData!
            for c in 0..<2 {
                for i in 0..<Int(buffer.frameLength) {
                    let v = data[c][i]
                    stats.peak[c] = max(stats.peak[c], abs(v))
                    stats.sumSquares += Double(v * v)
                }
            }
            stats.frames += Int64(buffer.frameLength)
            remaining -= Int64(buffer.frameLength)
        }
        file.close()
        for (strip, _) in strips { strip.stop() }
        return stats
    }

    /// Peak and RMS of an audio file, for checking exports and takes.
    static func analyze(_ url: URL) throws -> (frames: Int64, channels: Int, peak: Float, rms: Double) {
        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        var peak: Float = 0, sum = 0.0, count = 0.0
        while file.framePosition < file.length {
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            for c in 0..<Int(buf.format.channelCount) {
                let d = buf.floatChannelData![c]
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[i])); sum += Double(d[i] * d[i]); count += 1 }
            }
        }
        return (file.length, Int(file.processingFormat.channelCount), peak, count > 0 ? sqrt(sum / count) : 0)
    }
}

/// Waveform overviews: one peak per 256 frames, kept in memory per audio file.
final class Waveforms: ObservableObject {
    @Published private(set) var peaks: [String: [Float]] = [:]
    private var loading: Set<String> = []

    func set(_ name: String, _ values: [Float]) { peaks[name] = values }
    func clear() { peaks = [:]; loading = [] }

    func load(_ name: String, folder: URL) {
        guard peaks[name] == nil, !loading.contains(name) else { return }
        loading.insert(name)
        let url = folder.appendingPathComponent(name)
        DispatchQueue.global(qos: .utility).async {
            let values = Self.compute(url)
            DispatchQueue.main.async {
                self.loading.remove(name)
                self.peaks[name] = values
            }
        }
    }

    static func compute(_ url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let block = InputRecorder.peakBlock
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(block * 256))!
        var out: [Float] = []
        out.reserveCapacity(Int(file.length) / block + 1)
        while file.framePosition < file.length {
            guard (try? file.read(into: buf)) != nil, buf.frameLength > 0 else { break }
            var i = 0
            let n = Int(buf.frameLength)
            let channels = Int(buf.format.channelCount)
            while i < n {
                var p: Float = 0
                for c in 0..<channels {
                    let d = buf.floatChannelData![c]
                    for j in i..<min(n, i + block) { p = max(p, abs(d[j])) }
                }
                out.append(p)
                i += block
            }
        }
        return out
    }
}
