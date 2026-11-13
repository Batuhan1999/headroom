import XCTest
@testable import HeadroomCore

final class HeadroomCoreTests: XCTestCase {
    func testCapturedXM5Frames() {
        XCTAssertEqual(SonyFrame(payload: [0, 0]).encoded, [0x3e, 0x0c, 0, 0, 0, 0, 2, 0, 0, 0x0e, 0x3c])
        XCTAssertEqual(SonyFrame(payload: [0x22, 0]).encoded, [0x3e, 0x0c, 0, 0, 0, 0, 2, 0x22, 0, 0x30, 0x3c])
        XCTAssertEqual(SonyFrame(sequence: 1, payload: [0x66, 0x17]).encoded,
                       [0x3e, 0x0c, 1, 0, 0, 0, 2, 0x66, 0x17, 0x8c, 0x3c])
    }

    func testFramingAcrossEveryChunkBoundaryAndEscapedBytes() {
        let message = SonyFrame(kind: 0x0e, sequence: 1, payload: Array(0...255))
        let bytes = message.encoded
        for split in 0...bytes.count {
            var reader = SonyFrameReader()
            let results = reader.push(Array(bytes.prefix(split))) + reader.push(Array(bytes.dropFirst(split)))
            XCTAssertEqual(results, [message])
        }
    }

    func testCorruptionRejectedAndReaderResynchronizes() {
        let good = SonyFrame(payload: [0x23, 0, 72, 0])
        var bad = good.encoded; bad[8] ^= 1
        var reader = SonyFrameReader()
        XCTAssertEqual(reader.push([1, 2, 3] + bad + good.encoded), [good])
        XCTAssertTrue(reader.push([0x3e, 0x0c, 0x3d, 0x3c]).isEmpty)
    }

    func testMalformedRepliesNeverBecomeIdle() {
        for payload: [UInt8] in [[0xa3, 1], [0xa3, 1, 0, 2], [0xa3, 1, 1, 2, 0], [0xa3, 1, 0, 255, 0], [0xa3, 1, 0, 2, 255]] {
            XCTAssertEqual(SonyReply.parse(.init(payload: payload)), .playback(.unknown))
        }
        XCTAssertNil(SonyReply.parse(.init(kind: 0x0e, payload: [0xa3, 1, 0, 2, 0])))
    }

    func testPlaybackAndCallStatusAreDistinctFromSourceSelection() {
        XCTAssertEqual(SonyReply.parse(.init(payload: [0xa3, 1, 0, 1, 0])), .playback(.playing))
        XCTAssertEqual(SonyReply.parse(.init(payload: [0xa5, 1, 0, 2, 0])), .playback(.paused))
        XCTAssertEqual(SonyReply.parse(.init(payload: [0xa3, 1, 0, 3, 0])), .playback(.stopped))
        XCTAssertEqual(SonyReply.parse(.init(payload: [0xa3, 1, 0, 2, 1])), .playback(.call))
        XCTAssertEqual(SonyReply.parse(.init(payload: [1, 0, 0, 0, 0, 0, 0, 0])), .ready(table2: true))
    }

    func testParsesBothPeerLayoutsAndRejectsTruncation() {
        for withClass in [false, true] {
            var bytes: [UInt8] = [0x37, withClass ? 2 : 0, 2]
            for (id, slot, name) in [("AA:BB:CC:DD:EE:FF", UInt8(1), "Mac"), ("11:22:33:44:55:66", UInt8(2), "iPhone")] {
                bytes += Array(id.utf8) + [slot]
                if withClass { bytes += [0, 0, 0] }
                bytes += [UInt8(name.utf8.count)] + Array(name.utf8)
            }
            bytes.append(2)
            let expected = [Peer(id: "AA:BB:CC:DD:EE:FF", name: "Mac", selected: false),
                            Peer(id: "11:22:33:44:55:66", name: "iPhone", selected: true)]
            XCTAssertEqual(SonyReply.parse(.init(kind: 0x0e, payload: bytes)), .peers(expected))
            for end in 0..<bytes.count {
                XCTAssertNil(SonyReply.parse(.init(kind: 0x0e, payload: Array(bytes.prefix(end)))))
            }
        }
    }

    func testAddressValidationPreventsArbitrarySwitchPayloads() {
        XCTAssertNil(SonyRequest.playFrom("bad address"))
        XCTAssertNil(SonyRequest.playFrom("GG:00:00:00:00:00"))
        XCTAssertNotNil(SonyRequest.playFrom("AA:BB:CC:DD:EE:FF"))
    }

    func testSessionWaitsForMatchingAckAndResendsSameSequence() {
        var session = SonySession()
        let first = session.enqueue(.initialize, now: 0)
        XCTAssertTrue(session.enqueue(.battery, now: 0).isEmpty)
        XCTAssertTrue(session.receive(SonyFrame(kind: 1, sequence: 0, payload: []).encoded, now: 1).writes.isEmpty)
        XCTAssertEqual(session.tick(now: 2), first)
        let next = session.receive(SonyFrame(kind: 1, sequence: 1, payload: []).encoded, now: 2).writes
        XCTAssertEqual(next, [SonyFrame(sequence: 1, payload: [0x22, 0]).encoded])
    }

    func testSessionAcksNotificationsAndFailsClosedOnTimeout() {
        var session = SonySession()
        let bytes = SonyFrame(sequence: 0, payload: [0xa5, 1, 0, 1, 0]).encoded
        let result = session.receive(bytes, now: 0)
        XCTAssertEqual(result.writes, [SonyFrame.ack(0).encoded])
        XCTAssertEqual(result.replies, [.playback(.playing)])
        _ = session.enqueue(.powerOff, now: 0)
        _ = session.tick(now: 2); _ = session.tick(now: 4)
        XCTAssertTrue(session.tick(now: 6).isEmpty)
        XCTAssertTrue(session.timedOut)
        XCTAssertTrue(session.enqueue(.powerOff, now: 7).isEmpty)
    }

    private func input() -> IdleInput {
        IdleInput(enabled: true, playback: .paused, onlyLocalMac: true, macAudioActive: false, threshold: 60)
    }

    func testTimerFiresOnceAfterContinuousObservedIdle() {
        var policy = IdlePolicy()
        for second in 0..<60 {
            XCTAssertEqual(policy.evaluate(input(), now: Double(second)), .counting(remaining: Double(60 - second)))
        }
        XCTAssertEqual(policy.evaluate(input(), now: 60), .powerOff)
        XCTAssertEqual(policy.evaluate(input(), now: 61), .counting(remaining: 0))
    }

    func testEveryUncertainOrActiveStatePreventsPowerOffAndResetsTimer() {
        var variants: [IdleInput] = []
        var x = input(); x.enabled = false; variants.append(x)
        x = input(); x.keepANC = true; variants.append(x)
        x = input(); x.connected = false; variants.append(x)
        x = input(); x.statusAge = 13; variants.append(x)
        x = input(); x.peersAge = 13; variants.append(x)
        x = input(); x.onlyLocalMac = false; variants.append(x)
        x = input(); x.playback = .playing; variants.append(x)
        x = input(); x.playback = .call; variants.append(x)
        x = input(); x.playback = .unknown; variants.append(x)
        x = input(); x.macAudioActive = nil; variants.append(x)
        x = input(); x.macAudioActive = true; variants.append(x)
        for variant in variants {
            var policy = IdlePolicy()
            for t in 0..<59 { _ = policy.evaluate(input(), now: Double(t)) }
            guard case .hold = policy.evaluate(variant, now: 59) else { return XCTFail("Unsafe shutdown") }
            XCTAssertEqual(policy.evaluate(input(), now: 60), .counting(remaining: 60))
        }
    }

    func testSleepOrClockDiscontinuityCannotExpireTimer() {
        var policy = IdlePolicy()
        _ = policy.evaluate(input(), now: 0)
        XCTAssertEqual(policy.evaluate(input(), now: 120), .counting(remaining: 60))
        XCTAssertEqual(policy.evaluate(input(), now: 100), .counting(remaining: 60))
    }

    func testPhoneOnlyAndClosedLidStayBlockedAcrossWake() {
        var policy = ConnectionPolicy()
        policy.sleeping = true; XCTAssertTrue(policy.blocked)
        policy.sleeping = false; policy.lidClosed = true; XCTAssertTrue(policy.blocked)
        policy.lidClosed = false; policy.locked = true; XCTAssertTrue(policy.blocked)
        policy.locked = false; policy.phoneOnly = true; XCTAssertTrue(policy.blocked)
        policy.phoneOnly = false; XCTAssertFalse(policy.blocked)
        policy.shutdown = true; policy.protect = false; XCTAssertTrue(policy.blocked)
    }

    func testReconnectPrefersOnlyAnIdentifiedRemoteSource() {
        let mac = Peer(id: "AA:BB:CC:DD:EE:FF", name: "Mac", selected: true)
        let phone = Peer(id: "11:22:33:44:55:66", name: "iPhone", selected: false)
        XCTAssertEqual(preferredRemoteSource(peers: [mac, phone], localAddress: mac.id.lowercased()), phone)
        XCTAssertNil(preferredRemoteSource(peers: [mac, phone], localAddress: nil))
        XCTAssertNil(preferredRemoteSource(peers: [mac], localAddress: mac.id))
        XCTAssertNil(preferredRemoteSource(peers: [phone], localAddress: mac.id))
        XCTAssertNil(preferredRemoteSource(peers: [mac, phone, .init(id: "22:33:44:55:66:77", name: "Tablet", selected: false)], localAddress: mac.id))
    }

    func testSilentLocalStreamCanExpireDespitePlayingFlag() {
        var policy = IdlePolicy(), value = input()
        value.playback = .playing; value.macAudioActive = true
        value.localSelected = true; value.measuredSilence = true; value.threshold = 5
        for t in 0..<5 { XCTAssertEqual(policy.evaluate(value, now: Double(t)), .counting(remaining: Double(5 - t))) }
        XCTAssertEqual(policy.evaluate(value, now: 5), .powerOff)
    }

    func testRemotePlayingNeverBecomesSilenceFromLocalMeter() {
        var policy = IdlePolicy(), value = input()
        value.onlyLocalMac = false; value.remoteVerified = true
        value.playback = .playing; value.measuredSilence = true; value.localSelected = false
        for t in 0..<100 {
            guard case .hold = policy.evaluate(value, now: Double(t)) else { return XCTFail("Remote music must hold shutdown") }
        }
    }

    func testVerifiedMultipointPausedStateCanCountDown() {
        var policy = IdlePolicy(), value = input()
        value.onlyLocalMac = false; value.remoteVerified = true
        value.measuredSilence = true; value.macAudioActive = true; value.threshold = 5
        for t in 0..<5 { _ = policy.evaluate(value, now: Double(t)) }
        XCTAssertEqual(policy.evaluate(value, now: 5), .powerOff)
    }

    func testAudioAndCallUncertaintyCannotUseSilentStreamOverride() {
        var value = input()
        value.playback = .playing; value.localSelected = true; value.macAudioActive = true; value.measuredSilence = true
        for uncertain in [Playback.unknown, .call] {
            var policy = IdlePolicy(); value.playback = uncertain
            guard case .hold = policy.evaluate(value, now: 0) else { return XCTFail("Unknown/call must hold") }
        }
        value.playback = .playing; value.measuredSilence = nil
        var policy = IdlePolicy()
        guard case .hold = policy.evaluate(value, now: 0) else { return XCTFail("Uncalibrated capture must hold") }
        value.measuredSilence = true; value.recording = nil
        guard case .hold = policy.evaluate(value, now: 1) else { return XCTFail("Unknown mic state must hold") }
        value.recording = true
        guard case .hold = policy.evaluate(value, now: 2) else { return XCTFail("Mic use must hold") }
    }

    func testNativeTimerCapabilityAndSettingMessages() {
        XCTAssertEqual(SonyReply.parse(.init(payload: [0x21, 0x05, 2, 0x10, 0x11])), .autoOffCapabilities([0x10, 0x11]))
        XCTAssertEqual(SonyReply.parse(.init(payload: [0x27, 0x05, 0x10, 0])), .autoOffSetting(0x10))
        XCTAssertNil(SonyReply.parse(.init(payload: [0x21, 0x05, 3, 0x10, 0x11])))
    }

    func testPhonePauseValidatesAfterSonyFallsBackToMac() {
        var check = RemotePlaybackValidation()
        XCTAssertFalse(check.update(playback: .playing, remoteSelected: true, fresh: true, localSilence: true))
        XCTAssertTrue(check.update(playback: .paused, remoteSelected: false, fresh: true, localSilence: true))
    }

    func testPhoneValidationRequiresObservedPlayingFreshPauseAndQuietLocalAudio() {
        var check = RemotePlaybackValidation()
        XCTAssertFalse(check.update(playback: .paused, remoteSelected: true, fresh: true, localSilence: true))
        XCTAssertFalse(check.update(playback: .playing, remoteSelected: true, fresh: false, localSilence: true))
        XCTAssertFalse(check.sawRemotePlaying)
        _ = check.update(playback: .playing, remoteSelected: true, fresh: true, localSilence: true)
        XCTAssertFalse(check.update(playback: .call, remoteSelected: true, fresh: true, localSilence: true))
        XCTAssertFalse(check.update(playback: .paused, remoteSelected: false, fresh: false, localSilence: true))
        XCTAssertFalse(check.update(playback: .paused, remoteSelected: false, fresh: true, localSilence: false))
        XCTAssertFalse(check.update(playback: .paused, remoteSelected: false, fresh: true, localSilence: nil))
    }

    func testWakeReconnectSurvivesTransientFailureAndRespectsLock() {
        var plan = ReconnectPlan()
        plan.request(now: 10, delay: 3)
        XCTAssertFalse(plan.shouldAttempt(now: 12, blocked: false, connected: false, connecting: false))
        XCTAssertFalse(plan.shouldAttempt(now: 20, blocked: true, connected: false, connecting: false))
        XCTAssertTrue(plan.shouldAttempt(now: 20, blocked: false, connected: false, connecting: false))
        plan.failed(now: 20)
        XCTAssertFalse(plan.shouldAttempt(now: 22, blocked: false, connected: false, connecting: false))
        XCTAssertTrue(plan.shouldAttempt(now: 23, blocked: false, connected: false, connecting: false))
        XCTAssertFalse(plan.shouldAttempt(now: 23, blocked: false, connected: false, connecting: true))
        plan.complete()
        XCTAssertFalse(plan.shouldAttempt(now: 100, blocked: false, connected: false, connecting: false))
    }

    func testReconnectRetriesAreBoundedAndCanBeCancelled() {
        var plan = ReconnectPlan(); plan.request(now: 0)
        for attempt in 0..<5 { plan.failed(now: Double(attempt * 100)) }
        XCTAssertFalse(plan.pending)
        plan.request(now: 1000); XCTAssertTrue(plan.pending)
        plan.cancel(); XCTAssertFalse(plan.pending)
    }
}
