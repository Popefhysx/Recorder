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

    /// A stereo source node that plays live input while `mode` says so: `MonitorMode.off`,
    /// `.stereo` (inputs 1+2), or an input index (mono, sent to both sides). It stays about `lag`
    /// frames behind the newest input and skips ahead or pads with silence if the input and
    /// output devices' clocks drift. The node is created once per track and never rewired, so
    /// turning monitoring on and off doesn't change the running audio graph.
    func makeSource(mode: MonitorMode, lag: Int = 192) -> AVAudioSourceNode {
        var read = -1
        return AVAudioSourceNode(format: Formats.stereo) { [self] _, _, count, abl in
            let out = UnsafeMutableAudioBufferListPointer(abl)
            let n = Int(count)
            let m = mode.value.load(ordering: .relaxed)
            let usable = m != MonitorMode.off && sampleRate == Formats.rate
            let newest = written.load(ordering: .acquiring)
            if !usable || read < 0 || newest - read > Self.capacity / 4 || newest - read < 0 {
                read = usable ? newest - lag - n : -1
            }
            for k in 0..<min(2, out.count) {
                let dst = out[k].mData!.assumingMemoryBound(to: Float.self)
                let ch = m == MonitorMode.stereo ? k : max(0, m)
                for i in 0..<n {
                    let pos = read + i
                    dst[i] = usable && pos < newest ? data[(pos & (Self.capacity - 1)) * Self.channels + min(ch, Self.channels - 1)] : 0
                }
            }
            if usable { read = min(read + n, newest) }
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
