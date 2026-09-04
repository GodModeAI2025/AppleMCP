# Third Party Notices

## apple-voice-memo-mcp

Parts of the Voice Memos store access, transcript parser, and tool design are derived from
[apple-voice-memo-mcp](https://github.com/jwulff/apple-voice-memo-mcp) by John Wulff. The current
derived implementation is primarily in:

- `Sources/M3MCPApp/Providers/VoiceMemosProvider.swift`
- `Sources/M3MCPCore/VoiceMemoTranscript.swift`
- `Tests/M3MCPCoreTests/VoiceMemoTranscriptTests.swift`

The original project is a TypeScript MCP server with a Swift transcription helper. AppleMCP's
subsequent WAL snapshot, parser hardening, macOS 26 speech path, cache, temporary-file controls, and
security policy are later AppleMCP work rather than claims about upstream behavior.

Repository provenance records the initial AppleMCP import in commit
[`56ec977f4bcc7ef79f1ac4590e9ba69dce19100b`](https://github.com/GodModeAI2025/AppleMCP/commit/56ec977f4bcc7ef79f1ac4590e9ba69dce19100b).
That import did not record an exact upstream commit, so this notice does not invent one.

```
MIT License

Copyright (c) 2025 John Wulff

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
