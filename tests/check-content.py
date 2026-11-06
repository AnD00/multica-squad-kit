"""Scan all distributed paths and content without disclosing matched terms."""
import re
import sys
from pathlib import Path

root, source = (Path(p).resolve() for p in sys.argv[1:])
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
print('PASS content: 混入 0 件')
