import Foundation

// Wire layout adapted from Sound Connect (MIT); playback fields from
// SonyHeadphonesClient (MIT). See ThirdParty/ for the original licenses.
public struct SonyFrame: Equatable {
    public var kind: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(kind: UInt8 = 0x0c, sequence: UInt8 = 0, payload: [UInt8]) {
        self.kind = kind; self.sequence = sequence; self.payload = payload
    }

    public var encoded: [UInt8] {
        let size = UInt32(payload.count)
        var body = [kind, sequence, UInt8(size >> 24), UInt8((size >> 16) & 255),
                    UInt8((size >> 8) & 255), UInt8(size & 255)] + payload
        body.append(body.reduce(0, &+))
        return [0x3e] + body.flatMap { [0x3c, 0x3d, 0x3e].contains($0) ? [0x3d, $0 & 0xef] : [$0] } + [0x3c]
    }

    public static func ack(_ sequence: UInt8) -> SonyFrame {
        SonyFrame(kind: 1, sequence: 1 &- sequence, payload: [])
    }
}

public struct SonyFrameReader {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func push(_ bytes: [UInt8]) -> [SonyFrame] {
        buffer += bytes
        var frames: [SonyFrame] = []
        while let end = buffer.firstIndex(of: 0x3c) {
            let packet = Array(buffer[...end]); buffer.removeFirst(end + 1)
            guard let start = packet.lastIndex(of: 0x3e), start < end else { continue }
            var body: [UInt8] = [], escaping = false
            for byte in packet[(start + 1)..<end] {
                if escaping { body.append(byte | 0x10); escaping = false }
                else if byte == 0x3d { escaping = true }
                else { body.append(byte) }
            }
            guard !escaping, body.count >= 7,
                  body.dropLast().reduce(UInt8(0), &+) == body.last else { continue }
            let size = body[2..<6].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard size <= 65_536, body.count == Int(size) + 7 else { continue }
            frames.append(SonyFrame(kind: body[0], sequence: body[1], payload: Array(body[6..<(body.count - 1)])))
        }
        if buffer.count > 131_072 { buffer.removeAll() }
        return frames
    }
}

public enum Playback: String, Equatable {
    case unknown, playing, paused, stopped, call
    public var isIdle: Bool { self == .paused || self == .stopped }
}

public struct Peer: Equatable, Identifiable {
    public let id: String
    public let name: String
    public let selected: Bool
    public init(id: String, name: String, selected: Bool) {
        self.id = id; self.name = name; self.selected = selected
    }
}

public enum SonyReply: Equatable {
    case ready(table2: Bool)
    case battery(Int, charging: Bool = false)
    case firmware(String)
    case playback(Playback)
    case functions([UInt8])
    case peers([Peer])
    case switched(result: UInt8, target: String)
    case setting(HeadphoneSetting)
    case autoOffCapabilities([UInt8])
    case autoOffSetting(UInt8)

    public static func parse(_ frame: SonyFrame) -> SonyReply? {
        let p = frame.payload
        guard p.count >= 2 else { return nil }
        if frame.kind == 0x0c {
            switch (p[0], p[1]) {
            case (0x01, 0x00):
                guard p.count == 8 else { return nil }
                return .ready(table2: p[7] == 0)
            case (0x23, 0x00), (0x25, 0x00):
                guard p.count >= 4, p[2] <= 100 else { return nil }
                return .battery(Int(p[2]), charging: p[3] == 1)
            case (0x05, 0x02):
                guard p.count >= 3, p.count >= 3 + Int(p[2]) else { return nil }
                return .firmware(String(decoding: p[3..<(3 + Int(p[2]))], as: UTF8.self))
            case (0x21, 0x05):
                guard p.count >= 3, p.count >= 3 + Int(p[2]) else { return nil }
                return .autoOffCapabilities(Array(p[3..<(3 + Int(p[2]))]))
            case (0x27, 0x05), (0x29, 0x05):
                guard p.count >= 4 else { return nil }
                return .autoOffSetting(p[2])
            case (0xa3, 0x01), (0xa5, 0x01):
                guard p.count >= 5 else { return .playback(.unknown) }
                if p[4] == 1 { return .playback(.call) }
                // Never interpret unsupported/disabled or unknown values as silence.
                guard p[2] == 0, p[4] == 0 else { return .playback(.unknown) }
                return .playback([1: Playback.playing, 2: .paused, 3: .stopped][p[3]] ?? .unknown)
            default: return HeadphoneSetting.parse(p).map(SonyReply.setting)
            }
        }
        guard frame.kind == 0x0e else { return nil }
        if p[0] == 0x07, p[1] == 0, p.count >= 3 {
            let count = Int(p[2])
            guard p.count >= 3 + count * 2 else { return nil }
            return .functions((0..<count).map { p[3 + $0 * 2] })
        }
        if p[0] == 0x3d, p[1] == 1 {
            guard p.count == 20 else { return nil }
            let target = String(decoding: p[3..<20], as: UTF8.self)
            guard validAddress(target) else { return nil }
            return .switched(result: p[2], target: target)
        }
        guard [0x37, 0x39].contains(p[0]), [0, 2].contains(p[1]), p.count >= 3 else { return nil }
        var offset = 3, entries: [(String, String, UInt8)] = []
        for _ in 0..<Int(p[2]) {
            guard offset + 18 <= p.count else { return nil }
            let address = String(decoding: p[offset..<(offset + 17)], as: UTF8.self)
            guard validAddress(address) else { return nil }
            let slot = p[offset + 17]; offset += 18
            if p[1] == 2 { offset += 3 }
            guard offset < p.count else { return nil }
            let length = Int(p[offset]); offset += 1
            guard offset + length <= p.count else { return nil }
            let name = String(decoding: p[offset..<(offset + length)], as: UTF8.self); offset += length
            entries.append((address, name, slot))
        }
        guard offset < p.count else { return nil }
        let selected = p[offset]
        return .peers(entries.filter { $0.2 != 0 }.map { Peer(id: $0.0, name: $0.1, selected: $0.2 == selected) })
    }
}

public func validAddress(_ address: String) -> Bool {
    let components = address.split(separator: ":", omittingEmptySubsequences: false)
    return components.count == 6 && components.allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
}

public struct SonyRequest: Equatable {
    public var kind: UInt8
    public var payload: [UInt8]
    public var isMutation: Bool
    public init(kind: UInt8 = 0x0c, payload: [UInt8], isMutation: Bool = false) {
        self.kind = kind; self.payload = payload; self.isMutation = isMutation
    }
    public static let initialize = Self(payload: [0x00, 0x00])
    public static let battery = Self(payload: [0x22, 0x00])
    public static let firmware = Self(payload: [0x04, 0x02])
    public static let playback = Self(payload: [0xa2, 0x01])
    public static let functions = Self(kind: 0x0e, payload: [0x06, 0x00])
    public static let powerOff = Self(payload: [0x24, 0x03, 0x01], isMutation: true)
    public static let autoOffCapabilities = Self(payload: [0x20, 0x05])
    public static let autoOffSetting = Self(payload: [0x26, 0x05])
    public static func peers(withClass: Bool) -> Self { Self(kind: 0x0e, payload: [0x36, withClass ? 2 : 0]) }
    public static func playFrom(_ address: String) -> Self? {
        guard validAddress(address) else { return nil }
        return Self(kind: 0x0e, payload: [0x3c, 0x01] + Array(address.utf8), isMutation: true)
    }
}

public struct SonySession {
    private var reader = SonyFrameReader()
    private var sequence: UInt8 = 0
    private var pending: [SonyRequest] = []
    private var inflight: SonyRequest?
    private var sentAt: TimeInterval = 0
    private var attempts = 0
    public private(set) var timedOut = false
    public init() {}

    public mutating func enqueue(_ request: SonyRequest, now: TimeInterval) -> [[UInt8]] {
        guard !timedOut else { return [] }
        if request.isMutation {
            guard pending.last != request, inflight != request else { return [] }
        } else {
            // A read-back after a queued mutation must not reuse an older query.
            guard !pending.reversed().prefix(while: { !$0.isMutation }).contains(request) else { return [] }
            guard inflight != request || pending.contains(where: { $0.isMutation }) else { return [] }
        }
        pending.append(request)
        return next(now: now)
    }

    public mutating func receive(_ bytes: [UInt8], now: TimeInterval) -> (writes: [[UInt8]], replies: [SonyReply], acknowledged: [SonyRequest]) {
        var writes: [[UInt8]] = [], replies: [SonyReply] = [], acknowledged: [SonyRequest] = []
        for frame in reader.push(bytes) {
            if frame.kind == 1 {
                guard let request = inflight, frame.sequence == (1 &- sequence) else { continue }
                acknowledged.append(request)
                sequence = frame.sequence; inflight = nil
            } else {
                writes.append(SonyFrame.ack(frame.sequence).encoded)
                if let reply = SonyReply.parse(frame) { replies.append(reply) }
            }
        }
        writes += next(now: now)
        return (writes, replies, acknowledged)
    }

    public mutating func tick(now: TimeInterval) -> [[UInt8]] {
        guard let request = inflight, now - sentAt >= 1.5 else { return [] }
        // A timed-out mutation is never replayed after a later reconnection.
        guard attempts < 3 else { timedOut = true; pending.removeAll(); inflight = nil; return [] }
        attempts += 1; sentAt = now
        return [SonyFrame(kind: request.kind, sequence: sequence, payload: request.payload).encoded]
    }

    private mutating func next(now: TimeInterval) -> [[UInt8]] {
        guard !timedOut, inflight == nil, !pending.isEmpty else { return [] }
        let request = pending.removeFirst(); inflight = request; sentAt = now; attempts = 1
        return [SonyFrame(kind: request.kind, sequence: sequence, payload: request.payload).encoded]
    }
}
