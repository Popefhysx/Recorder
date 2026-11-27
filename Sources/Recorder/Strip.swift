import AVFoundation
import Synchronization

/// Peak levels written by an audio tap and read (and reset) by the UI.
final class Meter {
    private var lock = os_unfair_lock()
    private var left: Float = 0, right: Float = 0

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData else { return }
        let n = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        var peaks: [Float] = [0, 0]
        for c in 0..<min(channels, 2) {
            var p: Float = 0
            let ch = data[c]
            for i in 0..<n { p = max(p, abs(ch[i])) }
            peaks[c] = p
        }
        if channels == 1 { peaks[1] = peaks[0] }
        feed(left: peaks[0], right: peaks[1])
    }

    func feed(left l: Float, right r: Float) {
        os_unfair_lock_lock(&lock)
        left = max(left, l); right = max(right, r)
        os_unfair_lock_unlock(&lock)
    }

    /// Returns the peaks since the last call and starts over.
    func take() -> (Float, Float) {
        os_unfair_lock_lock(&lock)
        defer { left = 0; right = 0; os_unfair_lock_unlock(&lock) }
        return (left, right)
    }
}

enum Formats {
    static let rate: Double = 48000
    static let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    static let stereo = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
}

/// One track's chain: players (mono/stereo, pan) → panner → boost → gate → EQ (+ hum/low-cut bands)
/// → compressor → delay → reverb → fader → main mixer.
/// The same class builds the live graph and the offline export graph, so both sound alike.
final class Strip {
    let player = AVAudioPlayerNode()          // mono clips
    let stereoPlayer = AVAudioPlayerNode()    // stereo clips
    let panner = AVAudioMixerNode()
    let boost = AVAudioUnitEQ(numberOfBands: 0)   // input boost (globalGain, up to +24 dB)
    let gate = Strip.dynamics()
    // 0-8 the nine user bands, 9 low cut, 10-12 hum notches.
    static let userBands = EQSettings.bands.count
    let eq = AVAudioUnitEQ(numberOfBands: Strip.userBands + 4)
    let comp = Strip.dynamics()
    let delay = AVAudioUnitDelay()
    let reverb = AVAudioUnitReverb()
    let fader = AVAudioMixerNode()
    let meter = Meter()
    private var reverbPreset = -1
    private var openFiles: [String: AVAudioFile] = [:]
    private(set) var monitorSource: AVAudioSourceNode?
    let monitorMode = MonitorMode()
    var isMonitoring: Bool { monitorMode.value.load(ordering: .relaxed) != MonitorMode.off }

    /// Switches live input for this track on (mono input or stereo) or off; no graph changes.
    func setMonitor(_ track: Track?) {
        let mode = track.map { $0.stereo ? MonitorMode.stereo : $0.inputChannel } ?? MonitorMode.off
        monitorMode.value.store(mode, ordering: .relaxed)
    }

    init(engine: AVAudioEngine, meterTap: Bool, monitorRing: MonitorRing? = nil) {
        for node in nodes { engine.attach(node) }
        engine.connect(player, to: panner, format: Formats.mono)
        engine.connect(stereoPlayer, to: panner, format: Formats.stereo)
        if let monitorRing {
            let source = monitorRing.makeSource(mode: monitorMode)
            engine.attach(source)
            engine.connect(source, to: panner, format: Formats.stereo)
            monitorSource = source
        }
        engine.connect(panner, to: boost, format: Formats.stereo)
        engine.connect(boost, to: gate, format: Formats.stereo)
        engine.connect(gate, to: eq, format: Formats.stereo)
        engine.connect(eq, to: comp, format: Formats.stereo)
        engine.connect(comp, to: delay, format: Formats.stereo)
        engine.connect(delay, to: reverb, format: Formats.stereo)
        engine.connect(reverb, to: fader, format: Formats.stereo)
        engine.connect(fader, to: engine.mainMixerNode, format: Formats.stereo)

        let bands = eq.bands
        for (i, def) in EQSettings.bands.enumerated() {
            bands[i].filterType = def.shelf ? .highShelf : .parametric
            bands[i].frequency = def.centre
            bands[i].bandwidth = def.octaves
        }
        let cut = Strip.userBands
        bands[cut].filterType = .highPass; bands[cut].frequency = 80
        for b in bands[(cut + 1)...] { b.filterType = .parametric; b.bandwidth = 0.08; b.gain = -40 }
        for b in bands { b.bypass = false }

        if meterTap {
            let meter = self.meter
            fader.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        }
    }

    private var nodes: [AVAudioNode] { [player, stereoPlayer, panner, boost, gate, eq, comp, delay, reverb, fader] }

    static func dynamics() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    }

    func detach(from engine: AVAudioEngine) {
        stop()
        if let m = monitorSource { engine.detach(m) }
        fader.removeTap(onBus: 0)
        for node in nodes { engine.detach(node) }
    }

    func play(at time: AVAudioTime?) {
        player.play(at: time)
        stereoPlayer.play(at: time)
    }

    func apply(_ track: Track, audible: Bool, tempo: Double = 120) {
        player.pan = track.pan
        stereoPlayer.pan = track.pan
        monitorSource?.pan = track.pan
        fader.outputVolume = audible ? track.volume : 0
        boost.globalGain = track.boost
        boost.bypass = track.boost == 0

        // Gate: a downward expander below the threshold, no compression above it. 4:1 with a 250 ms
        // release lets word endings fade out; the first version (50:1, 80 ms) chopped them to silence.
        let g = track.gate
        gate.bypass = !g.enabled
        if let unit = gate.audioUnit as AudioUnit? {
            let set = { (id: UInt32, v: Float) in AudioUnitSetParameter(unit, AudioUnitParameterID(id), kAudioUnitScope_Global, 0, v, 0) }
            set(UInt32(kDynamicsProcessorParam_Threshold), 20)
            set(UInt32(kDynamicsProcessorParam_HeadRoom), 40)
            set(UInt32(kDynamicsProcessorParam_ExpansionThreshold), g.threshold)
            set(UInt32(kDynamicsProcessorParam_ExpansionRatio), 4)
            set(UInt32(kDynamicsProcessorParam_AttackTime), 0.001)
            set(UInt32(kDynamicsProcessorParam_ReleaseTime), 0.25)
            set(6, 0)
        }

        let bands = eq.bands
        eq.bypass = !(track.eq.enabled || g.humHz != 0 || g.lowCut)
        let gains = track.eq.gains
        for i in 0..<Strip.userBands {
            bands[i].gain = gains[i]
            bands[i].bypass = !track.eq.enabled || gains[i] == 0
        }
        bands[Strip.userBands].bypass = !g.lowCut
        for (i, b) in bands[(Strip.userBands + 1)...].enumerated() {
            b.bypass = g.humHz == 0
            if g.humHz != 0 { b.frequency = Float(g.humHz * (i + 1)) }
        }

        comp.bypass = !track.comp.enabled
        if let unit = comp.audioUnit as AudioUnit? {
            AudioUnitSetParameter(unit, AudioUnitParameterID(kDynamicsProcessorParam_Threshold), kAudioUnitScope_Global, 0, track.comp.threshold, 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kDynamicsProcessorParam_HeadRoom), kAudioUnitScope_Global, 0, track.comp.headroom, 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kDynamicsProcessorParam_AttackTime), kAudioUnitScope_Global, 0, 0.003, 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(kDynamicsProcessorParam_ReleaseTime), kAudioUnitScope_Global, 0, 0.15, 0)
            AudioUnitSetParameter(unit, AudioUnitParameterID(6 /* overall gain */), kAudioUnitScope_Global, 0, track.comp.makeup, 0)
        }

        let d = track.delay
        delay.bypass = !d.enabled
        delay.delayTime = d.seconds(tempo: tempo)
        delay.feedback = d.feedback
        delay.wetDryMix = d.mix
        delay.lowPassCutoff = d.tone

        reverb.bypass = !track.reverb.enabled
        if reverbPreset != track.reverb.preset {
            reverbPreset = track.reverb.preset
            let presets: [AVAudioUnitReverbPreset] = [.smallRoom, .mediumRoom, .largeRoom, .mediumHall, .largeHall, .plate, .cathedral]
            reverb.loadFactoryPreset(presets[min(max(0, track.reverb.preset), presets.count - 1)])
        }
        reverb.wetDryMix = track.reverb.mix
    }

    func stop() {
        player.stop()
        stereoPlayer.stop()
        openFiles.removeAll()
    }

    /// Schedules the parts of `clips` that fall in timeline frames [from, to) so that timeline frame
    /// `from` plays at player sample time `base`. Faded regions are read into buffers; the rest
    /// streams from disk, which keeps memory low for long takes.
    func schedule(_ clips: [Clip], audioFolder: URL, from: Int64, to: Int64?, base: Int64) {
        let rate = Formats.rate
        for clip in clips {
            let clipStart = Int64((clip.start * rate).rounded())
            let length = Int64((clip.duration * rate).rounded())
            let fadeIn = min(Int64((clip.fadeIn * rate).rounded()), length)
            let fadeOut = min(Int64((clip.fadeOut * rate).rounded()), length - fadeIn)
            // Clip-relative frames to play.
            let first = max(0, from - clipStart)
            let last = min(length, (to ?? Int64.max) - clipStart)
            guard first < last, let file = file(clip.file, in: audioFolder) else { continue }
            let channels = Int(file.processingFormat.channelCount)
            let player = channels == 2 ? stereoPlayer : self.player
            let fileOffset = Int64((clip.offset * rate).rounded())

            func at(_ f: Int64) -> AVAudioTime { AVAudioTime(sampleTime: base + clipStart + f - from, atRate: rate) }
            let regions: [(Int64, Int64, Bool)] = [(0, fadeIn, true), (fadeIn, length - fadeOut, false), (length - fadeOut, length, true)]
            for (a0, b0, faded) in regions {
                let a = max(a0, first), b = min(b0, last)
                guard a < b else { continue }
                if !faded {
                    let available = file.length - (fileOffset + a)
                    let count = min(b - a, available)
                    guard count > 0 else { continue }
                    player.scheduleSegment(file, startingFrame: fileOffset + a, frameCount: AVAudioFrameCount(count), at: at(a))
                    continue
                }
                // Fade regions, in chunks of up to 5 s, read through a separate file object so the
                // player's own streaming reads of `file` are left alone.
                guard let reader = try? AVAudioFile(forReading: file.url) else { continue }
                var f = a
                while f < b {
                    let n = min(b - f, Int64(rate * 5))
                    guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(n)) else { break }
                    reader.framePosition = fileOffset + f
                    do { try reader.read(into: buf, frameCount: AVAudioFrameCount(n)) } catch { break }
                    for c in 0..<channels {
                        let data = buf.floatChannelData![c]
                        for i in 0..<Int(buf.frameLength) {
                            let pos = f + Int64(i)
                            var g: Float = 1
                            if pos < fadeIn { g *= Float(pos) / Float(fadeIn) }
                            if pos >= length - fadeOut, fadeOut > 0 { g *= Float(length - pos) / Float(fadeOut) }
                            data[i] *= g
                        }
                    }
                    if buf.frameLength > 0 { player.scheduleBuffer(buf, at: at(f)) }
                    f += n
                }
            }
        }
    }

    private func file(_ name: String, in folder: URL) -> AVAudioFile? {
        if let f = openFiles[name] { return f }
        guard let f = try? AVAudioFile(forReading: folder.appendingPathComponent(name)),
              f.processingFormat.sampleRate == Formats.rate, (1...2).contains(f.processingFormat.channelCount) else { return nil }
        openFiles[name] = f
        return f
    }
}
