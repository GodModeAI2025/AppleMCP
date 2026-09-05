# Security Policy

AppleMCP is a local privileged service: its native app can hold Full Disk Access and macOS TCC
grants, then exposes a bounded tool surface to an MCP client over an owner-only Unix socket. Treat
that app-to-client boundary as security-sensitive.

## Supported versions

There is currently no tagged binary release. Only the latest source on `main` is supported. The
source currently declares version 0.3.0; the app and bridge must always be built from the same
commit because their transport, protocol, and launch-time tool policy are versioned together.

Updating means pulling the latest supported source, rebuilding, and reinstalling the app and
bridge together. Older source snapshots do not receive separate security backports.

## Reporting a vulnerability

Use GitHub's private vulnerability-reporting channel:

**https://github.com/GodModeAI2025/AppleMCP/security/advisories/new**

Do not open a public issue for an undisclosed vulnerability. Include the affected commit, macOS and
Swift versions, required permissions or opt-ins, reproduction steps, impact, and any proof of
concept that can be shared safely.

This project has no on-call rotation or contractual SLA. An acknowledgement is expected within a
few days and an initial assessment with a rough remediation window within two weeks. If no reply
arrives within two weeks, follow up in the private advisory.

## Security model

The maintained threat model, implemented controls, residual limitations, retention behavior, and
release checklist are in [docs/SECURITY_MODEL.md](docs/SECURITY_MODEL.md). In particular:

- a `0700` directory and `0600` socket exclude other users and normally sandboxed apps; a same-user
  unsandboxed process is stopped by the capability token, which every route other than `GET /health`
  requires and which a client that holds a copy of can still present;
- Mail, Notes, Calendar text, transcripts, filenames, and other provider data remain untrusted
  content even when marked with the machine-readable provenance boundary;
- Calendar mutation, permission UI, and user-created Shortcuts are separate launch-time opt-ins;
  Calendar mutations and Shortcut calls additionally require one native default-deny approval;
- user-created Shortcuts are open-world and can make network requests or cause side effects;
- cancellation is best-effort interruption, not rollback of an external effect already committed;
- the stable local signing key is a reusable capability: any process allowed to sign with it can
  create a bundle satisfying the app's certificate-based designated requirement, so its Keychain
  access must remain protected;
- local speech recognition fails when no on-device path is available, although Apple frameworks
  may download model assets.

Security tests use synthetic data and relocated sockets. They do not grant TCC permissions or read
the user's production Mail, Calendar, Notes, Photos, Contacts, Reminders, or Voice Memos data.
