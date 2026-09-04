# Changelog

The version of this project is the first `## X.Y.Z` heading below. Nothing else in the repository
carries a version number: `script/package_release.sh` writes this one into the app bundle's
`Info.plist`, and the release workflow refuses a tag that does not match it. `script/version.sh`
reads it.

## Unreleased

### Added

- **Client authentication on the socket.** The only access control on
  `~/Library/Application Support/M3MCP/mcp.sock` was the filesystem: `0600` in a `0700` directory.
  That keeps out other users, sandboxed apps and web pages, and nothing else — every unsandboxed
  process of the same user could connect and inherit the app's Full Disk Access. Two checks now sit
  in front of every request except `GET /health`:
  - a **capability token**, 32 bytes from `SecRandomCopyBytes`, created on the app's first start and
    kept in the login keychain. `M3MCPBridge` sends it as `Authorization: Bearer …`, reading it from
    `M3MCP_TOKEN` or from the keychain. Missing or wrong is `401`.
  - the **code identity of the connecting process**. `getsockopt(LOCAL_PEERTOKEN)` yields the peer's
    audit token — not a pid, which can be recycled between `accept` and the lookup — and the Security
    framework turns it into a `SecCode` whose signature is checked and whose code directory hash is
    read. The app pins that hash to the `M3MCPBridge` beside its own executable, so a token copied
    out of an MCP client's config and replayed by another process is `403`.

  A `getpeereid` check was considered and left out on purpose: a `0600` socket in a `0700` directory
  means the kernel already refused every other uid, so it would restate a condition rather than add
  one. Answers [issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9).
- **`M3MCP_TOKEN`** configures a client that cannot answer a keychain prompt, and
  **`M3MCP_TRUSTED_CLIENT_CDHASH`** pins a bridge that lives outside the app bundle.
- **Server › Copy MCP Client Token** (⇧⌘T) puts the token on the pasteboard, and the app window and
  `/health` both report whether the client binary is pinned or whether the install is running
  token-only.

### Changed

- **`/health` no longer carries the call history.** It was the same reply as `/status`, so
  `recentActivity` — the last 30 calls with their arguments and results — was readable by anything
  that could open the socket. `/health` stays free of a token because it is the documented probe, and
  now answers with version, endpoint, providers and the state of the client check. `/status` returns
  the history and needs the token.
- **`LocalHTTPServer` moved from the app target to `M3MCPCore`.** Security code that only runs inside
  a GUI app is security code nobody checks; from `M3MCPCore` the authorization path is exercised by
  `swift test`, including a case that launches the packaged `M3MCPBridge` as a real client.
- **`script/install_local.sh` installs `M3MCPBridge` into the bundle** next to the app, the way
  `script/package_release.sh` already did. Without a sibling bridge there is nothing for the app to
  pin, and the documented install path produced exactly that.

## 0.3.0

### Added

- **Calendar write support.** `calendar_create_event`, `calendar_update_event` and
  `calendar_delete_event`, plus the three tools a caller needs to use them safely:
  `calendar_list_calendars` (which calendar, and is it writable), `calendar_read_event` (read one
  event back by id — `calendar_search` scans a date window, so it cannot confirm a write that moved
  an event out of that window), and `calendar_create_calendar` / `calendar_delete_calendar`.
- **`project_slug` on create and update.** A machine-readable project identifier, stored as a
  `Project: <slug>` line at the top of the notes and reported back as `metadata.project_slug` by
  every calendar read path. Notes rather than `url`, because `EKEvent.url` is dropped by some CalDAV
  and Exchange servers while notes are plain text everywhere. Slugs are validated, so a slug carrying
  a newline cannot plant a second marker.
- **`calendar` on `calendar_search`**, to scope a search to one calendar. Without it a busy range can
  push a specific event past the 100-item ceiling.
- **`raw_state` on the permission items that can disagree with themselves.** `permissions_status`
  promotes a `not_determined` status to `authorized` from a `UserDefaults` flag; that flag is keyed on
  the bundle identifier, so a second build of the app inherits it and claims access it does not have.
  `raw_state` reports what the framework actually said.
- **`M3MCP_SOCKET_DIR`** relocates the endpoint for both the app and the bridge, so a development
  build can run beside an installed one. `LocalHTTPServer.start()` unlinks the socket path before
  binding, so without this a development build silently steals the installed app's endpoint.
- **`M3MCP_TCC_REQUEST_TIMEOUT_SECONDS`** bounds the wait for the macOS permission dialog.
- **A downloadable build.** `script/package_release.sh <dir>` produces `M3MCP.app.zip` and
  `M3MCP.app.zip.sha256` offline, and `.github/workflows/release.yml` attaches both to the release a
  `v*` tag creates. The bundle carries `M3MCPBridge` in `Contents/MacOS`, so an MCP client can be
  pointed at the download without a checkout. The app is signed ad hoc: no Developer ID, no
  notarisation, a Gatekeeper warning on first launch, and a Full Disk Access grant that has to be
  given again after every update because the designated requirement is the binary hash.
- **`script/check_release_artifact.sh`** runs in CI on every push. It packages, checks the archive
  against an exact list of expected entries, verifies the signature and the checksum, starts the
  packaged bridge to see which version it reports to an MCP client, and compares a second packaging
  run byte for byte. A broken package fails before a tag is set instead of after.

### Changed

- **Calendar tools no longer request access on every call.** They read
  `EKEventStore.authorizationStatus` first and only prompt when it is `notDetermined`. The old path
  called `requestFullAccessToEvents` on every `calendar_search`, which re-activated the app each time
  and, after a denial, asked an already-answered question instead of reporting what was wrong.
- **A permission request is bounded.** An unanswered dialog never calls its completion handler, so the
  old code hung for as long as the client would wait — indistinguishable from a broken server. It now
  returns an error naming the missing permission.
- **`calendar_create_calendar` will not fall back to the default calendar's source.** On a machine
  with no local ("On My Mac") source the old-style fallback would create a calendar inside whichever
  account happened to be default. It now says so and asks for `source` explicitly.

### Fixed

- `VoiceMemosProvider.dateValue` called `doubleValue(statement, column)` without the required
  argument label, so `main` did not compile with Swift 6.3.

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
