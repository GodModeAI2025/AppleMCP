# AppleMCP

Native macOS 15+ MCP server that gives AI assistants secure, read-only access to your local Apple data and Apple Intelligence features.

AppleMCP consists of a SwiftUI app that bridges macOS privacy-controlled APIs and a `stdio` MCP server for Claude Desktop, Claude Code, and other MCP clients. Everything runs locally — no cloud, no sync, no data leaves your machine.

## What It Does

| Source | Access Method | Permission |
|---|---|---|
| **Mail** | Local Envelope Index (SQLite) + `.emlx` body parsing, AppleScript fallback | Full Disk Access or Mail Automation |
| **Calendar** | EventKit | Calendar Access |
| **Contacts** | Contacts.framework | Contacts Access |
| **Reminders** | EventKit | Reminders Access |
| **Notes** | Notes.app AppleScript Automation | Automation Permission |
| **Photos** | Photos.framework | Photos Access |
| **Voice Memos** | Local `CloudRecordings.db` + in-file transcripts, SpeechAnalyzer / SFSpeechRecognizer for recordings without one | Full Disk Access, Speech Recognition (only for `voicememos_transcribe`) |
| **Apple Intelligence** | Native APIs (ImagePlayground, Translation, Writing Tools) | None |
| **Foundation Models** | On-device language model via FoundationModels (macOS 26, weak-linked) | None |

## Quick Start

### 1. Build

```bash
swift build
swift test   # parser tests for the Voice Memos transcript format
```

### 2. Run the App

```bash
./script/build_and_run.sh
```

The app opens a macOS window and starts a local endpoint on a Unix domain socket at `~/Library/Application Support/M3MCP/mcp.sock`. Click **Permissions** on first launch to grant macOS access to Calendar, Contacts, Reminders, Photos, and Notes.

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
      "command": "/path/to/AppleMCP/.build/debug/M3MCPBridge"
    }
  }
}
```

#### Claude Code

```bash
claude mcp add applemcp /path/to/AppleMCP/.build/debug/M3MCPBridge
```

The M3MCP UI app must be running for MCP calls to work. The bridge talks to the app over a Unix domain socket in the user's Application Support directory.

## MCP Tools

### Data Access

| Tool | Description |
|---|---|
| `mail_search` | Search messages in Apple Mail (subject, sender, date, read status) |
| `mail_read` | Read full email content by ID (body, recipients, attachments metadata) |
| `calendar_search` | Search calendar events via EventKit |
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
| `voicememos_transcribe` | Transcribe on device: stored transcript, cache, SpeechAnalyzer (macOS 26), then SFSpeechRecognizer |

### Apple Intelligence

| Tool | Description |
|---|---|
| `ai_summarize` | Summarize text and extract action items with the on-device foundation model (macOS 26) |
| `ai_writing_tools` | Summarize, rewrite, proofread, or change tone of text (needs a "Writing Tools" Shortcut) |
| `ai_translate` | Translate text using Apple system translation |
| `ai_image_playground` | Generate images from text descriptions (macOS 15.4+) |

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

All data stays local. The app uses macOS TCC (Transparency, Consent, and Control) for every data source. No network requests are made at all: the endpoint is a Unix domain socket, not a TCP port.

Because the app holds Full Disk Access, anything that can reach the endpoint inherits that reach. The socket lives in a `0700` directory and is itself `0600`, so a sandboxed app — the case macOS TCC exists to stop — cannot connect, and a web page cannot reach it under any circumstances. Mail reads the local SQLite index directly — it never sends emails or modifies any data. Voice Memos are opened read-only, and speech recognition runs on device whenever the locale supports it, so recordings never leave the Mac.

## Requirements

- macOS 15.0+
- Swift 5.9+
- Apple Intelligence features require macOS 15.4+ with Apple Silicon

## Credits

The Voice Memos support is a native Swift port of [jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) (MIT). See [docs/THIRD_PARTY.md](docs/THIRD_PARTY.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
