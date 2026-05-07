# M3MCP Access Best Practices

M3MCP is a local macOS app that exposes Apple data sources and Apple Intelligence actions through an MCP `stdio` bridge. The app should stay transparent about which macOS subsystem is being used and should never make the MCP bridge process the privacy principal.

## macOS Privacy

- Keep one stable bundle identifier: `de.markzimmermann.m3mcp`.
- Sign the `.app` bundle with a stable code-signing identity whenever possible. Ad-hoc signatures can change the code identity across rebuilds and cause macOS TCC permissions to appear lost.
- Use the same `Info.plist` in the SwiftPM-linked binary and the staged `.app` bundle. A mismatch invalidates code signing and breaks permission prompts.
- Request Calendar, Contacts, Reminders, Photos, and Notes Automation permissions from `M3MCPApp`, not from the MCP bridge or `/usr/bin/osascript`.
- Read Mail from the local Envelope Index instead of enumerating Mail.app via AppleEvents. Mail.app can become unresponsive when its AppleEvent interface is asked to enumerate messages.
- Treat Mail local index access as Full Disk Access remediation when macOS blocks `~/Library/Mail`.
- Prefer native frameworks where Apple exposes them: EventKit, Contacts.framework, and Photos.framework.
- Use AppleEvents only where there is no equivalent public read API and the target is not known to hang under enumeration. Currently this is Notes.app.
- Do not auto-prompt on launch. Show current state first, then let the user request permissions intentionally.
- Bound all AppleEvent calls with timeouts. If an authorized app does not answer, return a clear diagnostic instead of hanging the MCP client.

Relevant Apple docs:

- EventKit: https://developer.apple.com/documentation/eventkit
- Contacts: https://developer.apple.com/documentation/contacts
- Photos: https://developer.apple.com/documentation/photokit
- Apple Events usage description: https://developer.apple.com/documentation/bundleresources/information-property-list/nsappleeventsusagedescription
- Other app data usage description: https://developer.apple.com/documentation/BundleResources/Information-Property-List/NSAppDataUsageDescription

## MCP UX And Safety

- Keep MCP `stdout` pure JSON-RPC. Send diagnostics to `stderr` or the app UI.
- Expose visible tool status in the UI so the user can see what is available to the model.
- Record invocations in the app Activity area with provider, endpoint, status, and timing.
- Keep data-source tools read-only. Apple Intelligence tools may launch or invoke system actions, so their descriptions must be explicit.
- Add permission tools (`permissions_status`, `permissions_request`, `permissions_open_settings`) so the model can explain missing access without guessing.

Relevant MCP docs:

- stdio transport: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
- tools and human-in-the-loop guidance: https://modelcontextprotocol.io/specification/2025-03-26/server/tools
- security best practices: https://modelcontextprotocol.io/docs/tutorials/security/security_best_practices
