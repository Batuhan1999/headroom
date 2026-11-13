import Foundation

// Sony v2 layouts adapted from Sound Connect (MIT). See ThirdParty/.
public enum ListeningMode: String, CaseIterable, Identifiable {
    case noiseCancelling, ambient, off
    public var id: Self { self }
    public var title: String {
        switch self { case .noiseCancelling: return "Noise Cancelling"; case .ambient: return "Ambient Sound"; case .off: return "Off" }
    }
    public var symbol: String {
        switch self { case .noiseCancelling: return "waveform.circle"; case .ambient: return "ear"; case .off: return "speaker.slash" }
    }
}

public struct NoiseControl: Equatable {
    public var mode: ListeningMode
    public var focusOnVoice: Bool
    public var ambientLevel: Int
    public init(mode: ListeningMode, focusOnVoice: Bool = false, ambientLevel: Int = 20) {
        self.mode = mode; self.focusOnVoice = focusOnVoice; self.ambientLevel = min(20, max(1, ambientLevel))
    }
}

public enum EQPreset: UInt8, CaseIterable, Identifiable {
    case off = 0, bright = 0x10, excited, mellow, relaxed, vocal, trebleBoost, bassBoost, speech
    case manual = 0xa0, custom1, custom2
    public var id: Self { self }
    public var title: String {
        switch self {
        case .off: return "Off"; case .bright: return "Bright"; case .excited: return "Excited"
        case .mellow: return "Mellow"; case .relaxed: return "Relaxed"; case .vocal: return "Vocal"
        case .trebleBoost: return "Treble Boost"; case .bassBoost: return "Bass Boost"; case .speech: return "Speech"
        case .manual: return "Manual"; case .custom1: return "Custom 1"; case .custom2: return "Custom 2"
        }
    }
}

public struct Equalizer: Equatable {
    public var preset: UInt8
    // Clear Bass, 400 Hz, 1 kHz, 2.5 kHz, 6.3 kHz, 16 kHz; -10...10.
    public var values: [Int]
    public init(preset: UInt8 = 0, values: [Int] = Array(repeating: 0, count: 6)) {
        self.preset = preset; self.values = Array((values + Array(repeating: 0, count: 6)).prefix(6)).map { min(10, max(-10, $0)) }
    }
    public var title: String { EQPreset(rawValue: preset)?.title ?? "Preset \(preset)" }
}

public struct ChatOptions: Equatable {
    public var sensitivity: UInt8
    public var duration: UInt8
    public init(sensitivity: UInt8 = 0, duration: UInt8 = 1) { self.sensitivity = sensitivity; self.duration = duration }
}

public enum HeadphoneSetting: Equatable {
    case codec(String), noise(NoiseControl), equalizer(Equalizer), dsee(Bool), speakToChat(Bool)
    case chatOptions(ChatOptions), wearingPause(Bool), noiseButton(UInt8)

    static func parse(_ p: [UInt8]) -> Self? {
        guard p.count >= 3 else { return nil }
        switch (p[0], p[1]) {
        case (0x13, 2), (0x15, 2):
            return .codec([1: "SBC", 2: "AAC", 0x10: "LDAC", 0x20: "aptX", 0x21: "aptX HD"][p[2]] ?? String(format: "0x%02x", p[2]))
        case (0x67, 0x17), (0x69, 0x17):
            guard p.count == 7, p[2] == 1, p[3] <= 1, p[4] <= 1, p[5] <= 1, (1...20).contains(p[6]) else { return nil }
            return .noise(NoiseControl(mode: p[3] == 0 ? .off : p[4] == 0 ? .noiseCancelling : .ambient,
                                      focusOnVoice: p[5] == 1, ambientLevel: Int(p[6])))
        case (0x57, 0), (0x59, 0):
            guard p.count == 10, p[3] == 6, p[4...].allSatisfy({ $0 <= 20 }) else { return nil }
            return .equalizer(Equalizer(preset: p[2], values: p[4...].map { Int($0) - 10 }))
        case (0xe7, 1), (0xe9, 1): return p[2] <= 1 ? .dsee(p[2] == 1) : nil
        case (0xf7, 0x0c), (0xf9, 0x0c): return p[2] <= 1 ? .speakToChat(p[2] == 0) : nil
        case (0xf7, 1), (0xf9, 1): return p.count == 3 && p[2] <= 1 ? .wearingPause(p[2] == 0) : nil
        case (0xfb, 0x0c), (0xfd, 0x0c):
            guard p.count == 4, p[2] <= 2, p[3] <= 3 else { return nil }
            return .chatOptions(ChatOptions(sensitivity: p[2], duration: p[3]))
        case (0x67, 0x30), (0x69, 0x30): return p.count == 3 && (1...4).contains(p[2]) ? .noiseButton(p[2]) : nil
        default: return nil
        }
    }
}

public extension SonyRequest {
    static let codec = Self(payload: [0x12, 2])
    static let noise = Self(payload: [0x66, 0x17])
    static let equalizer = Self(payload: [0x56, 0])
    static let dsee = Self(payload: [0xe6, 1])
    static let speakToChat = Self(payload: [0xf6, 0x0c])
    static let chatOptions = Self(payload: [0xfa, 0x0c])
    static let wearingPause = Self(payload: [0xf6, 1])
    static let noiseButton = Self(payload: [0x66, 0x30])
    static let pause = Self(payload: [0xa4, 1, 0, 1], isMutation: true)
    static let featureQueries: [Self] = [.codec, .noise, .equalizer, .dsee, .speakToChat, .chatOptions, .wearingPause, .noiseButton]
    static func setNoise(_ state: NoiseControl) -> Self {
        Self(payload: [0x68, 0x17, 1, state.mode == .off ? 0 : 1, state.mode == .ambient ? 1 : 0,
                       state.focusOnVoice ? 1 : 0, UInt8(min(20, max(1, state.ambientLevel)))], isMutation: true)
    }
    static func setPreset(_ preset: EQPreset) -> Self { Self(payload: [0x58, 0, preset.rawValue, 0], isMutation: true) }
    static func setEqualizer(_ state: Equalizer) -> Self {
        Self(payload: [0x58, 0, EQPreset.manual.rawValue, 6] + state.values.map { UInt8(min(10, max(-10, $0)) + 10) }, isMutation: true)
    }
    static func setDSEE(_ on: Bool) -> Self { Self(payload: [0xe8, 1, on ? 1 : 0], isMutation: true) }
    static func setSpeakToChat(_ on: Bool) -> Self { Self(payload: [0xf8, 0x0c, on ? 0 : 1, 1], isMutation: true) }
    static func setWearingPause(_ on: Bool) -> Self { Self(payload: [0xf8, 1, on ? 0 : 1], isMutation: true) }
    static func setChatOptions(_ options: ChatOptions) -> Self? {
        guard options.sensitivity <= 2, options.duration <= 3 else { return nil }
        return Self(payload: [0xfc, 0x0c, options.sensitivity, options.duration], isMutation: true)
    }
    static func setNoiseButton(_ code: UInt8) -> Self? {
        guard (1...4).contains(code) else { return nil }
        return Self(payload: [0x68, 0x30, code], isMutation: true)
    }
    static func setAutoOff(_ code: UInt8) -> Self? {
        guard [0x10, 0x11].contains(code) else { return nil }
        return Self(payload: [0x28, 5, code, 0], isMutation: true)
    }
}

public struct SourceHandoff {
    public private(set) var target: String?
    public private(set) var targetIsMac = false
    public private(set) var deadline: TimeInterval = 0
    public init() {}
    public mutating func begin(target: String, isMac: Bool, now: TimeInterval) {
        self.target = target; targetIsMac = isMac; deadline = now + 10
    }
    public func holdsMac(now: TimeInterval) -> Bool { target != nil && targetIsMac && now < deadline }
    public func isPending(now: TimeInterval) -> Bool { target != nil && now < deadline }
    public mutating func cancel() { target = nil; deadline = 0 }
    public static func shouldRestoreMac(localSelected: Bool, suspended: Bool, audible: Bool?, inCall: Bool) -> Bool {
        localSelected && suspended && audible == true && !inCall
    }
}

public struct LowBattery {
    private var notified: Set<Int> = []
    public init() {}
    public mutating func update(_ level: Int, charging: Bool = false) -> Int? {
        guard (0...100).contains(level) else { return nil }
        if charging || level > 25 { notified.removeAll(); return nil }
        let crossed = [5, 10, 20].first { level <= $0 && !notified.contains($0) }
        if let crossed { notified.formUnion([5, 10, 20].filter { level <= $0 }) ; return crossed }
        return nil
    }
}

public struct CallAmbience {
    private var previous: NoiseControl?
    private var wasRecording = false
    private var changedManually = false
    public init() {}
    public mutating func manualChange() { if wasRecording { changedManually = true } }
    public mutating func update(recording: Bool?, state: NoiseControl?) -> NoiseControl? {
        guard let recording, let state else { return nil }
        defer { wasRecording = recording }
        if recording && !wasRecording {
            previous = state; changedManually = false
            if state.mode != .ambient { var next = state; next.mode = .ambient; return next }
        }
        if !recording && wasRecording {
            defer { previous = nil; changedManually = false }
            if !changedManually, state.mode == .ambient, let previous, previous.mode != .ambient { return previous }
        }
        return nil
    }
}

public struct MacAudioStartDetector {
    private var quietSince: TimeInterval?
    private var audibleSince: TimeInterval?
    private var armed = false
    private var lastCheck: TimeInterval?
    public init() {}
    public mutating func observe(silence: Bool?, now: TimeInterval) -> Bool {
        defer { lastCheck = now }
        if let lastCheck, now < lastCheck || now - lastCheck > 4 {
            quietSince = nil; audibleSince = nil; armed = false
        }
        guard let silence else { quietSince = nil; audibleSince = nil; armed = false; return false }
        if silence {
            audibleSince = nil
            if quietSince == nil { quietSince = now }
            if now - quietSince! >= 2 { armed = true }
        } else {
            quietSince = nil
            guard armed else { return false }
            if audibleSince == nil { audibleSince = now }
            if now - audibleSince! >= 1 {
                armed = false; audibleSince = nil
                return true
            }
        }
        return false
    }
}
