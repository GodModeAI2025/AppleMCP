import AppKit
import Foundation
import ImagePlayground
import M3MCPCore

final class AppleIntelligenceProvider {
    private static let maximumShortcutTextCharacters = 250_000
    private static let maximumImageConceptCharacters = 4_000

    // MARK: - Writing Tools

    func writingTool(input: [String: JSONValue]) async -> ToolResponse {
        let text = input.string("text")
        guard !text.isEmpty else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Missing required argument: text")
        }
        guard text.count <= Self.maximumShortcutTextCharacters else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Text exceeds the 250,000-character Shortcut input limit.")
        }
        let action = input.string("action", default: "summarize")
        let validActions = ["summarize", "rewrite", "proofread", "friendly", "professional", "concise"]
        guard validActions.contains(action) else {
            return ToolResponse(
                ok: false,
                source: "Apple Intelligence",
                message: "Invalid action '\(action)'. Valid values: \(validActions.joined(separator: ", "))"
            )
        }

        let payload: Data
        do {
            payload = try shortcutPayload([
                "contract_version": 1,
                "operation": "writing_tools",
                "action": action,
                "instruction": instruction(for: action),
                "text": text
            ])
        } catch {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Could not encode Shortcut input.")
        }
        guard !Task.isCancelled else { return cancellationResponse("Writing Tools") }
        let result = await ShortcutRunner.run(named: "Writing Tools", jsonInput: payload)
        guard !Task.isCancelled else { return cancellationResponse("Writing Tools") }

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            let item = DataItem(
                id: UUID().uuidString,
                title: "Writing Tools: \(action)",
                kind: "writing_tools_result",
                source: "Apple Intelligence",
                preview: trimmed,
                metadata: ["action": action, "input_length": String(text.count)]
            )
            return ToolResponse(ok: true, source: "Apple Intelligence", items: [item])
        case .failure(let error):
            return ToolResponse(
                ok: false,
                source: "Apple Intelligence",
                message: "Writing Tools unavailable: \(StringSanitizer.compact(error.message, limit: 600))"
            )
        }
    }

    // MARK: - Translation

    func translate(input: [String: JSONValue]) async -> ToolResponse {
        let text = input.string("text")
        guard !text.isEmpty else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Missing required argument: text")
        }
        guard text.count <= Self.maximumShortcutTextCharacters else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Text exceeds the 250,000-character Shortcut input limit.")
        }
        let targetLanguage = input.string("target_language", default: "de").lowercased()
        let sourceLanguage = input.string("source_language", default: "").lowercased()
        guard isLanguageTag(targetLanguage),
              sourceLanguage.isEmpty || isLanguageTag(sourceLanguage) else {
            return ToolResponse(
                ok: false,
                source: "Apple Intelligence",
                message: "Language values must be BCP-47-style tags such as de, en-US, or zh-Hans."
            )
        }

        let payload: Data
        do {
            payload = try shortcutPayload([
                "contract_version": 1,
                "operation": "translate",
                "source_language": sourceLanguage.isEmpty ? "auto" : sourceLanguage,
                "target_language": targetLanguage,
                "text": text
            ])
        } catch {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Could not encode Shortcut input.")
        }
        guard !Task.isCancelled else { return cancellationResponse("Translate") }
        let result = await ShortcutRunner.run(named: "Translate", jsonInput: payload)
        guard !Task.isCancelled else { return cancellationResponse("Translate") }

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            let item = DataItem(
                id: UUID().uuidString,
                title: "Translation → \(targetLanguage)",
                kind: "translation_result",
                source: "Apple Intelligence",
                preview: trimmed,
                metadata: [
                    "target_language": targetLanguage,
                    "source_language": sourceLanguage.isEmpty ? "auto" : sourceLanguage,
                    "input_length": String(text.count)
                ]
            )
            return ToolResponse(ok: true, source: "Apple Intelligence", items: [item])
        case .failure(let error):
            return ToolResponse(
                ok: false,
                source: "Apple Intelligence",
                message: "Translation unavailable: \(StringSanitizer.compact(error.message, limit: 600))"
            )
        }
    }

    // MARK: - Image Playground

    func imagePlayground(input: [String: JSONValue]) async -> ToolResponse {
        let concept = input.string("concept")
        guard !concept.isEmpty else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Missing required argument: concept")
        }
        guard concept.count <= Self.maximumImageConceptCharacters else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Concept exceeds the 4,000-character Image Playground limit.")
        }
        let style = input.string("style", default: "")
        guard style.isEmpty || ["animation", "illustration", "sketch"].contains(style.lowercased()) else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Style must be animation, illustration, or sketch.")
        }

        guard #available(macOS 15.4, *) else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Image Playground API requires macOS 15.4 or later.")
        }

        guard !Task.isCancelled else { return cancellationResponse("Image Playground") }
        return await generateImage(concept: concept, style: style)
    }

    @available(macOS 15.4, *)
    private func generateImage(concept: String, style: String) async -> ToolResponse {
        guard !Task.isCancelled else { return cancellationResponse("Image Playground") }
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Image Playground is not available: \(error.localizedDescription)")
        }
        guard !Task.isCancelled else { return cancellationResponse("Image Playground") }

        let playgroundStyle: ImagePlaygroundStyle
        switch style.lowercased() {
        case "sketch": playgroundStyle = .sketch
        case "illustration": playgroundStyle = .illustration
        default: playgroundStyle = .animation
        }

        do {
            var lastImage: ImageCreator.CreatedImage?
            for try await image in creator.images(for: [.text(concept)], style: playgroundStyle, limit: 1) {
                guard !Task.isCancelled else { return cancellationResponse("Image Playground") }
                lastImage = image
            }

            guard !Task.isCancelled else { return cancellationResponse("Image Playground") }
            guard let result = lastImage else {
                return ToolResponse(ok: false, source: "Apple Intelligence", message: "No image was generated.")
            }

            let nsImage = NSImage(cgImage: result.cgImage, size: NSSize(width: result.cgImage.width, height: result.cgImage.height))
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                return ToolResponse(ok: false, source: "Apple Intelligence", message: "Could not encode generated image.")
            }

            // Writing the generated artifact is the final persistent side effect in this provider.
            guard !Task.isCancelled else { return cancellationResponse("Image Playground") }
            let privateURL = try PrivateTemporaryFile.write(
                pngData,
                prefix: "m3mcp-image-",
                suffix: ".png"
            )

            let item = DataItem(
                id: UUID().uuidString,
                title: "Generated: \(concept)",
                kind: "image_playground",
                source: "Apple Intelligence",
                preview: privateURL.path,
                metadata: [
                    "concept": concept,
                    "style": style.isEmpty ? "animation" : style,
                    "path": privateURL.path,
                    "width": String(result.cgImage.width),
                    "height": String(result.cgImage.height)
                ]
            )
            return ToolResponse(ok: true, source: "Apple Intelligence", items: [item])
        } catch {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Image generation failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private helpers

    private func instruction(for action: String) -> String {
        switch action {
        case "summarize":
            return "Summarize the text concisely."
        case "rewrite":
            return "Rewrite the text to improve clarity and flow."
        case "proofread":
            return "Proofread the text and return the corrected version."
        case "friendly":
            return "Rewrite the text in a friendly tone."
        case "professional":
            return "Rewrite the text in a professional tone."
        case "concise":
            return "Make the text more concise."
        default:
            return "Process the text."
        }
    }

    private func shortcutPayload(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func isLanguageTag(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 35 else { return false }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard let primary = parts.first,
              (2...3).contains(primary.count),
              primary.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return false
        }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.count) && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        }
    }

    private func cancellationResponse(_ operation: String) -> ToolResponse {
        ToolResponse(
            ok: false,
            source: "Apple Intelligence",
            message: "\(operation) was cancelled. Any external action already committed before cancellation cannot be rolled back."
        )
    }
}
