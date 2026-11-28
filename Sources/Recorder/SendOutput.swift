import AVFoundation
import AudioToolbox

/// "Also send to": a copy of everything Recorder plays (after the master plugins) goes to a
/// second output device, such as a virtual cable (BlackHole, Loopback, VB-Cable) that vMix, OBS or
/// a call app uses as its input, while the main output keeps playing to your headphones.
///
/// A tiny pass-through Audio Unit at the end of the master chain copies each buffer into a ring
/// on the real-time thread (no tap delay); a second engine on the other device plays the ring,
/// resampling and absorbing clock drift the same way live monitoring does.
final class SendTapUnit: AUAudioUnit {
    static let desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: 0x726E_6464 /* rndd */,
                                                componentManufacturer: 0x5263_6472 /* Rcdr */, componentFlags: 0, componentFlagsMask: 0)
    static let registered: Void = {
        AUAudioUnit.registerSubclass(SendTapUnit.self, as: desc, name: "Recorder: Send", version: 1)
    }()

    /// Set right after creation; read on the render thread.
    var ring: MonitorRing?
    private var inputs: AUAudioUnitBusArray!
    private var outputs: AUAudioUnitBusArray!
    private var buffer: AVAudioPCMBuffer?

    override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []) throws {
        try super.init(componentDescription: componentDescription, options: options)
        let format = Formats.stereo
        inputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [try AUAudioUnitBus(format: format)])
        outputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [try AUAudioUnitBus(format: format)])
        maximumFramesToRender = 4096
    }

    override var inputBusses: AUAudioUnitBusArray { inputs }
    override var outputBusses: AUAudioUnitBusArray { outputs }
    override var canProcessInPlace: Bool { true }

    override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        let format = inputs[0].format
        buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFramesToRender)
        ring?.sampleRate = format.sampleRate
    }

    override func deallocateRenderResources() {
        buffer = nil
        super.deallocateRenderResources()
    }

    override var internalRenderBlock: AUInternalRenderBlock {
        { [unowned self] flags, timestamp, frames, _, output, _, pullInput in
            guard let pullInput, let buffer = self.buffer, frames <= buffer.frameCapacity else { return kAudioUnitErr_NoConnection }
            let inList = buffer.mutableAudioBufferList
            let ins = UnsafeMutableAudioBufferListPointer(inList)
            for i in 0..<ins.count { ins[i].mDataByteSize = frames * 4 }
            var pullFlags = AudioUnitRenderActionFlags()
            let status = pullInput(&pullFlags, timestamp, frames, 0, inList)
            guard status == noErr else { return status }
            let outs = UnsafeMutableAudioBufferListPointer(output)
            for i in 0..<min(ins.count, outs.count) {
                if outs[i].mData == nil { outs[i].mData = ins[i].mData }
                else if outs[i].mData != ins[i].mData { memcpy(outs[i].mData, ins[i].mData, Int(frames) * 4) }
                outs[i].mDataByteSize = frames * 4
            }
            self.ring?.write(UnsafePointer(inList), frames: Int(frames))
            return noErr
        }
    }
}

/// The second engine that plays the send ring on another output device.
final class SendOutput {
    let ring = MonitorRing()
    private var engine: AVAudioEngine?
    private let mode: MonitorMode = { let m = MonitorMode(); m.value.store(MonitorMode.stereo, ordering: .relaxed); return m }()
    private(set) var device: AudioObjectID?
    private var observer: NSObjectProtocol?

    var isRunning: Bool { engine?.isRunning ?? false }

    func start(device id: AudioObjectID) throws {
        stop()
        let engine = AVAudioEngine()
        if let unit = engine.outputNode.audioUnit {
            var dev = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &dev, UInt32(MemoryLayout<AudioObjectID>.size))
            if status != noErr { throw RecorderError.message("Couldn't open the send output (\(status)).") }
        }
        IOBuffer.set(engine.outputNode.audioUnit, frames: 128)
        let source = ring.makeSource(mode: mode, lag: 256)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: Formats.stereo)
        engine.prepare()
        try engine.start()
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak engine] _ in
            guard let engine, !engine.isRunning else { return }
            engine.prepare(); try? engine.start()
        }
        self.engine = engine
        device = id
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine?.stop()
        engine = nil
        device = nil
    }
}
