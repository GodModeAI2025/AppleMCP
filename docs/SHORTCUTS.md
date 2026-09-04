# User Shortcut Contract

AppleMCP's `ai_writing_tools` and `ai_translate` tools call user-created Shortcuts. They are disabled by default because their behavior cannot be inferred or constrained by AppleMCP. Enable them only with `M3MCP_ENABLE_USER_SHORTCUTS=1` in both the app and bridge environments.

Every invocation still requires one native approval in M3MCPApp.

## Invocation behavior

- Shortcut names are exactly `Writing Tools` and `Translate`.
- AppleMCP invokes `/usr/bin/shortcuts` directly with an argument vector. It does not use a shell, AppleScript, or Python to construct the command.
- Input is passed only on the child process's standard input with `--input-path -`; AppleMCP does
  not create or later reopen a JSON input path.
- The Shortcut must return non-empty UTF-8 plain text.
- Standard output and standard error are each capped at 1 MiB; truncation of either stream fails the call.
- Execution is terminated after 60 seconds.

The JSON object is contract version 1. Consumers should reject unsupported future versions rather than guessing.

## `Writing Tools` input

```json
{
  "contract_version": 1,
  "operation": "writing_tools",
  "action": "summarize",
  "instruction": "Summarize the text concisely.",
  "text": "Caller-provided text"
}
```

`action` is one of `summarize`, `rewrite`, `proofread`, `friendly`, `professional`, or `concise`. `instruction` is the corresponding plain-language request supplied by AppleMCP. The Shortcut should process `text` according to those fields and return the resulting text.

## `Translate` input

```json
{
  "contract_version": 1,
  "operation": "translate",
  "source_language": "auto",
  "target_language": "de",
  "text": "Caller-provided text"
}
```

Language values are BCP-47-style tags validated by AppleMCP, such as `de`, `en-US`, or `zh-Hans`. `source_language` is `auto` when the caller did not specify a source. The Shortcut should translate `text` to `target_language` and return only text.

## Security warning

These contracts describe inputs and outputs; they do not restrict Shortcut actions. A user can build either Shortcut to send text to a web service, write or delete files, message people, or control other applications. Review the Shortcut in the Shortcuts app before enabling this group. The native AppleMCP sheet authorizes one invocation of the named Shortcut, including all actions defined inside it.
