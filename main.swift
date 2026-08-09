import Cocoa

// Entry point. Swift only allows top-level code in a file named main.swift, so this is kept
// separate from AppDelegate in CaffeinateCat.swift.

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // Hides it from the Dock
let delegate = AppDelegate()
app.delegate = delegate
app.run()
