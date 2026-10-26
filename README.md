# Socrates

A study app for university lectures, for the Mac and the iPhone. Record a lecture with the slides open; Socrates transcribes it on your Mac and lines it up with the slides.

Version 0.1.

![Review: the slide, the transcript, your notes and the agent](docs/images/review.png)

Review: slide, transcript, your notes and the agent.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/notes-dark.png">
  <img src="docs/images/notes.png" alt="A lecture's Summary with your notes beside it">
</picture>

A lecture's Summary, with your notes beside it.

![A lecture with the "This slide" pane](docs/images/lecture.png)

This slide: exam hints and what was only said in class.

![A course's books, papers and links](docs/images/materials.png)

Course materials.

<img src="docs/images/iphone-recorder.png" width="280" alt="The iPhone recorder, paused">

The iPhone recorder.

## What it does

- Records lectures and stamps each slide change on the audio.
- Transcribes on the device (Whisper) and aligns the transcript to the slides.
- One Claude agent across the app. Every change it makes can be undone.
- Deadlines and room changes from your mail, classes in a "Socrates" calendar.

## Requirements

- macOS 26 on Apple silicon (iOS 26 for the iPhone app)
- Xcode 26.5 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- For the AI features: the [Claude Code](https://docs.anthropic.com/en/docs/claude-code) CLI with a Claude subscription

## Build

```sh
xcodegen generate
xcodebuild -project Socrates.xcodeproj -scheme Socrates -destination 'platform=macOS' -skipMacroValidation build
```

For your own signing team or iCloud sync, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`.

## Privacy

- Your library stays on your devices. No telemetry, no server.
- Claude gets text through your own CLI, never audio.
- iCloud sync is opt-in and uses your private CloudKit database.

## License

MIT, see [LICENSE](LICENSE). Third-party code and models: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
