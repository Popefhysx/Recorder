import AVFoundation
import Synchronization

/// Hands live input from the input engine's real-time callback to the output engine.
/// One writer (the input device's thread); each monitored track reads with its own position.
final class MonitorRing: @unchecked Sendable {
    static let capacity = 16384                 // frames, power of two
    static let channels = 2
    private let data: UnsafeMutablePointer<Float>
    let written = Atomic<Int>(0)
    var sampleRate: Double = Formats.rate

    init() {
        data = .allocate(capacity: Self.capacity * Self.channels)
        data.initialize(repeating: 0, count: Self.capacity * Self.channels)
    }
    deinit { data.deallocate() }

    /// Called on the input thread with the device's buffers.
    func write(_ abl: UnsafePointer<AudioBufferList>, frames: Int) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        let start = written.load(ordering: .relaxed)
        for c in 0..<Self.channels {
            let src = list[min(c, list.count - 1)].mData?.assumingMemoryBound(to: Float.self)
            for i in 0..<frames {
                data[((start + i) & (Self.capacity - 1)) * Self.channels + c] = src?[i] ?? 0
            }
        }
        written.store(start + frames, ordering: .releasing)
    }

    /// The loudest sample currently held (for tests).
    func peek(_ body: (Float) -> Void) {
        var m: Float = 0
        for i in 0..<(Self.capacity * Self.channels) { m = max(m, abs(data[i])) }
        body(m)
    }

    /// A stereo source node that plays live input while `mode` says so: `MonitorMode.off`,
    /// `.stereo` (inputs 1+2), or an input index (mono, sent to both sides). It stays about `lag`
    /// output frames behind the newest input and skips ahead or pads with silence if the input and
    /// output devices' clocks drift. Inputs not at 48 kHz (a Bluetooth headset mic runs at 16 or
    /// 24 kHz) are resampled by linear interpolation; that used to be silence. The node is created
    /// once per track and never rewired, so turning monitoring on and off doesn't change the
    /// running audio graph.
    func makeSource(mode: MonitorMode, lag: Int = 192) -> AVAudioSourceNode {
        var read: Double = -1                       // position in input frames
        return AVAudioSourceNode(format: Formats.stereo) { [self] _, _, count, abl in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(count)
            let m = mode.value.load(ordering: .relaxed)
            let rate = sampleRate
            let usable = m != MonitorMode.off && rate > 0
            let step = rate / Formats.rate          // input frames per output frame
            let newest = written.load(ordering: .acquiring)
            let ahead = Double(newest) - read
            if !usable || read < 0 || ahead > Double(Self.capacity / 4) || ahead < 1 {
                read = usable ? max(0, Double(newest) - (Double(lag + n) * step).rounded(.up) - 1) : -1
            }
            for k in 0..<min(2, out.count) {
                let dst = out[k].mData!.assumingMemoryBound(to: Float.self)
                let ch = min(m == MonitorMode.stereo ? k : max(0, m), Self.channels - 1)
                for i in 0..<n {
                    let p = read + Double(i) * step
                    let i0 = Int(p)
                    guard usable, i0 + 1 < newest else { dst[i] = 0; continue }
                    let a = data[(i0 & (Self.capacity - 1)) * Self.channels + ch]
                    let b = data[((i0 + 1) & (Self.capacity - 1)) * Self.channels + ch]
                    dst[i] = a + (b - a) * Float(p - Double(i0))
                }
            }
            if usable { read = min(read + Double(n) * step, Double(newest)) }
            return noErr
        }
    }
}

/// Which input a strip's live feed plays: `off`, `stereo` (inputs 1+2) or an input index.
final class MonitorMode: @unchecked Sendable {
    static let off = -2
    static let stereo = -1
    let value = Atomic<Int>(MonitorMode.off)
}

enum IOBuffer {
    /// Small device buffers keep monitoring delay low (128 frames ≈ 2.7 ms at 48 kHz).
    static func set(_ unit: AudioUnit?, frames: UInt32) {
        guard let unit else { return }
        var f = frames
        AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &f, 4)
    }
}
