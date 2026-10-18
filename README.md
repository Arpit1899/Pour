# Pour

Push-to-talk dictation for macOS that runs entirely on your Mac. Hold a shortcut, speak, let go, and the words are typed into whatever app you were using.

## What it does

- **Hold or press once.** Hold ⌃Space while you talk, or switch to press once to start and again to finish. The shortcut can be changed.
- **A small bar on screen.** It sits above the Dock, or on either side of the screen if you drag it there. While you speak it glows with a soft amber aurora. Click it to start or stop a dictation.
- **Tidy text.** With Apple Intelligence on, an on-device model adds punctuation and capitals and drops filler words, without rewording what you said. It can match the app: casual in chat, formal in mail, left alone in code editors and terminals.
- **Nowhere to paste?** If nothing you can type into is focused, the text waits in a card with a Copy button instead of being lost.
- **Your words, spelled right.** Add names, acronyms and jargon to the Dictionary and the recogniser leans toward them.
- **Recent dictations** are listed on the Home page so you can copy one again.
- Pick the microphone and the language, and choose whether Pour opens at login.

## Privacy

Speech recognition uses Apple's on-device speech model, and cleanup uses the on-device Apple Intelligence model. No audio or text leaves your Mac.

Recent dictations are saved in `~/Library/Application Support/Pour/history.json` so they appear on the Home page. Clear them from Home at any time.

## Requirements

- macOS 26.4 or later
- Xcode 26.4 or later to build
- Apple Intelligence turned on, for the cleanup feature only. Dictation works without it.

The first time you dictate in a language, macOS downloads its speech model, which can take a minute.

## Build and run

1. Clone the repository and open `Pour.xcodeproj` in Xcode.
2. In the Pour target's **Signing & Capabilities**, choose your own team. The project is set to the author's team, which your Xcode account won't have.
3. Press Run (⌘R).

On first use Pour asks for two permissions:

- **Microphone and Speech Recognition**, to hear you.
- **Accessibility**, to type into the app you're using. Without it, Pour copies the text to the clipboard and you paste it yourself.

Debug builds signed with a development certificate keep these grants between builds. If macOS asks again after every build, check that a team is selected.

## Project layout

| File | What's in it |
| --- | --- |
| `PourApp.swift` | App entry, the floating bar panel, docking and dragging |
| `PourHUD.swift` | The bar, the aurora animation and the copy card |
| `DockTargets.swift` | The dimmed overlay and spots shown while dragging the bar |
| `PourSession.swift` | The dictation flow: start, stop, paste or hold for copy |
| `VoiceRecorderService.swift` | Microphone capture and on-device transcription |
| `TranscriptPolisher.swift` | Cleanup with the on-device language model |
| `TextFocus.swift` | Checks whether the focused element can take typed text |
| `ContentView.swift`, `PourPages.swift` | The main window: Home, Dictionary, Style and Settings |
| `PourSettings.swift` | Saved preferences |
| `GlobalHotKey.swift`, `ShortcutRecorder.swift` | The global shortcut and recording a new one |

## License

MIT. See [LICENSE](LICENSE).
