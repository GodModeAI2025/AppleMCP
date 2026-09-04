#!/usr/bin/env python3
"""Checks the documentation against the code it describes.

Every check here derives its expectation from a source file, so it fails when
the code moves and the prose stays behind. Checks that would pass forever are
deliberately absent.

  1. Tool parity      new tool in ToolCatalog.swift, not in the README table
  2. Build config     install_local.sh switches configuration, docs keep the old path
  3. Write claim      the README calls the server read-only while write tools exist
  4. Prerequisites    ai_translate shells out to /usr/bin/python3 without saying so

Run: python3 script/check_docs.py
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Sources" / "M3MCPBridge" / "ToolCatalog.swift"
AI_PROVIDER = ROOT / "Sources" / "M3MCPApp" / "Providers" / "AppleIntelligenceProvider.swift"
INSTALL = ROOT / "script" / "install_local.sh"
README = ROOT / "README.md"
PAGE = ROOT / "index.html"

DOCS = (README, PAGE)

failures = []


def fail(check, message):
    failures.append((check, message))


def read(path):
    if not path.exists():
        fail("setup", f"{path.relative_to(ROOT)} is missing")
        return ""
    return path.read_text(encoding="utf-8")


def catalog_tools(text):
    return set(re.findall(r'MCPTool\(\s*name:\s*"([a-z0-9_]+)"', text))


def readme_tools(text):
    """Tool names in the first column of the tables under '## MCP Tools'."""
    section = re.search(r"\n## MCP Tools\n(.*?)(?=\n## )", text, re.S)
    if not section:
        fail("tool parity", "README has no '## MCP Tools' section to compare against")
        return set()
    return set(re.findall(r"^\|\s*`([a-z0-9_]+)`\s*\|", section.group(1), re.M))


def check_tool_parity(catalog_text, readme_text):
    catalog = catalog_tools(catalog_text)
    if not catalog:
        fail("tool parity", "no tools parsed from ToolCatalog.swift, the parser is out of date")
        return
    documented = readme_tools(readme_text)
    for name in sorted(catalog - documented):
        fail("tool parity", f"{name} is registered in ToolCatalog.swift but missing from the README tables")
    for name in sorted(documented - catalog):
        fail("tool parity", f"{name} is in the README tables but no longer registered in ToolCatalog.swift")


def check_build_configuration(install_text):
    match = re.search(r'CONFIGURATION="\$\{M3MCP_CONFIGURATION:-([a-z]+)\}"', install_text)
    if not match:
        fail("build config", "cannot read the default configuration out of script/install_local.sh")
        return
    configuration = match.group(1)
    for path in DOCS:
        text = read(path)
        name = path.name
        paths = set(re.findall(r"\.build/([a-z]+)/M3MCPBridge", text))
        if not paths:
            fail("build config", f"{name} names no bridge binary, so nobody can wire up an MCP client")
        for found in sorted(paths - {configuration}):
            fail(
                "build config",
                f"{name} points at .build/{found}/M3MCPBridge while install_local.sh builds {configuration}",
            )
        expected_command = "swift build" if configuration == "debug" else f"swift build -c {configuration}"
        if expected_command not in text:
            fail("build config", f"{name} has no '{expected_command}', so its own bridge path is never produced")


def check_write_claim(catalog_text):
    writers = sorted(n for n in catalog_tools(catalog_text) if re.search(r"_(create|update|delete)", n))
    if not writers:
        return
    blanket = re.compile(r"read[-\s]?only\s+(access|MCP|server)", re.I)
    for path in DOCS:
        hit = blanket.search(read(path))
        if hit:
            fail(
                "write claim",
                f"{path.name} still promises {hit.group(0)!r} while {len(writers)} write tools ship: "
                + ", ".join(writers),
            )


def check_translate_prerequisites(provider_text, readme_text):
    interpreter = "/usr/bin/python3"
    in_code = interpreter in provider_text
    in_readme = interpreter in readme_text
    if in_code and not in_readme:
        fail("prerequisites", f"AppleIntelligenceProvider shells out to {interpreter}, the README never mentions it")
    if in_readme and not in_code:
        fail("prerequisites", f"the README requires {interpreter}, no provider uses it any more")


def main():
    catalog_text = read(CATALOG)
    readme_text = read(README)
    check_tool_parity(catalog_text, readme_text)
    check_build_configuration(read(INSTALL))
    check_write_claim(catalog_text)
    check_translate_prerequisites(read(AI_PROVIDER), readme_text)

    if failures:
        print(f"{len(failures)} documentation problem(s):\n")
        for check, message in failures:
            print(f"  [{check}] {message}")
        return 1

    print(f"Documentation matches the code: {len(catalog_tools(catalog_text))} tools, "
          "build configuration, write claim, ai_translate prerequisites.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
