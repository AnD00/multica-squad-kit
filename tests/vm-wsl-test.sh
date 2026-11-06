#!/usr/bin/env bash
set -euo pipefail
if ! command -v pwsh >/dev/null 2>&1; then
 if [[ ${SQUAD_KIT_REQUIRE_PWSH:-} == 1 ]]; then echo 'FAIL WSL: pwsh が必要です' >&2; exit 1; fi
 echo 'SKIP WSL: pwsh がないためテストを飛ばします'
 exit 0
fi
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/vm-wsl.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
PATH= SQUAD_KIT_REQUIRE_PWSH=0 /bin/bash "$root/tests/vm-wsl-test.sh" >"$test_dir/skip.log"
grep -q '^SKIP WSL:' "$test_dir/skip.log"
if PATH= SQUAD_KIT_REQUIRE_PWSH=1 /bin/bash "$root/tests/vm-wsl-test.sh" >"$test_dir/required.log" 2>&1; then exit 1; fi
grep -q '^FAIL WSL: pwsh' "$test_dir/required.log"
echo 'PASS WSL: missing pwsh skips locally and fails when CI requires it'
mkdir -p "$test_dir/bin with space"
printf '#!/bin/bash\nexec %q %q %q "$@"\n' "$(command -v python3)" "$root/tests/vm-wsl-cli.py" "$test_dir" >"$test_dir/bin with space/wsl.exe"
chmod +x "$test_dir/bin with space/wsl.exe"
python3 - "$root/vm/wsl.ps1" <<'PY'
import sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes().startswith(b'\xef\xbb\xbf'), 'wsl.ps1 must be UTF-8 with BOM for PowerShell 5.1'
PY
PATH="$test_dir/bin with space:$PATH" pwsh -NoLogo -NoProfile -NonInteractive -File "$root/tests/vm-wsl-test.ps1" -Root "$root" -TestDirectory "$test_dir"
