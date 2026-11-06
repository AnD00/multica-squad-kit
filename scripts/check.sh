#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find lib tests scripts common -type f \( -name '*.sh' -o -name 'squad-*' -o -name gh -o -name pre-push \) -print0)
while IFS= read -r -d '' file; do bash -n "$file"; done < <(find vm -type f \( -name '*.sh' -o -path 'vm/guest/*' \) -print0)
bash -n setup.sh
python3 -c 'import ast; from pathlib import Path; [ast.parse(p.read_text()) for folder in ("lib", "tests") for p in Path(folder).glob("*.py")]'
if command -v pwsh >/dev/null 2>&1; then
	pwsh -NoLogo -NoProfile -NonInteractive -Command '$tokens = $null; $parseErrors = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path (Get-Location) "vm/wsl.ps1"), [ref]$tokens, [ref]$parseErrors); if ($parseErrors.Count) { $parseErrors | ForEach-Object { [Console]::Error.WriteLine($_.ToString()) }; exit 1 }'
elif [[ ${SQUAD_KIT_REQUIRE_PWSH:-} == 1 ]]; then
	echo 'FAIL syntax: pwsh が必要です' >&2
	exit 1
else
	echo 'SKIP syntax: pwsh がないため wsl.ps1 の構文を飛ばします'
fi
echo 'PASS syntax'
