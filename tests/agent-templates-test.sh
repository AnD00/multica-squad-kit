#!/usr/bin/env bash
# ひな形の本体で、全構成の条件と差し込みの契約を検証する。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/tmp"
test_dir=$(mktemp -d "$root/tmp/agent-templates.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
roles='orchestrator planner designer claude-implementer codex-implementer claude-fixer codex-fixer code-reviewer ux-reviewer security-reviewer performance-reviewer qa ci-monitor usage-monitor dependabot-merger'

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
	claude-only|runtime-claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / } ;;
	codex-only|runtime-codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / } ;;
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
grep -qF 'どちらもしない実行では、この確認は流さない' "$test_dir/preflight"
for dir in "$test_dir/"*/; do
	[[ -f $dir/orchestrator ]] || continue
	first_check=$(awk '/^## 受け取ったら確かめること$/ {inside=1; next} inside && /^- / {print; exit}' "$dir/orchestrator")
	[[ $first_check == *'squad-handoff の「実行の始めの確認」'* && $first_check == *'分かれ道より先'* ]]
	if grep -qF 'squad-review-wait status' "$dir/orchestrator"; then
		grep -F 'squad-review-wait status' "$dir/orchestrator" | grep -qF '開始時の確認が通ったあと'
		grep -F 'squad-review-wait leader-check' "$dir/orchestrator" | grep -qF '開始時の確認が通ったあと'
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
echo 'PASS preflight templates: 共通スキルと全構成の進行・見張りに、開始時の確認、失敗時の停止・人間への報告・直し方を残す'

for runtime in claude codex; do
	if [[ $runtime == claude ]]; then expected=claude-sonnet-5-5; else expected=gpt-6.1-sol; fi
	for file in "$test_dir/runtime-$runtime-only/"*; do
		case ${file##*/} in squad|autopilots) continue ;; esac
		role=${file##*/}
		model=$(template_field "$file" model)
		if [[ $runtime == claude && ( $role == planner || $role == designer ) ]]; then
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

awk -F'|' '!/^#/ && NF {if(NF!=3 || $2 !~ /^#[0-9a-f]+$/ || length($2)!=7 || seen[$1]++) exit 1; count++} END {if(count!=4) exit 1}' "$root/common/labels"
for label in 開発 運用 検証 指示の改善; do grep -q "^$label|" "$root/common/labels"; done
grep -qx '# multica-squad-kit-managed' "$root/common/codex/config.toml"
grep -qx 'allow_login_shell = false' "$root/common/codex/config.toml"
if grep -Eq 'mcp_config:|max_concurrent_tasks: [2-9]|^skills:.*e2e-test|github-link' "$root/common/agents/"*.md "$root/common/autopilots.md"; then exit 1; fi
echo 'PASS templates: 4 ラベルと印付き Codex 設定を持ち、固有の接続やメモリの上限を含めない'

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
done
for role in code-reviewer performance-reviewer security-reviewer ux-reviewer qa; do
	grep -qF 'スキル squad-handoff の「本文の書き方」に従う' "$test_dir/all/$role"
	grep -qF '「引き継ぐとき」の形と順序にそろえる' "$test_dir/all/$role"
	grep -qF '3 行以内' "$test_dir/all/$role"
done
grep -qF '設計の承認を頼むタスクのコメントは' "$test_dir/all/designer"
grep -qF '実装の一覧は、課題のコメントに' "$test_dir/all/designer"
echo 'PASS templates: 役の指示と共通スキルが、本文の書き方・PR の本文の置き場所・引き継ぎの順序を同じ見出しで参照する'

# 指示にはリポジトリの一覧が必要である。
awk -F '\t' '$1!="repositories"' "$test_dir/values" >"$test_dir/without-list"
if render 'orchestrator codex-implementer codex-fixer' "$test_dir/without-list" "$root/common/agents/orchestrator.md" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '値が足りない: repositories' "$test_dir/err"
echo 'PASS templates: 全構成でリポジトリの一覧を渡し、単一の値だけでは一覧の欠落を補わない'
