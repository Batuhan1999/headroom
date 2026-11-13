import CoreAudio
import Foundation
import HeadroomCore

struct MacAudioSnapshot {
    var active: Bool?
    var recording: Bool?
    var outputUID: String?
}

enum MacAudio {
    static func snapshot(address: String) -> MacAudioSnapshot {
        let activity = activity()
        return MacAudioSnapshot(active: activity.active, recording: activity.recording,
                                outputUID: headphoneOutputUID(address: address))
    }

    private static func headphoneOutputUID(address: String) -> String? {
        var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &property, 0, nil, &size) == noErr else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &property, 0, nil, &size, &devices) == noErr else { return nil }
        func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
            var p = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var value: Unmanaged<CFString>?, count = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &p, 0, nil, &count, &value) == noErr else { return nil }
            return value?.takeRetainedValue() as String?
        }
        func compact(_ value: String) -> String { value.lowercased().filter { $0.isHexDigit } }
        let candidates = devices.compactMap { id -> String? in
            guard SonyModel.identify(string(id, kAudioObjectPropertyName) ?? "") != nil,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            var p = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var count: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &p, 0, nil, &count) == noErr, count > 0 else { return nil }
            return uid
        }
        let exact = candidates.filter { compact($0).contains(compact(address)) }
        if exact.count == 1 { return exact[0] }
        return candidates.count == 1 ? candidates[0] : nil
    }

    // Read the process list once, without retaining any process names or audio.
    private static func activity() -> (active: Bool?, recording: Bool?) {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return (nil, nil) }
        if size == 0 { return (false, false) }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return (nil, nil) }
        var input = false, output = false, inputFailed = false, outputFailed = false
        for process in processes {
            address.mSelector = kAudioProcessPropertyPID
            var pid: Int32 = 0, pidSize = UInt32(MemoryLayout<Int32>.size)
            guard AudioObjectGetPropertyData(process, &address, 0, nil, &pidSize, &pid) == noErr else {
                inputFailed = true; outputFailed = true; continue
            }
            // Our private level-monitor input is not a microphone or call.
            if pid == ProcessInfo.processInfo.processIdentifier { continue }
            for isInput in [true, false] {
                address.mSelector = isInput ? kAudioProcessPropertyIsRunningInput : kAudioProcessPropertyIsRunningOutput
                var value: UInt32 = 0, count = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(process, &address, 0, nil, &count, &value) != noErr {
                    if isInput { inputFailed = true } else { outputFailed = true }
                } else if value != 0 {
                    if isInput { input = true } else { output = true }
                }
            }
        }
        let recording: Bool? = input ? true : inputFailed ? nil : false
        let active: Bool? = input || output ? true : inputFailed || outputFailed ? nil : false
        return (active, recording)
    }
}
