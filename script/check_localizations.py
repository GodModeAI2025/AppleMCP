#!/usr/bin/env python3
"""Validate complete DE/EN catalogs, interpolation types and distributable resources."""
import collections
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLACEHOLDER = re.compile(r'%(?:(\d+)\$)?(lld|llu|ld|lu|@|d|u|f|g)')

def arguments(value):
    result = collections.Counter()
    sequential = 0
    for match in PLACEHOLDER.finditer(value):
        sequential += 1
        result[(int(match[1]) if match[1] else sequential, match[2])] += 1
    return result

def check():
    count = 0
    for path in sorted((ROOT / 'Sources/M3MCPApp/Localization').glob('*.xcstrings')):
        catalog = json.loads(path.read_text())
        assert catalog['sourceLanguage'] == 'de', path
        for key, entry in catalog['strings'].items():
            for language in ('de', 'en'):
                unit = entry.get('localizations', {}).get(language, {}).get('stringUnit', {})
                assert unit.get('state') == 'translated' and unit.get('value'), (path.name, key, language)
                assert arguments(key) == arguments(unit['value']), (path.name, key, language, 'format arguments changed')
            count += 1
    if len(sys.argv) > 1:
        app = Path(sys.argv[1])
        for language in ('de', 'en'):
            for table in ('Localizable', 'InfoPlist'):
                assert (app / 'Contents/Resources' / f'{language}.lproj' / f'{table}.strings').is_file(), (language, table)
    print(f'{count} catalog entries: DE/EN complete; interpolation arguments preserved.')

if __name__ == '__main__':
    check()
