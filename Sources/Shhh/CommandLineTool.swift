import Carbon.HIToolbox
import Foundation

/// Terminal test modes, to check each part of the pipeline without the app:
///
///     Shhh --transcribe <audio-file>   transcribe a file with the on-device model
///     Shhh --clean "<text>"            run the AI cleanup pass (one line per input line)
///     Shhh --style <style> "<text>"    apply a writing style: veryFormal, casual, veryCasual
///     Shhh --microphones               list microphones and show what Automatic picks
///     Shhh --record <seconds>          record from the Automatic microphone and transcribe
///     Shhh --selftest                  check the cleanup safety rules and writing styles (no model)
enum CommandLineTool {
    private static let usage = """
    Usage:
      Shhh --transcribe <audio-file>
      Shhh --clean "<text>"
      Shhh --style <veryFormal|casual|veryCasual> "<text>"
      Shhh --microphones
      Shhh --record <seconds>
      Shhh --selftest
    """

    /// Runs a test mode and exits if one was requested; returns otherwise.
    static func runIfRequested() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let mode = args.first, mode.hasPrefix("--") else { return }

        switch (mode, args.count) {
        case ("--microphones", 1):
            print("Lid closed:", AudioDevices.isLidClosed)
            for input in AudioDevices.inputs() { print("-", input.name, "[\(input.kind)]") }
            print("Automatic picks:", AudioDevices.resolve(preferredUID: nil)?.name ?? "nothing")
            exit(0)
        case ("--style", 3):
            guard let style = WritingStyle(rawValue: args[1]) else { fail("Unknown style: \(args[1])") }
            print(style.apply(args[2]))
            exit(0)
        case ("--selftest", 1):
            selfTest()
            exit(0)
        case ("--transcribe", 2):
            run { try await transcribe(file: args[1]) }
        case ("--clean", 2):
            run { try await clean(args[1]) }
        case ("--record", 2):
            guard let seconds = Double(args[1]) else { fail("Usage: Shhh --record <seconds>") }
            run { try await record(seconds: seconds) }
        default:
            fail(usage)
        }
    }

    private static func selfTest() {
        let safe: [(String, String, Bool)] = [
            ("Send it to John, sorry, to Jane by Friday.", "Send it to Jane by Friday.", true),
            ("Let's meet on Monday, actually no, Tuesday at noon.", "Let's meet on Tuesday at noon.", true),
            ("Tu peux corriger la fonction de login, non pardon, la fonction de logout.", "Tu peux corriger la fonction de logout ?", true),
            ("So the the button should be blue.", "So the button should be blue.", true),
            // A cue word used normally: nothing may be deleted.
            ("Sorry for the late reply, I was traveling all week for work.", "Sorry for the late reply.", false),
            ("Actually the meeting went really well today.", "The meeting went really well today.", false),
            ("Non, je ne pense pas que ce soit une bonne idée.", "Je ne pense pas que ce soit une bonne idée.", false),
            ("Please review the pull request today.", "Please review the request today.", false),
        ]
        for (input, output, expected) in safe {
            precondition(TextCleaner.isSafe(input: input, output: output) == expected, "isSafe: \(input) → \(output)")
        }
        let styles: [(WritingStyle, String, String)] = [
            (.veryFormal, "don't touch that", "Do not touch that."),
            (.veryFormal, "isn't it great", "Isn't it great?"),
            (.veryFormal, "don't you think so", "Don't you think so?"),
            (.veryFormal, "can you send it", "Can you send it?"),
            (.veryFormal, "I'm gonna be late", "I am going to be late."),
            (.veryCasual, "Send the API key.", "send the API key"),
            (.veryCasual, "Wait...", "wait..."),
        ]
        for (style, input, expected) in styles {
            let got = style.apply(input)
            precondition(got == expected, "\(style): \(input) → \(got)")
        }
        let fillers = [
            ("Je pense que, euh, on devrait partir.", "Je pense qu'on devrait partir."),
            ("Um, I think we should go.", "I think we should go."),
            ("Tell me, uh, about it.", "Tell me about it."),
        ]
        for (input, expected) in fillers {
            let got = TextCleaner.removeFillers(input)
            precondition(got == expected, "removeFillers: \(input) → \(got)")
        }
        // ⌘V must press the key that types "v" on the current layout, not the QWERTY V position.
        for (id, expected) in [("com.apple.keylayout.US", 9), ("com.apple.keylayout.Dvorak", 47)] {
            let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
            guard let layout = (TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource])?.first else { preconditionFailure("missing layout \(id)") }
            let got = TextInserter.commandKeyCode(for: "v", in: layout)
            precondition(got == CGKeyCode(expected), "commandKeyCode \(id) → \(String(describing: got))")
        }
        print("ok")
    }

    private static func transcribe(file: String) async throws {
        let transcriber = Transcriber()
        try await transcriber.load { _ in }
        let start = Date()
        let text = try await transcriber.transcribe(fileURL: URL(fileURLWithPath: file))
        print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
    }

    private static func clean(_ input: String) async throws {
        let cleaner = TextCleaner()
        try await cleaner.load { _ in }
        for line in input.components(separatedBy: "\n") where !line.isEmpty {
            let start = Date()
            let text = await cleaner.clean(line)
            print(String(format: "[%.2fs] %@", Date().timeIntervalSince(start), text))
        }
        await cleaner.unload()
    }

    @MainActor
    private static func record(seconds: Double) async throws {
        let recorder = AudioRecorder()
        let start = Date()
        let recording = try await recorder.start(preferredUID: nil)
        print(String(format: "Recording %.0fs from %@ (started in %.2fs)…", seconds, recording.input.name, Date().timeIntervalSince(start)))
        try await Task.sleep(for: .seconds(seconds))
        let samples = await recorder.stop(recording, covering: seconds)
        let peak = samples.reduce(0) { max($0, abs($1)) }
        print(String(format: "Captured %.1fs, peak level %.2f", Double(samples.count) / 16_000, peak))
        let transcriber = Transcriber()
        try await transcriber.load { _ in }
        print("Text:", try await transcriber.transcribe(samples))
    }

    private static func run(_ work: @escaping () async throws -> Void) -> Never {
        Task {
            do {
                try await work()
                exit(0)
            } catch {
                fail("Error: \(error.localizedDescription)")
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
