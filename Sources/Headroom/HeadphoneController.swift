import AppKit
import CoreBluetooth
import IOBluetooth
import IOKit
import Observation
import ServiceManagement
import HeadroomCore

struct HeadphoneChoice: Identifiable {
    let id: String
    let name: String
    let connected: Bool
}

@Observable
final class HeadphoneController: NSObject, IOBluetoothRFCOMMChannelDelegate, CBCentralManagerDelegate {
    var choices: [HeadphoneChoice] = []
    var selectedID: String = UserDefaults.standard.string(forKey: "HeadphoneAddress") ?? "" {
        didSet {
            guard selectedID != oldValue, !demo else { return }
            stopLink(); cachedDevice = nil; pairedRefreshAt = 0; UserDefaults.standard.set(selectedID, forKey: "HeadphoneAddress")
            battery = nil; firmware = nil; lowBattery = LowBattery(); note("Selected WH-1000XM5"); refresh()
        }
    }
    var protect = UserDefaults.standard.object(forKey: "Protect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(protect, forKey: "Protect"); enforce() }
    }
    var reconnect = UserDefaults.standard.object(forKey: "Reconnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(reconnect, forKey: "Reconnect") }
    }
    var phoneOnly = ProcessInfo.processInfo.arguments.contains("--phone-only") || UserDefaults.standard.bool(forKey: "PhoneOnly") {
        didSet { UserDefaults.standard.set(phoneOnly, forKey: "PhoneOnly"); idle.reset(); enforce() }
    }
    var idleEnabled = UserDefaults.standard.bool(forKey: "IdleEnabled") {
        didSet { if !demo { UserDefaults.standard.set(idleEnabled, forKey: "IdleEnabled") }; idle.reset() }
    }
    var keepANC = UserDefaults.standard.bool(forKey: "KeepANC") {
        didSet { if !demo { UserDefaults.standard.set(keepANC, forKey: "KeepANC") }; idle.reset() }
    }
    var idleMinutes = UserDefaults.standard.object(forKey: "IdleMinutes") as? Int ?? 15 {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "IdleMinutes"); idle.reset() }
    }
    var status = "Looking for your WH-1000XM5"
    var bluetoothStatus = "Checking Bluetooth permission…"
    var bluetoothReady = false
    var linked = false
    var connected = false
    var battery: Int?
    var firmware: String?
    var playback = Playback.unknown
    var peers: [Peer] = []
    var idleStatus = "Idle power-off is off"
    var macAudio: Bool?
    var recordingActivity: Bool?
    var events: [String] = []
    var locked = false
    var sleeping = false
    var lidClosed = false
    var lastPlayback: TimeInterval?
    var lastPeers: TimeInterval?
    var lastAction = "No connection changes yet"
    var notice: String?
    var demo = false
    var levelStatus = "Audio level detection is off"
    var levelDB: Double = -100
    var levelsEnabled = UserDefaults.standard.bool(forKey: "AudioLevels")
    var measuredSilence: Bool?
    var remoteVerified = false
    var phoneTestStatus: String?
    var hardwareAutoOffChoices: [UInt8] = []
    var hardwareAutoOffCode: UInt8?
    var powerEventsAvailable = false
    var macOutputSuspended = false
    var smartSwitching = UserDefaults.standard.object(forKey: "SmartSwitching") as? Bool ?? true {
        didSet { if !demo { UserDefaults.standard.set(smartSwitching, forKey: "SmartSwitching") } }
    }

    var codec: String?
    var noiseControl: NoiseControl?
    var equalizer: Equalizer?
    var dsee: Bool?
    var speakToChat: Bool?
    var chatOptions: ChatOptions?
    var wearingPause: Bool?
    var noiseButton: UInt8?
    var sourceStatus: String?
    var showBattery = UserDefaults.standard.object(forKey: "ShowBattery") as? Bool ?? true {
        didSet { if !demo { UserDefaults.standard.set(showBattery, forKey: "ShowBattery") } }
    }
    var lowBatteryAlerts = UserDefaults.standard.object(forKey: "LowBatteryAlerts") as? Bool ?? true {
        didSet { if !demo { UserDefaults.standard.set(lowBatteryAlerts, forKey: "LowBatteryAlerts") } }
    }
    var modeHUD = UserDefaults.standard.object(forKey: "ModeHUD") as? Bool ?? true {
        didSet { if !demo { UserDefaults.standard.set(modeHUD, forKey: "ModeHUD") } }
    }
    var ambientDuringCalls = UserDefaults.standard.bool(forKey: "AmbientDuringCalls") {
        didSet { if !demo { UserDefaults.standard.set(ambientDuringCalls, forKey: "AmbientDuringCalls") } }
    }
    @ObservationIgnored var onLowBattery: ((Int) -> Void)?
    @ObservationIgnored var onModeChanged: ((ListeningMode) -> Void)?
    @ObservationIgnored private var sourceHandoff = SourceHandoff()
    @ObservationIgnored private var sourceAfterPause: Peer?
    @ObservationIgnored private var macStartDetector = MacAudioStartDetector()
    @ObservationIgnored private var macStartPendingUntil: TimeInterval = 0
    @ObservationIgnored private var lowBattery = LowBattery()
    @ObservationIgnored private var callAmbience = CallAmbience()
    @ObservationIgnored private var callWasEnabled = false
    @ObservationIgnored private var featurePollAt: TimeInterval = 0
    @ObservationIgnored private var cachedDevice: IOBluetoothDevice?
    @ObservationIgnored private var pairedRefreshAt: TimeInterval = 0
    @ObservationIgnored private var audioPollInFlight = false
    @ObservationIgnored private var audioSnapshotAt: TimeInterval = 0
    @ObservationIgnored private var headphoneOutputUID: String?
    @ObservationIgnored private let audioQueue = DispatchQueue(label: "io.github.Batuhan1999.headroom.audio", qos: .utility)
    @ObservationIgnored private var writeID: UInt = 0
    @ObservationIgnored private var writeBuffers: [UInt: (IOBluetoothRFCOMMChannel, NSMutableData)] = [:]
    @ObservationIgnored private var maxTickMS: Double = 0
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var channel: IOBluetoothRFCOMMChannel?
    @ObservationIgnored private var session = SonySession()
    @ObservationIgnored private var idle = IdlePolicy()
    @ObservationIgnored private var tickTimer: Timer?
    @ObservationIgnored private var pollAt: TimeInterval = 0
    @ObservationIgnored private var retryAt: TimeInterval = 0
    @ObservationIgnored private var openedAt: TimeInterval = 0
    @ObservationIgnored private var openDeadline: TimeInterval?
    @ObservationIgnored private var listWithClass: Bool?
    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []
    @ObservationIgnored private var reconnectPlan = ReconnectPlan()
    @ObservationIgnored private var connectingAt: TimeInterval?
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var peerSnapshot: [Peer]?
    @ObservationIgnored private var diagnosticURL: URL?
    @ObservationIgnored private var lastSnapshot = ""
    @ObservationIgnored private var snapshotAt: TimeInterval = 0
    @ObservationIgnored private var shutdownPending = false
    @ObservationIgnored private var shutdownAt: TimeInterval = 0
    @ObservationIgnored private var disconnectedAfterPowerOff = false
    @ObservationIgnored private var bluetoothStartedAt: TimeInterval = 0
    @ObservationIgnored private var preferRemoteAfterReconnect = false
    @ObservationIgnored private var powerObserver: PowerObserver?
    @ObservationIgnored private var meter: AnyObject?
    @ObservationIgnored private var levelRetryAt: TimeInterval = 0
    @ObservationIgnored private var phoneTestRunning = false
    @ObservationIgnored private var phoneValidation = RemotePlaybackValidation()
    @ObservationIgnored private var verificationKey: String?
    @ObservationIgnored private var pendingAutoOffAt: TimeInterval?
    @ObservationIgnored private var quickTestSeconds: TimeInterval?
    @ObservationIgnored private var localSilentSince: TimeInterval?
    @ObservationIgnored private var lastHandoff: TimeInterval = 0
    @ObservationIgnored private var sourceChangedAt: TimeInterval = 0
    @ObservationIgnored private var calibrationRequested = false
    @ObservationIgnored private let bluetoothQueue = DispatchQueue(label: "io.github.Batuhan1999.headroom.bluetooth")
    @ObservationIgnored private var bluetoothGeneration = 0
    @ObservationIgnored private let diagnosticQueue = DispatchQueue(label: "io.github.Batuhan1999.headroom.diagnostics", qos: .utility)

    var policy: ConnectionPolicy {
        var result = ConnectionPolicy()
        result.protect = protect; result.locked = locked; result.sleeping = sleeping
        result.lidClosed = lidClosed; result.phoneOnly = phoneOnly; result.shutdown = shutdownPending
        return result
    }
    var selectedName: String { choices.first { $0.id == selectedID }?.name ?? "WH-1000XM5" }
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var selectedDevice: IOBluetoothDevice? {
        guard bluetoothReady, cachedDevice?.addressString == selectedID else { return nil }
        return cachedDevice
    }
    var localAddress: String? {
        guard !demo, bluetoothReady else { return nil }
        return IOBluetoothHostController.default()?.addressAsString()?.replacingOccurrences(of: "-", with: ":").uppercased()
    }
    var onlyLocalMac: Bool {
        guard peers.count == 1, let localAddress else { return false }
        return peers[0].id.uppercased() == localAddress
    }
    var freshStatus: Bool {
        guard let lastPlayback else { return false }
        return now - lastPlayback <= 12
    }

    init(demo: Bool = false, diagnosticURL: URL? = nil) {
        self.demo = demo; self.diagnosticURL = diagnosticURL
        super.init()
        if demo {
            choices = [.init(id: "demo", name: "WH-1000XM5", connected: true)]
            selectedID = "demo"; linked = true; connected = true; battery = 72; firmware = "demo"
            status = "Preview · no headphones controlled"; bluetoothStatus = "Preview data"; bluetoothReady = true
            playback = .paused; idleStatus = "Another source may be active · automatic shutdown paused"
            peers = [.init(id: "mac", name: "MacBook Pro", selected: false), .init(id: "phone", name: "iPhone", selected: true)]
            codec = "AAC"
            noiseControl = NoiseControl(mode: .noiseCancelling, ambientLevel: 12)
            equalizer = Equalizer(preset: EQPreset.manual.rawValue, values: [3, 0, 1, 2, 1, 0])
            dsee = false; speakToChat = false; wearingPause = true
            chatOptions = ChatOptions(); noiseButton = 2
            hardwareAutoOffChoices = [0x10, 0x11]; hardwareAutoOffCode = 0x10
            note("Preview only. No Bluetooth commands are sent.")
            return
        }
        UserDefaults.standard.set(phoneOnly, forKey: "PhoneOnly")
        note("Started Headroom")
        powerObserver = PowerObserver(onSleep: { [weak self] in self?.systemWillSleep() },
                                      onWake: { [weak self] in self?.systemDidWake() })
        powerEventsAvailable = powerObserver?.available == true
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemWillSleep()
        })
        tokens.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.systemDidWake()
        })
        let distributed = DistributedNotificationCenter.default()
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = true; self?.note("Mac locked"); self?.enforce()
        })
        tokens.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.locked = false; self?.note("Mac unlocked"); self?.enforce()
        })
        if let state = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = state["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        lidClosed = Self.readLid() ?? false
        retryBluetooth()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common); tickTimer = timer
        refresh()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.centralManagerDidUpdateState(central) }
            return
        }
        if central.state == .unknown, bluetoothReady { return }
        bluetoothReady = central.state == .poweredOn
        switch CBCentralManager.authorization {
        case .denied, .restricted:
            bluetoothStatus = "Bluetooth access needed in System Settings → Privacy & Security → Bluetooth"
        case .notDetermined: bluetoothStatus = "Allow Bluetooth access to find your XM5s"
        default:
            bluetoothStatus = central.state == .poweredOn ? "Bluetooth is on" : "Turn on Bluetooth in System Settings"
        }
        if central.state == .poweredOn, connectNote == nil {
            connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        }
        note(bluetoothStatus); refresh()
    }

    func retryBluetooth() {
        guard !demo else { return }
        bluetoothStartedAt = now
        bluetoothStatus = "Checking Bluetooth permission…"
        bluetoothReady = false
        central = CBCentralManager(delegate: self, queue: bluetoothQueue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        bluetoothGeneration += 1
        let generation = bluetoothGeneration
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let poweredOn = IOBluetoothHostController.default()?.powerState.rawValue == 1
            DispatchQueue.main.async {
                guard let self, generation == self.bluetoothGeneration,
                      CBCentralManager.authorization == .allowedAlways,
                      poweredOn, !self.bluetoothReady else { return }
                self.bluetoothReady = true; self.bluetoothStatus = "Bluetooth is on"
                if self.connectNote == nil {
                    self.connectNote = IOBluetoothDevice.register(forConnectNotifications: self,
                        selector: #selector(HeadphoneController.deviceConnected(_:device:)))
                }
                self.note("Bluetooth is on"); self.refresh(); self.enforce()
            }
        }
    }

    func refresh() {
        guard !demo, !stopping else { return }
        guard bluetoothReady else {
            connected = false; status = "Waiting for Bluetooth"; return
        }
        if now >= pairedRefreshAt {
            pairedRefreshAt = now + 15
            let devices = ((IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []).filter(Self.isXM5)
            choices = devices.map { HeadphoneChoice(id: $0.addressString ?? "", name: $0.nameOrAddress, connected: $0.isConnected()) }
            cachedDevice = devices.first { $0.addressString == selectedID }
            if selectedID.isEmpty, choices.count == 1 { selectedID = choices[0].id }
        }
        connected = selectedDevice?.isConnected() == true
        if shutdownPending {
            if !connected {
                disconnectedAfterPowerOff = true
                status = "Headphones disconnected after power-off request"
                if lastAction != status { lastAction = status; note(status) }
            } else if now - shutdownAt > 8 {
                notice = "Power-off was requested, but the headphones are still connected. Check them before retrying."
            }
        } else if choices.isEmpty {
            status = "No paired WH-1000XM5 found"
        } else if selectedID.isEmpty { status = "Choose your WH-1000XM5" }
        else if policy.blocked { status = phoneOnly ? "Phone only · Mac connection blocked" : "Mac locked, asleep or lid closed · connection blocked" }
        else if linked { status = "Connected · monitoring headphone status" }
        else if connected { status = "Opening Sony control channel…" }
        else { status = "XM5s are disconnected from this Mac" }
    }

    private func tick() {
        guard !demo, !stopping else { return }
        let tickStarted = now
        defer { maxTickMS = max(maxTickMS, (now - tickStarted) * 1000) }
        if let central, central.state != .unknown, bluetoothReady != (central.state == .poweredOn) { centralManagerDidUpdateState(central) }
        if !bluetoothReady, central?.state == .unknown, now - bluetoothStartedAt > 8 {
            bluetoothStatus = "Bluetooth hasn't responded. Turn it on in Bluetooth Settings, then retry."
        }
        let lid = Self.readLid() ?? lidClosed
        if lid != lidClosed { lidClosed = lid; note(lid ? "Lid closed" : "Lid opened") }
        refresh(); enforce()
        if bluetoothReady, !policy.blocked, connected, channel == nil, now >= retryAt { openControl() }
        if let deadline = openDeadline, now >= deadline { failLink("Sony control channel did not open") }
        if let since = connectingAt, now - since > 15 {
            connectingAt = nil; reconnectPlan.failed(now: now)
            notice = reconnectPlan.pending && reconnect ? "Bluetooth is still waking. Retrying shortly…" : "Connection timed out. Turn on the XM5s and retry."
        }
        if linked {
            write(session.tick(now: now))
            if session.timedOut { failLink("Sony stopped acknowledging requests; retrying read-only connection") }
            else if now - pollAt >= 4 { pollAt = now; queryStatus() }
        }
        pollAudioActivity()
        if now - audioSnapshotAt > 3 { macAudio = nil; recordingActivity = nil }
        updateMeter()
        checkPhoneValidation()
        reconcileHandoff()
        handoffSilentMac()
        if linked, ambientDuringCalls || callWasEnabled {
            let recording = ambientDuringCalls ? (playback == .call ? true : recordingActivity) : false
            if let next = callAmbience.update(recording: recording, state: noiseControl) {
                changeNoise(next, manual: false)
            }
            callWasEnabled = ambientDuringCalls
        }
        if linked, now - featurePollAt >= 30 {
            featurePollAt = now
            SonyRequest.featureQueries.forEach(requestSony)
            requestSony(.autoOffSetting)
        }
        let input = IdleInput(enabled: idleEnabled, keepANC: keepANC, connected: linked,
            playback: playback, statusAge: lastPlayback.map { now - $0 } ?? .infinity,
            peersAge: lastPeers.map { now - $0 } ?? .infinity, onlyLocalMac: onlyLocalMac,
            macAudioActive: macAudio, threshold: quickTestSeconds ?? Double(idleMinutes * 60),
            localSelected: localIsSelected, measuredSilence: measuredSilence,
            remoteVerified: remoteVerified, recording: recordingActivity)
        switch idle.evaluate(input, now: now) {
        case .hold(let reason): idleStatus = reason; pendingAutoOffAt = nil
        case .counting(let remaining):
            if pendingAutoOffAt != nil { idleStatus = "Checking activity before power-off…" }
            else { idleStatus = remaining <= 60 ? "Power off in \(Int(ceil(remaining))) sec of silence" : "Power off in \(Int(ceil(remaining / 60))) min of silence" }
            if let requestedAt = pendingAutoOffAt, remaining == 0,
               now - requestedAt >= 2, (lastPlayback ?? 0) >= requestedAt, (lastPeers ?? 0) >= requestedAt {
                pendingAutoOffAt = nil; quickTestSeconds = nil
                note("Final idle check passed; sending automatic power-off")
                powerOff()
            }
        case .powerOff:
            idleStatus = "Checking both sources before power-off…"
            pendingAutoOffAt = now; queryStatus()
        }
        saveSnapshot()
    }

    private func enforce() {
        guard !demo, !stopping, bluetoothReady else { return }
        if policy.blocked {
            if connected, !shutdownPending { releaseMacConnection() }
            else if !shutdownPending { stopLink() }
        } else if reconnect, !locked, !sleeping, !lidClosed,
                  reconnectPlan.shouldAttempt(now: now, blocked: policy.blocked,
                    connected: connected, connecting: connectingAt != nil) {
            connect(retryAttempt: true)
        }
    }

    private func releaseMacConnection() {
        guard let device = selectedDevice else { return }
        reconnectPlan.request(now: now, delay: 3)
        stopLink()
        let result = device.closeConnection()
        if result == kIOReturnSuccess { lastAction = "Disconnected the Mac; pairing retained" }
        else { lastAction = "Mac disconnect returned error \(result)" }
        note(lastAction)
    }

    func connect(preferRemote: Bool = true, retryAttempt: Bool = false) {
        guard !demo, bluetoothReady, !policy.blocked, connectingAt == nil, let device = selectedDevice else { return }
        notice = nil
        if !retryAttempt { reconnectPlan.request(now: now) }
        if device.isConnected() { reconnectPlan.complete(); retryAt = 0; refresh(); return }
        connectingAt = now
        preferRemoteAfterReconnect = preferRemote
        let result = device.openConnection(self)
        if result != kIOReturnSuccess {
            connectingAt = nil; reconnectPlan.failed(now: now)
            notice = reconnectPlan.pending && reconnect ? "Bluetooth connection failed (\(result)). Retrying shortly…" : "Could not connect (\(result)). Are the XM5s on?"
        }
        note("Requested Mac connection")
    }

    func clearShutdown() {
        shutdownPending = false; disconnectedAfterPowerOff = false; shutdownAt = 0; notice = nil; retryAt = 0
        note("Ready to reconnect after you turn the headphones on")
        refresh()
    }

    var needsPowerOn: Bool { shutdownPending }

    @objc private func connectionComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        guard device.addressString == selectedID else { return }
        connectingAt = nil; retryAt = now + 1
        if status != kIOReturnSuccess {
            reconnectPlan.failed(now: now)
            notice = reconnectPlan.pending && reconnect ? "Bluetooth connection failed (\(status)). Retrying shortly…" : "Bluetooth connection failed (\(status)). Use Connect to retry."
            note("Bluetooth reconnect failed (\(status)); attempt \(reconnectPlan.failures) of 5")
        } else { reconnectPlan.complete() }
        enforce(); refresh()
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard device.addressString == selectedID else { return }
        if shutdownPending, disconnectedAfterPowerOff {
            clearShutdown(); idle.reset()
            self.note("Headphones came back on; resumed monitoring")
        }
        retryAt = now + 1
        if policy.blocked { self.note("Blocked an XM5 reconnection to the Mac"); enforce() }
        refresh()
    }

    private func openControl() {
        guard let device = selectedDevice, device.isConnected(), !policy.blocked else { return }
        guard let uuid = Self.serviceUUID else { return }
        guard let record = device.getServiceRecord(for: uuid) else {
            device.performSDPQuery(self, uuids: [uuid]); retryAt = now + 8; return
        }
        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            notice = "Sony control service has no serial channel"; retryAt = now + 15; return
        }
        var opened: IOBluetoothRFCOMMChannel?
        let result = device.openRFCOMMChannelAsync(&opened, withChannelID: channelID, delegate: self)
        if result == kIOReturnSuccess, let opened {
            channel = opened; openDeadline = now + 12
        } else {
            opened?.close(); retryAt = now + 15
            notice = "Sony control channel unavailable (\(result)). Try closing Sony Sound Connect on the iPhone."
            note(notice!)
        }
    }

    @objc private func sdpQueryComplete(_ device: IOBluetoothDevice, status: IOReturn) {
        if device.addressString == selectedID { retryAt = now + 1 }
    }

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        guard rfcommChannel === channel else { return }
        openDeadline = nil
        guard error == kIOReturnSuccess, !policy.blocked else { failLink("Control channel could not open (\(error))"); return }
        linked = true; session = SonySession(); openedAt = now; pollAt = now; notice = nil
        note("Sony control channel opened; reading status")
        for request in [SonyRequest.initialize, .firmware, .battery, .playback, .autoOffCapabilities, .autoOffSetting] + SonyRequest.featureQueries { requestSony(request) }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data pointer: UnsafeMutableRawPointer!, length: Int) {
        guard rfcommChannel === channel, let pointer, length > 0 else { return }
        let result = session.receive(Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length)), now: now)
        write(result.writes)
        if result.acknowledged.contains(.pause), let peer = sourceAfterPause {
            sourceAfterPause = nil
            performSourceSwitch(peer)
        }
        for reply in result.replies {
            switch reply {
            case .ready(let table2):
                note("Sony v2 handshake received")
                if table2 { requestSony(.functions) }
            case .firmware(let version): firmware = version
            case .battery(let value, let charging):
                battery = value
                if lowBattery.update(value, charging: charging) != nil, lowBatteryAlerts { onLowBattery?(value) }
            case .playback(let value):
                lastPlayback = now
                if playback != value { note("Headphone playback: \(value.rawValue)"); idle.reset() }
                playback = value
            case .functions(let functions):
                if functions.contains(0x32) || functions.contains(0x33) { listWithClass = true }
                else if functions.contains(0x30) { listWithClass = false }
                if let listWithClass { requestSony(.peers(withClass: listWithClass)) }
            case .peers(let devices):
                peers = devices; lastPeers = now
                if peerSnapshot != devices {
                    if peerSnapshot?.first(where: { $0.selected })?.id != devices.first(where: { $0.selected })?.id {
                        sourceChangedAt = now
                    }
                    idle.reset(); peerSnapshot = devices
                    note("Headphones report \(devices.count) connected source(s)")
                }
                if preferRemoteAfterReconnect,
                   let remote = preferredRemoteSource(peers: devices, localAddress: localAddress) {
                    preferRemoteAfterReconnect = false
                    if !remote.selected, let request = SonyRequest.playFrom(remote.id) {
                        requestSony(request); note("Returning audio priority to the other source after Mac reconnect")
                    }
                }
            case .switched(let result, let target):
                if sourceHandoff.target?.caseInsensitiveCompare(target) == .orderedSame {
                    if result == 0 {
                        sourceStatus = "Source switch accepted"
                    } else {
                        sourceHandoff.cancel()
                        let reason = [1: "the headphones rejected it", 2: "a call is active", 3: "that device has no audio connection", 4: "the voice assistant has priority"][Int(result)] ?? "the headphones returned code \(result)"
                        notice = "Could not switch: \(reason)."
                        sourceStatus = "Switch failed"
                        setMacOutputSuspended(remotePeer?.selected == true)
                        note(notice!)
                    }
                }
                queryStatus()
            case .setting(let setting): receiveSetting(setting)
            case .autoOffCapabilities(let values):
                hardwareAutoOffChoices = values
                note("Headphone automatic power-off choices: \(values.map(String.init).joined(separator: ","))")
            case .autoOffSetting(let value): hardwareAutoOffCode = value
            }
        }
        restoreRemoteVerification(); checkPhoneValidation()
        refresh(); saveSnapshot(force: true)
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard rfcommChannel === channel else { return }
        stopLink(); retryAt = now + 5; note("Sony control channel closed"); refresh()
    }

    private func queryStatus() {
        requestSony(.playback); requestSony(.battery)
        if let listWithClass { requestSony(.peers(withClass: listWithClass)) }
        if now - openedAt > 12, lastPlayback == nil { notice = "Headphones have not reported playback status; idle power-off is blocked." }
    }

    private func requestSony(_ request: SonyRequest) {
        guard linked, !demo, (!policy.blocked || (shutdownPending && request == .powerOff)) else { return }
        write(session.enqueue(request, now: now))
    }

    private func write(_ frames: [[UInt8]]) {
        guard let channel else { return }
        for frame in frames {
            writeID += 1
            let id = writeID
            let buffer = NSMutableData(data: Data(frame))
            writeBuffers[id] = (channel, buffer)
            let result = channel.writeAsync(buffer.mutableBytes, length: UInt16(buffer.length),
                                            refcon: UnsafeMutableRawPointer(bitPattern: id))
            if result != kIOReturnSuccess {
                writeBuffers.removeValue(forKey: id)
                failLink("Bluetooth write failed (\(result))"); return
            }
        }
    }

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {
        if let refcon { writeBuffers.removeValue(forKey: UInt(bitPattern: refcon)) }
        if rfcommChannel === channel, error != kIOReturnSuccess { failLink("Bluetooth write failed (\(error))") }
    }

    private func pollAudioActivity() {
        guard !audioPollInFlight else { return }
        audioPollInFlight = true
        let address = selectedID
        audioQueue.async { [weak self] in
            let snapshot = MacAudio.snapshot(address: address)
            DispatchQueue.main.async {
                guard let self else { return }
                self.audioPollInFlight = false
                guard address == self.selectedID else { return }
                self.macAudio = snapshot.active; self.recordingActivity = snapshot.recording
                self.headphoneOutputUID = snapshot.outputUID; self.audioSnapshotAt = self.now
            }
        }
    }

    private func failLink(_ message: String) {
        notice = message; note(message); stopLink(); retryAt = now + 15
    }

    private func stopLink() {
        let old = channel; channel = nil; linked = false; openDeadline = nil
        session = SonySession(); listWithClass = nil; playback = .unknown
        lastPlayback = nil; lastPeers = nil; peers = []; peerSnapshot = nil; idle.reset()
        stopMeter(); headphoneOutputUID = nil; audioSnapshotAt = 0; recordingActivity = nil; pendingAutoOffAt = nil; localSilentSince = nil; sourceHandoff.cancel(); sourceStatus = nil; sourceAfterPause = nil
        macStartDetector = MacAudioStartDetector(); macStartPendingUntil = 0
        codec = nil; noiseControl = nil; equalizer = nil; dsee = nil; speakToChat = nil
        chatOptions = nil; wearingPause = nil; noiseButton = nil; hardwareAutoOffCode = nil
        hardwareAutoOffChoices = []; callAmbience = CallAmbience()
        old?.close()
        writeBuffers = writeBuffers.filter { $0.value.0 !== old }
    }

    func powerOff() {
        guard linked, !demo, !policy.blocked else { return }
        quickTestSeconds = nil; reconnectPlan.cancel()
        lastAction = "Sent power-off request; waiting for disconnection"
        note(lastAction)
        requestSony(.powerOff)
        disconnectedAfterPowerOff = false; shutdownPending = true; shutdownAt = now
        saveSnapshot(force: true)
    }

    func switchTo(_ peer: Peer, manual: Bool = true) {
        guard linked, peers.contains(peer), !policy.blocked, !demo,
              SonyRequest.playFrom(peer.id) != nil else { return }
        guard playback != .call, recordingActivity != true else {
            notice = "Finish the call before switching audio sources."; return
        }
        let isMac = peer.id.caseInsensitiveCompare(localAddress ?? "") == .orderedSame
        notice = nil
        sourceHandoff.begin(target: peer.id, isMac: isMac, now: now)
        sourceStatus = "Switching to \(peer.name)…"
        // Explicit choices and fresh Mac playback release the old stream before taking playback rights.
        lastHandoff = now; localSilentSince = nil; idle.reset()
        if manual, !peer.selected, playback == .playing {
            sourceAfterPause = peer
            requestSony(.pause)
        } else {
            sourceAfterPause = nil
            performSourceSwitch(peer)
        }
    }

    private func performSourceSwitch(_ peer: Peer) {
        guard sourceHandoff.isPending(now: now), let request = SonyRequest.playFrom(peer.id) else { return }
        let isMac = peer.id.caseInsensitiveCompare(localAddress ?? "") == .orderedSame
        setMacOutputSuspended(!isMac)
        requestSony(request); queryStatus(); note("Requested source switch")
    }

    private func reconcileHandoff() {
        guard let target = sourceHandoff.target else { return }
        if !sourceHandoff.isPending(now: now) {
            let confirmed = peers.contains { $0.selected && $0.id.caseInsensitiveCompare(target) == .orderedSame }
            sourceHandoff.cancel(); sourceAfterPause = nil
            sourceStatus = confirmed ? nil : "Source did not change; try pausing the other device first."
            if !confirmed { setMacOutputSuspended(remotePeer?.selected == true) }
        } else if peers.contains(where: { $0.selected && $0.id.caseInsensitiveCompare(target) == .orderedSame }) {
            sourceStatus = sourceHandoff.targetIsMac ? "Mac selected" : "Phone selected"
        }
    }

    var localIsSelected: Bool {
        guard let localAddress else { return false }
        return peers.contains { $0.selected && $0.id.caseInsensitiveCompare(localAddress) == .orderedSame }
    }

    private var remotePeer: Peer? { preferredRemoteSource(peers: peers, localAddress: localAddress) }

    func useMac() {
        phoneOnly = false
        if shutdownPending { clearShutdown() }
        if linked, let localAddress, let peer = peers.first(where: { $0.id.caseInsensitiveCompare(localAddress) == .orderedSame }) {
            switchTo(peer)
        } else { connect(preferRemote: false) }
    }

    func setLevelsEnabled(_ enabled: Bool) {
        guard !demo else { return }
        levelsEnabled = enabled; UserDefaults.standard.set(enabled, forKey: "AudioLevels")
        calibrationRequested = enabled; levelRetryAt = 0
        stopMeter(); updateMeter(); idle.reset()
    }

    func retryLevels() {
        guard !demo else { return }
        calibrationRequested = true; levelRetryAt = 0; stopMeter(); updateMeter()
    }

    private func updateMeter() {
        guard levelsEnabled, linked, !policy.blocked else {
            stopMeter()
            levelStatus = levelsEnabled ? "Connect the Mac to measure headphone output" : "Audio level detection is off"
            return
        }
        guard #available(macOS 14.2, *) else { levelStatus = "Audio levels require macOS 14.2 or later"; return }
        guard let uid = headphoneOutputUID else {
            stopMeter(); levelStatus = "Waiting for the headphone audio output"; return
        }
        var active = meter as? SilenceMeter
        if active?.deviceUID != uid || active?.running != true {
            guard now >= levelRetryAt else { return }
            active?.stop(); active = SilenceMeter(); meter = active
            active?.start(deviceUID: uid, calibrate: false)
            calibrationRequested = true
            if active?.running != true { levelRetryAt = now + 15 }
        }
        guard let active else { return }
        levelStatus = active.status
        let value = active.consumePeak()
        levelDB = value.peak > 0 ? max(-100, Double(20 * log10(value.peak))) : -100
        measuredSilence = active.running && value.heardSound && !active.calibrating && now - value.sampledAt < 3 ? value.peak < 0.0001 : nil
        if smartSwitching, remotePeer?.selected == true, !sourceHandoff.holdsMac(now: now), now - lastHandoff > 2 {
            setMacOutputSuspended(true)
        }
        if calibrationRequested, active.running, freshStatus, playback.isIdle, recordingActivity == false {
            active.playCalibration(); calibrationRequested = false
        }
    }

    private func stopMeter() {
        if #available(macOS 14.2, *) { (meter as? SilenceMeter)?.stop() }
        meter = nil; measuredSilence = nil; levelDB = -100; macOutputSuspended = false
    }

    private func setMacOutputSuspended(_ value: Bool) {
        guard #available(macOS 14.2, *), let active = meter as? SilenceMeter else { return }
        let wasMuted = active.muted
        if active.setMuted(value) {
            macOutputSuspended = active.muted
            if wasMuted != value { note(value ? "Released Mac audio output while retaining headphone controls" : "Restored Mac audio output") }
        }
    }

    private func systemWillSleep() {
        if !sleeping { note("System sleep requested; releasing the Mac connection before acknowledgement") }
        sleeping = true; idle.reset(); pendingAutoOffAt = nil
        stopMeter(); enforce()
    }

    private func systemDidWake() {
        guard !stopping else { return }
        sleeping = false; idle.reset(); pendingAutoOffAt = nil
        if reconnectPlan.pending { reconnectPlan.request(now: now, delay: 3) }
        lidClosed = Self.readLid() ?? lidClosed
        if let state = CGSessionCopyCurrentDictionary() as? [String: Any] {
            locked = state["CGSSessionScreenIsLocked"] as? Bool ?? locked
        }
        note("System woke; checking lid and lock before reconnecting")
        enforce()
    }

    func beginPhoneTest() {
        guard !demo else { return }
        phoneTestRunning = true; phoneValidation = RemotePlaybackValidation()
        phoneTestStatus = "Play audio on the iPhone for 10 seconds, then pause it."
        phoneOnly = false
        if shutdownPending { clearShutdown() }
        if let remotePeer, linked { switchTo(remotePeer) }
        else { connect() }
    }

    private func restoreRemoteVerification() {
        guard let firmware, let remotePeer else { return }
        let key = "VerifiedRemote/\(selectedID)/\(firmware)/\(remotePeer.id)"
        guard verificationKey != key else { return }
        verificationKey = key; remoteVerified = UserDefaults.standard.bool(forKey: key)
    }

    private func checkPhoneValidation() {
        guard phoneTestRunning, linked, remotePeer != nil,
              let lastPlayback,
              now - lastPlayback < 6 else { return }
        let sawPlaying = phoneValidation.sawRemotePlaying
        let settledRemote = remotePeer?.selected == true && now - sourceChangedAt > 1 && lastPlayback > sourceChangedAt
        let passed = phoneValidation.update(playback: playback, remoteSelected: settledRemote,
            fresh: true, localSilence: measuredSilence)
        if !sawPlaying, phoneValidation.sawRemotePlaying {
            phoneTestStatus = "iPhone playback detected. Pause it to finish the check."
            note("Detected playback from the selected remote source")
        } else if passed, let verificationKey {
            remoteVerified = true; phoneTestRunning = false
            UserDefaults.standard.set(true, forKey: verificationKey)
            phoneTestStatus = "iPhone playing and paused states verified."
            note("Remote playback transitions verified for this headphone firmware and phone")
        }
    }

    private func handoffSilentMac() {
        if macStartDetector.observe(silence: measuredSilence, now: now) { macStartPendingUntil = now + 15 }
        if measuredSilence == true || localIsSelected { macStartPendingUntil = 0 }
        guard smartSwitching, !phoneTestRunning, linked, freshStatus,
              !policy.blocked, playback != .call, recordingActivity == false,
              let remote = remotePeer, !sourceHandoff.isPending(now: now), now - lastHandoff > 6 else { localSilentSince = nil; return }
        if SourceHandoff.shouldRestoreMac(localSelected: localIsSelected, suspended: macOutputSuspended,
            audible: measuredSilence.map { !$0 }, inCall: playback == .call) {
            setMacOutputSuspended(false)
            note("Restored audible Mac output already selected by the headphones")
        }
        if localIsSelected, measuredSilence == true {
            if localSilentSince == nil { localSilentSince = now }
            if now - localSilentSince! >= 8 {
                switchTo(remote, manual: false); lastHandoff = now; localSilentSince = nil
                note("Mac output stayed silent; released audio priority to the phone")
            }
        } else {
            localSilentSince = nil
            if !localIsSelected, measuredSilence == false, now < macStartPendingUntil, now - sourceChangedAt > 2,
               let localAddress, let local = peers.first(where: { $0.id.caseInsensitiveCompare(localAddress) == .orderedSame }) {
                switchTo(local); lastHandoff = now; macStartPendingUntil = 0
                note("New Mac audio started; interrupted the phone and selected the Mac")
            }
        }
    }

    func beginQuickIdleTest() {
        quickTestSeconds = 15; keepANC = false; idleEnabled = true; idle.reset()
        note("Started a 15-second end-to-end idle test; normal timeout remains \(idleMinutes) minutes")
    }

    func openBluetoothSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
    }

    func quit() {
        stopping = true; tickTimer?.invalidate(); connectNote?.unregister()
        stopLink(); note("Quit; no further connection enforcement")
        NSApp.terminate(nil)
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Headroom-diagnostics.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { writeDiagnostics(url) }
    }

    private func note(_ text: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        events.append("\(time)  \(text)"); if events.count > 100 { events.removeFirst(events.count - 100) }
        saveSnapshot(force: true)
    }

    private func saveSnapshot(force: Bool = false) {
        guard let diagnosticURL else { return }
        let fingerprint = "\(status)|\(bluetoothStatus)|\(playback)|\(battery ?? -1)|\(linked)|\(events.count)"
        guard now - snapshotAt >= 0.5, force || fingerprint != lastSnapshot || now - snapshotAt > 10 else { return }
        lastSnapshot = fingerprint; snapshotAt = now; writeDiagnostics(diagnosticURL)
    }

    private func writeDiagnostics(_ url: URL) {
        let data: [String: Any] = [
            "app": "Headroom 0.3.0", "date": ISO8601DateFormatter().string(from: Date()),
            "status": status, "bluetooth": bluetoothStatus, "pairedXM5Count": choices.count,
            "connectedToMac": connected, "controlChannelOpen": linked,
            "battery": battery as Any? ?? NSNull(), "firmware": firmware as Any? ?? NSNull(),
            "playback": playback.rawValue, "playbackFresh": freshStatus,
            "connectedSourceCount": peers.count, "onlyLocalMac": onlyLocalMac,
            "macAudioActive": macAudio as Any? ?? NSNull(), "idlePowerOffEnabled": idleEnabled,
            "idleStatus": idleStatus, "protectionEnabled": protect, "phoneOnly": phoneOnly,
            "lidClosed": lidClosed, "locked": locked, "sleeping": sleeping,
            "levelStatus": levelStatus, "measuredSilence": measuredSilence as Any? ?? NSNull(),
            "levelDB": levelDB, "remotePlaybackVerified": remoteVerified,
            "macOutputSuspended": macOutputSuspended,
            "sourceHandoff": sourceStatus as Any? ?? NSNull(),
            "codec": codec as Any? ?? NSNull(), "noiseMode": noiseControl?.mode.rawValue as Any? ?? NSNull(),
            "equalizer": equalizer?.title as Any? ?? NSNull(),
            "maxMainTickMS": maxTickMS, "pendingBluetoothWrites": writeBuffers.count,
            "reconnectPending": reconnectPlan.pending, "reconnectFailures": reconnectPlan.failures,
            "phoneTestStatus": phoneTestStatus as Any? ?? NSNull(), "powerEventsAvailable": powerEventsAvailable,
            "hardwareAutoOffChoices": hardwareAutoOffChoices,
            "events": events, "note": notice as Any? ?? NSNull()
        ]
        diagnosticQueue.async {
            var snapshot = data
            snapshot["openAtLogin"] = SMAppService.mainApp.status == .enabled
            if let bytes = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: url, options: .atomic)
            }
        }
    }

    private static func isXM5(_ device: IOBluetoothDevice) -> Bool {
        device.nameOrAddress.uppercased().contains("WH-1000XM5")
    }
    private static let serviceUUID: IOBluetoothSDPUUID? = {
        let uuid = UUID(uuidString: "956C7B26-D49A-4BA8-B03F-B17D393CB6E2")!
        return withUnsafeBytes(of: uuid.uuid) { IOBluetoothSDPUUID(bytes: $0.baseAddress, length: 16) }
    }()
    private static func readLid() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }
}


extension HeadphoneController {
    private func receiveSetting(_ setting: HeadphoneSetting) {
        switch setting {
        case .codec(let value): codec = value
        case .noise(let value):
            let previous = noiseControl?.mode
            noiseControl = value
            if let previous, previous != value.mode, modeHUD { onModeChanged?(value.mode) }
        case .equalizer(let value): equalizer = value
        case .dsee(let value): dsee = value
        case .speakToChat(let value): speakToChat = value
        case .chatOptions(let value): chatOptions = value
        case .wearingPause(let value): wearingPause = value
        case .noiseButton(let value): noiseButton = value
        }
    }

    func changeNoise(_ state: NoiseControl, manual: Bool = true) {
        guard noiseControl != nil else { return }
        if manual { callAmbience.manualChange() }
        change(.setNoise(state), verify: .noise)
    }
    func changeMode(_ mode: ListeningMode) {
        guard var state = noiseControl else { return }
        state.mode = mode; changeNoise(state)
    }
    func nextMode() {
        guard let mode = noiseControl?.mode, let i = ListeningMode.allCases.firstIndex(of: mode) else { return }
        changeMode(ListeningMode.allCases[(i + 1) % ListeningMode.allCases.count])
    }
    func change(_ request: SonyRequest?, verify query: SonyRequest) {
        guard let request, linked, !demo, !policy.blocked else { return }
        requestSony(request); requestSony(query)
    }
    func changeAutoOff(_ code: UInt8) {
        guard hardwareAutoOffChoices.contains(code) else { return }
        change(.setAutoOff(code), verify: .autoOffSetting)
    }
}
