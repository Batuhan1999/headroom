import AppKit
import Carbon.HIToolbox
import SwiftUI
import UserNotifications
import HeadroomCore

struct ShortcutToggle: View {
    var model: HeadphoneController
    @AppStorage("ModeShortcut") private var enabled = false
    var body: some View {
        Toggle("Switch modes with ⌃⌥⌘N", isOn: $enabled)
            .disabled(model.demo)
            .onChange(of: enabled) { _, _ in NotificationCenter.default.post(name: .init("HeadroomShortcutChanged"), object: nil) }
    }
}

// Carbon hot keys work across apps without Accessibility permission.
@MainActor
final class AppExtras: NSObject, UNUserNotificationCenterDelegate {
    var menuIsOpen = false
    private let model: HeadphoneController
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var token: NSObjectProtocol?
    private var hud: NSPanel?
    private var hideTimer: Timer?

    init(model: HeadphoneController) {
        self.model = model
        super.init()
        guard !model.demo else { return }
        model.onLowBattery = { [weak self] in self?.notifyLowBattery($0) }
        model.onModeChanged = { [weak self] in self?.showMode($0) }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<AppExtras>.fromOpaque(context).takeUnretainedValue().model.nextMode() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        token = NotificationCenter.default.addObserver(forName: .init("HeadroomShortcutChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyShortcut() }
        }
        applyShortcut()
    }

    private func applyShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        guard UserDefaults.standard.bool(forKey: "ModeShortcut") else { return }
        let id = EventHotKeyID(signature: OSType(0x4844524d), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey | cmdKey),
                                        id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.notice = "The mode shortcut is already in use by another app (\(result))." }
    }

    private func notifyLowBattery(_ level: Int) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
            let content = UNMutableNotificationContent()
            content.title = "Headphone battery is low"
            content.body = "WH-1000XM5 has \(level)% remaining."
            try? await center.add(UNNotificationRequest(identifier: "headroom-low-battery", content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func showMode(_ mode: ListeningMode) {
        guard !menuIsOpen, let screen = NSScreen.main else { return }
        let panel = hud ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud = panel
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.ignoresMouseEvents = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let content = HStack(spacing: 12) {
            Image(systemName: mode.symbol).font(.system(size: 23)).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(mode.title).font(.system(size: 14, weight: .semibold))
                Text("WH-1000XM5").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(16)
        let host = NSHostingView(rootView: content)
        let size = host.fittingSize
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow; background.state = .active
        background.wantsLayer = true; background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true
        host.frame = background.bounds; background.addSubview(host); panel.contentView = background
        panel.setFrame(NSRect(x: screen.visibleFrame.maxX - size.width - 16,
                              y: screen.visibleFrame.maxY - size.height - 16, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak panel] _ in
            MainActor.assumeIsolated { panel?.orderOut(nil) }
        }
    }
}
