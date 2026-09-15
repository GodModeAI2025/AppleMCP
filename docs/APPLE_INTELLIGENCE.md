# Apple Intelligence in LocalMCP

Audit: 12 September 2026, Xcode 27 beta 6 / macOS 27.

| Function | Current implementation | Boundary |
| --- | --- | --- |
| Summarize / actions | ai_summarize, styles summary, actions, summary_and_actions | Direct SystemLanguageModel, macOS 26+, on device |
| Shorten / key points | ai_summarize, styles concise and key_points | Direct local model prompts; not the system Writing Tools UI |
| Rewrite / proofread / friendly / professional | Optional ai_writing_tools | User-created Shortcut; requires opt-in and native approval |
| Translation | Optional ai_translate | User-created Shortcut; its implementation determines processing location |
| Image generation | ai_image_playground | Legacy ImageCreator on macOS15.4–26; explicitly unavailable on macOS27+ |
| Private Cloud Compute | Not integrated | Direct API exists in macOS 27; managed entitlement and separate explicit cloud choice required |

The SDK contains PrivateCloudComputeLanguageModel, introduced in macOS 27.
Apple requires eligibility and approval for the managed entitlement
com.apple.developer.private-cloud-compute. LocalMCP neither has this entitlement
nor creates PCC sessions. Do not describe the framework as universally limited to
on-device processing, and do not describe this app as already supporting PCC.
There is no automatic cloud fallback for ai_summarize.

The five local styles are operations prompted against a language model. Their
output can contain mistakes or omissions. They are not the same implementation
as Apple's system Writing Tools, and they do not cover every Writing Tools format
(e.g. tables) or every Foundation Models capability (e.g. image input).

In the sandbox build, optional Shortcuts use Shortcuts Events with typed inputs.
The required scripting access group is still missing because Xcode MCP's
AddEntitlement rejects documented sandbox keys. Native shortcut execution is not
yet verified. A user-created Shortcut can access the network and perform writes;
its name or requested operation does not constrain its actual implementation.

Sources:
- https://developer.apple.com/apple-intelligence/
- https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.private-cloud-compute
- https://developer.apple.com/private-cloud-compute/

The local Xcode MCP DocumentationSearch confirmed the PCC entitlement requirements
and model availability APIs; the installed FoundationModels Swift interface confirms
the macOS 27 availability annotation. No cloud model request was made.

## Native text workspace

The Sprachmodell page also exposes all five local modes through a native editor.
It uses the same ai_summarize service as MCP, requires completed setup and a
running server, shows provider errors, and supports cancellation. No private text
is added to activity logs by this native entry point. Input is limited to32,000
characters, matching the provider. A native synthetic key-points run and visual
layout check passed in the separate signed Debug app.

## macOS 27 image generation change

An actual signed-app MCP call on this Mac returned ImageCreator.Error.notSupported.
Apple announced on11 June2026 that ImageCreator no longer works on macOS27+. The
SDK confirms deprecation; Apple recommends the interactive Image Playground sheet.
LocalMCP now returns reason=image_creator_removed on macOS27+, without attempting
generation or silently switching providers. Its source status and native page
explain this limitation. This is honest compatibility handling, not a completed
migration: the interactive replacement still needs integration and acceptance.

Source: https://developer.apple.com/news/?id=dz9wvq0r

Apple's WWDC26 session375 explicitly states that the replacement Image Playground
model runs on Private Cloud Compute. It is not an offline replacement. Optional
third-party styles require explicit inclusion; no such integration has been added.
User decision requested before implementing the cloud-based replacement.
Source: https://developer.apple.com/videos/play/wwdc2026/375/

## Authorized integration update

The user authorized the pending sandbox entries, native personal-data permission
checks and an optional Apple-cloud image dialog. Both Notes and Shortcuts entries
were applied and verified in the signed CloudDialog Release. Native source execution
is still pending; applying signing entitlements is not a TCC permission grant.

The Apple Intelligence page now contains an explicit cloud description field and
start button, using imagePlaygroundSheet on macOS27. Personalization is disabled;
allowed styles are illustration, animation and sketch, excluding externalProvider.
Accepted images are read with a25MiB bound, decoded and copied to an app-owned
private temporary file. The standard MCP image tool remains local/legacy and
returns an explicit macOS27 limitation instead of silently opening a cloud dialog.
The new UI compiled in Release; live dialog/output validation remains open.

A Calendar TCC request is currently pending. CUA refuses access to the macOS
UserNotificationCenter app for safety reasons, so the user was asked to confirm
that system dialog themselves. This is a tool interaction restriction, not a
lack of user authorization for the permissions.

Native acceptance now passed for the optional cloud dialog: a synthetic red-apple
description generated an image, which was visually inspected and accepted. The
app successfully copied the result into private temporary storage and displayed
its preview. This verifies the native dialog, not a cloud MCP image endpoint.
