"""Scan all distributed paths and content without disclosing matched terms."""
import argparse
import re
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--public', action='store_true')
parser.add_argument('root', type=Path)
parser.add_argument('source', type=Path, nargs='?')
args = parser.parse_args()
root = args.root.resolve()
patterns = []
if not args.public:
    if args.source is None:
        parser.error('禁止語の一覧ファイルを指定してください')
    source = args.source.resolve()
    if source.is_relative_to(root) and not source.is_relative_to(root / 'tmp'):
        sys.exit('FAIL content: 一覧ファイルは原本の外か tmp に置いてください')
    words = [s.strip() for s in source.read_text().splitlines() if s.strip()]
    if not words:
        sys.exit('FAIL content: 一覧が空です')
    words = [s.casefold() for s in words]
    # Short alphabetic terms denote names, not fragments inside ordinary words.
    patterns = [re.compile(r'(?<![a-z])' + re.escape(s) + r'(?![a-z])') if s.isascii() and s.isalpha() and len(s) <= 3 else re.compile(re.escape(s)) for s in words]

def forbidden(text):
    return any(pattern.search(text.casefold()) for pattern in patterns)

uuid = re.compile(r'[\da-f]{8}-[\da-f]{4}-[\da-f]{4}-[\da-f]{4}-[\da-f]{12}', re.I)
count = 0
for p in root.rglob('*'):
    relative = p.relative_to(root)
    if relative.parts[0] in ('.git', 'tmp'):
        continue
    if p.is_symlink():
        count += 1
        continue
    name = str(relative)
    if not p.is_file():
        if forbidden(name):
            count += 1
        continue
    data = p.read_bytes().decode('utf-8', errors='replace')
    if forbidden(name) or forbidden(data) or uuid.search(name) or uuid.search(data):
        count += 1
if count:
    sys.exit(f'FAIL content: 混入 {count} 件（検出した値は表示しません）')
if args.public:
    print('PASS content: 公開の検査で混入 0 件（秘密の語は見ていない）')
else:
    print('PASS content: 混入 0 件')
