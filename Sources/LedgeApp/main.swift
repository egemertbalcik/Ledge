import AppKit
import LedgeShell

// AppKit lifecycle, not the SwiftUI `App` lifecycle. `App`/`Scene` fights every
// one of: accessory activation policy, stray `WindowGroup` windows, panel
// levels, and multi-display window ownership. SwiftUI is used for views only,
// hosted inside panels we own.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
