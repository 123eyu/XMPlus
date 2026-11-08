#!/usr/bin/env python3
"""Extract exactly the tagged version's top-level CHANGELOG release section."""
import argparse
from pathlib import Path
import re


def release_notes(changelog, tag):
    if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError(f'Expected a stable release tag, got: {tag}')
    sections = list(re.finditer(r'^##[ \t]+([^\r\n]+?)[ \t]*\r?$', changelog, re.M))
    matches = [index for index, section in enumerate(sections) if section[1] == tag[1:]]
    if len(matches) != 1:
        raise ValueError(f'Expected exactly one CHANGELOG section for {tag}')
    index = matches[0]
    start = sections[index].start()
    end = sections[index + 1].start() if index + 1 < len(sections) else len(changelog)
    notes = changelog[start:end].strip()
    if not notes.partition('\n')[2].strip():
        raise ValueError(f'Empty CHANGELOG section for {tag}')
    return notes + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    parser.add_argument('--changelog', type=Path, default=Path('CHANGELOG.md'))
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.write_text(release_notes(args.changelog.read_text(encoding='utf-8'), args.tag), encoding='utf-8')


if __name__ == '__main__':
    main()
