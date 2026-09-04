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

Values in `ZPATH` are not trusted as arbitrary paths. AppleMCP uses only the final filename component
and resolves it directly under the selected recordings directory. Resolution opens the directory
and recording with no-follow descriptor operations and records both inode identities. Every later
transcript, base64, or transcription read reopens the same filename relative to a verified directory
descriptor and compares the opened file's owner, regular-file type, single-link count, device, and
inode before consuming data. AVFoundation receives `/dev/fd` for that retained descriptor plus an
explicit MIME hint derived from the original filename. The legacy Speech service receives bounded
PCM buffers, never the mutable library path or descriptor URL. Replacing the library pathname
therefore cannot redirect a Full Disk Access read. Detail tools accept only a canonical
positive-decimal id returned by `voicememos_search`.

### Why the store is copied before reading

`CloudRecordings.db` runs in WAL mode, and the write-ahead log routinely holds the newest
recordings — it can be larger than the main database. Opening only the main file can therefore omit
recently recorded memos.

Each read copies the database plus its existing `-wal` and `-shm` sidecars into a private snapshot.
The macOS per-user temporary path is first canonicalized past the system `/var` alias; the resulting
owner-only directory is opened with `O_DIRECTORY | O_NOFOLLOW_ANY` and retained as an anchor. The
snapshot directory is created relative to that descriptor with mode `0700`. Sources and mode-`0600`
destinations are opened no-follow, must be current-user regular files with one link, and are copied
descriptor-to-descriptor; each component is capped at 1 GiB.

SQLite additionally enforces a 256 KiB value/row materialization ceiling on the read-only snapshot.
Before Swift constructs database strings, paths, labels, titles, digest text, and schema identifiers
are validated from their exact UTF-8 byte lengths against smaller field-specific caps. Embedded NUL
and invalid UTF-8 values fail closed. Search queries are rejected above 4,096 UTF-8 bytes before
case normalization, and returned title/filename/label/path fields have independent UTF-8 byte caps.

SQLite opens the copy with `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW`. A pinned read transaction
forces the copied WAL/SHM to be opened before the parent, directory, database, and sidecar inodes are
validated again together with each component's size and modification/change timestamps. SQLite can
legitimately update the existing `-shm` metadata while establishing its WAL read locks, so only that
same safe sidecar inode receives a new baseline immediately after open; the database and WAL remain
strictly unchanged. A final strict check runs after the query, so ordinary same-inode rewrites fail
closed. Cleanup unlinks only the exact components relative to the retained
directory descriptor and removes the named directory only if its inode still matches. The user's
store is never opened for writing. These metadata checks are not same-user authentication against a
malicious process that can race individual syscalls; the local operating-system account remains the
trust boundary. If the process exits before normal cleanup, native app startup cleanup makes
exact-name, same-owner snapshot directories older than 24 hours eligible for removal. That
best-effort pass runs after socket startup on one retained utility task, incrementally inspects at
most 4,096 top-level temporary entries, and attempts at most 64 removals; later launches can process
leftovers beyond either budget.

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
- `json` — plain text plus a `segments_json` metadata field with `text`, `start`, and `end`.
  That field is a complete JSON array of whole segments capped at exactly 40,000 UTF-8 bytes;
  `segments_returned` and `segments_truncated` report what fit.

Before Foundation decodes a `tsrp` payload, a linear byte preflight rejects JSON with a nesting depth
above 64, or with more than 262,144 nodes or 65,536 containers. Delimiters inside quoted strings
do not count. Decoded payloads are then limited to 65,536 runs, 32,000 attribute entries, 30,000
segments, 1,000,000 cumulative transcript UTF-8 bytes, and a 128-byte locale identifier. These
internal parsing limits are independent of the exact 750,000-byte transcript response cap.

## Transcription

A memo recorded on iPhone and synced through iCloud arrives on the Mac with no transcript at all, so
reading the `tsrp` atom is not enough. `voicememos_transcribe` works through four sources, cheapest
first:

1. **The stored transcript** in the recording — free, no recognition run, works on macOS 15.
2. **An earlier cached run**, keyed on `ZAUDIODIGEST`, the SHA-256 Voice Memos already maintains.
   Keying on the digest rather than a modification date means the cache survives file touches and
   iCloud evict/restore cycles. Empty transcripts are never cached, so a recording with no speech is
   not pinned to an empty result forever.
3. **`SpeechAnalyzer` / `SpeechTranscriber`** on macOS 26 — the same engine Voice Memos uses for its
   own transcripts. First use of a locale can download its on-device model. Recordings that
   `AVAudioFile` cannot open directly, such as edited `.qta` files, are decoded through
   `AVAssetReader` as a pull-driven, in-memory `AnalyzerInput` sequence. No decoded scratch file
   is created.
4. **`SFSpeechRecognizer`** when the newer analyzer cannot service the call, including macOS 15 to
   25. AppleMCP checks `supportsOnDeviceRecognition` before starting a task and sets
   `requiresOnDeviceRecognition = true`. If the locale cannot run on device, the call fails; there is
   no cloud-recognition fallback. Work is bounded by `timeout_seconds` (default 300; accepted range
   10...1800), and the task is cancelled when it expires. The bridge waits up to 1830 seconds for the
   local app response, reserving 30 seconds beyond the maximum provider deadline for cancellation,
   response encoding, and local delivery.

Values outside the documented `timeout_seconds` range are rejected instead of silently clamped.
The value is one whole-call monotonic budget: if the macOS 26 analyzer fails in a way that permits
the legacy fallback, the fallback receives only the remaining time rather than a second full
timeout.
Both recognition paths use monotonic time and return to the caller when the budget expires even if
an Apple framework operation takes longer to observe cancellation. Analyzer and legacy operations
each have a single-flight admission slot that remains occupied until the corresponding native task
actually exits; retries therefore fail as busy instead of accumulating background recognizers.
For the legacy path, cancellation is only a request: the slot and verified audio descriptor remain
held until the PCM feeder has unwound through its serialized `endAudio` call and
`SFSpeechRecognitionTask` reports `.completed`. The intermediate `.canceling` state is not treated
as drained.
The legacy deadline begins before authorization/capability checks and AVAsset metadata loading, not
only when the Speech task starts.
The legacy recognition callback also checks the same absolute monotonic deadline before publishing
a final result or stage error, because a dispatch timeout callback can itself be scheduled late.

Everything runs inside M3MCPApp, so macOS attributes the legacy fallback's Speech Recognition
permission to the signed app bundle rather than to the MCP bridge process. The framework can use the
network to download an on-device model asset; AppleMCP does not send the recording to a cloud
recognizer.

- The locale defaults to the system locale. Pass `language` (for example `de-DE`) to override it.
- Pass `prefer_stored: false` to skip steps 1 and 2 and force fresh recognition.
- Missing language packs surface as a clear error. Install them under
  System Settings > Accessibility > Voice Control.

Steps 3 and 4 write their result to
`~/Library/Application Support/M3MCP/transcripts/<audio-digest>.txt`, so
`voicememos_transcript` can return it afterwards — without timestamps, which only stored transcripts
carry. The cache directory is `0700`, cache files are `0600`, and cache entries do not expire
automatically. A cache key must be exactly 64 hexadecimal characters (the SHA-256 digest), and cache
reads and writes are limited to 16 MiB. Every directory component is opened without following
symlinks; cache files are created owner-only and atomically renamed within the validated directory.
A single MCP result returns at most 750,000 UTF-8 bytes of transcript and reports
`content_truncated`, `content_bytes`, and `returned_bytes` metadata when the cache or stored atom is
larger.

Before bounded decoding for the analyzer fallback or legacy PCM feeder, the selected audio track
must have valid duration and sample-rate
metadata, be no longer than 7,200 seconds, and estimate no more than 400,000,000 source frames. The
pull-driven decoder normalizes to mono 16 kHz Float32 PCM and stops before exceeding 115,200,000
decoded frames, 512 MiB of cumulative decoded PCM, or 500,000 sample buffers. Each frame/byte budget
is charged before allocating the next PCM buffer, the sequence holds at most the buffer currently
requested by the consumer, and cancellation is checked between buffers. Older AppleMCP versions
did create scratch CAF files; exact-name, same-owner leftovers older than 24 hours are still removed
at native app startup without following symlinks or sweeping unrelated temporary files.

`voicememos_audio` returns a path without loading the audio, or bounded base64 data. Base64 defaults
to a 4,000,000-byte ceiling; callers can lower it or raise it only as far as 5,000,000 bytes. Use
`format: "path"` for larger recordings so the bridge does not duplicate a large binary payload.

The macOS 26 engine, the digest cache, and the `.qta` fallback come from
[PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1) by
[@aheusingfeld](https://github.com/aheusingfeld).

## Permissions

| Permission | Needed for | Remediation |
|---|---|---|
| Full Disk Access | Reading `CloudRecordings.db` and the `.m4a` files | `permissions_open_settings` with pane `voice_memos` |
| Speech Recognition | Legacy `SFSpeechRecognizer` fallback in `voicememos_transcribe` | `permissions_open_settings` with pane `speech` |

Both appear in `permissions_status` as `voice_memos_store` and `speech_recognition`. Neither is
marked required, so a Mac without Voice Memos still reports a healthy permission state.

The macOS 26 `SpeechAnalyzer` path does not require Speech Recognition authorization. If the legacy
`SFSpeechRecognizer` fallback is needed, it checks authorization with prompting disabled. Missing
permission then returns an error; grant it manually in System Settings, or explicitly enable the
permission-UI group before using `permissions_request` or `permissions_open_settings`.

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

`swift test` includes `Tests/M3MCPCoreTests/VoiceMemoTranscriptTests.swift`, which builds recordings
with `tsrp` atoms in code — no private binary fixtures — and covers the atom walk, payload bounds,
64-bit atoms, malformed sizes, empty transcripts, duration-style time ranges, unsafe time values,
and timestamp rendering.

## Attribution

The store layout, the `tsrp` atom format, and the tool surface follow
[jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) (MIT), ported from
TypeScript to Swift for this app. See [THIRD_PARTY.md](THIRD_PARTY.md).
