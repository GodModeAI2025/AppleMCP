# Changelog

## Unreleased

### Added

- **`mail_search` can be paged, scoped and trusted.** New inputs `offset`, `mailbox`, `fields`,
  `match`, `include_junk`, `include_recipients` and `auto_intent`; `limit` now goes to 500 instead of
  being silently clamped to 50.
- **`mail_list_mailboxes`**: every mailbox in the index with its account, path, role (`inbox`, `sent`,
  `drafts`, `archive`, `junk`, `trash`, `folder`) and message counts — so a `mailbox` filter can name
  something that exists.
- **`ToolResponse.meta`**, an optional string map. `mail_search` fills in `total`, `returned`,
  `offset`, `limit`, `has_more`, `truncated`, `total_exact`, `scanned`, `scan_capped`,
  `fields_matched` inputs, and `recipients_searchable`. Additive: every existing decoder and every
  provider that does not set it are unaffected.
- Each mail item now reports `mailbox`, `mailbox_role` and `fields_matched`, so a hit can be
  attributed to a folder and to the field that matched it.
- `M3MCP_MAIL_ROOT` relocates the Mail store root the provider reads, so the search behaviour can be
  tested against a synthetic Envelope Index. Read-only, like the provider.

### Fixed

- **A sender address behind a display name was unsearchable.** The query matched
  `COALESCE(addresses.comment, addresses.address)`, so a non-null display name masked the address
  column: measured on a real store, three address-shaped queries returned 150 items with **zero**
  sender matches — every hit came from a subject line. Display and matching are now separate
  expressions, and `firstname.lastname` actually searches an address.
- **Recipients were never searched**, so "the message I sent to X" was findable only if X appeared in
  the subject. `mail_search` now joins `recipients` when the schema has it, and reports
  `meta.recipients_searchable` when it does not.
- **A truncated result was indistinguishable from a complete one.** `limit:200` returned 50 items with
  `message: null`. `meta.truncated` / `meta.has_more` / `meta.total` now say so.
- **A multi-word query was matched as one substring**, so `"Graph API"` returned nothing while
  `"Graph"` returned 23. Terms are ANDed by default; `match:"phrase"` keeps the old behaviour.
- `since_hours` is applied in the query rather than to an already-truncated page.
- `include_body` was documented and never read; it now returns a body snippet, and `fields:["body"]`
  searches message bodies within a `max_candidates` bound that `meta.scan_capped` reports.
- The `mail_search` schema claimed inbox-only scope (`"Maximum inbox messages to inspect"`). The SQL
  never had a mailbox predicate — the description was wrong, not the code.
- `VoiceMemosProvider.dateValue` called `doubleValue(statement, column)` without the `column:` label,
  so the app target did not build with Swift 6.3.

## 0.2.0

### Breaking

- **The local endpoint moved from `127.0.0.1:47651` to a Unix domain socket** at
  `~/Library/Application Support/M3MCP/mcp.sock`. MCP client configuration is unaffected — clients
  launch the bridge, and only the bridge knows the transport — but **the app and the bridge must be
  rebuilt together**. A 0.1.0 bridge cannot reach a 0.2.0 app. Anything that called the TCP port
  directly now uses:

  ```bash
  curl --unix-socket ~/Library/Application\ Support/M3MCP/mcp.sock http://localhost/health
  ```

- `StatusResponse` reports `endpoint` (the socket path) in place of `port`.

### Added

- **Voice Memos** as a data source: `voicememos_search`, `voicememos_read`, `voicememos_transcript`,
  `voicememos_audio`, `voicememos_transcribe`. Reads the local `CloudRecordings.db` and the
  transcripts macOS stores inside the recordings themselves.
- **Transcription cascade** for recordings without a stored transcript — a memo recorded on iPhone
  arrives with none: cached earlier run (keyed on `ZAUDIODIGEST`), then `SpeechAnalyzer` on
  macOS 26, then `SFSpeechRecognizer` on macOS 15 to 25.
- **`ai_summarize`** over the on-device foundation model: summaries and action items without a
  Shortcut. Transcript text is fenced as data so instructions inside a recording are not followed.
- Parser tests under `Tests/M3MCPCoreTests`, runnable with `swift test`.

### Security

- The endpoint is no longer reachable by other local processes. The app holds Full Disk Access, so
  anything that reached the old TCP port borrowed that privilege — including sandboxed apps that
  macOS specifically prevents from reading the underlying data. Access control is now filesystem
  permissions: `0700` directory, `0600` socket.
- Browser-originated and DNS-rebound requests are rejected (kept as defence in depth).

### Fixed

- Voice Memos results no longer miss the newest recordings. `CloudRecordings.db` runs in WAL mode,
  and a read-only open cannot replay the log; reads now go through a snapshot of the store plus its
  `-wal`/`-shm` sidecars.
- Deleted memos are no longer listed as current ones — `ZEVICTIONDATE` is the deletion timestamp,
  not an iCloud eviction marker. Placeholder rows with an empty `ZPATH` are filtered out.
- Writing Tools and Translate report a missing Shortcut as a failure instead of `ok: true` carrying
  the error text as its result.
- The bridge no longer reports the app as unreachable while it is still working; its socket timeout
  is 600s.

### Credits

Voice Memos support began as a Swift port of
[jwulff/apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) (MIT). The macOS 26
transcription engine, the digest-keyed cache, `ai_summarize`, the Shortcut fix, and the store
findings come from [@aheusingfeld](https://github.com/aheusingfeld) via
[PR #1](https://github.com/GodModeAI2025/AppleMCP/pull/1).

## 0.1.0

Initial release: Mail, Calendar, Contacts, Reminders, Notes, Photos, and Apple Intelligence tools
over a local HTTP endpoint with an MCP `stdio` bridge.
