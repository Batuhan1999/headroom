import Foundation
import IOKit.pwr_mgt
import IOKit

final class PowerObserver {
    // IOMessage.h's function-like macros are not imported by Swift.
    private static let canSleep: UInt32 = 0xe0000270
    private static let willSleep: UInt32 = 0xe0000280
    private static let didWake: UInt32 = 0xe0000300
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var connection: io_connect_t = 0
    private let onSleep: () -> Void
    private let onWake: () -> Void
    var available: Bool { connection != 0 }

    init(onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        self.onSleep = onSleep; self.onWake = onWake
        connection = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(), &port, { context, _, message, argument in
            guard let context else { return }
            let observer = Unmanaged<PowerObserver>.fromOpaque(context).takeUnretainedValue()
            if message == PowerObserver.canSleep {
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            } else if message == PowerObserver.willSleep {
                observer.onSleep()
                IOAllowPowerChange(observer.connection, Int(bitPattern: argument))
            } else if message == PowerObserver.didWake {
                observer.onWake()
            }
        }, &notifier)
        if let port, let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    deinit {
        if connection != 0 { IODeregisterForSystemPower(&notifier); IOServiceClose(connection) }
        if let port { IONotificationPortDestroy(port) }
    }
}
