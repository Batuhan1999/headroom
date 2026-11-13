import AppKit
import SwiftUI

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

// SwiftUI owns the native menu-extra lifecycle and AppKit event loop.
HeadroomApplication.main()
