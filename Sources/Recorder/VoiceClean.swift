import AVFoundation

/// Neural voice clean-up with DeepFilterNet 3, run through the project's own command-line tool
/// (bundled as Contents/MacOS/deep-filter by build.sh). Unlike Denoise it needs no noise print:
/// the model separates speech or singing from any noise, steady or not.
///
/// The tool reads 16-bit or float WAVs only (not 24-bit), writes 16-bit, and with `-D` returns
/// output aligned to the input but 30 ms shorter. So: source → float temp → tool → padded 24-bit.
enum VoiceClean {
    static var tool: URL? {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "deep-filter"),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Strength is the most the noise may be turned down, in dB; `maxStrength` means no limit.
    static let maxStrength: Float = 100

    enum Failure: LocalizedError {
        case notInstalled, failed(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "Voice Clean isn't installed in this copy of Recorder. Rebuild it with build.sh while online."
            case .failed(let why): "Voice Clean couldn't process this recording. \(why)"
            }
        }
    }

    static func process(source: URL, dest: URL, strength: Float) throws {
        guard let tool else { throw Failure.notInstalled }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("voiceclean-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let input = try AVAudioFile(forReading: source)
        let channels = Int(input.processingFormat.channelCount)
        let total = input.length
        let floatCopy = work.appendingPathComponent("in.wav")
        try copy(input, to: floatCopy, bits: 32, float: true, length: total)

        let run = Process()
        run.executableURL = tool
        run.arguments = ["-D", "-a", String(Int(min(maxStrength, max(1, strength)))), "-o", work.appendingPathComponent("out").path, floatCopy.path]
        let errors = Pipe()
        run.standardError = errors
        run.standardOutput = FileHandle.nullDevice
        try run.run()
        let log = errors.fileHandleForReading.readDataToEndOfFile()
        run.waitUntilExit()
        let cleaned = work.appendingPathComponent("out/in.wav")
        guard run.terminationStatus == 0, FileManager.default.fileExists(atPath: cleaned.path) else {
            let line = String(decoding: log, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
            throw Failure.failed(line)
        }
        let result = try AVAudioFile(forReading: cleaned)
        guard Int(result.processingFormat.channelCount) == channels else { throw Failure.failed("The channel count changed.") }
        try copy(result, to: dest, bits: 24, float: false, length: total)
    }

    /// Copies `file` to a WAV of the given sample format, padded with silence (or cut) to `length`.
    private static func copy(_ file: AVAudioFile, to url: URL, bits: Int, float: Bool, length: AVAudioFramePosition) throws {
        let format = file.processingFormat
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: bits,
                                       AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: false]
        let out = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let chunk: AVAudioFrameCount = 65536
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk)!
        var written: AVAudioFramePosition = 0
        file.framePosition = 0
        while written < length {
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunk), length - written))
            if file.framePosition < file.length {
                try file.read(into: buf, frameCount: want)
            } else {
                buf.frameLength = 0
            }
            if buf.frameLength < want {         // past the end of the source: silence
                for c in 0..<Int(format.channelCount) {
                    let p = buf.floatChannelData![c]
                    for i in Int(buf.frameLength)..<Int(want) { p[i] = 0 }
                }
                buf.frameLength = want
            }
            try out.write(from: buf)
            written += AVAudioFramePosition(buf.frameLength)
        }
    }
}
