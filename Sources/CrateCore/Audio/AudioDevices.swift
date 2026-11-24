import CoreAudio
import Foundation

/// A device sound can be sent to.
public struct AudioOutput: Equatable, Identifiable, Sendable {
    public var id: AudioDeviceID
    /// Stays the same across restarts and re-plugging, unlike `id`.
    public var uid: String
    public var name: String
    /// Output channels. Four or more means a second stereo pair, for headphones.
    public var channels: Int

    public var hasHeadphoneOutput: Bool { channels >= 4 }
    /// A DJ controller with its own sound card: master on outputs 1-2, headphones on 3-4.
    public var isDJController: Bool { hasHeadphoneOutput && name.uppercased().contains("DDJ") }
}

/// The Mac's audio outputs, straight from Core Audio.
public enum AudioDevices {
    private static func address(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func string(_ device: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func outputChannels(_ device: AudioDeviceID) -> Int {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return 0 }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Every device that has outputs.
    public static func outputs() -> [AudioOutput] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let channels = outputChannels(id)
            guard channels > 0, let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioOutput(id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? name, name: name, channels: channels)
        }
    }

    /// The output chosen in System Settings.
    public static func defaultOutput() -> AudioDeviceID? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    /// Calls `handler` (on the main queue) whenever a device is plugged in or pulled out, or the system's choice of output changes.
    public static func onChange(_ handler: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in handler() }
        }
    }

    /// Which output to use. "auto": a DJ controller if one is connected, otherwise the system's output.
    /// "system": the system's output. Anything else is the `uid` of a device, used if it is connected.
    public static func resolve(_ choice: String, among devices: [AudioOutput] = outputs()) -> AudioOutput? {
        let system = defaultOutput().flatMap { id in devices.first { $0.id == id } }
        switch choice {
        case "system": return system
        case "auto", "": return devices.first(where: \.isDJController) ?? system
        default: return devices.first { $0.uid == choice } ?? system
        }
    }
}
