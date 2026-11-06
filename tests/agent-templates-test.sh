#!/usr/bin/env bash
# 段12の本体で、全構成の条件と差し込みの契約を検証する。
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

for scenario in all no-planner no-designer no-planning claude-only codex-only no-reviews minimum; do
	enabled=" $roles "
	case $scenario in
	no-planner) enabled=${enabled/ planner / } ;;
	no-designer) enabled=${enabled/ designer / } ;;
	no-planning) enabled=${enabled/ planner / }; enabled=${enabled/ designer / } ;;
	claude-only) enabled=${enabled/ codex-implementer / }; enabled=${enabled/ codex-fixer / } ;;
	codex-only) enabled=${enabled/ claude-implementer / }; enabled=${enabled/ claude-fixer / } ;;
	no-reviews) for role in code-reviewer ux-reviewer security-reviewer performance-reviewer qa; do enabled=${enabled/ $role / }; done ;;
	minimum) enabled=' orchestrator codex-implementer codex-fixer ' ;;
	esac
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
grep -qF '1 段 1 行にする' "$test_dir/all/designer"
echo 'PASS templates: 役の指示と共通スキルが、本文の書き方・PR の本文の置き場所・引き継ぎの順序を同じ見出しで参照する'

# 単一の互換用の値が残っていても、一覧の欠落を先頭への読み替えで補わない。
awk -F '\t' '$1!="repositories"' "$test_dir/values" >"$test_dir/without-list"
if render 'orchestrator codex-implementer codex-fixer' "$test_dir/without-list" "$root/common/agents/orchestrator.md" >"$test_dir/out" 2>"$test_dir/err"; then exit 1; fi
grep -q '値が足りない: repositories' "$test_dir/err"
echo 'PASS templates: 全構成でリポジトリの一覧を渡し、単一の値だけでは一覧の欠落を補わない'
