# Shhh

Hold the right ⌘ key, talk, let go. Your words are typed wherever your cursor is.

Shhh is a tiny macOS menu-bar app I built for myself to dictate prompts to AI tools instead of typing them. Everything runs on your Mac: no account, no cloud, no subscription.

- **Hold right ⌘** to record. A small pill appears at the bottom of the screen only while you hold it.
- **Let go** and the text is pasted into the focused app. Your clipboard is put back right after.
- **English and French** (and 23 other European languages), detected automatically.
- **AI cleanup** (optional, off by default): removes "um / uh / euh", repeated words and spoken self-corrections ("Monday, actually no, Tuesday" → "Tuesday"). It only ever deletes words. If the model tries to change or add anything, Shhh keeps your original words.

## Requirements

- Apple Silicon Mac, macOS 14 or later
- Xcode (for the Swift toolchain) to build

## Build and install

```bash
./scripts/make-signing-cert.sh   # once: local signing certificate so permissions survive rebuilds
swift scripts/make-icon.swift    # once: generates the app icon
./scripts/build.sh --install     # builds Shhh.app, copies it to /Applications and launches it
```

On first launch, macOS asks for:

1. **Microphone**, to hear you (only while right ⌘ is held).
2. **Accessibility**, to detect the right ⌘ key and paste the text. Enable Shhh in System Settings → Privacy & Security → Accessibility.

The speech model (~500 MB) downloads on first launch. The cleanup model (~1.1 GB) downloads the first time you turn on AI cleanup.

## Menu

Click the waveform icon in the menu bar:

- **AI cleanup**: turn the cleanup pass on or off.
- **Copy last transcript**: if a paste landed nowhere, get the text back.
- **Launch at login**
- **Quit Shhh**

## How it works

| Step | What | Where |
| --- | --- | --- |
| Hotkey | Global monitor on the right ⌘ key; any other key while held cancels (so ⌘C still works) | `HotkeyMonitor.swift` |
| Audio | Default microphone → 16 kHz mono | `AudioRecorder.swift` |
| Speech-to-text | NVIDIA Parakeet (Ultra) on the Apple Neural Engine via FluidAudio | `Transcriber.swift` |
| Cleanup | Qwen3-1.7B via llama.cpp, used as a few-shot copy-editor, with a delete-only safety check | `TextCleaner.swift` |
| Insert | Clipboard + synthetic ⌘V, then the previous clipboard is restored | `TextInserter.swift` |
| UI | Menu-bar item + floating pill | `AppDelegate.swift`, `RecordingPanel.swift` |

Test the pipeline from the terminal without the UI:

```bash
BIN=$(swift build -c release --show-bin-path)
$BIN/Shhh --transcribe recording.wav
$BIN/Shhh --clean "Um, let's meet Monday, actually no, Tuesday."
```

## Credits

- [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0) and NVIDIA Parakeet (CC-BY-4.0)
- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and [Qwen3](https://huggingface.co/Qwen/Qwen3-1.7B) (Apache 2.0)

Inspired by Wispr Flow. Not affiliated with Wispr in any way.

## License

MIT
