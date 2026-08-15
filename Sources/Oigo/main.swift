import AppKit

let application = NSApplication.shared
let delegate = OigoAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
