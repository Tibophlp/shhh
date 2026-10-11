import AppKit

CommandLineTool.runIfRequested() // terminal test modes, see CommandLineTool.swift

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
