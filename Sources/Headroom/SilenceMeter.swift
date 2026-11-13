import AppKit
import CoreAudio
import os

struct LevelReading {
    var peak: Float = 0
    var sampledAt: TimeInterval = 0
    var heardSound = false
}

@available(macOS 14.2, *)
final class SilenceMeter {
    private let readings = OSAllocatedUnfairLock(initialState: LevelReading())
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var calibration: NSSound?
    private var startedAt: TimeInterval = 0
    private var tapDescription: CATapDescription?
    private(set) var muted = false
    private var calibrationEndsAt: TimeInterval = 0
    var calibrating: Bool { ProcessInfo.processInfo.systemUptime < calibrationEndsAt }
    private(set) var deviceUID: String?
    private(set) var error: String?
    var running: Bool { ioProc != nil }

    var reading: LevelReading { readings.withLock { $0 } }
    var silence: Bool? {
        let value = reading
        guard running, value.heardSound, ProcessInfo.processInfo.systemUptime - value.sampledAt < 3 else { return nil }
        return value.peak < 0.0001
    }
    var status: String {
        if let error { return error }
        guard running else { return "Audio level detection is off" }
        if calibrating { return "Checking audio level access…" }
        let value = reading
        if !value.heardSound {
            return ProcessInfo.processInfo.systemUptime - startedAt < 8
                ? "Checking audio access with a short tone…"
                : "Audio access is unverified. Allow System Audio Recording, then retry."
        }
        guard ProcessInfo.processInfo.systemUptime - value.sampledAt < 3 else { return "Waiting for audio level readings" }
        return value.peak < 0.0001 ? "Mac output is silent" : "Mac audio is audible"
    }

    func start(deviceUID: String, calibrate: Bool) {
        stop()
        error = nil; self.deviceUID = deviceUID; startedAt = ProcessInfo.processInfo.systemUptime
        readings.withLock { $0 = LevelReading() }
        let description = CATapDescription(excludingProcesses: [], deviceUID: deviceUID, stream: 0)
        description.name = "Headroom audio levels"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        tapDescription = description
        let create = AudioHardwareCreateProcessTap(description, &tapID)
        guard create == noErr else { fail("Audio level access failed (\(create))"); return }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0, format.mBitsPerChannel == 32 else {
            fail("The headphone audio format cannot be metered"); return
        }
        let config: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Headroom Level Monitor",
            kAudioAggregateDeviceUIDKey: "io.github.Batuhan1999.headroom.meter.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true
            ]]
        ]
        let aggregate = AudioHardwareCreateAggregateDevice(config as CFDictionary, &aggregateID)
        guard aggregate == noErr else { fail("Could not start level monitor (\(aggregate))"); return }
        let shared = readings
        let setup = AudioDeviceCreateIOProcIDWithBlock(&ioProc, aggregateID, nil) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            var peak: Float = 0
            var count = 0
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                for i in 0..<sampleCount {
                    let value = abs(samples[i])
                    if value.isFinite { peak = max(peak, value) }
                }
                count += sampleCount
            }
            guard count > 0 else { return }
            let measuredPeak = peak
            shared.withLock { value in
                // Retain a peak until the UI consumes it so short sounds reset the timer.
                value.peak = max(value.peak, measuredPeak)
                value.sampledAt = ProcessInfo.processInfo.systemUptime
                value.heardSound = value.heardSound || measuredPeak > 0.001
            }
        }
        guard setup == noErr, let ioProc else { fail("Could not read audio levels (\(setup))"); return }
        let start = AudioDeviceStart(aggregateID, ioProc)
        guard start == noErr else { fail("Audio level monitor did not start (\(start))"); return }
        if calibrate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.playCalibration() }
        }
    }

    func consumePeak() -> LevelReading {
        readings.withLock { value in
            let result = value; value.peak = 0; return result
        }
    }

    @discardableResult
    func setMuted(_ value: Bool) -> Bool {
        guard running, let tapDescription else { return false }
        if muted == value { return true }
        tapDescription.muteBehavior = value ? .mutedWhenTapped : .unmuted
        var reference = Unmanaged.passUnretained(tapDescription)
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let result = AudioObjectSetPropertyData(tapID, &address, 0, nil,
            UInt32(MemoryLayout<Unmanaged<CATapDescription>>.size), &reference)
        if result == noErr { muted = value }
        return result == noErr
    }

    func playCalibration() {
        guard running, let deviceUID else { return }
        calibrationEndsAt = ProcessInfo.processInfo.systemUptime + 2
        let rate = 48_000, frames = rate / 5
        var pcm = Data(capacity: frames * 2)
        for frame in 0..<frames {
            let fade = min(1.0, Double(frame) / 800, Double(frames - frame) / 800)
            let value = Int16(sin(2 * .pi * 660 * Double(frame) / Double(rate)) * 180 * fade)
            var sample = value.littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count)); wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate))
        append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        wav.append(Data("data".utf8)); append(UInt32(pcm.count)); wav.append(pcm)
        calibration = NSSound(data: wav)
        calibration?.playbackDeviceIdentifier = deviceUID
        calibration?.play()
    }

    func stop() {
        calibration?.stop(); calibration = nil
        if let ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProc)
            AudioDeviceDestroyIOProcID(aggregateID, ioProc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        tapDescription = nil; muted = false
        deviceUID = nil
        readings.withLock { $0 = LevelReading() }
    }

    private func fail(_ message: String) { stop(); error = message }
    deinit { stop() }
}
