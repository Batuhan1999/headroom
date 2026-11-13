import XCTest
@testable import HeadroomCore

final class HeadphoneSettingsTests: XCTestCase {
    private func reply(_ bytes: [UInt8]) -> SonyReply? { SonyReply.parse(SonyFrame(payload: bytes)) }

    func testOverEarModelProfilesShareProtocolWithoutMatchingEarbuds() {
        XCTAssertEqual(SonyModel.identify("Sony WH-1000XM5"), .xm5)
        XCTAssertEqual(SonyModel.identify("wh-1000xm6"), .xm6)
        XCTAssertEqual(SonyModel.xm5.eqLayout, 0)
        XCTAssertEqual(SonyModel.xm6.eqLayout, 4)
        XCTAssertNil(SonyModel.identify("WF-1000XM6"))
        XCTAssertNil(SonyModel.identify("WH-1000XM4"))
    }

    func testXM6TenBandProtocolAndRoundTrip() {
        // Sony Device Center layout, also covered by Sound Connect's tests.
        XCTAssertEqual(SonyRequest.equalizer(layout: 4).payload, [0x56, 4])
        XCTAssertEqual(SonyRequest.setPreset(.bright, layout: 4).payload, [0x58, 4, 0x10, 0])
        let eq = Equalizer(preset: 0x10, layout: 4)
        XCTAssertEqual(eq.values, Array(repeating: 6, count: 10))
        XCTAssertEqual(reply([0x57, 4, 0x10, 10] + Array(repeating: 6, count: 10)), .setting(.equalizer(eq)))
        let custom = Equalizer(layout: 4, values: [0, 1, 2, 3, 4, 5, 6, 7, 8, 20])
        var notification = SonyRequest.setEqualizer(custom).payload
        XCTAssertEqual(notification, [0x58, 4, 0xa0, 10, 0, 1, 2, 3, 4, 5, 6, 7, 8, 12])
        notification[0] = 0x59
        XCTAssertEqual(reply(notification), .setting(.equalizer(Equalizer(preset: 0xa0, layout: 4, values: custom.values))))
        XCTAssertNil(reply([0x57, 4, 0x10, 10, 6]))
        XCTAssertNil(reply([0x57, 4, 0x10, 10] + Array(repeating: 13, count: 10)))
    }

    func testCapturedWHXM5Settings() {
        // WH-1000XM5 replies published by Sound Connect, firmware 2.4.1.
        XCTAssertEqual(reply([0x13, 2, 2]), .setting(.codec("AAC")))
        XCTAssertEqual(reply([0x67, 0x17, 1, 1, 1, 0, 20]), .setting(.noise(NoiseControl(mode: .ambient))))
        XCTAssertEqual(reply([0x57, 0, 0, 6, 10, 10, 10, 10, 10, 10]), .setting(.equalizer(Equalizer())))
        XCTAssertEqual(reply([0xe7, 1, 0]), .setting(.dsee(false)))
    }

    func testNoiseAndEQRoundTripAndClampAtWireBoundary() {
        for mode in ListeningMode.allCases {
            let state = NoiseControl(mode: mode, focusOnVoice: true, ambientLevel: 7)
            var bytes = SonyRequest.setNoise(state).payload; bytes[0] = 0x69
            XCTAssertEqual(reply(bytes), .setting(.noise(state)))
        }
        let eq = Equalizer(values: [-100, -10, -2, 0, 10, 100])
        var bytes = SonyRequest.setEqualizer(eq).payload; bytes[0] = 0x59
        XCTAssertEqual(bytes, [0x59, 0, 0xa0, 6, 0, 0, 8, 10, 20, 20])
        XCTAssertEqual(reply(bytes), .setting(.equalizer(Equalizer(preset: 0xa0, values: [-10, -10, -2, 0, 10, 10]))))
    }

    func testInvertedSystemSettingsAndUnsupportedValues() {
        XCTAssertEqual(SonyRequest.setSpeakToChat(true).payload, [0xf8, 0x0c, 0, 1])
        XCTAssertEqual(SonyRequest.setWearingPause(false).payload, [0xf8, 1, 1])
        XCTAssertEqual(reply([0xf9, 0x0c, 0, 1]), .setting(.speakToChat(true)))
        XCTAssertEqual(reply([0xf9, 1, 1]), .setting(.wearingPause(false)))
        XCTAssertEqual(reply([0xfd, 0x0c, 2, 3]), .setting(.chatOptions(ChatOptions(sensitivity: 2, duration: 3))))
        XCTAssertNil(reply([0xfd, 0x0c, 3, 3]))
        XCTAssertNil(reply([0x67, 0x17, 1, 1, 1, 0, 255]))
        XCTAssertNil(reply([0x57, 0, 0, 6, 10]))
        XCTAssertNil(SonyRequest.setAutoOff(0))
        XCTAssertNil(SonyRequest.setNoiseButton(0))
        XCTAssertNil(SonyRequest.setChatOptions(ChatOptions(sensitivity: 4)))
    }

    func testReadBackAfterMutationDoesNotReuseInflightQuery() {
        var session = SonySession()
        XCTAssertEqual(session.enqueue(.dsee, now: 0).count, 1)
        XCTAssertTrue(session.enqueue(.setDSEE(true), now: 0.1).isEmpty)
        XCTAssertTrue(session.enqueue(.dsee, now: 0.2).isEmpty)
        let first = session.receive(SonyFrame.ack(0).encoded, now: 0.3)
        XCTAssertEqual(first.acknowledged, [.dsee])
        XCTAssertEqual(SonyFrameReader.readForTest(first.writes[0]).payload, SonyRequest.setDSEE(true).payload)
        let second = session.receive(SonyFrame.ack(1).encoded, now: 0.4)
        XCTAssertEqual(second.acknowledged, [.setDSEE(true)])
        XCTAssertEqual(SonyFrameReader.readForTest(second.writes[0]).payload, SonyRequest.dsee.payload)
    }

    func testSourceResultIncludesRejectionAndTarget() {
        let address = "AA:BB:CC:DD:EE:FF"
        for code: UInt8 in [0, 1, 2, 3, 4, 255] {
            let frame = SonyFrame(kind: 0x0e, payload: [0x3d, 1, code] + Array(address.utf8))
            XCTAssertEqual(SonyReply.parse(frame), .switched(result: code, target: address))
        }
        XCTAssertNil(SonyReply.parse(SonyFrame(kind: 0x0e, payload: [0x3d, 1])))
        XCTAssertEqual(SonyRequest.pause.payload, [0xa4, 1, 0, 1])
    }

    func testManualMacHandoffSurvivesStalePhoneStatusAndExpires() {
        var handoff = SourceHandoff()
        handoff.begin(target: "AA:BB:CC:DD:EE:FF", isMac: true, now: 100)
        XCTAssertTrue(handoff.holdsMac(now: 102))
        XCTAssertTrue(handoff.isPending(now: 109))
        XCTAssertFalse(handoff.holdsMac(now: 110))
        handoff.cancel()
        XCTAssertFalse(handoff.holdsMac(now: 102))
        handoff.begin(target: "11:22:33:44:55:66", isMac: false, now: 120)
        XCTAssertFalse(handoff.holdsMac(now: 121))
    }

    func testAudibleAlreadySelectedMacIsUnmutedWithoutStealingPhoneOrCall() {
        XCTAssertTrue(SourceHandoff.shouldRestoreMac(localSelected: true, suspended: true, audible: true, inCall: false))
        XCTAssertFalse(SourceHandoff.shouldRestoreMac(localSelected: false, suspended: true, audible: true, inCall: false))
        XCTAssertFalse(SourceHandoff.shouldRestoreMac(localSelected: true, suspended: true, audible: nil, inCall: false))
        XCTAssertFalse(SourceHandoff.shouldRestoreMac(localSelected: true, suspended: true, audible: true, inCall: true))
    }

    func testLowBatteryCrossingsDoNotSpamAndResetAfterCharging() {
        var low = LowBattery()
        XCTAssertNil(low.update(70))
        XCTAssertEqual(low.update(19), 20)
        XCTAssertNil(low.update(18))
        XCTAssertEqual(low.update(8), 10)
        XCTAssertEqual(low.update(3), 5)
        XCTAssertNil(low.update(2))
        XCTAssertNil(low.update(12, charging: true))
        XCTAssertEqual(low.update(12), 20)
        var lowAtLaunch = LowBattery()
        XCTAssertEqual(lowAtLaunch.update(4), 5)
        XCTAssertNil(lowAtLaunch.update(4))
    }

    func testNewMacAudioHasNoDebounceAndDoesNotBounceContinuousPlayback() {
        var detector = MacAudioStartDetector()
        XCTAssertFalse(detector.observe(silence: false, now: 0))
        XCTAssertFalse(detector.observe(silence: true, now: 0.1))
        XCTAssertTrue(detector.observe(silence: false, now: 0.2))
        XCTAssertFalse(detector.observe(silence: false, now: 0.3))
        // The phone can take over a continuous Mac stream without a bounce back.
        XCTAssertFalse(detector.observe(silence: false, now: 1))
        XCTAssertFalse(detector.observe(silence: true, now: 1.1))
        XCTAssertTrue(detector.observe(silence: false, now: 1.2))
    }

    func testUnknownMeterAndSleepDoNotInventANewAudioStart() {
        var detector = MacAudioStartDetector()
        _ = detector.observe(silence: true, now: 0)
        XCTAssertFalse(detector.observe(silence: nil, now: 0.1))
        XCTAssertFalse(detector.observe(silence: false, now: 0.2))
        _ = detector.observe(silence: true, now: 1)
        XCTAssertFalse(detector.observe(silence: false, now: 30))
    }

    func testCallsRestorePreviousNoiseStateAndHonorManualChange() {
        var policy = CallAmbience()
        let original = NoiseControl(mode: .noiseCancelling, ambientLevel: 12)
        let ambient = NoiseControl(mode: .ambient, ambientLevel: 12)
        XCTAssertEqual(policy.update(recording: true, state: original), ambient)
        XCTAssertNil(policy.update(recording: true, state: ambient))
        XCTAssertEqual(policy.update(recording: false, state: ambient), original)
        XCTAssertEqual(policy.update(recording: true, state: original), ambient)
        policy.manualChange()
        XCTAssertNil(policy.update(recording: false, state: ambient))
    }
}

private extension SonyFrameReader {
    static func readForTest(_ bytes: [UInt8]) -> SonyFrame {
        var reader = SonyFrameReader()
        return reader.push(bytes)[0]
    }
}
