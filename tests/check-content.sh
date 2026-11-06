#!/usr/bin/env bash
# 非公開の語は一覧ファイルで受け取る。内容とファイル名をログに出さない。
set -euo pipefail
python3 "$(dirname "$0")/check-content.py" "${1:-$(cd "$(dirname "$0")/.." && pwd)}" "${SQUAD_KIT_FORBIDDEN_FILE:?禁止語の一覧ファイルを指定してください}"
