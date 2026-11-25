import CoreAudio
import Foundation

struct InputDevice: Identifiable, Hashable {
    let id: String          // device UID, stable across reconnects
    let objectID: AudioObjectID
    let name: String
    let channels: Int
    var isUSB = false
    /// A USB audio interface output (not a USB display's audio).
    var isUSBOutput: Bool { isUSB && !name.localizedCaseInsensitiveContains("plugable") && !name.localizedCaseInsensitiveContains("display") }
}

/// Core Audio device listing and change notifications.
enum AudioDevices {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func objects(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func inputChannelCount(_ device: AudioObjectID) -> Int { channelCount(device, kAudioObjectPropertyScopeInput) }
    static func outputChannelCount(_ device: AudioObjectID) -> Int { channelCount(device, kAudioObjectPropertyScopeOutput) }

    private static func channelCount(_ device: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func inputDevices() -> [InputDevice] {
        objects(kAudioHardwarePropertyDevices).compactMap { id in
            let channels = inputChannelCount(id)
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            // Skip other apps' private aggregate devices (e.g. SoundSplit's taps).
            if uid.hasPrefix("SoundSplit") || name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            var transport: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            var addr = address(kAudioDevicePropertyTransportType)
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &transport)
            return InputDevice(id: uid, objectID: id, name: name, channels: channels, isUSB: transport == kAudioDeviceTransportTypeUSB)
        }
    }

    static func outputDevices() -> [InputDevice] {
        objects(kAudioHardwarePropertyDevices).compactMap { id in
            let channels = outputChannelCount(id)
            guard channels > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            if uid.hasPrefix("SoundSplit") || name.hasPrefix("CADefaultDeviceAggregate") { return nil }
            return InputDevice(id: uid, objectID: id, name: name, channels: channels, isUSB: transport(id) == kAudioDeviceTransportTypeUSB)
        }
    }

    static func transport(_ id: AudioObjectID) -> UInt32 {
        var t: UInt32 = 0
        var size = UInt32(4)
        var addr = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &t)
        return t
    }

    static func defaultOutput() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return id
    }

    static func defaultInput() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        return id
    }

    static func defaultOutputIsBuiltInSpeakers() -> Bool {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &id)
        var transport: UInt32 = 0
        size = 4
        var t = address(kAudioDevicePropertyTransportType)
        AudioObjectGetPropertyData(id, &t, 0, nil, &size, &transport)
        let name = string(id, kAudioObjectPropertyName) ?? ""
        return transport == kAudioDeviceTransportTypeBuiltIn && name.localizedCaseInsensitiveContains("speaker")
    }

    /// Calls `handler` on the main queue whenever devices come, go, or the default input changes.
    static func observeChanges(_ handler: @escaping () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var addr = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { _, _ in handler() }
        }
    }
}
