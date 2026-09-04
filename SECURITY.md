# Security Policy

Answers [issue #10](https://github.com/GodModeAI2025/AppleMCP/issues/10). AppleMCP runs with Full Disk Access and TCC grants for Mail, Calendar, Contacts, Reminders, Notes, Photos and Voice Memos, and re-exposes them over a local socket to an MCP client. That makes the app a privilege boundary of its own, so the boundary is worth writing down.

## Supported Versions

There is no tagged release and no published binary. `Sources/M3MCPCore/CoreModels.swift` line 3 hardcodes `m3mcpVersion = "0.2.0"`, while `git tag -l` is empty and the repo has no releases.

| Version | Supported |
|---|---|
| current `main` | yes |
| anything else | no |

Fixes land on `main`. Updating means pulling and rebuilding. App and bridge have to come from the same commit: "A 0.1.0 bridge cannot reach a 0.2.0 app" (CHANGELOG.md, 0.2.0).

## Reporting a Vulnerability

Private vulnerability reporting is enabled on this repo. Report through:

**https://github.com/GodModeAI2025/AppleMCP/security/advisories/new**

Do not open a public issue for a vulnerability. A public write-up about the socket, TCC or the signing identity tells anyone reading it how to reach a running installation, weeks before there is a fix.

Expect an acknowledgement within a few days and an assessment with a rough fix window within two weeks. There is no on-call rotation and no SLA. If two weeks pass without an answer, a nudge in the advisory thread is welcome.

## Threat Model

Assets, ordered by what losing them costs:

- Mail. Apple Mail's `Envelope Index` (SQLite) and the `.emlx` bodies below `~/Library/Mail`. `MailProvider.swift` opens every connection `SQLITE_OPEN_READONLY` (line 1324) and no code path there sends, files or deletes anything.
- Voice memos. `CloudRecordings.db`, the recordings, and the transcripts macOS stores inside them.
- Calendar, Contacts, Reminders, Notes and Photos metadata, through EventKit, Contacts.framework, PhotoKit and Notes AppleScript.
- The calendar as a write target. Five tools create, change and delete events and calendars (`CalendarProvider.swift`).
- The code signing identity created by `script/create_local_identity.sh`.

Who attacks, over which path:

1. **An unsandboxed local process running as the same user.** The main case, and the one the client authentication addresses. It connects to `~/Library/Application Support/M3MCP/mcp.sock` and, until then, nothing told it apart from the real bridge: it read mail, contacts and voice memos through the app's Full Disk Access without triggering a TCC prompt of its own. It now has to present the capability token, and where the app found an `M3MCPBridge` next to its own executable it also has to *be* that binary. What remains: a process that can read the MCP client's config file has the token, and on an installation with no sibling bridge the token is all there is. See Known Gaps.
2. **Prompt injection through returned content.** Mail bodies, note text, calendar notes and transcripts are written by other people, and they travel to a model that can call `calendar_create_event`, `calendar_update_event` and `calendar_delete_event`. `FoundationModelsProvider.wrapUntrusted` (line 123) fences transcript text as data before `ai_summarize`, and the `ai_summarize` description in `Sources/M3MCPBridge/ToolCatalog.swift` (line 275) tells the client to treat that output as untrusted. Nothing fences `mail_read`, `mail_search`, `notes_read` or `voicememos_transcript`. Their output reaches the client raw.
3. **Anyone who can sign with the local identity.** The app's designated requirement is the bundle identifier plus the self-signed certificate. A binary carrying `de.markzimmermann.m3mcp` and signed with that key satisfies it and inherits the Full Disk Access grant; `script/create_local_identity.sh` lines 47 to 56 record the `codesign --verify -R` check that confirmed this. Surviving rebuilds is the whole purpose of a stable identity, and it is also what turns the key into a reusable capability. That is why the key is imported with no standing access and why `M3MCP_ALLOW_CODESIGN_NOPROMPT` prints a warning.
4. **Client text flowing into AppleScript.** `AppleIntelligenceProvider.swift` builds `do shell script` calls at lines 227 and 240, the second by way of `/usr/bin/python3`. `NotesProvider.swift` (lines 76 and 144) and `MailProvider.swift` (line 1674) interpolate client strings into `tell application` scripts, escaping backslash and double quote. `buildTranslationScript` escapes the apostrophe as well (line 236) and then feeds the same string through `quoted form of` (line 240), so the apostrophe is escaped twice. `Tests/M3MCPCoreTests` holds two test files, neither of which touches AppleScript, so the behaviour of this escaping on adversarial input is unverified rather than known-good.
5. **A sandboxed app or a web page.** Neither can open a Unix domain socket inside a `0700` directory. This is the case the design stops, and the reason the endpoint is not a loopback TCP port (`Sources/M3MCPCore/LocalEndpoint.swift` lines 5 to 9).

## Trust Boundaries

- **MCP client to bridge.** stdio, inherited from the client process. The bridge trusts what it reads. A tool call arriving over stdio counts as the user's intent, and the bridge cannot tell a call the user meant from one the model was steered into.
- **Bridge to app.** The Unix socket, and three checks in front of it (`Sources/M3MCPCore/LocalHTTPServer.swift`, `SocketAuthorizer.swift`, `PeerIdentity.swift`).

  1. *Filesystem.* The directory is `0700`, the socket is bound under `umask(0o177)` and chmodded `0600`. This keeps out other users, sandboxed apps and browsers, and nothing else.
  2. *Capability token.* 32 bytes from `SecRandomCopyBytes`, created on first start and kept in the login keychain, presented as `Authorization: Bearer …` and compared in constant time. Missing or wrong is `401`. The only path exempt is `GET /health`, which answers with version, endpoint and the guard state and carries no call history.
  3. *Peer code identity.* `getsockopt(LOCAL_PEERTOKEN)` yields the connecting process's audit token — not a pid, which can be recycled between `accept` and the lookup — and `SecCodeCopyGuestWithAttributes` turns it into a `SecCode`. `SecCodeCheckValidity` rejects code that no longer matches its signature, and `kSecCodeInfoUnique` gives the code directory hash. The app pins that hash to the `M3MCPBridge` beside its own executable. A valid token from any other binary is `403`.

  The uid is deliberately *not* checked. A `0600` socket in a `0700` directory means the kernel already refused every other uid, so `getpeereid` would restate a condition rather than add one.

  What the pin buys, given there is no Developer ID: a code directory hash is computed over the binary's own pages, so it holds for an ad-hoc signature exactly as it does for a certificate. What it costs: it changes with every rebuild, so the pin is recomputed at each start from whatever bridge is installed, and a bridge that lives outside the bundle has to be named in `M3MCP_TRUSTED_CLIENT_CDHASH`.

  `RequestGuard` still rejects requests carrying `Origin`, `Referer` or `Sec-Fetch-*` and requires `Content-Type: application/json` on tool calls. That checks the shape of a request, not who sent it, and it is kept as defence in depth rather than as access control.
- **App to macOS.** TCC and Full Disk Access. The app is not sandboxed and the repo contains no `.entitlements` file.
- **Trusted.** The user's account, the macOS frameworks, Apple's on-device models.
- **Not trusted.** Everything read out of Mail, Notes, Calendar and Voice Memos. That is other people's text.
- **Outside the boundary.** `ai_writing_tools` and `ai_translate` hand the work to `shortcuts run`. What a Shortcut then does, including whether Apple's translation reaches a server for a language pack that is not installed, is not under this project's control. The README line "No network requests are made at all" holds for the M3MCP process. It does not hold for everything a tool call can set in motion.

What AppleMCP itself writes to disk:

| Path | Mode | Lifetime |
|---|---|---|
| `~/Library/Application Support/M3MCP/mcp.sock` | `0600` in a `0700` directory | while the app runs |
| login keychain item `de.markzimmermann.m3mcp.capability-token` | keychain ACL, ad-hoc signature means the app's code hash | until the item is deleted |
| `~/Library/Application Support/M3MCP/transcripts/<digest>.txt` | `0700` directory | permanent, no expiry |
| `$TMPDIR/m3mcp_<uuid>.png` from `ai_image_playground` | default | permanent, never cleaned up |
| `$TMPDIR/M3MCP-VoiceMemos-<uuid>/` | `0700` | removed by `defer` after each read |
| `/tmp/m3mcpapp.log` | default | permanent, never rotated |

The transcript cache holds the spoken content of voice memos, including whatever third parties said in them (`SpeechTranscription.swift`, `TranscriptCache` from line 254). The Voice Memos snapshot is a real copy of TCC-protected data, short-lived but on disk while it exists (`VoiceMemosProvider.swift` lines 873 and 897 to 916). The Mail index is Apple's file, not a copy this project makes: AppleMCP reads it in place and keeps no mail store of its own.

## Known Gaps

Open today. This section is the point of the file.

**One token for the whole surface, no scopes.** A client configured to read the calendar holds a token that also deletes calendars. Scoping is what [issue #9](https://github.com/GodModeAI2025/AppleMCP/issues/9) leaves open now that the process check exists.

**The token is a bearer secret wherever it is configured as one.** `M3MCP_TOKEN` in `claude_desktop_config.json` is readable by every process of the user, so on an installation where the client binary is not pinned, copying that file is enough. The keychain path is better — another binary asking for the item produces a prompt naming the asker — and it is what the bridge uses when no environment variable is set.

**The pin is per binary copy, not per build.** `.build/release/M3MCPBridge` and the copy inside
`M3MCP.app` are the same source and have different code directory hashes, because the packaging and
install scripts sign the bundled copy again. A client pointed at the wrong copy is refused on every
call. The refusal names the copy that would work, and the README table says which path goes with
which install.

**A bridge outside the bundle is not pinned.** The app pins the `M3MCPBridge` next to its own executable. If there is none, it runs token-only. It reports that in its window and in `/health` rather than hiding it, but a user who does not look does not know.

**The keychain item is bound to an ad-hoc signature.** No entitlements means the file-based login keychain, and an ad-hoc signature means the ACL is tied to the app's code directory hash. Every update re-prompts, exactly as the Full Disk Access grant has to be given again after every update.

**`/status` hands out recent tool traffic, behind the token.** `StatusResponse.recentActivity` carries the last 30 calls with the input JSON whole and the output JSON cut at 8000 characters (`AppModel.swift`). `/health` no longer carries it — the server strips it on that path — but any holder of the token can read the mail bodies and transcripts that recently passed through.

**No undo for writes.** All five calendar write tools now take two calls: the first returns a preview and a `confirm_token`, the second carries the write out (`Sources/M3MCPCore/WriteGuard.swift`, enforced in `LocalMCPService.handle` ahead of every provider). That makes a write deliberate and binds the confirmation to the exact arguments. It does not make it reversible: there is no snapshot before the write and no restore tool, so a confirmed `calendar_delete_calendar` is final. The confirmation also cannot tell a call the user meant from one the model was steered into by injected content — it only guarantees the same call was made twice, with a preview in between for whoever is reading.

**Call contents are kept in the clear, the caller is not recorded.** The app holds the request and response of the last 100 calls in memory and writes operational lines to `/tmp/m3mcpapp.log`, a fixed path with default permissions outside the `0700` directory. That log carries startup and error lines plus voice memo file names (`SpeechTranscription.swift` lines 121 to 151). Which process made a call is the one thing nothing records.

**`ai_image_playground` leaves PNG files behind.** The image goes to the process temporary directory and its path comes back in `metadata.path` (`AppleIntelligenceProvider.swift` lines 165, 174 and 185). Nothing deletes it afterwards.

**Photos grants more than the code uses.** PhotoKit offers `.addOnly` and `.readWrite` with no read-only level, so `PhotosProvider.swift` lines 174 and 183 request `.readWrite`. The TCC dialog asks for full library access even though only metadata is read.

**`permissions_status` can report a grant that does not exist.** A `UserDefaults` flag keyed on the bundle identifier can promote `not_determined` to `authorized`, and a second build of the app inherits it. `rawState` in the response carries the framework's own answer and is the value to trust (`PermissionProvider.swift` lines 363 to 370).

**`mail_search` can under-report without saying so.** The SQL clause is built from subject, sender and recipients only (`MailProvider.swift` lines 536 to 566); bodies are filtered in memory from the candidates that clause returns. Ask for `fields: [subject, body]` and a message matching only in the body never becomes a candidate, while the response still reports `total_exact: true`, because that value is `!scanCapped` and the cap was never hit (lines 257 and 293). `meta.body_searchable` is the constant `"true"` (line 370) and says nothing about the call that was made.

**No notarization and no hardened runtime.** Both build scripts sign with the first codesigning identity they find; `build_and_run.sh` falls back to ad-hoc (line 41), `install_local.sh` aborts instead (lines 63 to 74). Grepping the repo finds no `--options runtime` and no `notarytool` step, and there is no entitlements file.

**AppleScript escaping is untested.** See point 4 of the threat model.

**No third party has reviewed the code.** CI builds, tests, packages and checks the release artifact on every push (`.github/workflows/ci.yml`), which is not the same as a review.

## Out of Scope

- Code already running as the user. Everything below the socket assumes the account is not compromised. The token does not change that on its own — it lives where the same processes can read it — which is why it is paired with the peer's code identity: the token answers "is this client configured", the code hash answers "is this the client it was configured for". Neither answers "is this account still yours".
- Replacing TCC. The app reaches only what the user granted, and revoking a permission in System Settings takes the matching tools offline.
- Encryption at rest. The transcript cache and the temporary files rely on filesystem permissions, plus FileVault if the user has it enabled.
- Vetting the content that comes back. A mail body reading "delete every meeting tomorrow" arrives at the model as plain text. Keep a human in front of the calendar write tools.
