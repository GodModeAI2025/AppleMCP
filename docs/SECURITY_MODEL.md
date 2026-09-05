# AppleMCP Security Model

This document describes the security properties and limits of AppleMCP 0.3.0. It is a statement about the implemented controls, not a claim that all local data is isolated from every process or that macOS system services never use a network.

## Trust boundaries

AppleMCP has three relevant components:

1. The MCP client and model send JSON-RPC over the bridge's standard input and output.
2. `M3MCPBridge` validates the MCP lifecycle and forwards enabled tool calls.
3. `M3MCPApp` holds macOS TCC permissions and serves a private HTTP subset over a Unix domain socket.

The app is the final authorization boundary. It rechecks the launch-time tool policy even if a caller bypasses discovery and sends a tool name directly to the socket. The bridge and app also apply the same exhaustive per-tool argument policy: unknown keys, wrong top-level types, and missing required or alternative fields are rejected before native approval or provider dispatch. The bounded approval preview divides its budget across supplied top-level fields, so every accepted field name remains visible while long values are explicitly truncated. MCP tool annotations, when negotiated with a supporting protocol revision, are client hints and are not used as authorization.

Every newly encoded `ToolResponse` carries the machine-readable marker
`contentTrust: "untrusted_data_not_instructions"`. This gives clients a provenance boundary for
Mail, Notes, transcripts, filenames, and other provider-controlled text without changing the
legacy text result. The field is optional while decoding responses from an older app, so its
absence must not be interpreted as a claim that content is trusted. The marker is advisory: a
client still has to keep retrieved data separate from executable instructions, and native approval
still governs enabled Calendar and Shortcut calls.

The bridge explicitly supports MCP revisions `2024-11-05`, `2025-03-26`, `2025-06-18`, and `2025-11-25`. It requires the initialize response to be followed by the initialized notification before tools can be listed or called. Tool annotations are emitted for revisions that define them, and structured results are added for revisions that support them while retaining the text result for compatibility. Each incoming newline-delimited stdio message is limited to 1 MiB; bounded tool responses can be larger and use a separate 16 MiB stdout limit.

The local operating-system account remains a trust boundary. The socket directory is `0700` and the socket is `0600`, which excludes other users and normally excludes sandboxed processes without access to that path. Filesystem permissions alone do **not** authenticate another unsandboxed process running under the same user ID, so the endpoint adds a capability token on top of them. See [Client authentication](#client-authentication). Full Disk Access raises the impact of compromise of any same-user unsandboxed process that holds a copy of the token.

## Client authentication

Every request other than `GET /health` must carry `Authorization: Bearer <token>`. `/health` stays open because it is the readiness probe `script/install_local.sh` waits on and it never carries the activity log.

The token is 32 bytes from `SecRandomCopyBytes`, encoded as unpadded base64url so it survives an environment variable, a JSON configuration file, and an HTTP header unchanged. The app creates it on its first start and stores it in the login keychain as a generic password. `M3MCP_TOKEN` overrides the keychain in the app and in the bridge alike, which is how an MCP client is configured and how tests run without a keychain. Comparison is constant time in the token contents; the length is fixed by the generator and is allowed to leak.

If the token cannot be read or created, the app does not start the listener. Coming up without one would put the endpoint back where it was.

The bridge resolves the token on its first tool call and not at start-up, so `initialize` and `tools/list` are still answered by a bridge on a machine with no app, no keychain item, and no token. A keychain read from the bridge refuses interaction: an MCP client gives the bridge no session in which an authorization panel could be answered, and a panel there is indistinguishable from a server that never replies.

What a token does not do: it is a secret in a file, and a copy of it works. It raises "connect to the socket", which every process of the user can do, to "be configured for this endpoint". The second factor covers the copy.

### Pinned client binary

At every start the app reads the code directory hash of the `M3MCPBridge` next to its own executable and accepts connections from that binary alone. A valid token from any other binary is refused with `403`. `M3MCP_TRUSTED_CLIENT_CDHASH` replaces the sibling lookup with an explicit comma-separated list; it is read from the server's environment, which only the person starting the server controls.

The identity comes from the peer's audit token (`LOCAL_PEERTOKEN`) rather than its pid, because a pid can be recycled between `accept` and the lookup while a connection stays open through an asynchronous tool call. `SecCodeCheckValidity` runs as well as the hash comparison, so a binary whose pages were changed after signing is refused even when the recorded hash still matches.

Why the hash and not a team identifier or a certificate: `swift build` produces an ad-hoc signature whose designated requirement is the hash itself, so for a source build there is nothing else to pin. `script/install_local.sh` and `script/package_release.sh` do sign with a stable certificate, which would make a leaf-certificate pin possible and would also make it weaker: `script/create_local_identity.sh` creates one self-signed certificate that signs every binary its owner signs, a hand-written socket client included. The hash does not go stale, because it is read at each start rather than compiled in, and an install replaces app and bridge together.

Where no sibling bridge is found the pin cannot be computed. The app then runs token-only and reports that state in its window, in `source_status`, and in `/health`, rather than implying a protection that is not there.

### Known limits

The pin identifies a binary, not a caller. Any process that can start the bundled bridge and holds the token is a working client. The window between `connect` and the identity check is the time the request takes to arrive, so a process could in principle deliver a request and then become the pinned binary; that reaches only what the previous sentence already grants.

The endpoint is not reachable from a web page because browsers cannot open Unix domain sockets. Origin-style request headers are also rejected as defense in depth.

## Launch-time tool policy

Both the bridge and app resolve an immutable policy from their own environment at startup. Unknown tools fail closed. Missing, empty, malformed, and false values do not enable a group.

| Group | Default | Environment variable | Tools |
|---|---|---|---|
| Observation and bounded local processing | Enabled | None | 21 tools listed in the README |
| Calendar mutation | Disabled | `M3MCP_ENABLE_CALENDAR_MUTATIONS=1` | `calendar_create_event`, `calendar_update_event`, `calendar_delete_event`, `calendar_create_calendar`, `calendar_delete_calendar`, `calendar_undo_write` |
| Permission UI | Disabled | `M3MCP_ENABLE_PERMISSION_UI=1` | `permissions_request`, `permissions_open_settings` |
| User-created Shortcuts | Disabled | `M3MCP_ENABLE_USER_SHORTCUTS=1` | `ai_writing_tools`, `ai_translate` |

Accepted true tokens are `1`, `true`, `yes`, and `on`, without case sensitivity. There is no MCP tool that changes this policy at runtime. The bridge and app should be launched with matching values: otherwise a tool may be hidden by the bridge or denied by the app.

### Per-call native approval

Every enabled Calendar mutation and user-Shortcut invocation requires a separate decision in the app. The native sheet shows the exact tool name and a stable, bounded argument preview. Credential-like fields are redacted. Requests are queued so approval sheets cannot overlap.

Approval applies only to the waiting call. There is no reusable approval token. The default button is Deny, and a denial, closed sheet, cancelled task, 30-second timeout, or missing usable app window rejects the call. Environment opt-in is availability, not consent.

Cancellation before approval is consumed prevents dispatch. After approval, MCP cancellation and a disconnected local HTTP client are propagated to the in-flight app task and cooperative subprocess work. This is best-effort interruption, **not transactional rollback**. EventKit data committed before cancellation remains committed, and a Shortcut can retain file, network, message, or other effects completed before its process was stopped. A caller must inspect real state before retrying; automatic retry can duplicate a Calendar event or repeat a Shortcut effect.

### Preview and undo for calendar writes

Approval and preview are different questions, and they are asked separately.

`dry_run: true` on any calendar write tool resolves the target, validates the arguments, reports the
change that would be made with `meta.dry_run = "true"`, and writes nothing. No approval sheet is
shown for such a call, because nothing is being approved. The exemption is narrow: it is reachable
only through the literal boolean `true`, only for a tool whose reviewed argument policy declares
`dry_run`, and only inside a mutation group that was enabled at launch. It is resolved once, by
`M3MCPWriteIntent`, and the same value decides both the missing sheet and the missing write, so the
two cannot come apart. A preview discloses nothing the default-safe Calendar read tools do not.

`calendar_create_event`, `calendar_update_event`, and `calendar_delete_event` record what they
replaced before they commit, and return `meta.undo_token`. `calendar_undo_write` spends it once. The
journal is in memory, bounded to the 20 most recent writes, and expires each entry 30 minutes after
its write: snapshots hold event titles, notes, and locations, and persisting them would create a
second copy of calendar content outside the calendar with its own lifetime and its own exposure.

The boundary of the mechanism, stated rather than implied:

- A rebuilt event has a new `eventIdentifier`. `meta.undo_restores_identifier` reports this.
- Recurring events and `span: "future_events"` receive no token. The write proceeds and the response
  carries `meta.undo_unavailable` with the reason.
- Only fields these tools can write are restored: title, all-day flag, start, end, location, URL,
  notes, relative alarms, and calendar membership.
- `calendar_create_calendar` and `calendar_delete_calendar` support `dry_run` but issue no token.
- Undo is itself a calendar mutation: same launch opt-in, same per-call sheet. It writes the
  recorded previous values over the current state without checking whether something else changed
  the event in between. A failed undo changes nothing and leaves the token valid.

Permission UI does not use this additional sheet because macOS owns the permission prompt or System Settings surface. The group is still disabled by default so an MCP caller cannot make the app activate or raise security UI without a launch-time choice.
Cancelling a permission sequence returns control to AppleMCP, ignores late framework callbacks, and suppresses every later prompt in that sequence. A macOS permission prompt that the framework already displayed is system-owned and may remain on screen until the user dismisses it.

## macOS permissions

All 21 default tools preflight any TCC authorization they require and do not request permission or open System Settings. Contacts, Calendar, Reminders, Photos, and Notes reads fail with guidance when access is missing. When fresh Voice Memos transcription reaches the legacy `SFSpeechRecognizer` path, it checks Speech Recognition with `prompt: false` and also fails with guidance; the macOS 26 `SpeechAnalyzer` path does not use that legacy authorization callback. Permission requests and settings navigation are isolated in the optional permission-UI group. An Apple framework's system behavior while acquiring an on-device model asset is separate from AppleMCP's TCC request tools.

`permissions_status` checks Notes Automation with prompting disabled and never starts Notes. For an
explicit `notes_search` or `notes_read`, a `procNotFound` preflight can mean that an already-authorized
Notes target is merely closed. Only those explicit tool calls may launch Notes hidden and retry the
preflight, still with `prompt: false`. Cancellation is checked before Launch Services is called and
before a script is admitted. `AEDeterminePermissionToAutomateTarget` runs on a background worker so
an arbitrarily slow target or system prompt cannot block the app's main thread.

Important distinctions:

- Calendar uses Full Calendar Access because optional, separately gated tools can create, update, and delete real events and calendars.
- PhotoKit exposes `.addOnly` and `.readWrite`, not a read-existing-assets-only authorization level. AppleMCP must request `.readWrite` to fetch the existing library, although its Photos tool implementation contains no mutation operation.
- Notes is read through Notes.app Apple Events because macOS has no equivalent public read API. This requires Automation permission for Notes.
- Notes Automation determination and Notes AppleScript execution share one process-wide synchronous
  Apple Event slot. Each native Automation determination has a 30-second caller deadline;
  AppleScripts have an 8-second caller timeout. `AEDeterminePermissionToAutomateTarget` and
  `NSAppleScript.executeAndReturnError` cannot be killed safely in process, so timeout or cancellation
  returns control to the caller but retains the slot until the native call really ends. Late native
  completion is ignored. This prevents repeated requests from accumulating blocked workers across
  both operations.
- Mail has no AppleScript fallback in 0.3.0. It reads only the local Envelope Index and `.emlx` files and returns Full Disk Access guidance when that store is unavailable.
- Voice Memos uses a local store and recording files. Full Disk Access can be required for those paths.

TCC protects data sources from the app until the user grants access. Once granted, TCC does not distinguish one caller of AppleMCP's socket from another caller under the same trusted local account.

## Local transport controls

The default endpoint is `~/Library/Application Support/M3MCP/mcp.sock`. `M3MCP_SOCKET_DIR` can relocate the containing directory for development or tests.

Implemented limits include:

- socket directory mode `0700` and socket mode `0600`;
- a persistent owner-only per-endpoint `flock(2)` file held for the listener lifetime, serializing
  stale-socket inspection/removal and bind across competing app processes;
- a nonblocking liveness probe for any pre-existing socket under one 250 ms absolute monotonic
  deadline; timeout, unexpected poll state, or another ambiguous error preserves the endpoint and
  fails startup instead of replacing it;
- two separate caps, because a connection that has said nothing and one that is being served do not
  cost the same thing: at most 128 accepted connections waiting for a request, each costing a file
  descriptor and a dispatch source and no thread, and at most 16 framed requests being served at
  once, each holding a thread while its handler runs;
- displacement rather than refusal at the waiting cap: the connection that has waited longest without
  sending a byte yields its place to a new arrival, so filling every slot buys a silent process a
  burst and not an outage. A connection that has sent something is work in progress and is never
  displaced; when every slot holds one of those, a new arrival is refused with 503;
- a listen backlog matched to the waiting cap, so a burst is queued rather than answered with
  ECONNREFUSED, which a client cannot tell from a server that is not running;
- a 15-second absolute request-receive deadline measured from `accept`, even when a client trickles
  bytes or says nothing at all;
- 15-second blocked read and write timeouts as defence in depth;
- 32 KiB maximum HTTP header block;
- 1,048,576-byte (1 MiB) maximum HTTP request body, matching the bridge's MCP message limit;
- 8 MiB maximum app-to-bridge HTTP response body, with oversized provider results replaced by a
  bounded, parseable HTTP 413 response before socket writing;
- incremental bridge-side response framing that rejects an oversized `Content-Length` before EOF
  and stops at the complete declared body, under one absolute 1,830-second monotonic deadline for
  connect, request delivery, provider wait, and response reading;
- a 15-second absolute response-write deadline, even when a client never drains the socket;
- rejection of duplicate or invalid `Content-Length`, transfer encoding, trailing bytes, malformed JSON, and unexpected content types;
- nonblocking overload rejection and `SO_NOSIGPIPE` handling.

These are denial-of-service and parser-safety controls, not same-user authentication. Tool work such as transcription can legitimately run longer than the request/I/O limits because those limits cover framing and blocked socket operations, not the asynchronous tool operation.

The server watches for a disconnected client while a tool is running and cancels the corresponding
task. Mail propagates that cancellation through SQLite progress callbacks and its bounded database,
MIME, body, filesystem, and response loops. The same no-rollback rule applies: disconnect detection
does not compensate an already committed external effect.

## Health and diagnostics

`GET /health` returns operational status without recent activity. It is the endpoint to use for readiness checks.

`GET /status` adds up to 30 recent activity entries. Each entry can include up to 8,000
characters of tool input JSON and up to 8,000 characters of encoded output, plus a fixed truncation
marker when either value is cut; error detail is limited to 2,000 characters. Treat this route as
sensitive. The app retains at most 100 activity entries in memory and does not persist them as an
activity database.

Application diagnostics use macOS Unified Logging with dynamic text marked private and hash-masked. AppleMCP no longer appends a predictable log file under `/tmp`.

## Data and resource bounds

- Mail search accepts at most 4,096 query characters, 64 query terms, and 1,024 characters in a
  mailbox filter. The `fields` selector must be an array limited to the four documented fields,
  with at most 32 characters per entry. Search pages contain at most 500
  rows and body-filter candidate processing at most 5,000 rows. Mailbox discovery processes at most
  20,000 index rows and returns at most 1,000 mailboxes; listing probes one additional row and reports
  `scan_capped` and `total_exact`, while search and detail reads fail closed if the mailbox map is
  incomplete. Query and role filters are capped at 1,024 and 64 characters respectively.
- Mail's SQLite connection rejects any value above 256 KiB before Swift string construction; invalid UTF-8 and embedded NUL fail closed. Recipient joins fail closed above 20,000 rows or 1,000,000 SQLite VM instructions. Its local parser reads no more than 4 MiB from an `.emlx` source, bounds multipart nesting and part counts, limits returned body content to 8,000 characters, and caps a returned recipient header at 64 KiB of UTF-8 with explicit byte/truncation metadata. An explicit marker is appended when source or body content is cut. The default junk exclusion applies both the optional message flag and known Junk-mailbox ids; `include_junk=true` is required to include either.
- Mail search and mailbox-list responses have a 7 MiB encoded-response budget below the bridge's
  8 MiB HTTP body ceiling. The provider measures JSON-encoded items, appends only a complete stable
  prefix, and reports `response_budget_capped`, `has_more`, and `truncated`; search callers can resume
  by advancing `offset` by the returned item count, while mailbox callers can narrow their filters.
- Mail local row IDs must be canonical positive decimal values returned by `mail_search`; path-like and legacy AppleScript IDs are rejected.
- Contacts uses a predicate-bearing incremental fetch and stops after `limit + 1` callbacks rather than materializing all name matches. Identifiers, names, organization fields, and up to eight email addresses and phone numbers each have fixed UTF-8 response bounds; `metadata.content_truncated` reports field/value clipping.
- Calendar search queries EventKit in seven-day chunks and inspects 2,000 events by default, at most 5,000. Calendar discovery processes at most 400 calendars. Both return machine-readable scan/truncation metadata, and selected event/calendar fields have fixed UTF-8 response bounds. EventKit itself does not expose a per-query fetch limit, so one unusually dense seven-day chunk may still be materialized before AppleMCP's inspection budget is applied.
- Reminders rejects contradictory completed/incomplete filters, fetches one list at a time, and stops provider-side inspection after 1,000 reminders by default or 5,000 at most. Metadata names this a `post_fetch_scan_budget`: EventKit has no fetch-limit parameter and can still materialize one list's callback result before the provider applies that budget. Search/output fields have fixed UTF-8 bounds.
- Notes queries and direct ids are bounded before the prompt-free Automation preflight. AppleScript truncates identifiers, names, folders, dates, and bodies before building its result, the in-process result has a 2 MiB ceiling, and Swift repeats per-field UTF-8 bounds before response encoding. A direct note body is at most 65,536 characters and reports `metadata.content_truncated`.
- Photos album discovery inspects at most 2,000 albums and returns 50 by default, at most 200. Response metadata separately reports scan-budget, output-limit, and title-content truncation.
- Voice Memo detail IDs must be canonical positive decimals returned by search; queries are capped at 4,096 UTF-8 bytes before normalization. SQLite snapshot value/row materialization is capped at 256 KiB, individual database text fields have smaller byte caps before Swift string creation, and returned title/filename/label/path fields are independently bounded. A store path contributes only its last component. Resolution and every later content read use no-follow descriptors; the opened recording must remain the same same-owner, single-link regular-file device/inode under the same verified recordings-directory inode. AVFoundation receives the retained descriptor plus an explicit MIME override; legacy Speech receives only bounded PCM buffers. Its single-flight lease and descriptor survive caller timeout until the serialized feeder has ended audio and the Speech task reaches `.completed`, not merely `.canceling`.
- Voice Memo base64 audio uses a bounded read: 4,000,000 bytes by default and at most 5,000,000 bytes; larger recordings use path output. Transcript-cache keys must be exactly 64 hexadecimal SHA-256 characters, and cache reads and writes are limited to 16 MiB. Cache path components are opened with no-follow descriptor operations, directories and files must be owned by the current user, and replacement uses an owner-only temporary file plus same-directory atomic rename.
- Returned Voice Memo transcript text is capped at 750,000 UTF-8 bytes, independently of the larger internal atom/cache read limits. The response records original and returned byte counts plus `content_truncated`.
- Voice Memo transcript parsing inspects at most 65,536 atoms. Before Foundation materializes the private JSON, a linear preflight caps nesting at 64 levels, 262,144 nodes, and 65,536 containers. Decoded data is limited to 65,536 runs, 32,000 attribute entries, 30,000 segments, 1,000,000 cumulative transcript UTF-8 bytes, and a 128-byte locale identifier; malformed atom sizes and unsafe time values fail closed. `segments_json` is a complete JSON array of whole segments capped at 40,000 UTF-8 bytes and reports `segments_returned` plus `segments_truncated`.
- The local HTTP request parser and MCP message validator impose independent size and structural limits. Responses above 1,000,000 encoded bytes retain one complete compact JSON text result and omit the otherwise duplicate structured-content representation. Bridge stdout is nonblocking with a 15-second absolute write deadline; reservations continue to occupy the 16-call admission bound until output succeeds, is suppressed, or fails. A complete response that grows beyond the 16 MiB stdout limit through JSON-string escaping is replaced before writing by a bounded normal tool error for the same request ID. A partial/failed line or invalid internal JSON permanently fails that writer and prevents further tool dispatch in the process.
- Shortcut standard output and standard error are each limited to 1 MiB, and execution is limited to 60 seconds.

Data read from Mail, Notes, Calendar, contacts, reminders, photos, recordings, and transcripts is untrusted content. A downstream model can still interpret text as instructions. The `contentTrust` marker exposes that boundary to clients, but AppleMCP's allowlist, annotations, marker, and native approval cannot make source text semantically trustworthy.

## Speech and network behavior

Fresh Voice Memo transcription is fail-closed for remote recognition:

- On macOS 26, AppleMCP uses `SpeechAnalyzer`/`SpeechTranscriber`.
- On earlier supported systems, or if the newer analyzer cannot service the locale, AppleMCP checks `SFSpeechRecognizer.supportsOnDeviceRecognition` before creating a recognition task and sets `requiresOnDeviceRecognition = true`.
- If on-device recognition is unavailable, the call fails. AppleMCP does not fall back to cloud recognition.

The first use of an on-device speech locale can ask an Apple framework to download a model asset. Apple Intelligence and Image Playground can also depend on system-provided assets. Those downloads are different from uploading the caller's recording or prompt for remote processing, but they mean an absolute "no network activity" claim would be inaccurate.

The optional user-created Shortcuts are explicitly open-world. A Shortcut can use network actions, write data, contact other apps, or cause any other side effect configured by its author. AppleMCP invokes a fixed system binary without a shell, supplies the documented JSON contract, bounds execution, and asks for one-call native approval; it cannot sandbox the Shortcut's internal actions.

Apple apps and macOS services can independently sync their own data according to the user's Apple account and system settings. AppleMCP does not disable or control that system behavior.

## Files, caches, and cleanup

| Artifact | Protection | Lifecycle |
|---|---|---|
| Voice Memos SQLite snapshot | Canonical private temp parent retained by descriptor; `mkdirat` mode `0700`; no-follow source/destination opens, single-link owner/inode plus size and modification/change-time validation, 1 GiB per component; SQLite read-only plus `SQLITE_OPEN_NOFOLLOW` with strict validation before open, a same-inode `-shm` metadata rebaseline after WAL read-lock setup, and strict validation after the query | Exact components are unlinked through the retained directory descriptor; the directory is removed only if its inode still matches; same-owner exact-name snapshots older than 24 hours are eligible for bounded native app startup cleanup |
| Speech decoded PCM | No filesystem artifact; AVAssetReader feeds either a pull-driven AnalyzerInput sequence or the legacy on-device Speech audio-buffer request one buffer at a time | Source limited to 7,200 seconds / 400,000,000 estimated frames; mono 16 kHz Float32 stream limited to 115,200,000 frames, 512 MiB cumulative decoded PCM, and 500,000 buffers |
| Legacy speech transcode CAF | No longer created; strict recognition of the old UUID filename only | Same-owner exact-name leftovers from older versions are removed after 24 hours at native app startup |
| Shortcut JSON input | No filesystem artifact; delivered through the bounded child-process stdin pipe | The pipe closes when input delivery or the invocation ends; exact same-owner leftovers from older versions are removed after 24 hours at native app startup |
| Generated Image Playground PNG | Unique regular file, mode `0600` | Returned as a temporary path and retained for the caller; exact same-owner files still present after 24 hours are removed at native app startup |
| Generated transcript cache | `~/Library/Application Support/M3MCP/transcripts`, directory `0700`, files `0600` | Persists by recording digest to avoid retranscription; no automatic expiration |
| In-memory activity | App process memory | Maximum 100 entries; discarded when the app exits |

Cleanup only matches an exact AppleMCP prefix, canonical UUID, expected file type, current owner, and minimum age. It opens the temporary directory no-follow and consumes top-level entries incrementally rather than materializing the directory. One pass inspects at most 4,096 entries and attempts at most 64 removals; leftovers wait for a later launch. The app retains exactly one cancellable utility task per lifecycle and starts it only after the Unix-socket start attempt, so cleanup neither blocks the main actor nor races stale-socket setup. Cancellation is checked between entries and removals. The cleanup does not follow symlinks or sweep arbitrary temporary files.

## Enabling optional groups in installed or development builds

For a development bundle, use `open --env` as shown in the README. `script/install_local.sh`
persists only the three fixed security variables whose values are explicitly true in the installer's
environment. For example, this installs an app LaunchAgent with only permission UI enabled:

```bash
M3MCP_ENABLE_PERMISSION_UI=1 ./script/install_local.sh
```

The installer accepts `1`, `true`, `yes`, or `on` without case sensitivity and writes a normalized
value of `1` to the LaunchAgent `EnvironmentVariables` dictionary. Unset, empty, false, and
unrelated variables are not persisted. Rerunning the installer regenerates the
LaunchAgent from the values explicitly supplied to that run; running it with no opt-ins returns the
installed app to the default-safe policy. Configure matching variables in the MCP client's bridge
entry separately.

The replacement app and LaunchAgent are assembled, plist-checked, signed, signature-verified, and
assessed on the same filesystem before live paths change. Existing files are renamed to private
backup locations; a later failure or interruption restores both and, when applicable, attempts to
restart the previously loaded service. A successful `launchctl bootstrap` or legacy `load` is not
the commit point: the installer also waits for launchd to report the job and for the default Unix
socket's `GET /health` response to parse with a top-level `ok` value of `true`. The probe has finite
attempts and per-request timeouts. Failure keeps the transaction uncommitted so the same rollback
restores the previous app, plist, and service. Successful readiness removes the temporary backups.

## Release verification

A release candidate should pass, on macOS:

```bash
swift test
swift build -c release
plutil -lint Sources/M3MCPApp/Resources/Info.plist
for file in script/*.sh script/lib/*.sh Tests/Installer/*.sh; do bash -n "$file"; done
python3 script/check_docs.py
script/package_release.sh /private/tmp/m3mcp-release-candidate
script/check_release_artifact.sh /private/tmp/m3mcp-release-candidate
```

Tests and builds do not grant TCC permissions and must not touch a user's Calendar, Mail, Notes, Photos, or Voice Memos data. Runtime tests should use a relocated socket and synthetic inputs. A release review should additionally verify the default tool count, denial of direct calls to disabled tools, per-call approval behavior, socket permissions, strict on-device speech preflight, and that `/health` contains no recent activity.

The tag workflow reruns this complete CI contract with read-only repository permission. It transfers
only the checked ZIP, checksum, and release notes to subsequent jobs, attests ZIP provenance, and
grants `contents: write` only to a `release` environment job that performs no checkout and executes
neither the candidate nor a repository script. Its fixed publish commands still come from the
workflow file at the already verified, main-ancestor tag. That job is skipped unless the repository variable
`M3MCP_ENABLE_DRAFT_RELEASE` is exactly `true`. Repository administrators must separately protect
`v*` tag creation and require a reviewer on the `release` environment; YAML cannot enforce those
settings. The current workflow additionally refuses a tag run unless GitHub reports the triggering
tag as protected through `GITHUB_REF_PROTECTED`; this fails closed until that external rule exists.

The default automated ZIP is arm64, ad-hoc signed, and unnotarized. Its checksum supports transfer
integrity relative to the asset in the same release, not independent publisher authenticity. The
GitHub attestation binds it to the repository workflow, but a public production release still needs
a separately protected Developer ID identity, hardened runtime, trusted timestamp, notarization,
and stapling. Until then the workflow creates a clearly titled draft candidate, and a human must
decide whether to publish it.
