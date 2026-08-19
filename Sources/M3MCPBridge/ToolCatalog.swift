import Foundation
import M3MCPCore

struct MCPTool {
    let name: String
    let description: String
    let schema: [String: Any]
}

enum ToolCatalog {
    static let tools: [MCPTool] = [
        // MARK: - Core
        MCPTool(
            name: "source_status",
            description: "List local M3MCP providers, endpoints, and runtime states.",
            schema: objectSchema(properties: [:])
        ),
        MCPTool(
            name: "permissions_status",
            description: "Report macOS permission state for Calendar, Contacts, Reminders, local Mail index, Notes, Photos, the Voice Memos store, and Speech Recognition.",
            schema: objectSchema(properties: [:])
        ),
        MCPTool(
            name: "permissions_request",
            description: "Ask macOS for required M3MCP permissions before using Calendar, Contacts, Reminders, Notes, Photos, and Voice Memos transcription tools; reports manual Full Disk Access need for Mail and Voice Memos.",
            schema: objectSchema(properties: [:])
        ),
        MCPTool(
            name: "permissions_open_settings",
            description: "Open macOS System Settings for M3MCP permission remediation.",
            schema: objectSchema(properties: [
                "pane": [
                    "type": "string",
                    "description": "One of calendar, contacts, reminders, automation, mail, photos, voice_memos, speech, privacy."
                ]
            ])
        ),

        // MARK: - Apple Data Sources
        MCPTool(
            name: "calendar_search",
            description: "Read/search local macOS Calendar events via EventKit.",
            schema: querySchema(extra: [
                "start_days": ["type": "integer", "description": "Relative start day offset. Default -7."],
                "end_days": ["type": "integer", "description": "Relative end day offset. Default 60."]
            ])
        ),
        MCPTool(
            name: "contacts_search",
            description: "Read/search local macOS Contacts / Address Book.",
            schema: querySchema()
        ),
        MCPTool(
            name: "mail_search",
            description: "Read/search messages from the local Apple Mail index without driving Mail.app. Requires Full Disk Access if the Mail store is protected.",
            schema: querySchema(extra: [
                "unread_only": ["type": "boolean", "description": "When true, only return unread inbox messages."],
                "include_body": ["type": "boolean", "description": "When true, include message body snippets. Default false."],
                "since_hours": ["type": "integer", "description": "Only return messages received within the last N hours, e.g. 24."],
                "max_candidates": ["type": "integer", "description": "Maximum inbox messages to inspect. Default 500."]
            ])
        ),
        MCPTool(
            name: "mail_read",
            description: "Read the full content of a single email by its id (returned from mail_search). Returns subject, sender, recipients, date, and the full message body. Requires Full Disk Access.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Message id returned by mail_search."]
            ], required: ["id"])
        ),
        MCPTool(
            name: "reminders_search",
            description: "Read/search local macOS Reminders via EventKit.",
            schema: querySchema(extra: [
                "incomplete_only": ["type": "boolean", "description": "When true, only return incomplete reminders. Default false."],
                "completed_only": ["type": "boolean", "description": "When true, only return completed reminders. Default false."]
            ])
        ),
        MCPTool(
            name: "notes_search",
            description: "Read/search notes in Apple Notes.app.",
            schema: querySchema(extra: [
                "include_body": ["type": "boolean", "description": "When true, include note content in results. Default true when query is non-empty."],
                "max_candidates": ["type": "integer", "description": "Maximum notes to inspect. Default 500."]
            ])
        ),
        MCPTool(
            name: "notes_read",
            description: "Read one Apple Notes.app note by id returned from notes_search.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Note id returned by notes_search."]
            ], required: ["id"])
        ),
        MCPTool(
            name: "photos_search",
            description: "Read/search Apple Photos library metadata through Photos.framework.",
            schema: querySchema(extra: [
                "max_candidates": ["type": "integer", "description": "Maximum photos to inspect. Default 500."]
            ])
        ),
        MCPTool(
            name: "photos_albums",
            description: "List all albums in Apple Photos.app with photo counts.",
            schema: querySchema()
        ),
        MCPTool(
            name: "voicememos_search",
            description: "Read/search local Apple Voice Memos recordings from the CloudRecordings store. Returns title, date, duration, and transcript availability.",
            schema: querySchema(extra: [
                "offset": ["type": "integer", "description": "Number of matches to skip for pagination. Default 0."],
                "since_days": ["type": "integer", "description": "Only return recordings from the last N days."],
                "transcribed_only": ["type": "boolean", "description": "When true, only return recordings that already carry a transcript. Default false."],
                "search_transcripts": ["type": "boolean", "description": "When true, match the query against transcript text instead of titles. Default false."],
                "include_transcript": ["type": "boolean", "description": "When true, include a transcript snippet per recording. Default false."],
                "max_candidates": ["type": "integer", "description": "Maximum recordings to inspect when a transcript filter is active. Default 300."]
            ])
        ),
        MCPTool(
            name: "voicememos_read",
            description: "Read one Apple Voice Memos recording by the id returned from voicememos_search, including its stored transcript when macOS created one.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Recording id returned by voicememos_search."]
            ], required: ["id"])
        ),
        MCPTool(
            name: "voicememos_transcript",
            description: "Return the transcript macOS stored inside a Voice Memos recording. Requires macOS Sequoia or later, or a transcript created by voicememos_transcribe.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Recording id returned by voicememos_search."],
                "format": [
                    "type": "string",
                    "description": "Output format: text, timestamped, or json. Default: text."
                ]
            ], required: ["id"])
        ),
        MCPTool(
            name: "voicememos_audio",
            description: "Return the audio file of a Voice Memos recording as a local path, or as base64 data for small recordings.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Recording id returned by voicememos_search."],
                "format": ["type": "string", "description": "Either path or base64. Default: path."],
                "max_bytes": ["type": "integer", "description": "Maximum size for base64 output. Default 8000000."]
            ], required: ["id"])
        ),
        MCPTool(
            name: "voicememos_transcribe",
            description: "Transcribe a Voice Memos recording with on-device speech recognition. Returns the stored transcript first unless prefer_stored is false. Requires Speech Recognition permission.",
            schema: objectSchema(properties: [
                "id": ["type": "string", "description": "Recording id returned by voicememos_search."],
                "language": ["type": "string", "description": "Recognition locale, e.g. de-DE or en-US. Defaults to the system locale."],
                "prefer_stored": ["type": "boolean", "description": "When true, return an existing macOS transcript instead of re-running recognition. Default true."],
                "timeout_seconds": ["type": "integer", "description": "Abort recognition after N seconds. Default 300."]
            ], required: ["id"])
        ),

        // MARK: - Apple Intelligence
        MCPTool(
            name: "ai_writing_tools",
            description: "Use Apple Intelligence Writing Tools to summarize, rewrite, proofread, or change the tone of text.",
            schema: objectSchema(properties: [
                "text": ["type": "string", "description": "The text to process."],
                "action": [
                    "type": "string",
                    "description": "Writing action: summarize, rewrite, proofread, friendly, professional, concise. Default: summarize."
                ]
            ], required: ["text"])
        ),
        MCPTool(
            name: "ai_translate",
            description: "Translate text using Apple Intelligence / system translation.",
            schema: objectSchema(properties: [
                "text": ["type": "string", "description": "The text to translate."],
                "target_language": ["type": "string", "description": "Target language code, e.g. de, en, fr, es, it, ja, zh. Default: de."],
                "source_language": ["type": "string", "description": "Source language code. Leave empty for auto-detection."]
            ], required: ["text"])
        ),
        MCPTool(
            name: "ai_image_playground",
            description: "Launch Apple Intelligence Image Playground to generate an image from a concept description.",
            schema: objectSchema(properties: [
                "concept": ["type": "string", "description": "Concept or description for the image to generate."],
                "style": ["type": "string", "description": "Optional style hint, e.g. 'sketch', 'illustration', 'animation'."]
            ], required: ["concept"])
        )
    ]

    private static func querySchema(extra: [String: Any] = [:]) -> [String: Any] {
        var properties: [String: Any] = [
            "query": ["type": "string", "description": "Search text. Empty returns recent or representative items where supported."],
            "limit": ["type": "integer", "description": "Maximum number of items. Default 25."]
        ]
        extra.forEach { properties[$0.key] = $0.value }
        return objectSchema(properties: properties)
    }

    private static func objectSchema(properties: [String: Any], required: [String] = []) -> [String: Any] {
        var schema: [String: Any] = [
            "type": "object",
            "properties": properties,
            "additionalProperties": false
        ]
        if !required.isEmpty {
            schema["required"] = required
        }
        return schema
    }
}
