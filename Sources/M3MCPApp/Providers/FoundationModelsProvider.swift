import Foundation
import M3MCPCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Summarizes text with Apple's on-device foundation model.
///
/// This is the Apple Intelligence *language* model (`FoundationModels`, macOS 26), distinct from the
/// on-device speech models used for transcription — those live in `Speech.framework` and work whether
/// or not Apple Intelligence is enabled. Everything here runs locally; no text leaves the machine.
///
/// `FoundationModels` does not exist before macOS 26, so the framework is weak-linked in
/// `Package.swift` and every use is gated behind `#available`.
final class FoundationModelsProvider {
    private static let source = "Apple Intelligence"

    func summarize(input: [String: JSONValue]) async -> ToolResponse {
        let text = input.string("text").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return ToolResponse(ok: false, source: Self.source, message: "Missing required argument: text")
        }

        let style = input.string("style", default: "summary_and_actions")
        let validStyles = ["summary_and_actions", "summary", "actions"]
        guard validStyles.contains(style) else {
            return ToolResponse(
                ok: false,
                source: Self.source,
                message: "Invalid style '\(style)'. Valid values: \(validStyles.joined(separator: ", "))"
            )
        }

        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else {
            return ToolResponse(
                ok: false,
                source: Self.source,
                message: "On-device summarization requires macOS 26 or later."
            )
        }
        return await respond(text: text, style: style)
        #else
        return ToolResponse(
            ok: false,
            source: Self.source,
            message: "This build has no FoundationModels support; on-device summarization requires macOS 26 or later."
        )
        #endif
    }

    /// Capability line for `permissions_status`.
    var statusDescription: String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return "On-device Apple foundation model available."
            case .unavailable(let reason):
                return Self.explain(reason)
            }
        }
        return "On-device summarization requires macOS 26."
        #else
        return "On-device summarization requires macOS 26."
        #endif
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
private extension FoundationModelsProvider {
    func respond(text: String, style: String) async -> ToolResponse {
        let model = SystemLanguageModel.default

        if case .unavailable(let reason) = model.availability {
            return ToolResponse(ok: false, source: Self.source, message: Self.explain(reason))
        }

        let session = LanguageModelSession(instructions: Self.instructions(for: style))

        do {
            let response = try await session.respond(to: text)
            let content = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !content.isEmpty else {
                return ToolResponse(
                    ok: false,
                    source: Self.source,
                    message: "The on-device model returned no content."
                )
            }

            let item = DataItem(
                id: UUID().uuidString,
                title: "Summary (\(style))",
                kind: "summary_result",
                source: Self.source,
                preview: content,
                metadata: [
                    "style": style,
                    "input_length": String(text.count),
                    "model": "apple-on-device"
                ]
            )
            return ToolResponse(ok: true, source: Self.source, items: [item])
        } catch {
            return ToolResponse(
                ok: false,
                source: Self.source,
                message: "On-device summarization failed: \(StringSanitizer.compact(error.localizedDescription, limit: 600))"
            )
        }
    }

    static func instructions(for style: String) -> String {
        let base = """
        You process transcripts of voice memos. Reply in the same language as the input. \
        Be factual and concise; never invent details that are not in the text.
        """

        switch style {
        case "summary":
            return base + "\nReturn only a short summary of at most three sentences."
        case "actions":
            return base + """

            Return only concrete action items, one per line, each starting with "- ".
            If the text contains no actionable items, return exactly: (no action items)
            """
        default:
            return base + """

            Respond in exactly this format:
            Summary:
            <at most three sentences>

            Actions:
            - <one concrete action item per line>

            If there are no actionable items, write "- (none)" under Actions.
            """
        }
    }

    /// Maps the framework's coarse reason onto something a user can act on.
    static func explain(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This Mac does not support Apple Intelligence, so on-device summarization is unavailable."
        case .appleIntelligenceNotEnabled:
            // This reason is also reported when Apple Intelligence is enabled but the Siri language
            // does not match the system language — a common state, since Siri's language syncs across
            // devices and may have been set for a HomePod rather than this Mac.
            return """
            Apple Intelligence is not active for this process. Enable it in System Settings → \
            Apple Intelligence & Siri. If it is already enabled, check that the Siri language matches \
            the system language — a mismatch reports this same state.
            """
        case .modelNotReady:
            return "The on-device model is still downloading or preparing. Try again shortly."
        @unknown default:
            return "On-device summarization is unavailable on this Mac."
        }
    }
}
#endif
