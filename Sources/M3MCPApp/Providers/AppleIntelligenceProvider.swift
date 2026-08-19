import AppKit
import Foundation
import ImagePlayground
import M3MCPCore

final class AppleIntelligenceProvider {

    /// Fallback strings the helper scripts emit when the backing Shortcut is missing.
    ///
    /// The scripts end in `|| echo '<sentinel>'`, so AppleScript exits successfully and the failure
    /// text arrives as if it were a result. Left unchecked, the tool answers `ok: true` with an error
    /// message as its payload — an agent chaining these calls would summarize the words
    /// "Writing Tools shortcut not available". These constants exist so the emitted string and the
    /// check that detects it cannot drift apart.
    private enum Sentinel {
        static let writingTools = "Writing Tools shortcut not available"
        static let translationMissing = "Translation requires the Translate shortcut to be set up"
        static let translationUnavailable = "Translation not available"
    }

    // MARK: - Writing Tools

    func writingTool(input: [String: JSONValue]) async -> ToolResponse {
        let text = input.string("text")
        guard !text.isEmpty else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Missing required argument: text")
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

        // Apple Intelligence Writing Tools are exposed via the system writing tools service.
        // We use the `siri` shortcuts / Writing Tools API through a shell helper.
        let script = buildWritingToolScript(text: text, action: action)
        let result = await AppleScriptRunner.run(script)

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmed != Sentinel.writingTools, !trimmed.isEmpty else {
                return ToolResponse(
                    ok: false,
                    source: "Apple Intelligence",
                    message: "Writing Tools is not reachable: this requires a Shortcut named \"Writing Tools\" in the Shortcuts app. For on-device summarization without a Shortcut, use ai_summarize instead."
                )
            }

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
        let targetLanguage = input.string("target_language", default: "de")
        let sourceLanguage = input.string("source_language", default: "")

        let script = buildTranslationScript(text: text, source: sourceLanguage, target: targetLanguage)
        let result = await AppleScriptRunner.run(script)

        switch result {
        case .success(let output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)

            guard trimmed != Sentinel.translationMissing,
                  trimmed != Sentinel.translationUnavailable,
                  !trimmed.isEmpty else {
                return ToolResponse(
                    ok: false,
                    source: "Apple Intelligence",
                    message: "Translation is not reachable: this requires a Shortcut named \"Translate\" in the Shortcuts app."
                )
            }

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
        let style = input.string("style", default: "")

        guard #available(macOS 15.4, *) else {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Image Playground API requires macOS 15.4 or later.")
        }

        return await generateImage(concept: concept, style: style)
    }

    @available(macOS 15.4, *)
    private func generateImage(concept: String, style: String) async -> ToolResponse {
        let creator: ImageCreator
        do {
            creator = try await ImageCreator()
        } catch {
            return ToolResponse(ok: false, source: "Apple Intelligence", message: "Image Playground is not available: \(error.localizedDescription)")
        }

        let playgroundStyle: ImagePlaygroundStyle
        switch style.lowercased() {
        case "sketch": playgroundStyle = .sketch
        case "illustration": playgroundStyle = .illustration
        default: playgroundStyle = .animation
        }

        do {
            var lastImage: ImageCreator.CreatedImage?
            for try await image in creator.images(for: [.text(concept)], style: playgroundStyle, limit: 1) {
                lastImage = image
            }

            guard let result = lastImage else {
                return ToolResponse(ok: false, source: "Apple Intelligence", message: "No image was generated.")
            }

            let filename = "m3mcp_\(UUID().uuidString).png"
            let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

            let nsImage = NSImage(cgImage: result.cgImage, size: NSSize(width: result.cgImage.width, height: result.cgImage.height))
            guard let tiffData = nsImage.tiffRepresentation,
                  let bitmapRep = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
                return ToolResponse(ok: false, source: "Apple Intelligence", message: "Could not encode generated image.")
            }

            try pngData.write(to: fileURL)

            let item = DataItem(
                id: UUID().uuidString,
                title: "Generated: \(concept)",
                kind: "image_playground",
                source: "Apple Intelligence",
                preview: fileURL.path,
                metadata: [
                    "concept": concept,
                    "style": style.isEmpty ? "animation" : style,
                    "path": fileURL.path,
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

    private func buildWritingToolScript(text: String, action: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Writing Tools action mapping to system prompt-style instructions
        let instruction: String
        switch action {
        case "summarize":
            instruction = "Summarize the following text concisely"
        case "rewrite":
            instruction = "Rewrite the following text to improve clarity and flow"
        case "proofread":
            instruction = "Proofread the following text and return the corrected version"
        case "friendly":
            instruction = "Rewrite the following text in a friendly tone"
        case "professional":
            instruction = "Rewrite the following text in a professional tone"
        case "concise":
            instruction = "Make the following text more concise"
        default:
            instruction = "Process the following text"
        }

        // Use the macOS Writing Tools via the system writing tools shortcut
        return """
        set _input to "\(escaped)"
        set _instruction to "\(instruction)"
        -- Writing Tools via Shortcuts app
        set _result to do shell script "shortcuts run 'Writing Tools' <<< " & quoted form of (_instruction & ": " & _input) & " 2>/dev/null || echo '\(Sentinel.writingTools)'"
        return _result
        """
    }

    private func buildTranslationScript(text: String, source: String, target: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "'", with: "'\\''")

        return """
        set _text to "\(escaped)"
        set _result to do shell script "echo " & quoted form of "\(escaped)" & " | /usr/bin/python3 -c \\"import sys, subprocess; t = sys.stdin.read().strip(); r = subprocess.run(['shortcuts', 'run', 'Translate', '--input-stdin', '--output-type', 'text'], input=t.encode(), capture_output=True); print(r.stdout.decode() or r.stderr.decode() or '\(Sentinel.translationMissing)')\\"  2>/dev/null || echo '\(Sentinel.translationUnavailable)'"
        return _result
        """
    }
}
