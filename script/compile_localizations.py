#!/usr/bin/env python3
"""Compile the app's flat string catalogs for SwiftPM packaging (Xcode compiles them itself)."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

def compile_catalogs(destination):
    for catalog in sorted((ROOT / 'Sources/M3MCPApp/Localization').glob('*.xcstrings')):
        strings = json.loads(catalog.read_text())['strings']
        for language in ('de', 'en'):
            lines = []
            for key, entry in sorted(strings.items()):
                unit = entry['localizations'][language]['stringUnit']
                if unit['state'] != 'translated':
                    raise ValueError(f'Untranslated {language}: {key}')
                lines.append(f'{json.dumps(key, ensure_ascii=False)} = {json.dumps(unit["value"], ensure_ascii=False)};')
            output = destination / f'{language}.lproj' / f'{catalog.stem}.strings'
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text('\n'.join(lines) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    compile_catalogs(parser.parse_args().destination)
