#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find lib tests scripts common -type f \( -name '*.sh' -o -name 'squad-*' -o -name gh -o -name pre-push \) -print0)
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find vm -type f \( -name '*.sh' -o -path 'vm/guest/*' \) -print0)
bash -n setup.sh
python3 -c 'import ast; from pathlib import Path; [ast.parse(p.read_text()) for folder in ("lib", "tests") for p in Path(folder).glob("*.py")]'
echo 'PASS syntax'
