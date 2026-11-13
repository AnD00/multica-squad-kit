#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
die() { printf '%s\n' "$*" >&2; exit 1; }
source "$root/lib/ui.sh"
source "$root/lib/questions.sh"
project_key=shop member_key=owner
runtimes='["claude","codex"]'
repositories='[{"repository":"example/one"},{"repository":"example/three"}]'

# オートパイロットの名前は、登録に使う common/autopilots.md の見出しと同じになる。
heading() { grep -m1 "^## $1" "$root/common/autopilots.md" | sed "s/^## //; s/{{project_key}}/$project_key/; s/{{member_key}}/$member_key/; s|{{repository}}|${2:-}|"; }
test "$(autopilot_title security-reviewer example/one)" = "$(heading '週 1 回の依存ライブラリの脆弱性チェック' example/one)"
test "$(autopilot_title dependabot-merger example/three)" = "$(heading 'Dependabot の PR の週次の確認' example/three)"
test "$(autopilot_title usage-monitor)" = "$(heading '使用上限の見張り')"
echo 'PASS role-choices: オートパイロットの名前が、登録する見出しと同じになる'

choice() { jq -c --arg key "$1" '.[]|select(.key==$key)' <<<"$role_choices"; }
text() { role_choice_text "$(choice "$1")" '  ' "$(role_choice_note "$1")"; }

# 12項目すべてに、役・担当・エージェントがあり、見出しは種類ごとに分かれる。
test "$(jq length <<<"$role_choices")" = 12
test "$(text planner)" = "$(printf '要件定義: 要望をまとめて人間と合意する。\n  エージェント: shop-planner-owner\n  ほかに変わること: 要件は人間に補ってもらう')"
test "$(text security-reviewer)" = "$(printf 'セキュリティ: 危険な実装を確認する。\n  エージェント: shop-security-reviewer-owner\n  オートパイロット: 週 1 回の依存ライブラリの脆弱性チェック shop example/one、週 1 回の依存ライブラリの脆弱性チェック shop example/three\n  ほかに変わること: 返事を待つ役の一覧から外れる')"
test "$(text ci-monitor)" = "$(printf 'PR の CI の見張り: CIの結果を知らせる。\n  エージェント: shop-ci-monitor-owner\n  見張り: リーダーが PR ごとに置く CI の見張り')"
test "$(text usage-monitor)" = "$(printf '使用上限の見張り: AI の使用上限を見張る。\n  エージェント: shop-usage-monitor-owner\n  オートパイロット: 使用上限の見張り shop-owner')"
test "$(text claude)" = "$(printf 'Claude の実装・修正: 新規実装と指摘の修正を行う。\n  エージェント: shop-claude-implementer-owner、shop-claude-fixer-owner\n  ほかに変わること: 振り分け先から外れる')"
# 外せる項目の見出しは、あるものだけを出す。
for key in $(jq -r '.[].key' <<<"$role_choices"); do
	shown=$(text "$key")
	grep -q '^  エージェント: shop-' <<<"$shown"
	for field in autopilots:オートパイロット watch:見張り changes:ほかに変わること; do
		if ! jq -e --arg field "${field%%:*}" 'has($field)' >/dev/null <<<"$(choice "$key")"; then ! grep -q "^  ${field#*:}: " <<<"$shown"; fi
	done
done
echo 'PASS role-choices: 外せる12項目が、エージェント・オートパイロット・見張り・ほかに変わることの見出しに分かれる'

# 使うランタイムにない系統だけ、1行目の末尾に注意が付く。
runtimes='["claude"]'
test "$(text codex | sed -n 1p)" = 'Codex の実装・修正: 新規実装と指摘の修正を行う。（使うランタイムにないため外れます）'
test -z "$(role_choice_note claude)"
test -z "$(role_choice_note planner)"
echo 'PASS role-choices: 使わないランタイムの系統だけ、1行目に外れる注意が付く'

# リーダーのエージェント名と、使うランタイムの最上位の役を、外せない役として出す。
leader=$(printf 'リーダー（orchestrator）: 振り分けと進行を担当します。必須のため外せません。\n  エージェント: shop-orchestrator-owner')
claude_principal=$(printf 'Claude の最上位のレビュー（claude-principal）: すべてのタスクの最終レビューと、重要なタスクの設計の見直しをします。外せません。\n  エージェント: shop-claude-principal-owner')
codex_principal=$(printf 'Codex の最上位のレビュー（codex-principal）: すべてのタスクの最終レビューと、重要なタスクの設計の見直しをします。外せません。\n  エージェント: shop-codex-principal-owner')
runtimes='["claude","codex"]'
test "$(role_fixed_text)" = "$leader"$'\n'"$claude_principal"$'\n'"$codex_principal"
runtimes='["claude"]'
test "$(role_fixed_text)" = "$leader"$'\n'"$claude_principal"
runtimes='["codex"]'
test "$(role_fixed_text)" = "$leader"$'\n'"$codex_principal"
# 外せる項目の候補に、最上位の役は出ない。
test "$(jq '[.[].roles[]|select(test("principal"))]|length' <<<"$role_choices")" = 0
echo 'PASS role-choices: リーダーと使うランタイムの最上位の役を、外せない役として出す'
