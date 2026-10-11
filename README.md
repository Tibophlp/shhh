<p align="center">
  <img src="docs/icon.png" width="112" alt="Shhh icon">
</p>

<h1 align="center">Shhh</h1>

<p align="center">
  <b>Hold right ⌘. Talk. Let go.</b><br>
  Your words are typed wherever your cursor is: fast, private, entirely on your Mac.
</p>

<p align="center">
  <a href="https://github.com/Tibophlp/shhh/releases/latest"><img src="https://img.shields.io/github/v/release/Tibophlp/shhh?label=download&color=black" alt="Download"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-required-black" alt="Apple Silicon">
  <img src="https://img.shields.io/badge/license-MIT-black" alt="MIT license">
</p>

<p align="center">
  <img src="docs/hero.png" alt="Shhh dictating a prompt into a chat app" width="820">
</p>

---

I built Shhh to talk to AI tools instead of typing long prompts. It does one thing: speech to text, at your cursor, in any app. No account, no cloud, no subscription, and no bar on your screen when you're not using it.

## Features

- **Hold to talk.** Hold the right ⌘ key, speak, let go. The text appears in the focused app.
- **Invisible until needed.** A small pill shows at the bottom of the screen only while you're holding the key.
- **Fast.** Speech is transcribed in a fraction of a second on the Apple Neural Engine.
- **English and French** (and 23 other European languages), detected automatically. No setting to switch.
- **Private.** Audio never leaves your Mac. Nothing is stored.
- **Doesn't get in the way.** ⌘C, ⌘Tab and every other shortcut still work. Your clipboard is restored after each paste.
- **Optional AI cleanup.** Removes "um", repeated words and spoken self-corrections, also on-device.

## Install

### Download

1. Download **Shhh.zip** from the [latest release](https://github.com/Tibophlp/shhh/releases/latest), unzip it, and move **Shhh.app** to your Applications folder.
2. Open it. Shhh isn't notarized by Apple, so macOS blocks the first launch. Go to **System Settings → Privacy & Security** and click **Open Anyway**.
   Or run this once in Terminal:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Shhh.app
   ```

### Build from source

Needs Xcode (for the Swift toolchain).

```bash
git clone https://github.com/Tibophlp/shhh.git && cd shhh
./scripts/make-signing-cert.sh   # optional: keeps permissions across rebuilds
./scripts/build.sh --install     # builds, copies to /Applications and launches
```

### First launch

Shhh asks for two permissions:

| Permission | Why |
| --- | --- |
| **Microphone** | To hear you. Only used while right ⌘ is held. |
| **Accessibility** | To notice the right ⌘ key and paste the text into other apps. |

The speech model (~600 MB) downloads once on first launch. A waveform icon then appears in the menu bar and you're ready.

## Usage

| Do this | What happens |
| --- | --- |
| Hold **right ⌘** and talk | Recording. The pill appears at the bottom of the screen. |
| Let go | The text is typed at your cursor. |
| Tap right ⌘ quickly | Nothing. Only a real hold records. |
| Press another key while holding | Recording is cancelled, and your shortcut works as usual. |

The menu-bar icon has four options:

- **AI cleanup**: turn the cleanup pass on or off.
- **Copy last transcript**: get your text back if the cursor wasn't in a text field.
- **Launch at login**
- **Quit**

## AI cleanup

Off by default. Turn it on from the menu bar. It downloads a small local model (Qwen3 1.7B, ~1.1 GB) and adds about half a second.

| You say | Shhh types |
| --- | --- |
| Um, can you refactor the login function so that it uses async await? Actually no, rewrite the whole authentication module and add unit tests. | Rewrite the whole authentication module and add unit tests. |
| Okay, so the plan is we refactor the auth module first, then we, you know, add tests, and then, I mean, after that we can deploy it on Friday. No wait, on Thursday. | Okay, so the plan is we refactor the auth module first, then add tests, and then deploy it on Thursday. |
| Je voudrais que tu, euh, regardes le fichier et que tu me dises si, genre, il y a des bugs. | Je voudrais que tu regardes le fichier et que tu me dises si il y a des bugs. |
| Can you make the the header sticky? | Can you make the header sticky? |
| What is the capital of France? | What is the capital of France? |

**It only ever deletes words.** It never rewrites, translates or answers your prompt. If the model's output adds or changes a word, or drops real words when you didn't correct yourself, Shhh pastes your original words instead.

## How it works

```
right ⌘ held ─▶ microphone (16 kHz) ─▶ Parakeet speech model ─▶ [AI cleanup] ─▶ paste at cursor
```

| | |
| --- | --- |
| Speech to text | [NVIDIA Parakeet](https://huggingface.co/FluidInference/parakeet-ultra-coreml) on the Neural Engine, via [FluidAudio](https://github.com/FluidInference/FluidAudio) |
| Cleanup | [Qwen3 1.7B](https://huggingface.co/Qwen/Qwen3-1.7B) via [llama.cpp](https://github.com/ggml-org/llama.cpp), prompted as a copy-editor, with a delete-only safety check |
| Typing | Clipboard + ⌘V into the focused app, then your previous clipboard is restored |
| App | Native Swift, under 900 lines, no dependencies beyond the two above |

<details>
<summary><b>Project layout</b></summary>

```
Sources/Shhh/
  AppDelegate.swift      menu bar, permissions, dictation flow
  HotkeyMonitor.swift    right ⌘ detection
  AudioRecorder.swift    microphone capture
  Transcriber.swift      speech to text
  TextCleaner.swift      optional AI cleanup
  TextInserter.swift     paste + clipboard restore
  RecordingPanel.swift   the pill
scripts/
  build.sh               build Shhh.app (--install to install and launch)
  make-signing-cert.sh   local signing certificate
  make-icon.swift        regenerate the app icon
```

Test the pipeline without the app:

```bash
BIN=$(swift build -c release --show-bin-path)
$BIN/Shhh --transcribe recording.wav
$BIN/Shhh --clean "Um, let's meet Monday, actually no, Tuesday."
```

</details>

## Troubleshooting

<details>
<summary><b>Nothing happens when I hold right ⌘</b></summary>

Make sure Shhh is enabled in **System Settings → Privacy & Security → Accessibility**. If you rebuilt or updated the app, toggle it off and on again. Password fields and some secure apps block keyboard monitoring on purpose.
</details>

<details>
<summary><b>The text didn't appear</b></summary>

The cursor needs to be in a text field when you let go. Use **Copy last transcript** from the menu bar to get the text back.
</details>

<details>
<summary><b>The first word is sometimes cut off</b></summary>

The microphone takes a split second to start. Wait a beat after pressing right ⌘ before you speak, especially with Bluetooth headphones.
</details>

<details>
<summary><b>Where are the models stored?</b></summary>

The speech model is in `~/Library/Application Support/FluidAudio`, and the cleanup model in `~/Library/Application Support/Shhh`. Delete those folders to remove them.
</details>

## Credits

Built on [FluidAudio](https://github.com/FluidInference/FluidAudio) (Apache 2.0), NVIDIA Parakeet (CC-BY-4.0), [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) and [Qwen3](https://huggingface.co/Qwen/Qwen3-1.7B) (Apache 2.0).

Inspired by Wispr Flow. Not affiliated with Wispr.

## License

[MIT](LICENSE)
