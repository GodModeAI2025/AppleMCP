# AppleMCP

[![CI](https://github.com/GodModeAI2025/AppleMCP/actions/workflows/ci.yml/badge.svg)](https://github.com/GodModeAI2025/AppleMCP/actions/workflows/ci.yml)

Native macOS 15+ MCP server that gives AI assistants local access to your Apple data and Apple Intelligence features. Most tools read. Those that write include five calendar tools that change your calendars, `ai_image_playground`, which writes a PNG per call, and `voicememos_transcribe`, which keeps the transcripts it produces under `~/Library/Application Support/M3MCP/transcripts/` and leaves a scratch audio file in the temporary directory whenever a recording has to be transcoded before recognition.

AppleMCP consists of a SwiftUI app that bridges macOS privacy-controlled APIs and a `stdio` MCP server for Claude Desktop, Claude Code, and other MCP clients. It runs locally, with no cloud account and no sync of its own. That does not make every path local: `ai_translate` and `ai_writing_tools` hand your text to a Shortcut you built yourself, `voicememos_transcribe` lets Apple's speech service take the audio when the locale has no on-device model, and an event a calendar tool writes into an iCloud calendar syncs like any other. See [Limits](#limits).

## What It Does

| Source | Access Method | Permission |
|---|---|---|
| **Mail** | Local Envelope Index (SQLite) + `.emlx` body parsing, AppleScript fallback | Full Disk Access or Mail Automation |
| **Calendar** | EventKit, read and write | Calendar Access |
| **Contacts** | Contacts.framework | Contacts Access |
| **Reminders** | EventKit | Reminders Access |
| **Notes** | Notes.app AppleScript Automation | Automation Permission |
| **Photos** | Photos.framework | Photos Access |
| **Voice Memos** | Local `CloudRecordings.db` + in-file transcripts, SpeechAnalyzer / SFSpeechRecognizer for recordings without one | Full Disk Access, Speech Recognition (only for `voicememos_transcribe`) |
| **Apple Intelligence** | ImagePlayground framework for images; `shortcuts run` through AppleScript for Translation and Writing Tools | None |
| **Foundation Models** | On-device language model via FoundationModels (macOS 26, weak-linked) | None |

## What AppleMCP Is Not

- **No GUI automation.** It never clicks, types, or drives an app through its interface. Notes is reached through AppleScript, which is scripting, not the UI.
- **No screenshots, no screen recording.** Nothing reads the display.
- **No computer use.** There is no loop in which a model looks at the screen and acts on it.
- **No mail sending.** The Mail tools read the local index and the `.emlx` files. They compose nothing and send nothing.
- **No network.** The endpoint is a Unix domain socket, not a TCP port. The bridge does speak HTTP, but only across that socket. The sources open no connection to a remote host and contain no `URLSession`.

## Download

Each release carries `M3MCP.app.zip` and a checksum file. The ZIP holds the app and the bridge
binary, so an MCP client can be pointed at the download without a checkout.

```bash
curl -LO https://github.com/GodModeAI2025/AppleMCP/releases/latest/download/M3MCP.app.zip
curl -LO https://github.com/GodModeAI2025/AppleMCP/releases/latest/download/M3MCP.app.zip.sha256
shasum -a 256 -c M3MCP.app.zip.sha256
unzip M3MCP.app.zip
mv M3MCP.app /Applications/
```

**Apple Silicon only.** The build has one architecture, `arm64`. On an Intel Mac it will not start,
and building from source is the way in.

**macOS warns on first launch, and it has reason to.** The app is signed ad hoc: no Developer ID, no
notarisation, nothing Apple has inspected. `spctl --assess --type execute` answers `rejected`, which
is the ordinary verdict for a build like this one. Opening it the first time produces a dialog
saying macOS cannot verify it is free of malware.

To start it anyway: open it once and dismiss the dialog, then go to System Settings, Privacy &
Security, scroll to the note about M3MCP and choose **Open Anyway**. Right-click and Open stopped
working for apps that are not notarised. If you prefer one command:

```bash
xattr -d com.apple.quarantine /Applications/M3MCP.app
```

That drops the mark macOS puts on downloaded files, which means you are vouching for the file. Check
the checksum above before you do.

**The Full Disk Access grant does not survive an update.** An ad-hoc signature pins the app's
designated requirement to the binary hash, so the next release is a different app as far as macOS is
concerned and the grant has to be given again. The source build avoids that: `install_local.sh`
signs with a stable local certificate, and the grant then survives rebuilds.

The ZIP also contains no launch agent, so the downloaded app starts when you start it, not at login.
`script/install_local.sh` is what sets up the launchd side.

After the first launch, click **Permissions** in the app, then point the MCP client at the bridge
inside the bundle:

```bash
claude mcp add applemcp /Applications/M3MCP.app/Contents/MacOS/M3MCPBridge
```

## Quick Start

### 1. Build

```bash
swift build -c release
swift test
```

Release, not debug, because `script/install_local.sh` builds `-c release` and the MCP client config below points into `.build/release`. `script/build_and_run.sh` builds the debug configuration for a one-off run and does not produce that binary.

### 2. Run the App

For a persistent install under launchd, with a stable signature so the Full Disk Access grant survives rebuilds:

```bash
./script/install_local.sh
```

That signature has to come from somewhere. Without a usable code-signing identity the script stops with "No usable code-signing identity found", so create a local one first:

```bash
./script/create_local_identity.sh
```

For a one-off run from the terminal:

```bash
./script/build_and_run.sh
```

Either way the app starts a local endpoint on a Unix domain socket at `~/Library/Application Support/M3MCP/mcp.sock`. Click **Permissions** on first launch to grant macOS access to Calendar, Contacts, Reminders, Photos, and Notes.

Check that it is up:

```bash
curl --unix-socket ~/Library/Application\ Support/M3MCP/mcp.sock http://localhost/health
```

### 3. Connect Your MCP Client

#### Claude Desktop

Add to your Claude Desktop MCP config (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "applemcp": {
      "command": "/path/to/AppleMCP/.build/release/M3MCPBridge"
    }
  }
}
```

#### Claude Code

```bash
claude mcp add applemcp /path/to/AppleMCP/.build/release/M3MCPBridge
```

The M3MCP UI app must be running for MCP calls to work. The bridge talks to the app over a Unix domain socket in the user's Application Support directory.

## MCP Tools

### Data Access

| Tool | Description |
|---|---|
| `mail_search` | Search messages in the local Apple Mail index. Matches subject, sender and recipients by default, body on request; scoped to a mailbox with `mailbox`, narrowed with `unread_only` and `since_hours`, paged with `offset`, and `match` picks how a multi-word query applies: all, any, or phrase |
| `mail_list_mailboxes` | List the mailboxes of the local Mail index with account, path, role, and message counts, so a `mail_search` can be scoped to a name that exists |
| `mail_read` | Read full email content by ID (body, recipients, attachments metadata) |
| `calendar_search` | Search calendar events via EventKit, optionally scoped to one calendar |
| `calendar_read_event` | Read one event by ID, the way to confirm a write, since `calendar_search` only scans a date window |
| `calendar_list_calendars` | List calendars with their source, ID, and whether they are writable |
| `contacts_search` | Search contacts / address book |
| `reminders_search` | Search reminders (incomplete, completed, or all) |
| `notes_search` | Search Apple Notes by keyword |
| `notes_read` | Read a single note by ID |
| `photos_search` | Search Apple Photos library metadata |
| `photos_albums` | List photo albums with counts |
| `voicememos_search` | Search voice memos by title, date range, or transcript text |
| `voicememos_read` | Read one recording including its stored transcript |
| `voicememos_transcript` | Return a stored transcript as text, timestamped text, or JSON segments |
| `voicememos_audio` | Return the recording as a local path or base64 audio |
| `voicememos_transcribe` | Transcribe a recording: stored transcript, cache, SpeechAnalyzer (macOS 26), then SFSpeechRecognizer, which is on device only where the locale has a model |

### Calendar Writes

These change the user's calendar. There is no undo.

| Tool | Description |
|---|---|
| `calendar_create_event` | Create an event. Takes `project_slug`, stored as a `Project: <slug>` line in the notes and read back as `metadata.project_slug` |
| `calendar_update_event` | Change an event. Only the fields passed are changed; anything omitted is left as it is |
| `calendar_delete_event` | Delete an event by ID |
| `calendar_create_calendar` | Create a calendar. Requires `source` unless a local ("On My Mac") source exists, so a new calendar never lands in an account by default |
| `calendar_delete_calendar` | Delete a calendar and its events. `id` and `title` must both be given and must agree |

### Apple Intelligence

| Tool | Description |
|---|---|
| `ai_summarize` | Summarize text and extract action items with the on-device foundation model (macOS 26). Needs no Shortcut |
| `ai_writing_tools` | Summarize, rewrite, proofread, or change tone of text. Needs a Shortcut named "Writing Tools", see [Limits](#limits) |
| `ai_translate` | Translate text using Apple system translation. Needs a Shortcut named "Translate" and `/usr/bin/python3`, see [Limits](#limits) |
| `ai_image_playground` | Generate images from text descriptions (macOS 15.4+). Writes a PNG file and returns its path |

### System

| Tool | Description |
|---|---|
| `source_status` | List available providers and their states |
| `permissions_status` | Report macOS permission state for all providers |
| `permissions_request` | Request all required macOS permissions |
| `permissions_open_settings` | Open System Settings for permission remediation |

## Architecture

```
MCP Client (Claude) <--stdio--> M3MCPBridge <--HTTP over Unix socket--> M3MCPApp (SwiftUI)
                                                                            |
                                       EventKit / Contacts / Photos / Mail Index / Voice Memos Store / Speech / AppleScript
```

- **M3MCPApp** — SwiftUI app with macOS TCC permissions, provides the actual data access
- **M3MCPBridge** — Lightweight `stdio` MCP server that translates MCP protocol to HTTP calls
- **M3MCPCore** — Shared models and types

## Voice Memos

Voice Memos are read straight from the local Core Data store (`~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db`) — Voice Memos.app is never driven through AppleEvents. Transcripts have no sidecar file: macOS writes them into a private `tsrp` atom inside each `.m4a`, so AppleMCP parses the recording itself.

- Open Voice Memos once so macOS creates the store, and grant Full Disk Access if the folder is protected.
- On macOS Sequoia and later, opening a memo in Voice Memos makes macOS transcribe it. `voicememos_transcript` then returns that transcript without any recognition run.
- `voicememos_transcribe` falls back to Speech.framework and prefers on-device recognition, so audio stays on the Mac. It returns an existing transcript first unless you pass `prefer_stored: false`.
- `voicememos_search` matches titles by default. Pass `search_transcripts: true` to search spoken content instead; `max_candidates` bounds how many recordings are opened.

See [docs/VOICE_MEMOS.md](docs/VOICE_MEMOS.md) for the store layout, the transcript format, and troubleshooting.

## Privacy

What the app reads stays on the Mac, except where a tool hands it on: `ai_translate` and `ai_writing_tools` to a Shortcut you built, `voicememos_transcribe` to Apple's speech service on locales without an on-device model, see [Limits](#limits). The app uses macOS TCC (Transparency, Consent, and Control) for every data source. AppleMCP opens no remote connection: the endpoint is a Unix domain socket rather than a TCP port, and the HTTP the bridge speaks travels only over that socket.

Because the app holds Full Disk Access, anything that can reach the endpoint inherits that reach. The socket lives in a `0700` directory and is itself `0600`, so a sandboxed app — the case macOS TCC exists to stop — cannot connect, and a web page cannot reach it under any circumstances. An unsandboxed process running as you is a different case, see [Limits](#limits). Mail reads the local SQLite index directly, it never sends emails or modifies any data. Voice Memos are opened read-only. Speech recognition runs on device where the locale has a model for it; where it does not, the audio goes to Apple's speech service instead.

## Security

The security policy and the threat model live in `SECURITY.md`, currently in review as [PR #14](https://github.com/GodModeAI2025/AppleMCP/pull/14). They are not repeated here, so there is one place to correct when the architecture moves.

## Limits

- **The socket does not check who connects.** File permissions keep out sandboxed apps and web pages. They do not distinguish one unsandboxed process of yours from another, so any local process running as you can call the endpoint and use the app's Full Disk Access. Tracked as [issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9).
- **`ai_translate` has prerequisites nothing sets up for you.** The provider pipes the text through `/usr/bin/python3` into `shortcuts run Translate`. You need a Shortcut named "Translate" that you created yourself, and the system Python 3 at `/usr/bin/python3`. Without either the tool answers that translation is not reachable. Whether the translation itself stays on the Mac depends on whether the language pair is downloaded, which the Shortcuts and Translate apps decide, not AppleMCP.
- **`ai_writing_tools` needs a Shortcut named "Writing Tools"** for the same reason, and the same open question follows: the text goes into that Shortcut, and where it goes from there is the Shortcut's business, not AppleMCP's. `ai_summarize` does not; it calls FoundationModels directly and needs macOS 26.
- **`ai_image_playground` leaves files behind.** Each call writes a PNG into the process temporary directory and returns the path. AppleMCP never deletes them; they stay until macOS clears that directory.
- **`voicememos_transcribe` keeps what it recognizes.** Every recognition run writes the text to `~/Library/Application Support/M3MCP/transcripts/<digest>.txt`, mode `0600` in a `0700` directory, which is what makes the second call for the same recording cheap. Nothing deletes those files afterwards, and unlike the PNG files they do not sit in a directory macOS clears. Recognition is only on device where the locale has a model: `LegacySpeechRecognizer` sets `requiresOnDeviceRecognition` to whatever `SFSpeechRecognizer` reports as supported (line 72), so on every other locale the audio goes to Apple.
- **Calendar writes cannot be undone.** `calendar_delete_calendar` removes a calendar with its events. It refuses unless `id` and `title` agree and the calendar is mutable, and that is the whole safety net: there is no dry-run mode and no confirmation step.
- **Test coverage is narrow.** The suite covers the Voice Memos transcript parser and the calendar project slug. Providers, the local HTTP server, and the bridge have no tests, so CI proves that the package builds and those two units work, not that a provider still returns what it used to.
- **The release build carries no Apple signature.** It is signed ad hoc: no Developer ID, no
  notarisation, `spctl --assess` answers `rejected`, and because the designated requirement is the
  binary hash, Full Disk Access has to be granted again after every update. It ships one
  architecture, `arm64`. It is built and checked on macOS 26 runners; `LSMinimumSystemVersion` claims
  15.0 and nothing tests that claim.
- **The published checksum is not a reproducibility claim.** `script/package_release.sh` is
  deterministic, and CI compares two packaging runs byte for byte. `swift build` is not: two clean
  release builds of the same commit with the same toolchain produce different binaries, measured here
  at 746 differing bytes and different `LC_UUID`s. The SHA256 tells you the download arrived intact,
  not that you can rebuild it.
- **Building needs the macOS 26 SDK.** `Package.swift` weak-links `FoundationModels`, which exists only in that SDK. Without it the link step fails with `ld: framework 'FoundationModels' not found`, even though the built app runs on macOS 15.

## Roadmap

Tracked in the issue tracker:

- Verify the connecting process on the socket, so an unsandboxed local process cannot borrow the app's Full Disk Access ([issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9))
- Bring the threat model into the repo, updated for the current architecture ([issue #10](https://github.com/GodModeAI2025/AppleMCP/issues/10), in review as [PR #14](https://github.com/GodModeAI2025/AppleMCP/pull/14))

Wanted, no issue open yet:

- A safety layer for the write tools: dry-run, and a confirmation for the destructive ones
- Tests for the providers and the bridge, so CI covers more than the parser
- A build macOS does not warn about: Developer ID signing and notarisation. The release build is
  signed ad hoc, so every download costs the user a trip through System Settings

## Requirements

- macOS 15.0+ to run
- Xcode 26 or the matching Command Line Tools to build, for the macOS 26 SDK that carries the weak-linked `FoundationModels`
- Swift 5.9+ tools version
- Apple Intelligence features require macOS 15.4+ with Apple Silicon

## Changelog

See [CHANGELOG.md](CHANGELOG.md). Note for 0.1.0 users: the endpoint moved to a Unix domain socket, so the app and the bridge have to be rebuilt together.

## Credits

The Voice Memos support is a native Swift port of [jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) (MIT). See [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
