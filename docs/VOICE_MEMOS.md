# Voice Memos Access

AppleMCP reads the local Voice Memos library directly. Voice Memos.app is never driven through
AppleEvents, which keeps behaviour predictable and avoids the enumeration hangs described in
[BEST_PRACTICES.md](BEST_PRACTICES.md).

## Store Layout

Voice Memos keeps a Core Data SQLite store next to the recordings. AppleMCP probes these locations
in order and uses the first one that contains `CloudRecordings.db`:

1. `~/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings` (macOS Sonoma and later)
2. `~/Library/Application Support/com.apple.voicememos/Recordings`
3. `~/Library/Containers/com.apple.VoiceMemos/Data/Library/Application Support/Recordings`

The relevant table is `ZCLOUDRECORDING`:

| Column | Meaning |
|---|---|
| `Z_PK` | Primary key, used as the MCP item id |
| `ZPATH` | Recording filename, occasionally an absolute path |
| `ZCUSTOMLABEL` | User-assigned title |
| `ZENCRYPTEDTITLE` | Title macOS derives from the recording |
| `ZDATE` | Core Data timestamp, seconds since 2001-01-01 |
| `ZDURATION` | Length in seconds |

Column names are resolved through `PRAGMA table_info`, so a schema change in a future macOS release
degrades instead of breaking.

### Why the store is copied before reading

`CloudRecordings.db` runs in WAL mode, and the write-ahead log routinely holds the newest
recordings — it can be larger than the main database. Opening the live file read-only cannot replay
that log: SQLite either fails to create the `-shm` file or answers from the main database alone, so
recently recorded memos are missing from the results without any error.

Each read therefore copies the database plus its `-wal` and `-shm` sidecars into a private `0700`
directory, opens the *copy* read-write so SQLite can replay the log, and deletes the copy afterwards.
The user's store is never opened for writing.

### Rows that are not recordings

Two kinds of rows are excluded from `voicememos_search`:

- **Recently deleted memos.** `ZEVICTIONDATE` is the deletion timestamp — it marks the start of the
  roughly 30 day Recently Deleted window, not an iCloud audio eviction. `voicememos_read` still
  resolves such a memo by id, but labels it with `state: recently_deleted` and `deleted_at`.
- **Placeholders.** Rows with an empty `ZPATH` have no audio file and do not appear in Voice Memos.

Both findings come from [PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1) by
[@aheusingfeld](https://github.com/aheusingfeld), who established them by probing a live store.

## Transcripts

macOS Sequoia transcribes recordings automatically once they are opened in Voice Memos, but there is
no transcript file. The transcript is stored inside the recording, in a private MPEG-4 atom named
`tsrp` below `moov/trak/udta`.

The atom payload is a JSON document holding an archived attributed string:

```json
{
  "attributedString": {
    "runs": ["Erste Passage", 0, "zweite Passage", 1],
    "attributeTable": [{ "timeRange": [0.0, 2.4] }, { "timeRange": [2.4, 5.1] }]
  },
  "locale": { "identifier": "de-DE" }
}
```

`runs` alternates text with an index into `attributeTable`, and each attribute entry carries the time
range of the text before it. `VoiceMemoTranscriptReader` walks the atom headers on a memory mapped
file, so checking whether a recording carries a transcript does not read the audio payload.

`voicememos_transcript` renders that data three ways:

- `text` — the plain transcript
- `timestamped` — `[m:ss]` lines, grouped at sentence ends or every ~15 seconds
- `json` — plain text plus a `segments_json` metadata field with `text`, `start`, and `end`

## Speech Recognition

`voicememos_transcribe` is the fallback for recordings without a stored transcript, for example on
macOS Sequoia when the memo was never opened in Voice Memos. It runs `SFSpeechRecognizer` inside
M3MCPApp, so macOS attributes the Speech Recognition permission to the signed app bundle rather than
to the MCP bridge process.

- On-device recognition is requested whenever the locale supports it, so audio stays on the Mac.
- The locale defaults to the system locale. Pass `language` (for example `de-DE`) to override it.
- Recognition is bounded by `timeout_seconds` (default 300) and the task is cancelled on timeout.
- An existing macOS transcript is returned first. Pass `prefer_stored: false` to force recognition.

Missing language packs surface as a clear error. Install them under
System Settings > Accessibility > Voice Control.

## Permissions

| Permission | Needed for | Remediation |
|---|---|---|
| Full Disk Access | Reading `CloudRecordings.db` and the `.m4a` files | `permissions_open_settings` with pane `voice_memos` |
| Speech Recognition | `voicememos_transcribe` only | `permissions_open_settings` with pane `speech` |

Both appear in `permissions_status` as `voice_memos_store` and `speech_recognition`. Neither is
marked required, so a Mac without Voice Memos still reports a healthy permission state.

## Troubleshooting

**"The Voice Memos store was not found"** — open Voice Memos once, then grant Full Disk Access to
M3MCP and restart the app.

**"This recording carries no stored transcript"** — open the memo in Voice Memos on macOS Sequoia or
later to let macOS transcribe it, or call `voicememos_transcribe`.

**A recording has no `path` metadata** — the audio is still in iCloud only. Play it once in Voice
Memos so macOS downloads it.

**Transcript search feels slow** — `search_transcripts` opens recordings until `max_candidates`
(default 300) is reached. Narrow the range with `since_days`, or lower `max_candidates`.

## Differences From The Upstream Parser

The Swift parser was checked against the TypeScript implementation of
[apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) on byte-identical synthetic
recordings. Ordinary recordings produce identical text, locale, and segments. Four cases differ on
purpose:

| Case | Upstream | AppleMCP |
|---|---|---|
| Transcript in a track other than the first | No transcript found | All tracks are searched |
| 64 bit atom sizes (`size == 1`) | Parsing stops | Atom is read via its 64 bit largesize |
| `timeRange` stored as `[start, duration]` | `end` lands before `start` | `end` is normalized to `start + duration` |
| `tsrp` atom that decodes to no text | Reported as a transcript | Reported as no transcript |

The last one keeps `voicememos_search` and `voicememos_transcript` in agreement: a recording is only
advertised with `has_transcript: true` when the transcript can actually be returned.

Reading a recording also avoids loading the audio: the file is memory mapped and only the MPEG-4
atom headers are walked, while the upstream parser reads the whole file into memory.

## Tests

`swift test` runs `Tests/M3MCPCoreTests/VoiceMemoTranscriptTests.swift`, which builds recordings with
`tsrp` atoms in code — no binary fixtures — and covers the atom walk, the payload prefix, 64 bit
atoms, empty transcripts, duration-style time ranges, and timestamp rendering.

## Attribution

The store layout, the `tsrp` atom format, and the tool surface follow
[jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) (MIT), ported from
TypeScript to Swift for this app. See [THIRD_PARTY.md](THIRD_PARTY.md).
