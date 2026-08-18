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
| **Voice Memos** | Local Core Data store (SQLite) + on-device transcription via `SpeechAnalyzer` | Full Disk Access |
| **Apple Intelligence** | Native APIs (ImagePlayground, Translation, Writing Tools) | None |
| **Foundation Models** | `FoundationModels` on-device language model (macOS 26) | Apple Intelligence active |

## Quick Start

### 1. Build

```bash
swift build
```

### 2. Run the App

```bash
./script/build_and_run.sh
```

The app opens a macOS window and starts a local HTTP endpoint on `127.0.0.1:47651`. Click **Permissions** on first launch to grant macOS access to Calendar, Contacts, Reminders, Photos, and Notes.

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

The M3MCP UI app must be running for MCP calls to work. The bridge communicates with the app over a local loopback HTTP connection.

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
| `voicememos_search` | Search voice memos synced from iPhone (title, date, duration) |
| `voicememos_read` | Read one memo and transcribe it with Apple's on-device speech model |

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
MCP Client (Claude) <--stdio--> M3MCPBridge <--HTTP 127.0.0.1:47651--> M3MCPApp (SwiftUI)
                                                                            |
                                                      EventKit / Contacts / Photos / Mail Index / AppleScript
```

### Voice Memos

Voice Memos has no supported read API on macOS — it is not AppleScript-scriptable, its framework is
private, and its App Intents surface can start a recording but cannot enumerate or read one back.
AppleMCP therefore reads the Core Data store directly:

```
~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings/CloudRecordings.db
```

The store is WAL-mode and the write-ahead log routinely dwarfs the main database, so it is snapshotted
to a temporary directory before reading — the live store is never opened for writing.

Voice Memos does not persist transcripts anywhere on disk; it computes them lazily inside the app.
AppleMCP transcribes the audio itself with `SpeechAnalyzer` / `SpeechTranscriber`, the on-device Apple
Intelligence speech models (macOS 26+). Results are cached and keyed on the recording's SHA-256, so
repeat reads are instant. On macOS 15 the metadata tools work and transcription reports that it needs
macOS 26.

Memo titles are the reverse-geocoded location where the recording was made. No coordinates are stored
anywhere — not in the database, not in the audio file's metadata — so the title is the whole location
signal.

#### Polling for new memos

`voicememos_search` accepts `since_minutes` alongside `since_hours` so a short polling loop does not
re-fetch the same window every pass — with hour granularity, a 5-minute loop would return the same
memos twelve times. `since_minutes` wins when both are given. Pair it with `ai_summarize` to triage
new recordings:

```
voicememos_search since_minutes=10  ->  voicememos_read <id>  ->  ai_summarize <transcript>
```

Two schema notes worth knowing, both established by probing a live store rather than from docs:

- **`ZEVICTIONDATE` is the deletion timestamp, not an iCloud audio-eviction marker.** Deleting a memo
  sets it to "now" while `ZFLAGS` stays unchanged, `ZFOLDER` stays NULL, and the audio file remains on
  disk. It marks the start of the ~30 day Recently Deleted window. `voicememos_search` therefore
  excludes rows where it is set; `voicememos_read` still resolves them by id but labels them clearly.
- **Rows with an empty `ZPATH` are placeholders, not recordings.** They have no audio file, `ZFLAGS = 0`,
  and every BLOB column NULL, and they do not appear in Voice Memos.app. They are filtered out.

- **M3MCPApp** — SwiftUI app with macOS TCC permissions, provides the actual data access
- **M3MCPBridge** — Lightweight `stdio` MCP server that translates MCP protocol to HTTP calls
- **M3MCPCore** — Shared models and types

## Privacy

All data stays local. The app uses macOS TCC (Transparency, Consent, and Control) for every data source. No network requests are made except to `127.0.0.1`. Mail reads the local SQLite index directly — it never sends emails or modifies any data.

## Requirements

- macOS 15.0+
- Swift 5.9+
- Apple Intelligence features require macOS 15.4+ with Apple Silicon

## License

MIT
