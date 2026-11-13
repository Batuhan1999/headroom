import Foundation

public struct IdleInput {
    public var enabled: Bool
    public var keepANC: Bool
    public var connected: Bool
    public var playback: Playback
    public var statusAge: TimeInterval
    public var peersAge: TimeInterval
    public var onlyLocalMac: Bool
    public var macAudioActive: Bool?
    public var threshold: TimeInterval
    public var localSelected: Bool
    public var measuredSilence: Bool?
    public var remoteVerified: Bool
    public var recording: Bool?
    public init(enabled: Bool, keepANC: Bool = false, connected: Bool = true,
                playback: Playback, statusAge: TimeInterval = 0, peersAge: TimeInterval = 0,
                onlyLocalMac: Bool, macAudioActive: Bool?, threshold: TimeInterval,
                localSelected: Bool = false, measuredSilence: Bool? = nil,
                remoteVerified: Bool = false, recording: Bool? = false) {
        self.enabled = enabled; self.keepANC = keepANC; self.connected = connected
        self.playback = playback; self.statusAge = statusAge; self.peersAge = peersAge
        self.onlyLocalMac = onlyLocalMac; self.macAudioActive = macAudioActive; self.threshold = threshold
        self.localSelected = localSelected; self.measuredSilence = measuredSilence
        self.remoteVerified = remoteVerified; self.recording = recording
    }
}

public enum IdleDecision: Equatable {
    case hold(String)
    case counting(remaining: TimeInterval)
    case powerOff
}

public struct IdlePolicy {
    private var idleSince: TimeInterval?
    private var lastCheck: TimeInterval?
    private var fired = false
    public init() {}
    public mutating func reset() { idleSince = nil; lastCheck = nil; fired = false }

    public mutating func evaluate(_ input: IdleInput, now: TimeInterval) -> IdleDecision {
        defer { lastCheck = now }
        let reason: String?
        if !input.enabled { reason = "Idle power-off is off" }
        else if input.keepANC { reason = "Keeping noise cancellation available" }
        else if !input.connected { reason = "Connect your headphones to monitor inactivity" }
        else if input.statusAge > 12 || input.peersAge > 12 { reason = "Waiting for fresh headphone status" }
        else if !input.onlyLocalMac && !input.remoteVerified { reason = "Check iPhone playback detection to enable multipoint auto-off" }
        else if input.playback == .unknown { reason = "Playback status is unknown" }
        else if input.playback == .call || input.recording == true { reason = "A call or microphone is active" }
        else if input.recording == nil { reason = "Call status is unavailable" }
        else if input.playback == .playing && !(input.localSelected && input.measuredSilence == true) { reason = "Audio is playing" }
        else if input.measuredSilence == false { reason = "Mac audio is audible" }
        else if input.measuredSilence == nil && input.macAudioActive != false { reason = "Waiting for verified Mac audio levels" }
        else { reason = nil }
        if let reason { idleSince = nil; fired = false; return .hold(reason) }
        // Do not count time while the process is asleep or stalled.
        if let lastCheck, now - lastCheck > 8 || now < lastCheck { idleSince = nil; fired = false }
        if idleSince == nil { idleSince = now }
        let remaining = max(0, max(5, input.threshold) - (now - idleSince!))
        if remaining == 0, !fired { fired = true; return .powerOff }
        return .counting(remaining: remaining)
    }
}

public struct ConnectionPolicy {
    public var protect = true
    public var sleeping = false
    public var locked = false
    public var lidClosed = false
    public var phoneOnly = false
    public var shutdown = false
    public init() {}
    public var blocked: Bool { shutdown || phoneOnly || (protect && (sleeping || locked || lidClosed)) }
}

public func preferredRemoteSource(peers: [Peer], localAddress: String?) -> Peer? {
    guard let localAddress, validAddress(localAddress),
          peers.contains(where: { $0.id.caseInsensitiveCompare(localAddress) == .orderedSame }) else { return nil }
    let remote = peers.filter { $0.id.caseInsensitiveCompare(localAddress) != .orderedSame }
    return remote.count == 1 ? remote[0] : nil
}

public struct RemotePlaybackValidation {
    public private(set) var sawRemotePlaying = false
    public init() {}
    public mutating func update(playback: Playback, remoteSelected: Bool, fresh: Bool, localSilence: Bool?) -> Bool {
        guard fresh else { return false }
        if remoteSelected && playback == .playing { sawRemotePlaying = true }
        // Sony may select the Mac again as soon as the phone pauses.
        return sawRemotePlaying && playback.isIdle && localSilence == true
    }
}

public struct ReconnectPlan {
    public private(set) var pending = false
    public private(set) var failures = 0
    public private(set) var nextAttemptAt: TimeInterval = 0
    public init() {}
    public mutating func request(now: TimeInterval, delay: TimeInterval = 0) {
        pending = true; failures = 0; nextAttemptAt = now + delay
    }
    public func shouldAttempt(now: TimeInterval, blocked: Bool, connected: Bool, connecting: Bool) -> Bool {
        pending && !blocked && !connected && !connecting && now >= nextAttemptAt
    }
    public mutating func failed(now: TimeInterval) {
        failures += 1
        if failures >= 5 { pending = false }
        else { nextAttemptAt = now + min(30, 3 * pow(2, Double(failures - 1))) }
    }
    public mutating func complete() { pending = false; failures = 0 }
    public mutating func cancel() { pending = false; failures = 0 }
}
