#!/usr/bin/env bash
# ひな形の本体で、全構成の条件と差し込みの契約を検証する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/agent-templates.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
roles='orchestrator planner designer claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal code-reviewer ux-reviewer security-reviewer performance-reviewer qa ci-monitor usage-monitor dependabot-merger'

source "$root/lib/render.sh"
render() {
 template_filter "$1" "$3" >"$test_dir/filter" || return
 if [[ ${4:-0} == 1 ]]; then cat "$test_dir/filter"; return; fi
 jq -Rn '[inputs | split("\t") | {(.[0]): (.[1:]|join("\t"))}] | add' <"$2" >"$test_dir/values.json"
 template_apply "$test_dir/values.json" "$test_dir/filter"
}

for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	enabled=" $roles "
	runtimes='["claude","codex"]'
	case $scenario in
	no-planner) enabled=${enabled/ planner / } ;;
	no-designer) enabled=${enabled/ designer / } ;;
	no-planning) enabled=${enabled/ planner / }; enabled=${enabled/ designer / } ;;
	claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / } ;;
	codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / } ;;
	runtime-claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / }; enabled=${enabled/ codex-principal / } ;;
	runtime-codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / }; enabled=${enabled/ claude-principal / } ;;
	no-reviews) for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa; do enabled=${enabled/ $role / }; done ;;
	minimum) enabled=' orchestrator codex-implementer codex-fixer ' ;;
	esac
	case $scenario in runtime-claude-only) runtimes='["claude"]' ;; runtime-codex-only) runtimes='["codex"]' ;; esac
	mkdir "$test_dir/$scenario"
	cat >"$test_dir/values" <<'EOF'
project_key	demo
member_key	member-a
member_name	Owner
project_name	Demo & literal $HOME
project_id	project-a
repository	example/project
repositories	`example/project`、`example/client`
squad_id	squad-a
squad_mention	[@Squad](mention://squad/squad-a)
owner_mention	[@Owner](mention://member/member-a)
EOF
	for role in $enabled; do
		printf 'agent.%s.name\tdemo-%s-member-a\nagent.%s.id\tagent-%s\nagent.%s.mention\t[@Role](mention://agent/agent-%s)\n' "$role" "$role" "$role" "$role" "$role" "$role" >>"$test_dir/values"
	done
	for file in "$root/common/agents/"*.md; do
		role=$(basename "$file" .md)
		[[ $enabled == *" $role "* ]] || continue
		cp "$test_dir/values" "$test_dir/file-values"
		render "$enabled" "$test_dir/file-values" "$file" 1 >"$test_dir/filtered"
		awk -F': ' '$1=="model" {print "model\t" $2} $1=="thinking_level" {print "thinking_level\t" $2}' "$test_dir/filtered" >>"$test_dir/file-values"
		render "$enabled" "$test_dir/file-values" "$file" >"$test_dir/$scenario/$role"
		grep -qx "name: \"demo-$role-member-a\"" "$test_dir/$scenario/$role"
		grep -qF 'Demo & literal $HOME' "$test_dir/$scenario/$role"
		grep -q '^## このプロジェクトの値$' "$test_dir/$scenario/$role"
		grep -qx -- '- プロジェクトのリポジトリの一覧: `example/project`、`example/client`' "$test_dir/$scenario/$role"
		if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$test_dir/$scenario/$role"; then exit 1; fi
	done
	for config in squad autopilots; do
		render "$enabled" "$test_dir/values" "$root/common/$config.md" >"$test_dir/$scenario/$config"
		if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$test_dir/$scenario/$config"; then exit 1; fi
	done
	grep -qx -- '- プロジェクトのリポジトリの一覧: `example/project`、`example/client`' "$test_dir/$scenario/squad"
	for role in $roles; do
		[[ $enabled != *" $role "* ]] || continue
		if grep -RFq "demo-$role-member-a" "$test_dir/$scenario"; then exit 1; fi
	done
	echo "PASS templates: $scenario の有効な役だけが残り、値を文字列のまま差し込む"
done
runtimes='["claude","codex"]'

# 開始時の確認は、全構成で見張りの呼び出しと返事待ちの分岐より前に残す。
preflight_section() {
	awk '$0=="## 実行の始めの確認" {inside=1; next} inside && /^## / {exit} inside {print}' "$1"
}
assert_preflight() {
	preflight_section "$1" >"$test_dir/preflight"
	for text in squad-preflight 名前だけ 絶対パス '0 以外' 127 'GitHub の読み取り' 見張り in_review 呼ぶ人間 直し方 そのまま添 PATH '動いているタスクがないとき' セットアップ; do
		grep -qF -- "$text" "$test_dir/preflight"
	done
	grep -Eq '引数なし|引数を付けず' "$test_dir/preflight"
}
assert_preflight "$root/common/skills/squad-handoff/SKILL.md"
grep -qF 'squad-preflight <タスク>' "$test_dir/preflight"
grep -qF 'どちらもしない実行では、この確認は流さない' "$test_dir/preflight"
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	first_check=$(awk '/^## 受け取ったら確かめること$/ {inside=1; next} inside && /^- / {print; exit}' "$dir/orchestrator")
	[[ $first_check == *'squad-handoff の「実行の始めの確認」'* && $first_check == *'分かれ道より先'* ]]
	[[ $first_check == *'squad-preflight <タスク>'* ]]
	if grep -qF 'squad-review-wait status' "$dir/orchestrator"; then
		grep -F 'squad-review-wait status' "$dir/orchestrator" | grep -qF '開始時の確認が通ったあと'
		grep -F 'squad-review-wait proceed' "$dir/orchestrator" | grep -qF '開始時の確認が通ったあと'
	fi
	for role in ci-monitor dependabot-merger usage-monitor; do
		file=$dir/$role
		[[ -f $file ]] || continue
		assert_preflight "$file"
		grep -qF '[@Owner](mention://member/member-a)' "$test_dir/preflight"
		preflight_line=$(awk '/^## 実行の始めの確認$/ {print NR; exit}' "$file")
		watch_line=$(awk '/squad-(pr-watch|dependabot-merge|usage-check)/ {print NR; exit}' "$file")
		[[ $preflight_line -lt $watch_line ]]
		if [[ $role == ci-monitor ]]; then
			grep -qF -- '--content-file' "$test_dir/preflight"
			grep -qF 'タスクの状態は、開始時の確認で止まるときだけ' "$file"
		else
			grep -qF 'タスクのない実行は、オートパイロットの指示' "$test_dir/preflight"
		fi
	done
done
echo 'PASS preflight templates: 共通スキルと全構成のリーダー・見張りに、開始時の確認、失敗時の停止・人間への報告・直し方を残す'

# 進捗を聞かれたときと実行を止めるときの節は、全構成のリーダーに、確かめ方・止める条件・やり直し方の要を残す。
run_status_section() {
	awk '$0=="## 進捗を聞かれたときと、実行を止めるとき" {inside=1; next} inside && /^## / {exit} inside {print}' "$1"
}
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	[[ $(grep -cxF '## 進捗を聞かれたときと、実行を止めるとき' "$dir/orchestrator") -eq 1 ]]
	run_status_section "$dir/orchestrator" >"$test_dir/run-status"
	for text in 'runs <タスク> --active' '--siblings' 'run-messages' '--help' \
		'実行の ID' '役' '状態' '始まった時刻' '直近にしていたこと' '終わった' '失敗した' '止められた' \
		'cancel-task' '人間の指示か承認があるときだけ' '自分の判断では止めない' \
		'最後に push されたコミット' '編集・コミット' '失うおそれ' '未確認' '「なし」とは書かない' \
		'確認の 4 項目を挟まずに止める' 'メンションで呼び' '止めた実行の ID' '`multica issue rerun` は使わない'; do
		grep -qF -- "$text" "$test_dir/run-status"
	done
	# 節は、CI とコンフリクトの節の後、受け渡しの節の前に置く。
	ci_line=$(awk '$0=="## CI とコンフリクト" {print NR; exit}' "$dir/orchestrator")
	status_line=$(awk '$0=="## 進捗を聞かれたときと、実行を止めるとき" {print NR; exit}' "$dir/orchestrator")
	handoff_line=$(awk '$0=="## 受け渡しと人間を待つところ" {print NR; exit}' "$dir/orchestrator")
	[[ $ci_line -lt $status_line && $status_line -lt $handoff_line ]]
done
echo 'PASS run-status templates: 全構成のリーダーに、実行の確かめ方・止める条件・やり直し方の要の語句を残す'

for runtime in claude codex; do
	if [[ $runtime == claude ]]; then expected=claude-sonnet-5-5; else expected=gpt-6.1-sol; fi
	for file in "$test_dir/runtime-$runtime-only/"*; do
		case ${file##*/} in squad|autopilots) continue ;; esac
		role=${file##*/}
		model=$(template_field "$file" model)
		if [[ $role == *-principal ]]; then
			[[ $model == "$(template_field "$test_dir/all/$role" model)" ]]
		elif [[ $runtime == claude && ( $role == planner || $role == designer ) ]]; then
			[[ $model == claude-opus-5-5 ]]
		else [[ $model == "$expected" ]]; fi
		for field in thinking_level max_concurrent_tasks skills; do
			[[ $(template_field "$file" "$field") == "$(template_field "$test_dir/all/$role" "$field")" ]]
		done
	done
done
echo 'PASS templates: 片方だけのランタイムでは設計表のモデルへ移し、思考の深さ・同時実行数・スキルを保つ'

printf '<!-- IF runtime-claude -->\nclaude\n<!-- ELSE -->\ncodex\n<!-- ENDIF -->\n<!-- IF planner runtime-codex -->\neither\n<!-- ENDIF -->\n' >"$test_dir/runtime-conditions"
runtimes='["codex"]' template_filter '' "$test_dir/runtime-conditions" >"$test_dir/runtime-result"
printf 'codex\neither\n' >"$test_dir/runtime-want"
cmp "$test_dir/runtime-result" "$test_dir/runtime-want"
echo 'PASS templates: ランタイムの印を役とは別に評価し、ELSEと役とのOR条件を展開する'

for scenario in all runtime-claude-only runtime-codex-only; do
	case $scenario in all) expected='claude codex' ;; runtime-claude-only) expected=claude ;; runtime-codex-only) expected=codex ;; esac
	for file in usage-monitor autopilots; do
		grep -qF "USAGE_CHECK_RUNTIMES に \"$expected\" を渡す" "$test_dir/$scenario/$file"
	done
	sed -n '/^## 使用上限の見張り /,$p' "$test_dir/$scenario/autopilots" >"$test_dir/usage-pilot"
	if [[ $scenario == runtime-codex-only ]]; then
		! grep -q 'CLAUDE_CONFIG_DIR' "$test_dir/usage-pilot"
	else grep -q 'CLAUDE_CONFIG_DIR' "$test_dir/usage-pilot"; fi
	if [[ $scenario == runtime-claude-only ]]; then
		grep -qF '見張りは Claude / low' "$test_dir/usage-pilot"
		grep -qF 'Claude の上限に達すると見張りも止まる' "$test_dir/usage-pilot"
	else grep -qF '見張りは Codex / low' "$test_dir/usage-pilot"; fi
done
echo 'PASS templates: 使用上限の役とオートパイロットに、選択したランタイムの値・環境・停止時の案内だけを残す'

# コンフリクトの状態の確認と規則の入れ直しは別の節で、状態は確認の行に従う。PR の状態の書き方は共通スキルが決める。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	file="$test_dir/$scenario/orchestrator"
	check_section=$(awk '/^### コンフリクトの状態の確認$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$file")
	rearm_section=$(awk '/^### コンフリクトの規則の入れ直し$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$file")
	grep -qF 'squad-pr-watch conflicts-check <タスク>' <<<"$check_section"
	if grep -qF 'squad-pr-watch conflicts <タスク>' <<<"$check_section"; then exit 1; fi
	grep -qF 'squad-pr-watch conflicts <タスク>' <<<"$rearm_section"
	if grep -qF 'squad-pr-watch conflicts-check' <<<"$rearm_section"; then exit 1; fi
	grep -qF '`CONFLICTING` なら' <<<"$check_section"
	grep -qF '`MERGEABLE` なら' <<<"$check_section"
	grep -qF '「未確認」なら' <<<"$check_section"
	grep -qF '「なし」とは書かない' <<<"$check_section"
	grep -qF '`in_progress`' <<<"$check_section"
done
state_skill="$root/common/skills/squad-handoff/SKILL.md"
grep -qxF '## PR の状態を書く' "$state_skill"
state_section=$(awk '/^## PR の状態を書く$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$state_skill")
grep -qF 'コンフリクト:' <<<"$state_section"
grep -qF '未確認' <<<"$state_section"
grep -qF '「なし」' <<<"$state_section"
echo 'PASS templates: リーダーの指示は状態の確認と規則の入れ直しを分け、squad-handoff は PR の状態の書き方を決める'

# PR の紐付けは、受け取ったとき・人間のマージへ回す前・返事を待つ回の開始前に確かめ、空なら人間に画面で紐付けてもらって止まる。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	file="$test_dir/$scenario/orchestrator"
	link_section=$(awk '/^## PR の紐付けの確認$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file")
	grep -qF 'multica issue pull-requests <タスク> --output json' <<<"$link_section"
	grep -qF 'PR を受け取ったとき' <<<"$link_section"
	grep -qF '人間のマージへ回す前' <<<"$link_section"
	grep -qF '返事を待つ回を始める前' <<<"$link_section"
	grep -qF '`pull_requests` が空なら' <<<"$link_section"
	grep -qF 'タスクの画面で PR の URL を紐付けてもらうよう頼んで止まる' <<<"$link_section"
	grep -qF '「PR の紐付けの確認」に従い' "$file"
done
echo 'PASS templates: リーダーの指示は、PR の紐付けを 3 つの時点で確かめ、空なら人間に頼んで止まる'

for role in code-reviewer security-reviewer performance-reviewer ux-reviewer; do
	grep -qx 'model: claude-sonnet-5-5' "$test_dir/claude-only/$role"
	grep -qx 'model: gpt-6.1-sol' "$test_dir/all/$role"
	grep -qx 'model: gpt-6.1-sol' "$test_dir/codex-only/$role"
	[[ $(grep -c '^model:' "$test_dir/claude-only/$role") == 1 ]]
done
echo 'PASS templates: Codex を外したときだけレビュー 4 役を Claude へ替える'

for role in ci-monitor usage-monitor dependabot-merger; do
	if grep -q '^role:' "$test_dir/all/$role"; then exit 1; fi
	grep -qx 'max_concurrent_tasks: 1' "$test_dir/all/$role"
done
grep -qF 'squad-pr-watch ci-check <タスク> agent-orchestrator agent-ci-monitor' "$test_dir/all/ci-monitor"
grep -qF 'squad-dependabot-merge example/project project-a list' "$test_dir/all/autopilots"
grep -qF 'USAGE_CHECK_PROJECT に project-a、USAGE_CHECK_MEMBER に member-a' "$test_dir/all/autopilots"
grep -qF '使用上限の見張り demo-member-a' "$test_dir/all/autopilots"
grep -qF '依存ライブラリの脆弱性チェック demo' "$test_dir/all/autopilots"
if grep -q '^## ' "$test_dir/minimum/autopilots"; then exit 1; fi
echo 'PASS templates: 見張りはスクワッド外でホストの引数を使い、省略時はオートパイロットも消える'

awk -F'|' '!/^#/ && NF {if(NF!=3 || $2 !~ /^#[0-9a-f]+$/ || length($2)!=7 || seen[$1]++) exit 1; count++} END {if(count!=5) exit 1}' "$root/common/labels"
for label in 開発 運用 検証 指示の改善 重要; do grep -q "^$label|" "$root/common/labels"; done
grep -qx '# multica-squad-kit-managed' "$root/common/codex/config.toml"
grep -qx 'allow_login_shell = false' "$root/common/codex/config.toml"
if grep -Eq 'mcp_config:|max_concurrent_tasks: [2-9]|^skills:.*e2e-test|github-link' "$root/common/agents/"*.md "$root/common/autopilots.md"; then exit 1; fi
echo 'PASS templates: 5 ラベルと印付き Codex 設定を持ち、固有の接続やメモリの上限を含めない'

# 最上位の役は、系統ごとに決まったモデルと推論の強さを持ち、読んで指摘するだけにする。
principal_model() { awk -F': ' -v key="$2" '$1==key {print $2}' "$root/common/agents/$1.md"; }
test "$(principal_model claude-principal model)" = claude-fable-5-2
test "$(principal_model codex-principal model)" = gpt-6-astra
for role in claude-principal codex-principal; do
	test "$(principal_model "$role" thinking_level)" = high
	test "$(principal_model "$role" skills)" = 'squad-handoff, verify'
	[[ $(principal_model "$role" role) == 最上位のレビュー* ]]
	grep -qF 'ブランチへの push、PR の本文の書き換え、タスクの状態の変更をしない' "$root/common/agents/$role.md"
	grep -qF 'squad-review-wait report <タスク> <きっかけのコメント> <ファイル>' "$root/common/agents/$role.md"
	grep -qF '設計と PR の見直しでは、指摘ごとに種類として `設計` か `コード` を添える' "$root/common/agents/$role.md"
	if grep -qE '<!-- (IF|ELSE)' "$root/common/agents/$role.md" && grep -E '<!-- IF' "$root/common/agents/$role.md" | grep -vq 'orchestrator'; then exit 1; fi
	grep -qF '`重要`' "$root/common/agents/$role.md"
done
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	[[ ! -f $test_dir/$scenario/claude-principal ]] || grep -qx 'model: claude-fable-5-2' "$test_dir/$scenario/claude-principal"
	[[ ! -f $test_dir/$scenario/codex-principal ]] || grep -qx 'model: gpt-6-astra' "$test_dir/$scenario/codex-principal"
done
[[ ! -f $test_dir/runtime-claude-only/codex-principal && ! -f $test_dir/runtime-codex-only/claude-principal ]]
[[ -f $test_dir/runtime-claude-only/claude-principal && -f $test_dir/runtime-codex-only/codex-principal && -f $test_dir/all/claude-principal && -f $test_dir/all/codex-principal ]]
echo 'PASS templates: 最上位の役は、系統ごとに決まったモデルと high を持ち、使わない系統には置かない'

# 重要なタスクの指示は、使う系統の最上位の役だけを参照し、系統ごとの選び方を残す。
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews runtime-claude-only runtime-codex-only; do
	file="$test_dir/$scenario/orchestrator"
	section=$(awk '/^## 重要なタスクと最上位の役$/ {inside=1; next} inside && /^## / {exit} inside {print}' "$file")
	for heading in 重要の基準 判断する時機 印の記録 修正の依頼の数え方 最上位の役を呼ぶところ 返事の待ち方 最上位の役の選び方; do grep -qxF "### $heading" <<<"$section"; done
	grep -qF '重要の印: 付けた。基準:' <<<"$section"
	grep -qF '修正の依頼: <N> 回目' <<<"$section"
	grep -qF '設計の変更: 実装を始めたあと' <<<"$section"
	grep -qF 'squad-review-wait watch' <<<"$section"
	grep -qF '最上位の役の使用枠が' "$test_dir/$scenario/squad"
	grep -qF '2 つの務め' "$test_dir/$scenario/squad"
done
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews; do
	section=$(awk '/^### 最上位の役の選び方$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$test_dir/$scenario/orchestrator")
	grep -qF 'squad-dispatch-pick principal' <<<"$section"
	grep -qF -- '- `claude-principal`:' <<<"$section"
	grep -qF -- '- `codex-principal`:' <<<"$section"
done
section=$(awk '/^### 最上位の役の選び方$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$test_dir/runtime-claude-only/orchestrator")
grep -qF 'squad-usage-read' <<<"$section"
if grep -qF 'squad-dispatch-pick' <<<"$section"; then exit 1; fi
section=$(awk '/^### 最上位の役の選び方$/ {inside=1; next} inside && /^##/ {exit} inside {print}' "$test_dir/runtime-codex-only/orchestrator")
grep -qF 'squad-usage-read' <<<"$section"
if grep -qF 'squad-dispatch-pick' <<<"$section"; then exit 1; fi
for role in orchestrator designer squad; do
	[[ -f $test_dir/runtime-claude-only/$role ]] || continue
	if grep -qF 'codex-principal' "$test_dir/runtime-claude-only/$role"; then exit 1; fi
	if grep -qF 'claude-principal' "$test_dir/runtime-codex-only/$role"; then exit 1; fi
done
grep -qF 'claude-principal' "$test_dir/runtime-claude-only/orchestrator"
grep -qF 'codex-principal' "$test_dir/runtime-codex-only/orchestrator"
grep -qF '最上位の役は置かない' "$test_dir/minimum/orchestrator"
grep -qxF '## 重要の基準' "$root/skeleton/project.md"
grep -qF '[記入: このプロジェクトで重要なタスクとみなす条件' "$root/skeleton/project.md"
grep -qxF '## ラベル `重要` のあるタスク' "$root/common/agents/designer.md"
grep -qF '人間ではなくスクワッドへ返す' "$test_dir/all/designer"
echo 'PASS templates: リーダーの指示に重要の基準・時機・記録・選び方が残り、系統ごとに選び方が変わり、ない系統の最上位の役を参照しない'

# 省略した役を代行せず、次の有効な役へ回す。不足は人間へ返す。
grep -qF '次の有効な役へ直接回す' "$test_dir/no-planning/orchestrator"
grep -qF '自分で設計や draft PR を作らない' "$test_dir/no-planning/orchestrator"
grep -qF '人間に補ってもらう' "$test_dir/no-planner/designer"
grep -qF 'Claude 系統だけがある' "$test_dir/claude-only/orchestrator"
grep -qF 'Codex 系統だけがある' "$test_dir/codex-only/orchestrator"
grep -qF 'レビューと E2E の役は置かない' "$test_dir/minimum/orchestrator"
echo 'PASS templates: 省いた役を代行せず、不足は人間へ返し、次の有効な役と残る系統へ回す'

for broken in unknown-role missing-value unclosed else-twice; do
	case $broken in
	unknown-role) printf '<!-- IF unknown-role -->\ntext\n<!-- ENDIF -->\n' ;;
	missing-value) printf '%s\n' '{{missing_value}}' ;;
	unclosed) printf '<!-- IF planner -->\ntext\n' ;;
	else-twice) printf '<!-- IF planner -->\n<!-- ELSE -->\n<!-- ELSE -->\n<!-- ENDIF -->\n' ;;
	esac >"$test_dir/broken"
	if render "$roles" "$test_dir/values" "$test_dir/broken" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
	[[ -s $test_dir/err ]]
done
echo 'PASS templates: 未知の役・値の不足・印の不整合は展開を失敗させる'

# 挿入した文字列に差し込みや印があっても、再解釈しない。
printf '%s\n' '{{project_name}}' >"$test_dir/literal"
printf '%s\n' '{"project_name":"literal {{missing_value}} & $HOME \\ <!-- IF planner -->\nnext"}' >"$test_dir/literal.json"
template_apply "$test_dir/literal.json" "$test_dir/literal" >"$test_dir/literal.out"
jq -jr '.project_name+"\n"' "$test_dir/literal.json" >"$test_dir/literal.want"
cmp "$test_dir/literal.out" "$test_dir/literal.want"
echo 'PASS templates: 差し込んだ値の印・記法・改行・引用文字を再解釈しない'

# 本文の書き方・引き継ぎの順序の決まりを、役の指示と共通スキルが同じ見出しで参照する。
skill="$root/common/skills/squad-handoff/SKILL.md"
for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum runtime-claude-only runtime-codex-only; do
	for role in designer claude-implementer codex-implementer; do
		file="$test_dir/$scenario/$role"
		[[ -f $file ]] || continue
		grep -qF 'PR を作った直後に `squad-pr-link <タスク> <PR の URL>` を呼ぶ' "$file"
		grep -qF '成否に応じた metadata と引き継ぎは、スキル squad-handoff の「PR を作る・実装を積む」に従う' "$file"
	done
done
sed -n '/^## PR を作る・実装を積む$/,/^### PR の本文の置き場所と順序$/p' "$skill" >"$test_dir/pr-link-procedure"
grep -qF 'PR を作った直後に `squad-pr-link <タスク> <PR の URL>` を呼ぶ' "$test_dir/pr-link-procedure"
grep -qF '呼ぶ前に metadata の `pr_url` を書かない' "$test_dir/pr-link-procedure"
grep -qF '終了コードが 0 なら、metadata の `pr_url` はスクリプトが書いたので、`branch` だけを置く' "$test_dir/pr-link-procedure"
grep -qF '0 以外なら、止まらずに `branch` と `pr_url` を自分で置く' "$test_dir/pr-link-procedure"
grep -qF 'コマンドが見つからないとき（終了コード 127）も同じに扱う' "$test_dir/pr-link-procedure"
grep -qF '失敗したときは、引き継ぎのコメントの先頭、結論の行のすぐ次の行に「PR をタスクに紐付けられなかったので、タスクの画面で紐付けてほしい」と書く' "$test_dir/pr-link-procedure"
grep -qF '人間への依頼として扱い' "$test_dir/pr-link-procedure"
grep -qF 'スクリプトを呼ぶのは PR を作った直後の 1 回だけにする' "$test_dir/pr-link-procedure"
grep -qF 'タスクの識別子・作業番号・進行の記録は Multica 側に置き、PR の本文やコミットメッセージへ持ち出さない' "$test_dir/pr-link-procedure"
! grep -qF 'PR とタスクは、タスクの画面で URL を指定して紐付ける' "$test_dir/pr-link-procedure"
echo 'PASS templates: 全構成で PR 作成直後に紐付けを呼び、成功と失敗の metadata・引き継ぎ・識別子の扱いを保つ'

for heading in 本文の書き方 'PR を作る・実装を積む' 'PR の本文の置き場所と順序' 引き継ぐとき 'レビューと E2E の返事を返す' 'PR にレビューやテストの結果を書く'; do
	grep -qx "#\{2,3\} $heading" "$skill"
done
grep -qF '1 件 5 行ほど' "$skill"
grep -qF '1,000 字以内' "$skill"
grep -qF '見出しだけを続けない' "$skill"
for role in claude-implementer codex-implementer; do
	grep -qF '1 件 1 行で書く' "$test_dir/all/$role"
	grep -qF '本文を最新の状態の要約に書き直す' "$test_dir/all/$role"
	grep -qF '不一致を全部まとめて 1 回で報告する' "$test_dir/all/$role"
done
for role in claude-fixer codex-fixer; do
	grep -qF 'PR の本文を修正後の状態の要約に書き直す' "$test_dir/all/$role"
	grep -qF '「本来どうあるべきか」' "$test_dir/all/$role"
	grep -qF 'git diff --name-only --diff-filter=U' "$test_dir/all/$role"
	grep -qF 'git diff --name-only origin/main...HEAD' "$test_dir/all/$role"
	grep -qF '検証のスキルの節「コンフリクトを解消したときの検証」' "$test_dir/all/$role"
	grep -qF 'テスト全体は手元で流さず、push のあとの CI で確かめる' "$test_dir/all/$role"
	grep -qF '落ちたテストは流し直さない' "$test_dir/all/$role"
	grep -qF '落ちたテストの名前と出力を添える' "$test_dir/all/$role"
	grep -qF 'git show --remerge-diff <マージのコミット>' "$test_dir/all/$role"
	grep -qF '見直し: 新しいコンテキストで、両方の変更の意図に照らした。直したもの:' "$test_dir/all/$role"
	grep -qF '見直し: しなかった（文字の上の衝突を取り込んだだけ）' "$test_dir/all/$role"
	grep -qF '見直し: できなかった（<理由>）。直したもの: なし' "$test_dir/all/$role"
	! grep -qF '{{' "$test_dir/all/$role"
done
grep -qF 'Agent ツールで、新しいコンテキスト（fork ではないもの）のサブエージェント' "$test_dir/all/claude-fixer"
grep -qF 'codex exec --sandbox read-only --ephemeral' "$test_dir/all/codex-fixer"
! grep -qF 'Agent ツールで' "$test_dir/all/codex-fixer"
for role in code-reviewer performance-reviewer security-reviewer ux-reviewer qa; do
	grep -qF 'スキル squad-handoff の「本文の書き方」に従う' "$test_dir/all/$role"
	grep -qF '「引き継ぐとき」の形と順序にそろえる' "$test_dir/all/$role"
	grep -qF '3 行以内' "$test_dir/all/$role"
done
grep -qF '設計の承認を頼むタスクのコメントは' "$test_dir/all/designer"
grep -qF '実装の一覧は、タスクのコメントに' "$test_dir/all/designer"
echo 'PASS templates: 役の指示と共通スキルが、本文の書き方・PR の本文の置き場所・引き継ぎの順序を同じ見出しで参照する'

# 記入が足りないときの案内は、更新で届く共通スキルだけで読める。
sed -n '/^## 記入が足りずに止まるとき$/,/^## 人間を呼んで止まるとき$/p' "$skill" >"$test_dir/unfilled-stop"
grep -qx '## 記入が足りずに止まるとき' "$test_dir/unfilled-stop"
for phrase in 'squad_kit_task=project-instructions' 'squad_kit_task=repository-change' 見つからなかった 'その実行で受け取った' 推測で検証しない '未記入や未実行は成功にしない'; do
	grep -qF "$phrase" "$test_dir/unfilled-stop"
done
echo 'PASS templates: 共通スキルに未記入の再確認・記入のタスクの印・見つからないときの報告・検証の制約がある'

verify_skill="$root/skeleton/.agents/skills/verify/SKILL.md"
for phrase in 推測して実行せず '未記入や未実行は成功にしません' 'squad-handoff の「記入が足りずに止まるとき」'; do
	grep -qF "$phrase" "$verify_skill"
done
echo 'PASS templates: 検証スキルのひな形は推測と成功扱いを禁じ、共通スキルの返し方へ案内する'

# 指示にはリポジトリの一覧が必要である。
awk -F '\t' '$1!="repositories"' "$test_dir/values" >"$test_dir/without-list"
if render 'orchestrator codex-implementer codex-fixer' "$test_dir/without-list" "$root/common/agents/orchestrator.md" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '値が足りない: repositories' "$test_dir/err"
echo 'PASS templates: 全構成でリポジトリの一覧を渡し、単一の値だけでは一覧の欠落を補わない'
