# LocalMCP 1.0.1 – App Store review assessment

Assessment date: 13 September 2026. Reviewed candidate: build 14, Xcode 27 RC 27A266a. This is an evidence-based readiness assessment, not approval from Apple. Store submission is pending.

## Sources and scope

Requested skill: [safaiyeh/app-store-review-skill](https://github.com/safaiyeh/app-store-review-skill), version 1.3.1, commit `d7650c3741dc9a60f40b6f48af0564caa3b2fe02`. The five rule sections were used to classify the app's applicable requirements. Apple's [current review guidelines](https://developer.apple.com/app-store/review/guidelines/) control where the community checklist is broader than the actual rule. iPhone/iPad device checks are not applicable to this macOS-only binary.

Evidence includes source/configuration inspection, the real signed universal archive, native UI inspection, existing automated tests and App Store Connect readback. It does not include a fresh installation on every supported OS or a complete external-client personal-data walkthrough.

## Findings and corrections

1. **5.1.1(i), 1.5: privacy/support links missing inside the app — corrected in build 14.** The Help menu and Permissions screen now expose the existing privacy URL and a support email link. The initial risk notice exposes these links before any consent. Both labels are translated in the app's string catalog. Native Help-menu inspection confirmed both entries.
2. **Privacy API declarations absent — added in build 14.** The app and helper now include their own `PrivacyInfo.xcprivacy`. Declarations cover app-only preferences, metadata of app/group-container and explicitly selected files, and app-local timing. No tracking or developer data collection is declared. This is a documentation/hardening correction, not a claim that missing manifests universally block macOS: Apple's required-reason enforcement article explicitly lists other Apple platforms and must not be overgeneralised. [Apple API definitions](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
3. **2.1, 2.3: version/metadata drift — corrected.** Store version, source version and changelog now say 1.0.1. Screenshots are genuine DE/EN captures and ordered overview, text tools, permissions, intelligence. Review notes describe the RC build, opt-in writes, Notes exception and local helper. Previous beta build 12 must be replaced before submission.
4. **5.1.1(i): public privacy policy does not yet describe LocalMCP — OPEN.** The supplied URL currently describes website data handling. A bilingual, app-specific addendum has been prepared in the release workspace. It needs publication and confirmation of operational support-retention practices. Merely linking to the website does not resolve this content gap.
5. **2.1 / 2.4.5 / 2.5.1: runtime and API review risk — OPEN verification.** Mail and Voice Memos read user-selected local Apple stores; Notes uses an Apple Events temporary exception. Access is read-only and user-authorised, but Apple must assess these integrations. A successful build or schema validation is not proof of approval. External MCP queries against personal sources, optional user Shortcuts, and the full eight-permission fresh-install flow remain unverified end to end. Existing signed synthetic and native-source checks cover only their recorded scope.

## Coverage by guideline family

| Family | Assessment and evidence |
| --- | --- |
| 1.1, 1.2, 1.3, 1.4, 1.7 | No bundled offensive material, public publishing/social feed, random user chat, child-directed category, health advice, regulated substances or crime-reporting service. Private user documents and local AI text processing do not by themselves establish a hosted public UGC platform. Age questionnaire is saved as 4+; new social-media fields were addressed. |
| 1.5–1.6 | Contact links added. Token stored in app-specific Keychain; signed peer checks and private local socket; bounded input/output and one-action approval for writes. No private dataset or token included in store screenshots. |
| 2.1–2.3 | RC archive built and uploaded; accurate 1.0.1 metadata, DE/EN descriptions, four real screenshots each, no demo login required. Public policy and final runtime gaps above remain. No pre-order, IAP or in-app events. |
| 2.4 | Self-contained Xcode app with embedded signed sandboxed helper, universal architectures, deployment target macOS 15, availability gates for newer APIs. No root escalation or third-party installer in the store bundle. Risk acknowledgement explains data consequences, not a license key/paywall or replacement EULA. Physical Intel/older-OS execution was not tested in this assessment. |
| 2.5 | Source scan found no private selector loading, downloaded executable code or advertising SDK. Fixed optional Shortcuts execution and embedded bridge are documented. The sandbox transport is a local Unix socket; it does not require an IPv4 internet service. Full IPv6/cloud-system integration testing remains unverified. No browser, CallKit, Matter, push ads, screen recording or home-screen replacement. |
| 3.1–3.2 | One-time App Store purchase configured at EUR 4.99 base price. No IAP, subscription, alternate checkout, license server, cryptocurrency, financial services, gambling, donations or purchase restoration flow to implement. No mandatory promotion, review or referral action. |
| 4.1–4.4 | Original LocalMCP branding and native SwiftUI workflow; useful source access, diagnostics and local text tools, not a web wrapper. Single macOS store app; no extension marketplace or template variants. Independent local text tools exist on supported AI Macs; broader external-client and non-AI-device utility is not fully runtime verified. |
| 4.5–4.10 | No MusicKit, Apple-service scraping, spam, Apple Pay or social login. External MCP clients are not hosted/downloaded mini-apps inside this binary. Paid product provides the MCP workflow and controls rather than a separate fee for activating an Apple permission or Apple Intelligence capability; Apple's assessment under 4.10 remains discretionary. |
| 5.1 | Permissions are user-controlled and refusal is supported. Sources are local, external clients and optional cloud images are disclosed. No developer telemetry, account creation or own backend; ATT and account deletion are not applicable. App Privacy label is published as “Data Not Collected”. Public app-specific policy remains open. |
| 5.2 | Apache-2.0 license and upstream notices are bundled. User explicitly confirmed required content rights in App Store Connect. No claim of Apple endorsement. Ownership/rights declarations are based on the account holder's confirmation, not inferred from the source code. |
| 5.3–5.6 | No gambling/VPN/MDM. Organisation account, ordinary product keywords, no review manipulation. Storefront restriction: 42 European territories including UK/Switzerland. Manual release selected. |

## Validation

- Build 13 with Xcode RC: 391 Swift tests across three suites, four skipped, zero failures. These tests cover unchanged runtime logic also used by build 14; the build-14 changes are links, manifests and metadata.
- Build 14: universal Release archive succeeds; strict deep signature verification succeeds with access to the macOS trust store; both app/helper manifests are embedded and parse successfully.
- 298 catalog entries have complete German/English translations and matching format arguments. Native bundle language negotiation was checked on the RC build. The new Help links were confirmed in the real native menu.
- `script/check_docs.py`, localisation checks, shell syntax and `git diff --check` pass. The direct-distribution package checker now verifies the manifest against its source; a fresh complete direct ZIP release is a separate deliverable from this store archive.

Before final submission: publish the app-specific privacy details, finish remaining material runtime acceptance, select the latest corrected processed build, and rerun App Store Connect validation. Do not mark this assessment as “all green” while those items are open.

## Review remediation — 16 September 2026, build 15

Apple reviewed build 14 and cited 5.2.5 (Mac in subtitle), 2.4.5(v)
(administrator access during setup), and 5.1.1(iv) (Allow Access pre-prompt button).

Build 15 removes Full Disk Access instructions/settings links from the permissions
screen and denies corresponding settings actions in the sandbox distribution.
Mail and Voice Memos are optional and require already accessible selected data
folders. Provider errors no longer recommend elevated access. Native permission
pre-prompt buttons use Weiter / Continue; denial does not block setup.

Store subtitles now read “KI-Agenten mit lokalen Daten” and
“Connect AI to your local data”. Descriptions disclose the optional folder access.
Obsolete permissions screenshots were removed from both localizations; originals
remain in local release evidence.

Validation: six existing setup/cancellation tests passed; sandbox build passed
seven including refusal of all five Full Disk Access settings aliases while
retaining ordinary Calendar settings. Universal Release archive and strict deep
signature verification passed. Native permissions UI inspected and local bridge
connection succeeded. Existing-install runtime check does not establish a fresh
macOS permission-reset test. Apple acceptance remains pending.


## Review remediation — 19 September 2026, build 18

Apple reviewed build 15 and requested five clarifications about Contacts access,
server uploads, third-party sharing, data use and protection (2.1). Its privacy
finding (5.1.1/5.1.2) concerned identifying recipients before sharing. Both attached
screenshots were inspected: the native Contacts prompt and the generic risk notice.

LocalMCP implements the MCP server side. Users configure each receiving client;
there can be multiple clients, including clients using local LLMs. A fully local
configuration does not require cloud transfer. LocalMCP does not choose a downstream
AI provider and cannot reliably determine or control what a client does with its
results. The response explicitly acknowledges that third-party clients can receive
Contacts results and may forward them externally; it does not claim that all use
is local or that independently selected clients have verified protection policies.

Build 18 adds the agreed explanation to setup in German and English, including
non-exhaustive client examples, trusted-client guidance and token confidentiality.
A separate unchecked sharing acknowledgement is required alongside the existing
risk acknowledgement. Consent version 2 invalidates old acknowledgements; server
startup remains blocked until the new notice is accepted. macOS permissions and
restricted-tool opt-ins remain separate.

Detailed answers were sent to Apple on September 19 at 20:06, with a clarification
about local LLM clients and MCP interoperability at 20:08 (Europe/Berlin). Both
messages were verified in the review conversation. App Review Information was
updated with build-18 instructions and the same architecture explanation.

Validation: three consent tests passed, including migration from the old notice;
321 catalog entries are complete in German and English; documentation checks,
universal Xcode archive and strict signature verification passed. Native German
and English first-page layouts were visually inspected. This does not establish
full fresh-install or external-client runtime acceptance.

Build 18 uploaded successfully at 20:11:38. The last verified TestFlight state was
“Processing”; group availability and renewed Store submission were not yet verified.
Build 17 was an intermediate upload before the local-LLM wording was added and is
superseded by build 18. The privacy website is maintained separately by the owner
and was not changed or newly verified in this remediation. Apple's acceptance of
the revised disclosure remains pending.
