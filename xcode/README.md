# LocalMCP: Xcode and TestFlight

The Xcode project builds the sandboxed macOS app and its embedded MCP bridge. Generate it with XcodeGen; the generated `.xcodeproj` is intentionally ignored.

- Bundle ID: `de.mobilebox.LocalMCP`
- Development team: Mobile Box, `SP73Z8JWXM`
- Version: 1.0.1, build 14
- Universal binary: Apple silicon and Intel; minimum macOS 15
- German and English interface, selected automatically by macOS
- App Sandbox and Hardened Runtime enabled

## Build and validate

From the repository root:

```sh
xcodegen generate --spec xcode/project.yml
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project xcode/LocalMCP.xcodeproj -scheme LocalMCP-TestFlight \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath ../LocalMCP.xcarchive archive
python3 script/check_localizations.py \
  ../LocalMCP.xcarchive/Products/Applications/LocalMCP-TestFlight.app
```

The current code was archived with Xcode 27 RC (27A266a). Features requiring newer macOS releases are availability-gated. Apple determines distribution eligibility independently of a successful local build.

Run `swift test` with the same developer toolchain. Run `Tests/Localization/check_bundle.swift` with the archived `.app` path to check native language negotiation and localized permission descriptions. The local installer and ZIP packaging scripts compile the same catalogs into the main app's resource directory.

## Sandbox and privacy

The app and independently sandboxed `LocalMCPBridge.app` share the private Unix socket in App Group `SP73Z8JWXM.localmcp`. The bridge is embedded in `Contents/Helpers`. Authentication requires the capability token and the approved signed peer identity.

The sandbox app uses its own Data Protection Keychain access group. It does not read, migrate or delete the former development app's legacy keychain item. Existing clients moving from that legacy token must copy the new configuration once.

Mail and Voice Memos require explicit read-only folder selections. The app stores security-scoped bookmarks and restores them without UI. Missing, corrupt or stale grants fail closed; stale bookmarks require a new native selection. macOS may additionally require Full Disk Access. Notes uses its specific Apple Events sandbox exception; Shortcuts uses the configured scripting access group and a separate optional-tool opt-in.

The setup sequence covers eight sources and waits for each dialog. Cancellation preserves earlier grants, and concurrent setup starts are suppressed. System permission decisions remain with the user.

## Verified scope

Build 14: universal Release archive and strict deep signature validation passed; 391 Swift tests, four skipped, zero failures. All 298 catalog entries contain both languages with matching interpolation arguments. The build 12 interface was visually checked in English and then started normally in German; build 14 changes the version metadata. Native language negotiation and compiled permission descriptions passed checks.

Earlier signed runtime checks passed synthetic Mail and Voice Memos searches, local transcription and all five local text modes. Normal native app queries passed bounded reads for Calendar, Contacts, Reminders, Notes and Photos. Relocation tests confirmed that stale folder bookmarks are rejected without expanding write access. The optional Apple cloud image dialog generated and imported a synthetic image.

Remaining acceptance includes personal-source queries from an external MCP client, configured optional Shortcuts execution and the user's full eight-permission walkthrough on a fresh installation. Unit tests and archive success do not establish those outcomes.

## Distribution status

As of 13 September 2026, build 12 is available to the four-person internal TestFlight group. Version 1.0.1 (14) has been archived and verified with Xcode 27 RC; its upload completed successfully; Apple processing and assignment remain pending. The public app-specific privacy-policy addendum is being published by the account holder. App Store submission is not complete. The store is configured for manual release, 42 European storefronts and a one-time base price of EUR 4.99 in Germany. German and English metadata and screenshots, age rating, app privacy and authorised content-rights information are saved.

Do not overlay a new app on an old signed bundle. Use a clean staging bundle, verify its signature, preserve the previous app and then replace it. Overlay copies can retain Debug-only files and invalidate the signature.
