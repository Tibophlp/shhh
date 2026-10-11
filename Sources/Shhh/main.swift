import AppKit

// Command-line test modes (no UI):
//   Shhh --transcribe <audio-file>   transcribe a file with the on-device model
//   Shhh --clean "<text>"            run the AI cleanup pass on some text
if CommandLine.arguments.count >= 3 {
    let mode = CommandLine.arguments[1]
    let arg = CommandLine.arguments[2]
    if mode == "--transcribe" || mode == "--clean" {
        Task {
            do {
                if mode == "--transcribe" {
                    let transcriber = Transcriber()
                    try await transcriber.load { _ in }
                    let start = Date()
                    let text = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: arg))
                    print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
                } else {
                    let cleaner = TextCleaner()
                    try await cleaner.load { _ in }
                    for line in arg.components(separatedBy: "\n") where !line.isEmpty {
                        let start = Date()
                        let text = await cleaner.clean(line)
                        print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
                    }
                    await cleaner.unload()
                }
                exit(0)
            } catch {
                print("Error: \(error)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
