#!/usr/bin/env python3
"""Fail when public documentation drifts from source-controlled contracts."""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
POLICY = ROOT / "Sources/M3MCPCore/SecurityPolicy.swift"
CATALOG = ROOT / "Sources/M3MCPBridge/ToolCatalog.swift"
CORE_MODELS = ROOT / "Sources/M3MCPCore/CoreModels.swift"
AI_PROVIDER = ROOT / "Sources/M3MCPApp/Providers/AppleIntelligenceProvider.swift"
SHORTCUT_RUNNER = ROOT / "Sources/M3MCPApp/Support/ShortcutRunner.swift"
INSTALLER = ROOT / "script/install_local.sh"
README = ROOT / "README.md"
PAGE = ROOT / "index.html"
CHANGELOG = ROOT / "CHANGELOG.md"
PLIST = ROOT / "Sources/M3MCPApp/Resources/Info.plist"
WORKFLOWS = ROOT / ".github/workflows"
CI = WORKFLOWS / "ci.yml"
RELEASE_WORKFLOW = WORKFLOWS / "release.yml"
PACKAGE_RELEASE = ROOT / "script/package_release.sh"
ARTIFACT_CHECK = ROOT / "script/check_release_artifact.sh"
SECURITY = ROOT / "SECURITY.md"
SECURITY_MODEL = ROOT / "docs/SECURITY_MODEL.md"

failures: list[tuple[str, str]] = []


def fail(check: str, message: str) -> None:
    failures.append((check, message))


def read(path: Path) -> str:
    if not path.exists():
        fail("setup", f"{path.relative_to(ROOT)} is missing")
        return ""
    return path.read_text(encoding="utf-8")


def tool_definitions(policy_text: str) -> dict[str, str]:
    definitions = dict(
        re.findall(r'^\s*case\s+([A-Za-z][A-Za-z0-9_]*)\s*=\s*"([a-z0-9_]+)"', policy_text, re.M)
    )
    if not definitions:
        fail("tool parity", "no explicit tool raw values parsed from SecurityPolicy.swift")
    return definitions


def tool_partitions(
    policy_text: str,
    definitions: dict[str, str],
) -> tuple[set[str], set[str], dict[str, str]]:
    start_marker = "public static func classification(of tool: M3MCPToolName)"
    end_marker = "public static func classification(ofToolNamed"
    if start_marker not in policy_text or end_marker not in policy_text:
        fail("tool parity", "cannot locate the authoritative tool-classification switch")
        return set(), set(), {}
    block = policy_text.split(start_marker, 1)[1].split(end_marker, 1)[0]
    classifications: dict[str, str] = {}
    for match in re.finditer(
        r'^\s*case\s+(.*?):(.*?)(?=^\s*case\s+|^\s*}\s*$)',
        block,
        re.M | re.S,
    ):
        classification = re.search(r'return\s+\.([A-Za-z][A-Za-z0-9_]*)', match.group(2))
        if not classification:
            continue
        for case_name in re.findall(r'\.([a-z][A-Za-z0-9_]*)', match.group(1)):
            classifications[case_name] = classification.group(1)

    if set(classifications) != set(definitions):
        missing = sorted(set(definitions) - set(classifications))
        extra = sorted(set(classifications) - set(definitions))
        fail("tool parity", f"classification parser mismatch; missing={missing}, extra={extra}")

    default_classes = {"readOnly", "localProcessing", "localGeneration"}
    default_tools = {
        definitions[name] for name, classification in classifications.items()
        if classification in default_classes and name in definitions
    }
    optional_tools = {
        definitions[name] for name, classification in classifications.items()
        if classification not in default_classes and name in definitions
    }
    return default_tools, optional_tools, classifications


def source_opt_in_groups(
    policy_text: str,
    definitions: dict[str, str],
    classifications: dict[str, str],
) -> dict[str, set[str]]:
    constants = dict(
        re.findall(
            r'public static let\s+([A-Za-z][A-Za-z0-9_]*EnvironmentVariable)\s*=\s*'
            r'"(M3MCP_ENABLE_[A-Z_]+)"',
            policy_text,
        )
    )
    start_marker = "public static func requiredEnvironmentVariable(for tool: M3MCPToolName)"
    end_marker = "private static func explicitTrue"
    if start_marker not in policy_text or end_marker not in policy_text:
        fail("tool parity", "cannot locate the authoritative environment-variable switch")
        return {}

    block = policy_text.split(start_marker, 1)[1].split(end_marker, 1)[0]
    environment_by_classification: dict[str, str] = {}
    for match in re.finditer(
        r'^\s*case\s+([^\n:]+):\s*\n?\s*return\s+([A-Za-z][A-Za-z0-9_]*|nil)',
        block,
        re.M,
    ):
        constant_name = match.group(2)
        if constant_name == "nil":
            continue
        environment = constants.get(constant_name)
        if not environment:
            fail("tool parity", f"cannot resolve environment constant {constant_name}")
            continue
        for classification in re.findall(r'\.([a-z][A-Za-z0-9_]*)', match.group(1)):
            environment_by_classification[classification] = environment

    default_classes = {"readOnly", "localProcessing", "localGeneration"}
    optional_classes = set(classifications.values()) - default_classes
    if set(environment_by_classification) != optional_classes:
        fail(
            "tool parity",
            "environment mapping mismatch; "
            f"missing={sorted(optional_classes - set(environment_by_classification))}, "
            f"extra={sorted(set(environment_by_classification) - optional_classes)}",
        )

    groups: dict[str, set[str]] = {}
    for case_name, classification in classifications.items():
        environment = environment_by_classification.get(classification)
        if environment and case_name in definitions:
            groups.setdefault(environment, set()).add(definitions[case_name])
    return groups


def table_tool_names(section: str) -> set[str]:
    rows = "\n".join(line for line in section.splitlines() if line.startswith("|"))
    return set(re.findall(r'`([a-z][a-z0-9_]+)`', rows))


def documented_opt_in_groups(section: str, document_name: str) -> dict[str, set[str]]:
    groups: dict[str, set[str]] = {}
    for line in section.splitlines():
        if not line.startswith("|"):
            continue
        environments = re.findall(r'`(M3MCP_ENABLE_[A-Z_]+)(?:=1)?`', line)
        if not environments:
            continue
        if len(environments) != 1:
            fail("tool parity", f"{document_name} opt-in row names multiple environment variables")
            continue
        environment = environments[0]
        tools = set(re.findall(r'`([a-z][a-z0-9_]+)`', line))
        if not tools:
            fail("tool parity", f"{document_name} opt-in row for {environment} names no tools")
        if environment in groups:
            fail("tool parity", f"{document_name} repeats opt-in row for {environment}")
            groups[environment] |= tools
        else:
            groups[environment] = tools
    return groups


def check_tool_parity(
    policy_text: str,
    catalog_text: str,
    readme_text: str,
) -> tuple[int, set[str], dict[str, set[str]]]:
    definitions = tool_definitions(policy_text)
    catalog_cases = set(re.findall(r'MCPTool\(\s*name:\s*\.([A-Za-z][A-Za-z0-9_]*)', catalog_text))
    expected_cases = set(definitions)
    for case_name in sorted(expected_cases - catalog_cases):
        fail("tool parity", f"{case_name} exists in Core but is missing from ToolCatalog.swift")
    for case_name in sorted(catalog_cases - expected_cases):
        fail("tool parity", f"{case_name} is catalogued without a Core tool definition")

    default_tools, optional_tools, classifications = tool_partitions(policy_text, definitions)
    opt_in_groups = source_opt_in_groups(policy_text, definitions, classifications)
    default_section = re.search(
        r'^## Default-safe tools \(([0-9]+)\)(.*?)(?=^## Optional tool groups)',
        readme_text,
        re.M | re.S,
    )
    optional_section = re.search(
        r'^## Optional tool groups(.*?)(?=^### User-created Shortcut contract)',
        readme_text,
        re.M | re.S,
    )
    if not default_section or not optional_section:
        fail("tool parity", "README tool sections cannot be parsed")
        return len(definitions), default_tools, opt_in_groups

    documented_default = table_tool_names(default_section.group(2))
    documented_optional = table_tool_names(optional_section.group(1))
    if int(default_section.group(1)) != len(default_tools):
        fail("tool parity", "README default-tool heading count differs from source policy")
    if documented_default != default_tools:
        fail(
            "tool parity",
            f"README default table mismatch; missing={sorted(default_tools - documented_default)}, "
            f"stale={sorted(documented_default - default_tools)}",
        )
    if documented_optional != optional_tools:
        fail(
            "tool parity",
            f"README optional table mismatch; missing={sorted(optional_tools - documented_optional)}, "
            f"stale={sorted(documented_optional - optional_tools)}",
        )
    documented_groups = documented_opt_in_groups(optional_section.group(1), "README.md")
    if documented_groups != opt_in_groups:
        fail(
            "tool parity",
            "README optional tool-to-environment mapping mismatch; "
            f"source={{{', '.join(f'{key}: {sorted(value)}' for key, value in sorted(opt_in_groups.items()))}}}, "
            f"docs={{{', '.join(f'{key}: {sorted(value)}' for key, value in sorted(documented_groups.items()))}}}",
        )
    return len(definitions), default_tools, opt_in_groups


def check_policy_surfaces(
    readme_text: str,
    page_text: str,
    security_model_text: str,
    default_tools: set[str],
    opt_in_groups: dict[str, set[str]],
) -> None:
    for document_name, text in (
        ("README.md", readme_text),
        ("index.html", page_text),
        ("docs/SECURITY_MODEL.md", security_model_text),
    ):
        stated_counts = re.findall(r'\b([0-9]+)\s+default tools\b', text, re.I)
        if not stated_counts:
            fail("tool parity", f"{document_name} does not state a default-tool count")
        for stated_count in stated_counts:
            if int(stated_count) != len(default_tools):
                fail(
                    "tool parity",
                    f"{document_name} default-tool count {stated_count} differs from source policy",
                )

    page_count = re.search(r'<h3>\s*([0-9]+)\s+default tools\s*</h3>', page_text, re.I)
    if not page_count:
        fail("tool parity", "index.html does not state its default-tool count")
    elif int(page_count.group(1)) != len(default_tools):
        fail("tool parity", "index.html default-tool count differs from source policy")
    for environment in opt_in_groups:
        if environment not in page_text:
            fail("tool parity", f"index.html omits opt-in variable {environment}")

    section = re.search(
        r'^## Launch-time tool policy(.*?)(?=^### Per-call native approval)',
        security_model_text,
        re.M | re.S,
    )
    if not section:
        fail("tool parity", "docs/SECURITY_MODEL.md launch-time policy cannot be parsed")
        return
    policy_section = section.group(1)
    default_count = re.search(
        r'\|\s*Observation and bounded local processing\s*\|\s*Enabled\s*\|\s*None\s*\|\s*'
        r'([0-9]+)\s+tools\b',
        policy_section,
    )
    if not default_count:
        fail("tool parity", "docs/SECURITY_MODEL.md does not state its default-tool count")
    elif int(default_count.group(1)) != len(default_tools):
        fail("tool parity", "docs/SECURITY_MODEL.md default-tool count differs from source policy")
    documented_groups = documented_opt_in_groups(policy_section, "docs/SECURITY_MODEL.md")
    if documented_groups != opt_in_groups:
        fail(
            "tool parity",
            "docs/SECURITY_MODEL.md optional tool-to-environment mapping differs from source policy",
        )


def check_versions(core_text: str, readme_text: str, changelog_text: str) -> str:
    version_match = re.search(r'public let m3mcpVersion = "([0-9]+\.[0-9]+\.[0-9]+)"', core_text)
    if not version_match:
        fail("version", "cannot parse m3mcpVersion")
        return "unknown"
    version = version_match.group(1)

    try:
        with PLIST.open("rb") as handle:
            plist = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        fail("version", f"cannot parse Info.plist: {error}")
        return version

    if plist.get("CFBundleShortVersionString") != version:
        fail("version", "Info.plist short version differs from m3mcpVersion")
    if f"Version {version}" not in readme_text:
        fail("version", f"README.md does not name Version {version}")
    release_headings = re.findall(r'^##\s+([0-9]+\.[0-9]+\.[0-9]+)\b', changelog_text, re.M)
    if version not in release_headings:
        fail("version", f"CHANGELOG.md has no {version} release heading")
    elif release_headings.count(version) != 1:
        fail("version", f"CHANGELOG.md has {release_headings.count(version)} headings for {version}")
    if not re.search(r'^## Unreleased\s*$', changelog_text, re.M):
        fail("version", "CHANGELOG.md has no Unreleased section")
    return version


def check_build_paths(installer_text: str, readme_text: str, page_text: str) -> None:
    match = re.search(r'CONFIGURATION="\$\{M3MCP_CONFIGURATION:-([a-z]+)\}"', installer_text)
    if not match:
        fail("build config", "cannot parse the installer's default Swift configuration")
        return
    installed_configuration = match.group(1)
    installed_path = f".build/{installed_configuration}/M3MCPBridge"
    if installed_path not in readme_text:
        fail("build config", f"README.md never names the installed bridge path {installed_path}")

    for path, text in ((README, readme_text), (PAGE, page_text)):
        configurations = set(re.findall(r"\.build/([a-z]+)/M3MCPBridge", text))
        if not configurations:
            fail("build config", f"{path.name} names no MCP bridge binary")
        if "debug" in configurations and "swift build" not in text:
            fail("build config", f"{path.name} names a debug bridge without a debug build path")
        if "release" in configurations and not (
            "swift build -c release" in text or "install_local.sh" in text
        ):
            fail("build config", f"{path.name} names a release bridge without a release build path")


def check_write_claim(catalog_text: str, readme_text: str, page_text: str) -> None:
    has_mutation = bool(re.search(r'name:\s*\.calendar(?:Create|Update|Delete)', catalog_text))
    if not has_mutation:
        return
    blanket = re.compile(r"read[-\s]?only\s+(?:access|MCP|server)", re.I)
    for path, text in ((README, readme_text), (PAGE, page_text)):
        match = blanket.search(text)
        if match:
            fail("write claim", f"{path.name} promises {match.group(0)!r} while write tools exist")


def check_shortcut_contract(shortcut_text: str, readme_text: str, page_text: str) -> None:
    combined_docs = readme_text + "\n" + page_text
    for executable in ("/usr/bin/shortcuts", "/usr/bin/python3"):
        in_code = executable in shortcut_text
        in_docs = executable in combined_docs
        if in_code and not in_docs:
            fail("shortcut contract", f"provider uses {executable}, but public docs omit it")
        if in_docs and not in_code:
            fail("shortcut contract", f"public docs require stale executable {executable}")
    if "/usr/bin/shortcuts" in shortcut_text and "--input-path" not in shortcut_text:
        fail("shortcut contract", "Shortcut runner no longer uses the documented stdin input contract")


def check_reminder_claim(catalog_text: str, page_text: str) -> None:
    reminder_section = re.search(
        r'<h3>Reminders</h3>\s*<p>(.*?)</p>', page_text, re.S | re.I
    )
    if not reminder_section:
        fail("reminders", "index.html has no Reminders card")
        return
    card = re.sub(r"<[^>]+>", " ", reminder_section.group(1)).lower()
    reminder_schema = re.search(
        r'name:\s*\.remindersSearch,.*?schema:\s*querySchema\(extra:\s*\[(.*?)\]\)',
        catalog_text,
        re.S,
    )
    schema_text = reminder_schema.group(1) if reminder_schema else ""
    if ("due dates" in card or "priorities" in card) and not (
        '"due"' in schema_text or '"priority"' in schema_text
    ):
        fail("reminders", "index.html advertises due-date or priority filters absent from the schema")


def check_security_links(readme_text: str, page_text: str) -> None:
    for required in (SECURITY, SECURITY_MODEL):
        if not required.exists():
            fail("security docs", f"{required.relative_to(ROOT)} is missing")
    if "SECURITY.md" not in readme_text:
        fail("security docs", "README.md does not link the top-level security policy")
    if "docs/SECURITY_MODEL.md" not in page_text:
        fail("security docs", "index.html does not link the detailed security model")


def workflow_job_blocks(workflow_text: str) -> dict[str, str]:
    """Parse top-level job blocks from the deliberately simple workflow layout."""
    blocks: dict[str, list[str]] = {}
    current: str | None = None
    inside_jobs = False
    for line in workflow_text.splitlines():
        if line == "jobs:":
            inside_jobs = True
            current = None
            continue
        if not inside_jobs:
            continue
        if line and not line.startswith(" "):
            break
        job_match = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
        if job_match:
            current = job_match.group(1)
            blocks[current] = [line]
        elif current is not None:
            blocks[current].append(line)
    return {name: "\n".join(lines) for name, lines in blocks.items()}


def job_permissions(job_block: str) -> dict[str, str]:
    match = re.search(r'^    permissions:\s*\n((?:      [^\n]+\n?)*)', job_block, re.M)
    if not match:
        return {}
    return dict(re.findall(r'^      ([a-z-]+):\s*([^\s#]+)', match.group(1), re.M))


def check_ci_pinning(workflow_texts: dict[Path, str]) -> None:
    if not workflow_texts:
        fail("CI", "no GitHub Actions workflows found")
        return
    for path, workflow_text in sorted(workflow_texts.items()):
        uses = re.findall(r'^\s*uses:\s*([^\s#]+)', workflow_text, re.M)
        for action in uses:
            if action.startswith("./"):
                continue
            if not re.search(r"@[0-9a-f]{40}$", action):
                fail(
                    "CI",
                    f"{path.relative_to(ROOT)} action is not pinned to a full commit: {action}",
                )

    ci_text = workflow_texts.get(CI, "")
    release_text = workflow_texts.get(RELEASE_WORKFLOW, "")
    if "python3 script/check_docs.py" not in ci_text:
        fail("CI", "workflow does not run the documentation contract checker")
    if "import FoundationModels" not in ci_text or "swiftc -typecheck" not in ci_text:
        fail("CI", "workflow does not prove FoundationModels is importable by the active toolchain")
    for required in (
        "workflow_call:",
        "swift test --sanitize=thread",
        "script/package_release.sh",
        "script/check_release_artifact.sh",
        "actions/upload-artifact@",
        'GITHUB_REF_PROTECTED:-false',
    ):
        if required not in ci_text:
            fail("CI", f"ci.yml omits release gate {required}")
    checkout_count = len(re.findall(r'uses:\s*actions/checkout@', ci_text))
    if ci_text.count("persist-credentials: false") < checkout_count:
        fail("CI", "every checkout must disable persisted Git credentials")
    for required_name in ("name: Build and tests", "name: Docs against code"):
        if required_name not in ci_text:
            fail("CI", f"ci.yml changed a required branch-protection context: {required_name}")
    artifact_name = "m3mcp-release-${{ github.sha }}"
    if ci_text.count(f"name: {artifact_name}") != 1:
        fail("CI", "ci.yml must upload exactly one checked payload under the SHA-bound artifact name")
    if "retention-days: 7" not in ci_text:
        fail("CI", "release payload retention must cover a delayed environment review")

    release_jobs = workflow_job_blocks(release_text)
    if set(release_jobs) != {"verify", "attest", "draft-release"}:
        fail("release", f"release.yml job graph differs from verify/attest/draft-release: {sorted(release_jobs)}")
    verify_job = release_jobs.get("verify", "")
    attest_job = release_jobs.get("attest", "")
    draft_job = release_jobs.get("draft-release", "")

    if "uses: ./.github/workflows/ci.yml" not in verify_job:
        fail("release", "verify job does not reuse the complete CI workflow")
    if job_permissions(verify_job) != {"contents": "read"}:
        fail("release", "verify job permissions must be exactly contents: read")
    if not re.search(r'^    needs:\s*verify\s*$', attest_job, re.M):
        fail("release", "attest job must depend directly on verify")
    if job_permissions(attest_job) != {
        "actions": "read",
        "attestations": "write",
        "contents": "read",
        "id-token": "write",
    }:
        fail("release", "attest job permissions differ from the minimal provenance set")
    if not re.search(r'^    needs:\s*\[verify, attest\]\s*$', draft_job, re.M):
        fail("release", "draft-release job must depend on both verify and attest")
    if job_permissions(draft_job) != {"actions": "read", "contents": "write"}:
        fail("release", "draft-release job permissions must be exactly actions: read and contents: write")
    for job_name, job_block in release_jobs.items():
        if job_name != "draft-release" and "contents: write" in job_block:
            fail("release", f"{job_name} job unexpectedly has repository write permission")
    if "actions/checkout@" in release_text:
        fail("release", "release.yml must not check out tag-controlled code")
    if release_text.count("contents: write") != 1:
        fail("release", "release.yml must grant contents: write to exactly one publish job")
    if release_text.count(f"name: {artifact_name}") != 2:
        fail("release", "attest and draft jobs must download the exact SHA-bound checked payload")
    for forbidden in ("Contents/MacOS", "script/", "unzip ", "swift "):
        if forbidden in draft_job:
            fail("release", f"write-capable draft job must not execute candidate/repository code: {forbidden}")
    for required in (
        "environment: release",
        "if: vars.M3MCP_ENABLE_DRAFT_RELEASE == 'true'",
        "actions/attest-build-provenance@",
        "--draft",
        "--verify-tag",
        "Refusing to replace assets on an already-published release",
    ):
        if required not in draft_job and required not in attest_job:
            fail("release", f"release.yml omits protected candidate control {required}")
    if "subject-path: ${{ runner.temp }}/release-payload/M3MCP.app.zip" not in attest_job:
        fail("release", "attestation does not target the checked ZIP")


def check_release_contracts(
    readme_text: str,
    page_text: str,
    package_text: str,
    artifact_text: str,
) -> None:
    for required in ("Contents/Resources/LICENSE", "Contents/Resources/THIRD_PARTY.md"):
        if required not in artifact_text:
            fail("release", f"artifact allowlist omits {required}")
    if "m3mcp_resolve_explicit_identity_from_listings" not in package_text:
        fail("release", "packaging bypasses the hardened explicit identity resolver")
    if "PlistBuddy -c \"Add :CFBundle" in package_text:
        fail("release", "packaging still attempts to add and overwrite source version fields")
    for document_name, text in (("README.md", readme_text), ("index.html", page_text)):
        for required in (
            "M3MCP.app.zip.sha256",
            "ad-hoc",
            "unnotarized",
            "publisher authenticity",
            "--signer-workflow GodModeAI2025/AppleMCP/.github/workflows/release.yml",
        ):
            if required not in text:
                fail("release docs", f"{document_name} omits release-candidate caveat {required}")


def main() -> int:
    policy_text = read(POLICY)
    catalog_text = read(CATALOG)
    core_text = read(CORE_MODELS)
    read(AI_PROVIDER)
    shortcut_text = read(SHORTCUT_RUNNER)
    installer_text = read(INSTALLER)
    readme_text = read(README)
    page_text = read(PAGE)
    changelog_text = read(CHANGELOG)
    workflow_paths = sorted(WORKFLOWS.glob("*.yml")) + sorted(WORKFLOWS.glob("*.yaml"))
    workflow_texts = {path: read(path) for path in workflow_paths}
    package_text = read(PACKAGE_RELEASE)
    artifact_text = read(ARTIFACT_CHECK)
    security_model_text = read(SECURITY_MODEL)

    tool_count, default_tools, opt_in_groups = check_tool_parity(
        policy_text,
        catalog_text,
        readme_text,
    )
    check_policy_surfaces(
        readme_text,
        page_text,
        security_model_text,
        default_tools,
        opt_in_groups,
    )
    version = check_versions(core_text, readme_text, changelog_text)
    check_build_paths(installer_text, readme_text, page_text)
    check_write_claim(catalog_text, readme_text, page_text)
    check_shortcut_contract(shortcut_text, readme_text, page_text)
    check_reminder_claim(catalog_text, page_text)
    check_security_links(readme_text, page_text)
    check_ci_pinning(workflow_texts)
    check_release_contracts(readme_text, page_text, package_text, artifact_text)

    if failures:
        print(f"{len(failures)} documentation problem(s):\n")
        for check, message in failures:
            print(f"  [{check}] {message}")
        return 1

    print(f"Documentation matches source contracts: version {version}, {tool_count} tools, build paths, security links, pinned workflows, and release-candidate gates.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
