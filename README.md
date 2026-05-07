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
| **Apple Intelligence** | Native APIs (ImagePlayground, Translation, Writing Tools) | None |

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

### Apple Intelligence

| Tool | Description |
|---|---|
| `ai_writing_tools` | Summarize, rewrite, proofread, or change tone of text |
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
