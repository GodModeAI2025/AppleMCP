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
    read. The app pins that hash to the `M3MCPBridge` beside its own executable, so a socket client
    someone writes themselves is `403` even holding the right token.

    What that does not do is make a copied token useless. The pin identifies the binary on the other
    end, not the process that started it: anything that can read `M3MCP_TOKEN` out of an MCP client's
    config can also run `M3MCP.app/Contents/MacOS/M3MCPBridge`, and that bridge is the one the pin
    trusts. What an attacker loses is the direct path: no client of their own, only the shipped bridge
    and whatever it will do. Without the token that is nothing — the bridge refuses the keychain item
    it did not create rather than asking anyone. With the token it is everything, and that is the
    whole of it.
    `SocketAuthenticationTests.testThePinRefusesAHandwrittenClientAndPassesTheBundledBridge` measures
    both halves.

  A `getpeereid` check was considered and left out on purpose: a `0600` socket in a `0700` directory
  means the kernel already refused every other uid, so it would restate a condition rather than add
  one. Answers [issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9).
- **`M3MCP_TOKEN`** is how a client is configured — the keychain fallback only reaches an item whose
  ACL already names the bridge binary, and the bridge never asks for one that does not — and
  **`M3MCP_TRUSTED_CLIENT_CDHASH`** pins a bridge that lives outside the app bundle.
- **Server › Copy MCP Client Token** (⇧⌘T) puts the token on the pasteboard, and the app window and
  `/health` both report whether the client binary is pinned or whether the install is running
  token-only.
- **Two-step confirmation for the calendar write tools.** `calendar_create_event`,
  `calendar_update_event`, `calendar_delete_event`, `calendar_create_calendar` and
  `calendar_delete_calendar` no longer write on the first call. That call returns `ok: false` with a
  preview — for the two tools that change an existing event, the event as it stands right now — and a
  `confirm_token` in `meta`; repeating the call with the same arguments plus that token carries the
  write out.

  The token is an HMAC over the tool name and the canonical form of the arguments, so a token issued
  for moving one meeting cannot confirm deleting a calendar. It expires after five minutes, and the
  key is fresh per app start, so a pending confirmation does not survive a restart.

  The check sits in `LocalMCPService.handle` ahead of every provider, not in the tool schema: the
  bridge answers `tools/list` out of its own catalog without asking the app, so a schema that
  declares `confirm_token` says nothing about what the socket does. `confirm_token` is declared in
  `ToolCatalog` all the same — the schemas set `additionalProperties: false`, and a client that
  validates its arguments would otherwise drop the parameter and never get past step one.

### Fixed

- **A local process with no token could take the endpoint away from one that had it.** Every accepted
  connection was handed to a thread that then blocked in `read` with no timeout, and authorization
  happens after the request has been read whole, so 120 connections that connected and said nothing
  were enough: `/health` and authenticated tool calls both ran into their timeouts. A connection
  waiting for a request is now read through a dispatch source and costs a descriptor and a deadline
  rather than a thread; the deadline answers `408` and drops it. A thread is committed only once a
  complete request exists, and both counts are capped — 128 connections waiting, 32 requests being
  served, anything past that is `503` straight away.
  `SocketAuthenticationTests.testIdleConnectionsCannotStarveTheEndpoint` measures it: with 120 idle
  connections in place, `/health` and a tool call used to hit an eight second timeout and now answer
  in 0.04 seconds. What it is not is immunity: 128 connections held open still refuse the 129th until
  a deadline frees a slot, and SECURITY.md says so under Known Gaps. The listen backlog went from 16
  to the same 128 in the same breath — at 16 a burst overran it and the kernel answered a perfectly
  ordinary client with ECONNREFUSED before the server ever saw it.
- **The bridge hung instead of answering when it was not allowed to read the keychain item.** With no
  `M3MCP_TOKEN` set, the bridge reads the token from the login keychain — an item the app created, so
  the ACL names the app and a read from the bridge needs the user's confirmation. Measured with an
  item written by one binary and read by `M3MCPBridge`: `SecItemCopyMatching` had not returned after
  25 seconds and nothing had been printed, because the panel was waiting in a session an MCP client
  does not have. `kSecUseAuthenticationUI` turned out not to govern that panel at all — with
  `…UIFail` and with `…UISkip` the call still hung past 20 seconds — so the client path now turns
  interaction off with `SecKeychainSetUserInteractionAllowed`, deprecated and the only thing that
  works on the file-based login keychain. The same read comes back in 15 milliseconds, and the
  refusal names `M3MCP_TOKEN` and says the keychain item exists but may not be read without asking.
  The app's own read is untouched and still prompts.
- **`mail_search` lost body-only matches without saying so.** With `fields` containing `body`
  alongside anything else, the SQL term clause narrowed the candidate rows to subject, sender and
  recipient hits, and the body was then read from those rows only. A message carrying the search term
  solely in its body never became a candidate, was never opened, and the reply still reported
  `total_exact: true`. The candidate set is now the union of two queries: every row the term clause
  matches on the indexed fields, which stays exact, and the newest `max_candidates` rows in scope
  regardless of terms, which is the window the body is read from.

### Changed

- **`body` is in the default `fields` of `mail_search`.** It was opt-in, so a plain
  `mail_search("Rechnung")` searched subject, sender and recipients and never opened a message. That
  costs one file read per message in the scan window, and it is what makes the tool a full-text search
  rather than a header search.
- **A body search bounds the index side too, and now says so.** With `body` among the fields the
  candidate set is fetched twice with `limit: max_candidates` — once for the index hits, once for the
  scan window — so a query with more subject matches than that gets a `meta.total` that is a lower
  bound, and `offset` pages inside the candidate set instead of over the index. Measured on a
  synthetic index with 3000 subject hits: the default path returns 500 candidates and nothing at all
  at `offset: 1000`, while the same query without `body` in `fields` pages in SQL and answers 25.
  That is the cost of having `body` in the default, and the README, the tool description and the
  reply now name it: `meta.index_capped` is new next to `meta.body_scan_capped`, and the message no
  longer blames the body scan for a cut the index side took. A caller that needs an exact total and
  SQL paging passes `fields` without `body`.
- **Honest body-scan metadata.** `meta.body_searchable` was the constant `"true"`, which said nothing.
  It is replaced by `body_searched`, `body_scan_limit`, `body_scan_capped` and `body_messages_read`.
  `total_exact` is false exactly when the scan window was full, so an incomplete answer no longer
  looks like a complete one.
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
- **README and index.html point MCP clients at the bridge inside the bundle**, not at
  `.build/release/M3MCPBridge`. The two copies are the same source and different code directory
  hashes — `.build/release/M3MCPBridge` carries the ad-hoc signature SwiftPM emitted, the bundled one
  was signed again by the packaging or install script — so with the pin in place the old instruction
  would have produced a refusal on every call. `script/build_and_run.sh` puts no bridge in its
  bundle, so that path runs token-only and `.build/release/M3MCPBridge` still applies; the README
  table says which is which.

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
