import AVFoundation

/// Offline "make it sound finished" processing for a recorded clip:
///
/// - **Enhance voice:** level the take to −3 dBFS peak, then low cut (80 Hz), a little less mud
///   (−2.5 dB at 250 Hz), more presence (+3 dB at 3.2 kHz) and air (+2.5 dB shelf from 10 kHz),
///   then gentle compression (3:1 above −22 dBFS, 5 ms / 120 ms), and finally bring the result up
///   to −1 dBFS peak.
/// - **Volume:** normalize to −1 dBFS peak, or a fixed gain. Any gain goes through a 5 ms
///   look-ahead limiter with a −1 dBFS ceiling, so boosting a take never clips.
///
/// Writes a new 24-bit file of exactly the source's length. Stereo is processed linked (one gain
/// for both sides), so the image doesn't shift.
enum Enhance {
    static let ceiling: Float = 0.891          // −1 dBFS

    enum Volume: Equatable { case unchanged, normalize, gain(Float) }

    static func process(source: URL, dest: URL, enhance: Bool, volume: Volume, progress: (Double) -> Void = { _ in }) throws {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        let total = input.length
        let rate = Float(format.sampleRate)

        // Pass 1 (enhance only): how far to bring the take up before the compressor sees it.
        var pre: Float = 1
        if enhance {
            let peak = try peakLevel(input)
            pre = peak > 1e-6 ? 0.708 / peak : 1     // −3 dBFS
        }

        // Pass 2: pre-gain, EQ and compressor into a float scratch file; measure the result.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("enhance-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var peak2: Float = 0
        do {
            let out = try AVAudioFile(forWriting: scratch, settings: wavSettings(format, float: true),
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
            var filters = (0..<channels).map { _ in enhance ? voiceChain(rate) : [] }
            var comp = Compressor(rate: rate)
            try stream(input, total: total) { buf in
                let n = Int(buf.frameLength)
                let d = buf.floatChannelData!
                for i in 0..<n {
                    var level: Float = 0
                    for c in 0..<channels {
                        var x = d[c][i] * pre
                        for f in filters[c].indices { x = filters[c][f].run(x) }
                        d[c][i] = x
                        level = max(level, abs(x))
                    }
                    if enhance {
                        let g = comp.gain(level)
                        for c in 0..<channels { d[c][i] *= g }
                    }
                    for c in 0..<channels { peak2 = max(peak2, abs(d[c][i])) }
                }
                try out.write(from: buf)
                progress(0.5 * Double(input.framePosition) / Double(max(1, total)))
            }
        }

        // Pass 3: final level through the limiter, into the destination.
        let gain: Float
        switch volume {
        case .normalize: gain = peak2 > 1e-6 ? ceiling / peak2 : 1
        case .gain(let db): gain = pow(10, db / 20) * (enhance && peak2 > 1e-6 ? ceiling / peak2 : 1)
        case .unchanged: gain = enhance && peak2 > 1e-6 ? ceiling / peak2 : 1
        }
        let mid = try AVAudioFile(forReading: scratch)
        let out = try AVAudioFile(forWriting: dest, settings: wavSettings(format, float: false),
                                  commonFormat: .pcmFormatFloat32, interleaved: false)
        var limiter = Limiter(channels: channels, rate: rate, ceiling: ceiling)
        var skip = limiter.delay             // the limiter's look-ahead delays its output; drop that much
        let outBuf = AVAudioPCMBuffer(pcmFormat: out.processingFormat, frameCapacity: 8192)!
        var written: AVAudioFramePosition = 0
        func emit(_ frame: [Float]) throws {
            if skip > 0 { skip -= 1; return }
            guard written < total else { return }
            let i = Int(outBuf.frameLength)
            for c in 0..<channels { outBuf.floatChannelData![c][i] = frame[c] }
            outBuf.frameLength += 1
            written += 1
            if outBuf.frameLength == outBuf.frameCapacity { try out.write(from: outBuf); outBuf.frameLength = 0 }
        }
        var frame = [Float](repeating: 0, count: channels)
        try stream(mid, total: total) { buf in
            let d = buf.floatChannelData!
            for i in 0..<Int(buf.frameLength) {
                for c in 0..<channels { frame[c] = d[c][i] * gain }
                try emit(limiter.run(frame))
            }
            progress(0.5 + 0.5 * Double(mid.framePosition) / Double(max(1, total)))
        }
        for c in 0..<channels { frame[c] = 0 }
        while written < total { try emit(limiter.run(frame)) }      // flush the look-ahead
        if outBuf.frameLength > 0 { try out.write(from: outBuf) }
        progress(1)
    }

    static func peakLevel(_ file: AVAudioFile) throws -> Float {
        var peak: Float = 0
        try stream(file, total: file.length) { buf in
            for c in 0..<Int(buf.format.channelCount) {
                let d = buf.floatChannelData![c]
                for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(d[i])) }
            }
        }
        return peak
    }

    private static func stream(_ file: AVAudioFile, total: AVAudioFramePosition, _ body: (AVAudioPCMBuffer) throws -> Void) throws {
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65536)!
        file.framePosition = 0
        while file.framePosition < total {
            try file.read(into: buf, frameCount: AVAudioFrameCount(min(65536, total - file.framePosition)))
            if buf.frameLength == 0 { break }
            try body(buf)
        }
    }

    private static func wavSettings(_ format: AVAudioFormat, float: Bool) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: format.channelCount,
         AVLinearPCMBitDepthKey: float ? 32 : 24, AVLinearPCMIsFloatKey: float, AVLinearPCMIsBigEndianKey: false]
    }

    static func voiceChain(_ rate: Float) -> [Biquad] {
        [.highPass(80, q: 0.707, rate: rate),
         .peaking(250, q: 1, db: -2.5, rate: rate),
         .peaking(3200, q: 1, db: 3, rate: rate),
         .highShelf(10000, db: 2.5, rate: rate)]
    }
}

/// RBJ cookbook biquad, transposed direct form II.
struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    private var z1: Float = 0, z2: Float = 0

    init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0; self.b1 = b1 / a0; self.b2 = b2 / a0; self.a1 = a1 / a0; self.a2 = a2 / a0
    }

    mutating func run(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(_ f: Float, q: Float, rate: Float) -> Biquad {
        let w = 2 * Float.pi * f / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: (1 + c) / 2, b1: -(1 + c), b2: (1 + c) / 2, a0: 1 + alpha, a1: -2 * c, a2: 1 - alpha)
    }

    static func peaking(_ f: Float, q: Float, db: Float, rate: Float) -> Biquad {
        let a = pow(10, db / 40), w = 2 * Float.pi * f / rate, alpha = sin(w) / (2 * q), c = cos(w)
        return Biquad(b0: 1 + alpha * a, b1: -2 * c, b2: 1 - alpha * a, a0: 1 + alpha / a, a1: -2 * c, a2: 1 - alpha / a)
    }

    static func highShelf(_ f: Float, db: Float, rate: Float) -> Biquad {
        let a = pow(10, db / 40), w = 2 * Float.pi * f / rate, c = cos(w)
        let alpha = sin(w) / 2 * sqrt(2)          // shelf slope 1
        let s = 2 * sqrt(a) * alpha
        return Biquad(b0: a * ((a + 1) + (a - 1) * c + s), b1: -2 * a * ((a - 1) + (a + 1) * c), b2: a * ((a + 1) + (a - 1) * c - s),
                      a0: (a + 1) - (a - 1) * c + s, a1: 2 * ((a - 1) - (a + 1) * c), a2: (a + 1) - (a - 1) * c - s)
    }
}

/// Feed-forward peak compressor working in dB: 3:1 above −22 dBFS.
struct Compressor {
    let threshold: Float = -22, ratio: Float = 3
    let attack: Float, release: Float
    private var env: Float = -120

    init(rate: Float) {
        attack = exp(-1 / (0.005 * rate))
        release = exp(-1 / (0.120 * rate))
    }

    mutating func gain(_ level: Float) -> Float {
        let db = 20 * log10(max(level, 1e-6))
        env = db > env ? attack * env + (1 - attack) * db : release * env + (1 - release) * db
        let over = env - threshold
        return over > 0 ? pow(10, -over * (1 - 1 / ratio) / 20) : 1
    }
}

/// Look-ahead peak limiter: sees each peak `delay` samples early and is already turned down
/// when it arrives. A final clamp guarantees the ceiling.
struct Limiter {
    let delay: Int
    private let ceiling: Float, release: Float, attack: Float
    private var buffer: [[Float]], pos = 0
    private var env: Float = 0, g: Float = 1

    init(channels: Int, rate: Float, ceiling: Float) {
        delay = Int(0.005 * rate)
        self.ceiling = ceiling
        release = exp(-1 / (0.080 * rate))
        attack = exp(-1 / (Float(delay) / 4))
        buffer = Array(repeating: Array(repeating: 0, count: delay), count: channels)
    }

    mutating func run(_ frame: [Float]) -> [Float] {
        var peak: Float = 0
        for x in frame { peak = max(peak, abs(x)) }
        env = max(peak, env * release)
        let target = env > ceiling ? ceiling / env : 1
        g = target < g ? attack * g + (1 - attack) * target : target + (g - target) * release
        g = min(g, 1)
        var out = frame
        for c in frame.indices {
            let delayed = buffer[c][pos]
            buffer[c][pos] = frame[c]
            out[c] = min(ceiling, max(-ceiling, delayed * g))
        }
        pos = (pos + 1) % delay
        return out
    }
}
