import Accelerate
import AVFoundation

/// Learned-profile noise reduction, in the style of a classic "noise print" denoiser.
///
/// 1. Learn: the average power spectrum of the noise, taken from a stretch the user points at
///    (the loop region) or, automatically, from the quietest 8% of the take.
/// 2. Remove: for every 2048-sample frame (75% overlap), each frequency bin is turned down by how
///    much of its power the noise explains (spectral subtraction), never below a floor set by
///    `reduction`. Gains are smoothed across neighbouring bins and over time so steady hiss and hum
///    go away without the warbling "musical noise" that raw subtraction leaves.
///
/// Works on a file and writes a new one of exactly the same length, so clips keep their positions.
/// Stereo files get one set of gains for both channels, which keeps the stereo image steady.
enum Denoise {
    static let size = 2048
    static let hop = size / 4

    struct Options {
        var reduction: Float = 15            // dB: how far noise-only parts are turned down
        var profile: Range<Double>? = nil    // seconds in the file to learn the noise from; nil = automatic
    }

    enum Failure: LocalizedError {
        case unreadable, noNoise
        var errorDescription: String? {
            switch self {
            case .unreadable: "The recording couldn't be read."
            case .noNoise: "There was no noise to learn from (the chosen part is silent)."
            }
        }
    }

    /// Returns the noise profile that was used (power per bin), mainly for tests.
    @discardableResult
    static func process(source: URL, dest: URL, options: Options, progress: (Double) -> Void = { _ in }) throws -> [Float] {
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        let channels = Int(format.channelCount)
        guard channels >= 1, input.length > 0 else { throw Failure.unreadable }
        let fft = try FFT(size: size)
        let noise = try learn(input, fft: fft, range: options.profile)
        guard noise.contains(where: { $0 > 0 }) else { throw Failure.noNoise }

        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
                                       AVNumberOfChannelsKey: channels, AVLinearPCMBitDepthKey: 24,
                                       AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let output = try AVAudioFile(forWriting: dest, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let bins = size / 2 + 1
        let floorGain = pow(10, -max(0, options.reduction) / 20)
        let oversubtract: Float = 2
        let window = (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size))) }   // sqrt-Hann, both ends
        let olaScale = 1 / (2 * fft.roundTripScale)        // Hann² overlap at 75% sums to 2

        var inBuf = [[Float]](repeating: [Float](repeating: 0, count: size), count: channels)
        var outBuf = [[Float]](repeating: [Float](repeating: 0, count: size), count: channels)
        var re = [[Float]](repeating: [Float](repeating: 0, count: size / 2), count: channels)
        var im = re
        var gains = [Float](repeating: 1, count: bins)
        var smoothed = [Float](repeating: 1, count: bins)
        var frame = [Float](repeating: 0, count: size)

        let total = Int(input.length)
        let latency = size - hop             // output trails input by this much
        var toSkip = latency
        var written = 0
        input.framePosition = 0
        let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(hop))!
        let out = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: AVAudioFrameCount(hop))!
        var fed = 0
        var lastReport = 0

        while written < total {
            // Next hop of input, or zeros once the file is used up (flushes the tail).
            var got = 0
            if fed < total {
                try input.read(into: chunk, frameCount: AVAudioFrameCount(min(hop, total - fed)))
                got = Int(chunk.frameLength)
                fed += got
            }
            for c in 0..<channels {
                inBuf[c].withUnsafeMutableBufferPointer { b in
                    b.baseAddress!.update(from: b.baseAddress! + hop, count: size - hop)
                    for i in 0..<hop { b[size - hop + i] = i < got ? chunk.floatChannelData![c][i] : 0 }
                }
            }

            // Analyse every channel, then one gain curve from their summed power.
            var power = [Float](repeating: 0, count: bins)
            for c in 0..<channels {
                vDSP.multiply(inBuf[c], window, result: &frame)
                fft.forward(frame, re: &re[c], im: &im[c])
                power[0] += re[c][0] * re[c][0]
                power[bins - 1] += im[c][0] * im[c][0]
                for k in 1..<(bins - 1) { power[k] += re[c][k] * re[c][k] + im[c][k] * im[c][k] }
            }
            for k in 0..<bins {
                let p = power[k] / Float(channels)
                gains[k] = p > 0 ? max(floorGain, sqrt(max(0, 1 - oversubtract * noise[k] / p))) : floorGain
            }
            // Across frequency: a 5-bin average stops isolated bins flickering on and off.
            var spread = gains
            for k in 0..<bins {
                let a = max(0, k - 2), b = min(bins - 1, k + 2)
                var s: Float = 0
                for j in a...b { s += gains[j] }
                spread[k] = s / Float(b - a + 1)
            }
            // Over time: open quickly for speech onsets, close slowly so tails don't chop.
            for k in 0..<bins {
                let g = spread[k]
                smoothed[k] = g > smoothed[k] ? 0.3 * smoothed[k] + 0.7 * g : 0.75 * smoothed[k] + 0.25 * g
            }

            for c in 0..<channels {
                re[c][0] *= smoothed[0]
                im[c][0] *= smoothed[bins - 1]
                for k in 1..<(bins - 1) { re[c][k] *= smoothed[k]; im[c][k] *= smoothed[k] }
                fft.inverse(re: re[c], im: im[c], result: &frame)
                vDSP.multiply(frame, window, result: &frame)
                outBuf[c].withUnsafeMutableBufferPointer { o in
                    for i in 0..<size { o[i] += frame[i] * olaScale }
                }
            }

            // The first `hop` samples of outBuf are now complete.
            var start = 0
            if toSkip > 0 { start = min(hop, toSkip); toSkip -= start }
            let n = min(hop - start, total - written)
            if n > 0 {
                for c in 0..<channels {
                    let dst = out.floatChannelData![c]
                    for i in 0..<n { dst[i] = min(1, max(-1, outBuf[c][start + i])) }
                }
                out.frameLength = AVAudioFrameCount(n)
                try output.write(from: out)
                written += n
            }
            for c in 0..<channels {
                outBuf[c].withUnsafeMutableBufferPointer { o in
                    o.baseAddress!.update(from: o.baseAddress! + hop, count: size - hop)
                    for i in (size - hop)..<size { o[i] = 0 }
                }
            }
            if written - lastReport > 48000 * 2 { lastReport = written; progress(Double(written) / Double(total)) }
        }
        progress(1)
        return noise
    }

    /// Average noise power per bin (channel-averaged), from `range` or the quietest 8% of frames.
    private static func learn(_ file: AVAudioFile, fft: FFT, range: Range<Double>?) throws -> [Float] {
        let rate = file.processingFormat.sampleRate
        let total = Int(file.length)
        let channels = Int(file.processingFormat.channelCount)
        var starts: [Int]
        if let range {
            let a = max(0, Int(range.lowerBound * rate)), b = min(total, Int(range.upperBound * rate))
            starts = Array(stride(from: a, to: max(a + 1, b - size), by: hop))
        } else {
            // Cheap first pass: loudness of every frame, then take the quietest that aren't digital silence.
            var levels: [(Int, Float)] = []
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(size * 16))!
            file.framePosition = 0
            var pos = 0
            while pos < total {
                try file.read(into: buf, frameCount: AVAudioFrameCount(min(size * 16, total - pos)))
                let n = Int(buf.frameLength)
                if n == 0 { break }
                var f = 0
                while f + size <= n {
                    var e: Float = 0
                    for c in 0..<channels { e += vDSP.sumOfSquares(UnsafeBufferPointer(start: buf.floatChannelData![c] + f, count: size)) }
                    e /= Float(size * channels)
                    if e > 1e-12 { levels.append((pos + f, e)) }
                    f += size
                }
                pos += n
            }
            levels.sort { $0.1 < $1.1 }
            starts = levels.prefix(max(8, levels.count * 8 / 100)).map(\.0)
        }
        let bins = size / 2 + 1
        var sum = [Float](repeating: 0, count: bins)
        var count = 0
        let window = (0..<size).map { sqrt(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(size))) }
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(size))!
        var frame = [Float](repeating: 0, count: size)
        var re = [Float](repeating: 0, count: size / 2), im = re
        for s in starts where s + size <= total {
            file.framePosition = AVAudioFramePosition(s)
            try file.read(into: buf, frameCount: AVAudioFrameCount(size))
            guard Int(buf.frameLength) == size else { continue }
            for c in 0..<channels {
                vDSP.multiply(UnsafeBufferPointer(start: buf.floatChannelData![c], count: size), window, result: &frame)
                fft.forward(frame, re: &re, im: &im)
                sum[0] += re[0] * re[0]
                sum[bins - 1] += im[0] * im[0]
                for k in 1..<(bins - 1) { sum[k] += re[k] * re[k] + im[k] * im[k] }
            }
            count += channels
        }
        guard count > 0 else { throw Failure.noNoise }
        return sum.map { $0 / Float(count) }
    }
}

/// Real FFT of a fixed size on vDSP, in the packed layout: re[0] = DC, im[0] = Nyquist.
final class FFT {
    let size: Int
    private let fwd: vDSP_DFT_Setup
    private let inv: vDSP_DFT_Setup
    /// forward then inverse multiplies a signal by this.
    private(set) var roundTripScale: Float = 1
    private var evens: [Float], odds: [Float], outR: [Float], outI: [Float]

    init(size: Int) throws {
        guard let f = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD),
              let i = vDSP_DFT_zrop_CreateSetup(f, vDSP_Length(size), .INVERSE) else { throw Denoise.Failure.unreadable }
        self.size = size; fwd = f; inv = i
        evens = [Float](repeating: 0, count: size / 2); odds = evens; outR = evens; outI = evens
        var probe = [Float](repeating: 0, count: size); probe[3] = 1
        var re = evens, im = evens, back = probe
        forward(probe, re: &re, im: &im)
        inverse(re: re, im: im, result: &back)
        roundTripScale = back[3]
    }

    deinit { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }

    func forward(_ x: [Float], re: inout [Float], im: inout [Float]) {
        for i in 0..<(size / 2) { evens[i] = x[2 * i]; odds[i] = x[2 * i + 1] }
        vDSP_DFT_Execute(fwd, evens, odds, &re, &im)
    }

    func inverse(re: [Float], im: [Float], result: inout [Float]) {
        vDSP_DFT_Execute(inv, re, im, &outR, &outI)
        for i in 0..<(size / 2) { result[2 * i] = outR[i]; result[2 * i + 1] = outI[i] }
    }
}
