# ClaudeChat

ClaudeChat is a local-first Flutter client for Android and iOS. It combines private AI conversations, memories, diary entries, versioned files, reminders, and mobile coding workspaces in one app.

> [!IMPORTANT]
> This is an independent community project. It is not affiliated with, endorsed by, or sponsored by Anthropic. “Claude” is a trademark of Anthropic; users are responsible for complying with the terms of any model or API provider they configure.

## Highlights

- OpenAI-compatible streaming API client with configurable providers and local conversation history.
- SQLite storage for conversations, memories, diary entries, files, revisions, tombstones, and import conflicts.
- `.claudechat` backup/export and merge import, including legacy version 1/2 JSON migration.
- API keys stored in Keychain or Android Keystore; encrypted secret backups use Argon2id and AES-256-GCM.
- Android calendar/reminder intents, scheduled notifications, system-ringtone selection, and a home widget.
- iOS EventKit calendar/reminders, local notifications, and a WidgetKit extension using an App Group.
- Sandboxed HTML/SVG preview, Markdown and formula rendering, attachments, branching, and message export.
- Local mobile coding workspaces with file trees, checkpoints, version history, and agent-style task progress.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for storage, merge rules, and security boundaries.

## Privacy and security

- Conversation and workspace data remain on the device unless you export them or send content to a configured API provider.
- Do not commit API keys, signing certificates, keystores, provisioning profiles, exported diagnostics, or personal backups.
- HTML/SVG previews are sandboxed, but opening external links or running untrusted content still requires judgment.
- Please report security issues according to [SECURITY.md](SECURITY.md).

## Getting started

Install Flutter, then run:

```bash
flutter pub get
flutter run
```

Android debug verification on Windows:

```powershell
.\build-android.ps1 -Mode debug
```

The Android application ID is currently `com.susuclaude.app`. Forks intended for distribution should replace it, the iOS bundle identifiers, and the App Group identifiers with values they control.

## iOS unsigned IPA

The iOS runner and WidgetKit target share the Flutter/Dart code. iOS compilation requires macOS with Xcode. An unsigned IPA for later re-signing can be produced with:

```bash
./build-ios-unsigned.sh
```

The included GitHub Actions workflow can also build the unsigned IPA. See [docs/IOS_UNSIGNED_IPA.md](docs/IOS_UNSIGNED_IPA.md) for integrity checks, nested-app signing requirements, and installation limitations.

## Legacy export limitation

The legacy web project’s version-2 export included conversations, memories, diary data, and settings, but not `userFiles` or `workspaces`. Those two categories cannot be reconstructed from an old JSON file that never contained them. The current importer merges them when the fields are present, and new backups include files, workspaces, attachments, revisions, and tombstones.

## Contributing

Issues and pull requests are welcome. Keep ordinary chat and workspace execution isolated, preserve local-first storage semantics, and add regression tests for changes to streaming or tool-call ordering.

## License

Application source code is licensed under the [MIT License](LICENSE). Bundled fonts remain under the SIL Open Font License 1.1; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
