import AppKit

// Migrate this Mac's prototype preferences once; no device data ships in the app.
if !UserDefaults.standard.bool(forKey: "MigratedPrototype") {
    let keys = ["HeadphoneAddress", "Protect", "Reconnect", "PhoneOnly", "IdleEnabled", "KeepANC", "IdleMinutes", "AudioLevels", "SmartSwitching"]
    if let previous = UserDefaults.standard.persistentDomain(forName: "local.xm5guard.prototype") {
        for (key, value) in previous where keys.contains(key) || key.hasPrefix("VerifiedRemote/") {
            if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(value, forKey: key) }
        }
    }
    UserDefaults.standard.set(true, forKey: "MigratedPrototype")
}

// Keep AppKit's event loop outside a Swift concurrency main-actor job.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) { app.run() }
