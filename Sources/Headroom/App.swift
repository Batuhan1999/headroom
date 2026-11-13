import AppKit
import SwiftUI
import ServiceManagement
import HeadroomCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: HeadphoneController!
    private var panel: DropdownPanel!
    private var item: NSStatusItem!
    private var monitors: [Any] = []
    private var extras: AppExtras!
    private var statusMonitor: Any?
    private var capturedButton: Int?
    private var lastStatusClick: TimeInterval = -.infinity

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = ProcessInfo.processInfo.arguments
        var diagnostics: URL?
        if let i = arguments.firstIndex(of: "--diagnostics"), i + 1 < arguments.count {
            diagnostics = URL(fileURLWithPath: arguments[i + 1])
        }
        model = HeadphoneController(demo: arguments.contains("--demo"), diagnosticURL: diagnostics)
        extras = AppExtras(model: model)
        if arguments.contains("--start-at-login"), !model.demo {
            do { try SMAppService.mainApp.register() }
            catch { model.notice = "Could not enable Open at login: \(error.localizedDescription)" }
        }
        panel = DropdownPanel()
        let root = DropdownView(model: model, onPowerOff: { [weak self] in self?.confirmPowerOff() },
            onExport: { [weak self] in self?.close(); self?.model.exportDiagnostics() })
        panel.setContent(root) { [weak self] size in self?.resize(to: size) }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "beats.headphones", accessibilityDescription: "Headroom")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        item.button?.toolTip = "Headroom · click for controls"
        installStatusClickHandler()
        observeIcon()
        if arguments.contains("--show") || arguments.contains("--demo") { show() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "headroom" && url.host == "mode" {
            guard model.linked else { model.notice = "Connect the headphones before using a mode link."; show(); continue }
            switch url.path {
            case "/next": model.nextMode()
            case "/ambient": model.changeMode(.ambient)
            case "/noise-cancelling": model.changeMode(.noiseCancelling)
            case "/off": model.changeMode(.off)
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(); return false
    }

    @objc private func toggle() { panel.isVisible ? close() : show() }

    private func show() {
        guard !panel.isVisible else { return }
        resize(to: panel.contentSize)
        let screen = item.button?.window?.screen ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .zero
        var x = bounds.maxX - 308, top = bounds.maxY - 4
        if let button = item.button, let window = button.window, window.occlusionState.contains(.visible) {
            let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
            if bounds.intersects(frame.insetBy(dx: 0, dy: -30)) {
                x = min(frame.minX, bounds.maxX - 308); top = frame.minY - 4
            }
        }
        panel.setFrameOrigin(NSPoint(x: max(bounds.minX + 8, x), y: max(bounds.minY + 8, top - panel.frame.height)))
        panel.makeKeyAndOrderFront(nil)
        extras.menuIsOpen = true
        item.button?.highlight(true)
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, !self.pointerIsInsideMenu else { return }
                let timestamp = event.timestamp
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                    guard let self, abs(self.lastStatusClick - timestamp) > 0.1 else { return }
                    self.close()
                }
            },
            NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 { self.close(); return nil }
                return event
            }
        ].compactMap { $0 }
    }

    private func installStatusClickHandler() {
        // Consume both halves of our click before AppKit's tracking loop clears the highlight.
        statusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp, .rightMouseUp]) { [weak self] event in
            guard let self else { return event }
            let down = event.type == .leftMouseDown || event.type == .rightMouseDown
            if down {
                self.capturedButton = nil
                guard !event.modifierFlags.contains(.command), let button = self.item.button,
                      event.window === button.window,
                      button.bounds.contains(button.convert(event.locationInWindow, from: nil)) else { return event }
                self.capturedButton = event.buttonNumber
                self.lastStatusClick = event.timestamp
                self.toggle()
                return nil
            }
            if self.capturedButton == event.buttonNumber {
                self.capturedButton = nil
                return nil
            }
            return event
        }
    }

    private var pointerIsInsideMenu: Bool {
        let point = NSEvent.mouseLocation
        if panel.isVisible, panel.frame.contains(point) { return true }
        guard let button = item.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).insetBy(dx: -3, dy: -3).contains(point)
    }

    private func close() {
        extras.menuIsOpen = false
        panel.orderOut(nil); item.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor); monitors = []
    }

    private func resize(to size: CGSize) {
        let height = ceil(max(80, size.height))
        guard abs(panel.frame.height - height) > 0.5 else { return }
        let frame = panel.frame
        panel.setContentSize(NSSize(width: 300, height: height))
        if panel.isVisible {
            let bottom = panel.screen?.visibleFrame.minY ?? 0
            panel.setFrameOrigin(NSPoint(x: frame.minX, y: max(bottom + 8, frame.maxY - height)))
        }
    }

    private func confirmPowerOff() {
        close(); NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Power off your \(model.modelName)?"
        alert.informativeText = "Audio and calls will stop on every connected device. Turn them on again using their power button."
        alert.addButton(withTitle: "Power Off"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { model.powerOff() }
    }

    private func observeIcon() {
        withObservationTracking { _ = (model.battery, model.connected, model.phoneOnly, model.showBattery) } onChange: { [weak self] in
            DispatchQueue.main.async { self?.observeIcon() }
        }
        item.button?.title = model.showBattery ? (model.battery.map { " \($0)%" } ?? "") : ""
        item.button?.imagePosition = .imageLeading
        item.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        item.button?.toolTip = model.phoneOnly ? "Headroom · Phone only" : "Headroom"
    }
}

// The anchored menu-panel approach follows Sound Connect (MIT).
private final class DropdownPanel: NSPanel {
    private var host: NSView?
    var contentSize: CGSize { host?.layoutSubtreeIfNeeded(); return host?.fittingSize ?? CGSize(width: 300, height: 400) }
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Headroom"
        level = .popUpMenu; isOpaque = false; backgroundColor = .clear; hasShadow = true
        isReleasedWhenClosed = false; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }
    override var canBecomeKey: Bool { true }
    func setContent(_ view: some View, onResize: @escaping (CGSize) -> Void) {
        let background = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 300, height: 400))
        background.material = .menu; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 12; background.layer?.masksToBounds = true
        let host = NSHostingView(rootView: view.background(GeometryReader { proxy in
            Color.clear.onAppear { onResize(proxy.size) }.onChange(of: proxy.size) { _, size in onResize(size) }
        }))
        host.sizingOptions = [.intrinsicContentSize]
        host.frame = background.bounds
        host.autoresizingMask = [.width, .height]
        background.addSubview(host); contentView = background; self.host = host
    }
}

struct DropdownView: View {
    @Bindable var model: HeadphoneController
    let onPowerOff: () -> Void
    let onExport: () -> Void
    @State private var settings = false
    @State private var diagnostics = false
    @State private var soundExpanded = false
    @State private var bodyHeight: CGFloat = 220
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "headphones").font(.system(size: 20, weight: .light)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.modelName).font(.system(size: 13, weight: .semibold))
                    Text(model.demo ? "Preview" : model.sourceStatus?.hasPrefix("Switching") == true ? "Switching audio…" : model.phoneOnly ? "Phone only" : model.linked ? "Connected" : "Disconnected")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if let battery = model.battery {
                    Label("\(battery)%", systemImage: battery > 30 ? "battery.75percent" : "battery.25percent")
                        .font(.system(size: 12, weight: .medium)).monospacedDigit()
                        .help(model.linked ? "Headphone battery" : "Last known headphone battery")
                }
            }.padding(13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if settings { settingsView } else { controls }
                    if let notice = model.notice { Text(notice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                }.padding(12)
                    .background(GeometryReader { proxy in
                        Color.clear.onAppear { bodyHeight = ceil(proxy.size.height) }
                            .onChange(of: proxy.size.height) { _, height in bodyHeight = ceil(height) }
                    })
            }.frame(height: min(bodyHeight, max(180, (NSScreen.main?.visibleFrame.height ?? 800) - 145)))
                .scrollBounceBehavior(.basedOnSize)
            Divider()
            HStack(spacing: 12) {
                Button { settings.toggle() } label: {
                    Label(settings ? "Back" : "Settings", systemImage: settings ? "chevron.left" : "gearshape")
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(action: onPowerOff) { Image(systemName: "power") }
                    .accessibilityLabel("Power off headphones")
                    .disabled(!model.linked || model.demo || model.policy.blocked).buttonStyle(.plain)
                Menu {
                    Toggle("Keep headphones on", isOn: $model.keepANC)
                    Toggle("Open at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
                    Button("Project on GitHub…") { NSWorkspace.shared.open(URL(string: "https://github.com/Batuhan1999/headroom")!) }
                    Button("Export diagnostics…", action: onExport)
                    Divider()
                    Button("Quit Headroom") { model.quit() }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                    .accessibilityLabel("More options")
            }.font(.system(size: 11)).padding(13)
        }.frame(width: 300).fixedSize(horizontal: false, vertical: true)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.peers.isEmpty {
                Button { model.useMac() } label: {
                    Label("Connect to Mac", systemImage: "laptopcomputer").frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).disabled(!model.bluetoothReady)
                Text(model.phoneOnly ? "Mac disconnected · phone only" : model.status)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.peers) { peer in
                        MenuChoice(symbol: peer.name.lowercased().contains("iphone") ? "iphone" : "laptopcomputer",
                                   title: peer.name, selected: peer.selected) { model.switchTo(peer) }
                            .disabled(model.policy.blocked)
                    }
                }
            }
            if let noise = model.noiseControl {
                Divider()
                VStack(spacing: 0) {
                    ForEach(ListeningMode.allCases) { mode in
                        MenuChoice(symbol: mode.symbol, title: mode.title, selected: noise.mode == mode) { model.changeMode(mode) }
                    }
                }.disabled(!model.linked || model.policy.blocked)
            }
            if model.equalizer != nil || model.dsee != nil || model.speakToChat != nil {
                FoldHeader(title: "Sound", detail: model.equalizer?.title, expanded: $soundExpanded)
                if soundExpanded { HeadphoneControls(model: model) }
            }
            Divider()
            Toggle("Phone only", isOn: $model.phoneOnly).toggleStyle(.switch).controlSize(.mini)
                .help("Keep this Mac disconnected, including after restarts")
            Text(model.keepANC ? "Keeping headphones on" : model.idleStatus)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).help(model.idleStatus)
            if !model.bluetoothReady {
                Text(model.bluetoothStatus).font(.caption).foregroundStyle(.secondary)
                Button("Retry Bluetooth") { model.retryBluetooth() }.font(.caption)
                Button("Bluetooth Settings…") { model.openBluetoothSettings() }.font(.caption)
            }
        }.font(.system(size: 12))
    }

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 13) {
            caption("HEADPHONES")
            if model.linked || model.demo { HeadphoneSettingsView(model: model) }
            else { Text("Connect your headphones to change their settings.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            caption("APP")
            Toggle("Battery in menu bar", isOn: $model.showBattery)
            Toggle("Low battery alerts", isOn: $model.lowBatteryAlerts)
            Toggle("Mode change pop-up", isOn: $model.modeHUD)
            ShortcutToggle(model: model)
            Divider()
            caption("CONNECTION")
            Toggle("Release Mac when locked or asleep", isOn: $model.protect)
            Toggle("Reconnect when available", isOn: $model.reconnect)
            Toggle("Switch sources with audible activity", isOn: $model.smartSwitching)
            Text("A silent Mac yields to the phone. New Mac audio can interrupt the phone; calls keep priority.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            caption("POWER")
            Toggle("Power off after silence", isOn: $model.idleEnabled)
            Picker("After", selection: $model.idleMinutes) {
                ForEach([5, 10, 15, 30, 60], id: \.self) { Text("\($0) minutes").tag($0) }
            }
            Text("Runs while this Mac is connected and awake. Calls, audible audio and unknown status pause the timer.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            caption("SILENCE DETECTION")
            Toggle("Measure headphone audio levels", isOn: Binding(get: { model.levelsEnabled }, set: model.setLevelsEnabled))
            Text("Reads levels on this Mac only. Audio is never saved or sent. macOS asks for System Audio Recording access; the first check plays a short tone.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(model.levelStatus).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.levelsEnabled { Button("Check") { model.retryLevels() }.font(.caption) }
            }
            if model.levelsEnabled, model.linked {
                ProgressView(value: max(0, min(1, (model.levelDB + 80) / 80))).tint(.secondary)
                    .accessibilityLabel("Mac audio level")
            }
            Button(model.remoteVerified ? "Recheck iPhone playback…" : "Check iPhone playback…") { model.beginPhoneTest() }
                .disabled(model.demo || !model.bluetoothReady)
            if let status = model.phoneTestStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            Divider()
            DisclosureGroup("Diagnostics", isExpanded: $diagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playback: \(model.playback.rawValue)\nSystem sleep events: \(model.powerEventsAvailable ? "registered" : "unavailable")\nMultipoint detection: \(model.remoteVerified ? "verified" : "needs check")")
                    Text("Built-in auto-off choices: \(model.hardwareAutoOffChoices.map(String.init).joined(separator: ", "))")
                    ForEach(Array(model.events.suffix(6).enumerated()), id: \.offset) { _, event in
                        Text(event).textSelection(.enabled)
                    }
                    Button("Run 15-second idle test…") { model.beginQuickIdleTest() }.disabled(!model.linked || model.demo)
                    Button("Bluetooth Settings…") { model.openBluetoothSettings() }
                }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).padding(.top, 8)
            }.font(.caption)
        }.font(.system(size: 12)).toggleStyle(.switch).controlSize(.small)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { model.notice = "Could not change Open at login: \(error.localizedDescription)" }
    }
}


struct MenuChoice: View {
    let symbol: String
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.65))
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
                Text(title).lineLimit(1)
                Spacer()
                if selected { Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary) }
            }.frame(height: 29).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}


struct FoldHeader: View {
    let title: String
    var detail: String? = nil
    @Binding var expanded: Bool
    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).frame(width: 10)
                Text(title)
                Spacer()
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, minHeight: 27).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}
