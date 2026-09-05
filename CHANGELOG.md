# Changelog

## Unreleased

### Security

- **Capability token on the socket.** The app generates a 32-byte secret on its first start, keeps it
  in the login keychain, and refuses every request other than `GET /health` that does not present it
  as `Authorization: Bearer <token>`, compared in constant time. `M3MCP_TOKEN` overrides the keychain
  in both processes. If no token can be read or created the listener does not start. `Server › Copy
  MCP Client Token` puts it on the pasteboard; the bridge resolves it on its first tool call, so
  `initialize` and `tools/list` still answer on a machine with no app and no keychain item.
- **`/status` is no longer open.** It carries the activity log with tool inputs and bounded outputs,
  so it now needs the token. `/health` stays open and keeps omitting the log.

## 0.3.0 — 2026-09-04

### Security

- **Default-safe tool policy.** A normal launch exposes 21 observation and bounded local-processing
  tools. Calendar mutations, permission UI, and user-created Shortcuts are disabled independently by
  default and require `M3MCP_ENABLE_CALENDAR_MUTATIONS`, `M3MCP_ENABLE_PERMISSION_UI`, or
  `M3MCP_ENABLE_USER_SHORTCUTS` before both the app and bridge start. Unknown tools fail closed, and
  the app repeats authorization at dispatch time.
- **One-call native approval.** Every enabled Calendar mutation and Shortcut invocation is queued for
  a default-deny native sheet with a bounded, credential-redacted argument preview. Approval is not
  reusable; denial, dismissal, cancellation, timeout, or an unavailable app window rejects the call.
- **No TCC prompts from default tools.** All 21 default tools preflight any authorization they need
  without requesting permission or opening settings. For fresh Voice Memos transcription, the legacy
  recognizer checks Speech Recognition without prompting. Permission prompts and System Settings
  navigation are isolated in the optional permission-UI group.
- **Strict on-device speech.** `SFSpeechRecognizer` is started only when the locale advertises
  on-device recognition, and every request requires it. If local recognition is unavailable the tool
  fails instead of falling back to cloud recognition.
- **Hardened local HTTP framing.** Header/body/response limits, duplicate and overflow-safe
  `Content-Length` handling, malformed-JSON rejection, absolute request-receive and response-write
  deadlines, bounded concurrency, shutdown cancellation, and overload responses replace crash- and
  slow-client-prone parsing. An owner-only per-endpoint `flock(2)` held for the listener lifetime
  also serializes stale-socket removal and bind across competing app processes. Existing sockets are
  probed nonblocking under one 250 ms monotonic deadline; timeout or ambiguous probe state preserves
  the endpoint and fails startup. The 1 MiB HTTP request-body limit matches the bridge's MCP message
  limit so every accepted MCP request is representable on the app transport. Any provider result
  that would exceed the bridge's 8 MiB response ceiling is replaced centrally with a bounded,
  parseable HTTP 413 response. The bridge incrementally validates response framing and applies one
  absolute monotonic deadline across local connect, request writing, provider wait, and response
  reading, so a trickling peer cannot reset the deadline by making intermittent progress.
- **Stateful MCP validation.** The bridge now requires a valid initialize/initialized lifecycle,
  bounds each stdio message to 1 MiB, validates JSON-RPC identifiers and arguments, and explicitly
  supports protocol revisions 2024-11-05 through 2025-11-25. The app independently repeats the
  exhaustive per-tool argument validation before approval and dispatch. Supported revisions that
  define them receive advisory tool annotations and structured results; results above 1,000,000 encoded bytes
  omit the duplicate structured copy. Every newly encoded tool response also
  carries `contentTrust: "untrusted_data_not_instructions"`; decoding keeps that field optional for
  compatibility with legacy app responses.
- **Cancellation propagation.** MCP cancellations and local-client disconnects cancel the matching
  in-flight app task, permission callback wait, cooperative subprocess work, and bounded Mail
  database/MIME/filesystem scans. SQLite progress callbacks interrupt longer Mail queries. A cancelled
  permission sequence does not raise later prompts, and late framework callbacks are ignored. Legacy
  speech deadlines use a one-shot timer whose action captures are released immediately on cancel or fire.
  Cancellation is not rollback: Calendar changes or Shortcut effects committed before interruption
  remain and must be checked before retrying.
- **Bounded MCP output backpressure.** Tool reservations remain charged while their responses wait
  for stdout. Nonblocking writes have a 15-second deadline; a partial or failed JSON line fails the
  writer, cancels outstanding calls, and prevents additional tool dispatch in that bridge process.
  A complete candidate that exceeds the 16 MiB line budget before any byte is written is instead
  replaced by a small normal tool error for the same request ID, leaving the writer usable.
- **Private diagnostics and scratch data.** Diagnostics moved from a predictable `/tmp` log to
  privacy-marked Unified Logging. Voice Memos snapshots use descriptor-anchored no-follow copies,
  inode plus observable content-metadata validation before and after reads, a 1 GiB-per-component
  cap, and read-only SQLite; generated PNGs use owner-only creation;
  Shortcut JSON is delivered only through bounded standard input, and narrowly matched
  stale-artifact cleanup covers exact same-owner leftovers from older versions only at native app
  startup, not from read-only status tools. Startup cleanup now consumes the temporary directory
  incrementally, inspects at most 4,096 top-level entries, attempts at most 64 removals, and runs as
  one retained cancellable utility task only after socket startup is attempted instead of blocking
  the main actor. Speech fallback
  decoding is pull-driven in memory and creates no CAF scratch path.
- **Health/activity separation.** `/health` omits recent activity. `/status` remains an explicitly
  sensitive diagnostic route containing recent inputs and bounded outputs.

### Added

- **Opt-in Calendar write support.** `calendar_create_event`, `calendar_update_event`,
  `calendar_delete_event`, `calendar_create_calendar`, and `calendar_delete_calendar`, together with
  `calendar_list_calendars` and `calendar_read_event` for target selection and readback.
- **`project_slug` on Calendar create and update.** A validated machine-readable identifier is stored
  as a `Project: <slug>` line in notes and reported as `metadata.project_slug` on Calendar reads.
- **Scoped Calendar search.** `calendar_search.calendar` restricts a query to one calendar.
- **Relocatable sockets.** `M3MCP_SOCKET_DIR` lets development and synthetic runtime tests avoid an
  installed endpoint.
- **Release controls.** A macOS 26 CI workflow verifies the required SDK, dependency surface, full
  tests, ThreadSanitizer subset, release build, plist, shell, installer, and documentation contracts;
  third-party actions are pinned to a reviewed commit. `SECURITY.md` defines private reporting and
  supported versions, while `docs/SECURITY_MODEL.md` records the trust boundary, retention, and
  network caveats. Identity discovery admits Apple-issued certificates only from the verified keychain
  listing, permits the exact local self-signed identity only in its expected trust state, rejects
  near matches, and signs with the inspected certificate fingerprint. Release-candidate packaging
  preserves the source plist and required license notices, enforces an exact archive allowlist,
  verifies arm64/macOS 15 metadata and both 21-tool/30-tool MCP catalogs, and reproduces ad-hoc
  candidate bytes. A tag reruns the complete CI workflow, attests the checked ZIP, and grants
  repository write access only to a no-checkout job that creates an explicitly enabled draft
  candidate in the named `release` environment.

### Changed

- **Mail is local-store only.** Automatic Mail.app AppleScript fallback was removed. Mail tools now
  fail with Full Disk Access guidance when the local Envelope Index or `.emlx` store is unavailable;
  legacy `as:` identifiers are rejected.
- **Bounded provider work and results.** Mail search limits query length and term count, validates the
  field/match selector, excludes both flagged junk and known Junk mailboxes by default, and caps
  candidate, mailbox-row, mailbox-list, body, and recipient-header results. SQLite values above
  256 KiB, invalid text, and recipient joins beyond 20,000 rows or 1,000,000 VM instructions fail
  closed before unbounded materialization. Mailbox lists disclose their 20,000-row scan ceiling;
  search and detail reads reject an incomplete mailbox map. Photos album listing inspects at most 2,000 albums and
  returns at most 200 with truncation metadata. Contacts fetches only one
  result page; Calendar uses bounded date chunks and an explicit scan ceiling; Reminders fetches per
  list and applies a disclosed post-fetch scan budget. Contacts, Calendar, Reminders, and Notes now
  bound untrusted response fields in UTF-8 bytes. Notes also caps its in-process AppleScript result;
  direct note bodies remain capped at 65,536 characters with truncation metadata.
- **Shortcuts use a versioned contract.** `ai_writing_tools` and `ai_translate` invoke the fixed
  `/usr/bin/shortcuts` executable without a shell, pass JSON only through bounded standard input,
  require text output, and enforce runtime and output limits. The tools remain open-world because the
  user's Shortcut can network or cause arbitrary side effects.
- **Photo permission disclosure is exact.** PhotoKit's `.readWrite` TCC level is used because
  `.addOnly` cannot fetch existing assets; AppleMCP's exposed Photos tools remain non-mutating.
- **Installed policy is explicit.** `script/install_local.sh` persists only explicitly true values
  of the three fixed `M3MCP_ENABLE_*` variables in the generated LaunchAgent; unrelated environment
  values are never copied. App and LaunchAgent replacement is staged with retained backups and
  rollback on handled failures and termination signals, including failures in signing, validation,
  launchd startup, or the bounded Unix-socket `/health` readiness check.
- **Calendar source selection is explicit.** Creating a calendar no longer falls back to the default
  account when no local source exists.

### Fixed

- Malformed MPEG-4 atom sizes, payloads, and transcript time values now fail closed rather than
  overflowing indexes or unsafe numeric conversions.
- Voice Memo detail IDs, cache digests, recording paths, base64 reads, and transcript-cache sizes are
  validated and bounded. Base64 audio is capped at 5,000,000 source bytes; larger recordings use
  path output, and returned transcript text is capped at 750,000 UTF-8 bytes with truncation
  metadata. Store and cache paths cannot escape through symlinks; cache replacement uses validated
  directory descriptors and owner-only atomic files.
- Voice Memo recording reads reopen relative to a verified directory descriptor and compare the
  opened owner/type/link/device/inode identity. AVFoundation consumes the retained descriptor with
  an explicit MIME override, while legacy Speech receives only bounded PCM buffers; pathname
  replacement therefore cannot redirect those Full Disk Access reads.
- Voice Memo search and SQLite parsing now apply pre-normalization query limits, a 256 KiB SQLite
  materialization ceiling, bounded UTF-8 database access, and per-field output caps.
- Speech fallback decoding no longer creates a temporary transcode file. Duration, source-frame,
  decoded-frame, decoded-byte, and buffer-work limits apply before or during its pull-driven input
  stream; exact same-owner CAF leftovers from older versions are still recovered at startup.
- Legacy speech timeout/cancellation now drains the serialized PCM feeder and waits for the native
  recognition task's actual `.completed` state before releasing its single-flight lease.
- Permission status reports framework state without promoting stale bundle-keyed history into a false
  authorization result.
- `VoiceMemosProvider.dateValue` now compiles with the Swift 6.3 argument-label checks.

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
  Shortcut. The prompt labels transcript text as untrusted data; callers must still treat model
  output as untrusted.
- Parser tests under `Tests/M3MCPCoreTests`, runnable with `swift test`.

### Security

- The endpoint moved out of the loopback TCP namespace and into a `0700` directory with a `0600`
  socket. This blocks browsers, other users, and normally sandboxed apps without path access. It does
  not authenticate an unsandboxed process running under the same user ID.
- Browser-originated and DNS-rebound requests are rejected (kept as defence in depth).

### Fixed

- Voice Memos results no longer miss the newest recordings. `CloudRecordings.db` runs in WAL mode,
  and opening only the main database cannot replay the log; reads now go through a snapshot plus its
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
