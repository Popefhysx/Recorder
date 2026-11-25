import AVFoundation

/// Converts any audio file macOS can read (WAV, AIFF, MP3, M4A/AAC, CAF, FLAC…) into the
/// project's format: 48 kHz, 24-bit WAV, mono or stereo (extra channels are dropped).
enum Importer {
    struct Result { let frames: Int64; let channels: Int; let peaks: [Float] }

    static func convert(_ source: URL, to dest: URL) throws -> Result {
        let input = try AVAudioFile(forReading: source)
        let inFormat = input.processingFormat
        let k = min(2, Int(inFormat.channelCount))
        guard k > 0, let outFormat = AVAudioFormat(standardFormatWithSampleRate: Formats.rate, channels: AVAudioChannelCount(k)),
              let pickFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: AVAudioChannelCount(k)),
              let converter = AVAudioConverter(from: pickFormat, to: outFormat)
        else { throw RecorderError.message("\(source.lastPathComponent) isn't an audio format Recorder can read.") }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Formats.rate, AVNumberOfChannelsKey: k,
                                       AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        defer { output.close() }

        let chunk: AVAudioFrameCount = 32768
        let readBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(Double(chunk) * Formats.rate / inFormat.sampleRate) + 1024)!
        var finished = false
        var frames: Int64 = 0
        var peaks: [Float] = []
        var acc: Float = 0, count = 0

        while true {
            var error: NSError?
            let status = converter.convert(to: outBuf, error: &error) { _, inputStatus in
                if finished { inputStatus.pointee = .endOfStream; return nil }
                do { try input.read(into: readBuf, frameCount: chunk) } catch { finished = true; inputStatus.pointee = .endOfStream; return nil }
                if readBuf.frameLength == 0 { finished = true; inputStatus.pointee = .endOfStream; return nil }
                // Keep the first one or two channels.
                let picked = AVAudioPCMBuffer(pcmFormat: pickFormat, frameCapacity: readBuf.frameLength)!
                picked.frameLength = readBuf.frameLength
                for c in 0..<k { picked.floatChannelData![c].update(from: readBuf.floatChannelData![c], count: Int(readBuf.frameLength)) }
                inputStatus.pointee = .haveData
                return picked
            }
            if let error { throw error }
            if outBuf.frameLength > 0 {
                try output.write(from: outBuf)
                frames += Int64(outBuf.frameLength)
                for i in 0..<Int(outBuf.frameLength) {
                    for c in 0..<k { acc = max(acc, abs(outBuf.floatChannelData![c][i])) }
                    count += 1
                    if count == InputRecorder.peakBlock { peaks.append(acc); acc = 0; count = 0 }
                }
            }
            if status == .endOfStream || status == .error || (finished && outBuf.frameLength == 0) { break }
        }
        guard frames > 0 else { throw RecorderError.message("\(source.lastPathComponent) has no audio in it.") }
        return Result(frames: frames, channels: k, peaks: peaks)
    }
}
