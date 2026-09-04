# AppleMCP Access Best Practices

AppleMCP bridges privacy-controlled macOS data into MCP. Operate it as a local privileged service, not as a general-purpose or multi-user API.

## Identity and macOS privacy

- Keep the bundle identifier stable: `de.markzimmermann.m3mcp`.
- Sign the app with a stable identity when persistent TCC grants are needed. Ad-hoc signatures can change identity across rebuilds.
- Keep the packaged `Info.plist` identical to `Sources/M3MCPApp/Resources/Info.plist`; changing a signed bundle invalidates its signature.
- Grant only the permissions for providers you actually use. Full Disk Access is high impact because it covers much more than AppleMCP's local Mail and Voice Memos paths.
- Every default tool, including fresh Voice Memos transcription, should preflight only. Do not add implicit TCC prompts or settings navigation to the default catalog.
- Keep permission requests and System Settings navigation behind `M3MCP_ENABLE_PERMISSION_UI`.
- Request TCC access from `M3MCPApp`, which is the signed privacy principal, not from the bridge.
- Read Mail only through the local Envelope Index and bounded `.emlx` parser. Do not silently fall back to Mail Automation when Full Disk Access is missing.
- Use EventKit, Contacts.framework, and Photos.framework where Apple provides them. Keep optional Calendar writes separately enabled and approved per call.
- PhotoKit requires the `.readWrite` authorization level to fetch existing assets; `.addOnly` cannot support reads. Keep the exposed Photos implementation non-mutating and disclose the framework-level permission accurately.
- Use Apple Events only when there is no public read API. AppleMCP uses them for Notes and bounds every call with a timeout.
- Keep Notes status checks passive: never launch Notes and never enable prompting from
  `permissions_status`. An explicit Notes read/search may launch a closed target hidden, retry with
  `prompt: false`, and must check cancellation again before both launch and script admission.
- Keep in-process AppleScript single-flight. A timeout can complete the caller, but it must not free
  the slot until the uncancellable native execution actually returns.
- Keep Voice Memos store access copy-on-read: snapshot the database, WAL, and SHM into a private directory, replay only the copy, and remove it afterwards.
- Require on-device speech capability before starting `SFSpeechRecognizer`, set `requiresOnDeviceRecognition`, and fail when a locale cannot run locally.
- Treat speech-model installation as possible network activity even though recognition of the recording remains on device.

Relevant Apple documentation:

- [EventKit](https://developer.apple.com/documentation/eventkit)
- [Contacts](https://developer.apple.com/documentation/contacts)
- [PhotoKit](https://developer.apple.com/documentation/photokit)
- [Speech](https://developer.apple.com/documentation/speech)
- [Speech recognition usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsspeechrecognitionusagedescription)
- [Apple Events usage description](https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription)
- [Other app data usage description](https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppDataUsageDescription)

## Local endpoint

- Use a Unix domain socket, not a loopback TCP port.
- Keep the socket directory `0700`, the socket `0600`, and a restrictive creation `umask`.
- Remember that `0600` is not authentication against another unsandboxed process with the same user ID.
- Unlink only the exact configured stale socket before binding.
- Keep accepted-connection concurrency, request sizes, and blocked I/O time bounded.
- Reject ambiguous framing: duplicate or invalid `Content-Length`, transfer encoding, trailing bytes, and malformed JSON.
- Keep `SO_NOSIGPIPE` on accepted sockets and the listening descriptor nonblocking.
- Keep `/health` free of activity payloads. Restrict `/status` to intentional local diagnostics because it contains tool inputs and bounded outputs.
- Use `M3MCP_SOCKET_DIR` to isolate development and synthetic runtime tests from an installed instance.

Relevant references:

- [`unix(4)` domain protocol family](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man4/unix.4.html)
- [App Sandbox](https://developer.apple.com/documentation/security/app-sandbox)

## MCP policy and user consent

- Capture one immutable launch policy and enforce it independently in discovery, bridge dispatch, and app dispatch.
- Fail closed for unknown tool names and malformed environment values.
- Keep Calendar mutations, permission UI, and user Shortcuts in separate opt-in groups.
- Require one native, default-deny approval for every enabled Calendar mutation and Shortcut invocation.
- Show the tool and a bounded argument preview; redact credential-like values and never turn the preview into a capability token.
- Serialize approval dialogs and deny on cancellation, timeout, dismissal, or missing UI.
- Propagate client cancellation and disconnects, but never describe cancellation as rollback. Verify Calendar or Shortcut state before retrying because already committed effects remain.
- Treat MCP tool annotations as advisory metadata, not authorization.
- Treat all source data and tool output as untrusted content. Prompt-injection-looking text remains data unless the MCP client chooses to interpret it.
- Keep MCP `stdout` pure JSON-RPC. Send diagnostics through private Unified Logging or the app UI.
- Invoke Shortcuts with `/usr/bin/shortcuts` and an argument vector, not a shell. Deliver JSON through
  `--input-path -` and bounded stdin rather than a reopenable path; bound runtime and output, and
  document that user-created Shortcuts can network or cause arbitrary side effects.

Relevant MCP documentation:

- [stdio transport](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [security best practices](https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices)

## Release checks

- Run the full test suite and a release build on macOS.
- Lint the source `Info.plist` and every shell script.
- Verify the bridge requires a valid MCP initialization sequence before listing or calling tools.
- Assert that the default tool list contains exactly the documented 21 tools.
- Attempt direct calls to each disabled tool and verify app-side denial.
- Verify one-call approval behavior with allow, deny, timeout, cancellation, and no-window cases.
- Verify disconnect cancellation with synthetic long-running work, and separately verify that documentation never promises rollback of committed Calendar or Shortcut effects.
- Test HTTP and MCP parsers with negative, duplicate, overflowed, truncated, and oversized lengths and deeply nested JSON.
- Inspect socket and temporary-artifact permissions on the actual release bundle.
- Use synthetic stores and a relocated socket; release checks must not modify a user's Calendar or read private production data.
- Package required project and third-party license notices, then validate the archive against an
  exact path/type/size allowlist before extracting or executing it.
- Run the packaged bridge through a bounded initialize/initialized/tools-list lifecycle and require
  the exact default and all-opt-in catalogs.
- Keep build and verification jobs read-only. Give repository write permission only to a protected
  publish job that checks out no source and executes no tag-controlled repository script.
- Pin every external workflow action to a reviewed full commit and bind the checked artifact to the
  repository workflow with build-provenance attestation.
- Treat an ad-hoc, unnotarized ZIP as a candidate only. Production distribution requires a protected
  Developer ID, hardened runtime, trusted timestamp, notarization, and stapling.

The detailed threats, limits, and retention table are in [SECURITY_MODEL.md](SECURITY_MODEL.md).
