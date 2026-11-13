#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-pr-watch-register-test.sh で実行する。
# CLI を差し替え、実際のタスク・PR・エージェントには書き込まない。見張りの登録・通知先の選択・契約の検査を確かめる。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

source "$root/tests/pr-watch-test-lib.sh"

# 名前の置換で役を推測せず、引数の ID を規則にそのまま渡す。
reset_fixture
(cd "$test_dir" && bash "$script" ci test-issue monitor trigger-comment) >"$test_dir/output"
assert_jq -s 'length == 1 and (.[0].args | index("--agent-id") as $i | .[$i+1] == "monitor")
	and (.[0].body | contains("squad-pr-watch ci-check"))' "$test_dir/wakeups.jsonl"
assert_jq -s 'all(.[]; .[0:2] != ["agent", "list"])' "$test_dir/calls.jsonl"
reset_fixture
(cd "$test_dir" && bash "$script" conflicts test-issue) >"$test_dir/output"
assert_jq -s 'length == 1 and (.[0].body | contains("リーダーの「実装・修正の振り分け」に従い、有効な修正の役を選んでください"))
	and (.[0].body | contains("squad-dispatch-pick") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS 登録: 見張り役 ID を渡し、コンフリクト通知はリーダーの振り分けを参照する'

# 規則の欄（agent_id・mode・condition・enabled・paused_reason）は、欄がある場合の動作を確かめる。
# 欄が読めずに null になると、止まった規則を作り直して暴走の防止を外したり、有効な規則を重ねたりする。
# 見本の規則から欄を差し替えて並べ、登録の結果（出力・作った規則・消した規則）を見る。
ci_rule() { # id agent_id mode event enabled paused_reason
	fixture issue-wakeups | jq -c --arg id "$1" --arg agent "$2" --arg mode "$3" --arg event "$4" --argjson enabled "$5" --argjson paused "$6" \
		'. + {id: $id, agent_id: $agent, mode: $mode, enabled: $enabled, paused_reason: $paused,
			condition: (if $event == "" then null else {type: "pull_request", event: $event} end)}'
}
register_ci() { # rules... (JSON の 1 行ずつ)。出力は register-output に残す。
	reset_fixture
	printf '%s\n' "$@" | jq -s '.' >"$test_dir/rules.json"
	(cd "$test_dir" && bash "$script" ci test-issue monitor trigger-comment) >"$test_dir/register-output"
}
deleted_ids() { jq -sr '[.[] | select(.[0:3] == ["issue", "wakeup", "delete"]) | .[4]] | sort | join(",")' "$test_dir/calls.jsonl"; }
metadata_writes() { jq -s '[.[] | select(.[0:3] == ["issue", "metadata", "set"])] | length' "$test_dir/calls.jsonl"; }

# 暴走の防止で止まった規則は、作り直さず、止まった理由を知らせる。
for paused in loop rate; do
	register_ci "$(ci_rule old monitor continuous checks_finished false "\"$paused\"")"
	[[ $(<"$test_dir/register-output") == "CI の見張りが止まっています（${paused}）。次に人間を呼ぶコメントに添えてください。" ]]
	[[ ! -s $test_dir/wakeups.jsonl && -z $(deleted_ids) ]]
done
register_ci "$(ci_rule loop-rule monitor continuous checks_finished false '"loop"')" "$(ci_rule rate-rule monitor continuous checks_finished false '"rate"')"
[[ $(<"$test_dir/register-output") == 'CI の見張りが止まっています（loop, rate）。次に人間を呼ぶコメントに添えてください。' ]]
[[ ! -s $test_dir/wakeups.jsonl && -z $(deleted_ids) ]]
echo 'PASS ci 登録: loop・rate で止まった規則があれば、理由を知らせ、作り直さず消さない'

# 有効な規則があれば何もしない。有効でない規則（paused_reason なし）は消して入れ直す。
register_ci "$(ci_rule live monitor continuous checks_finished true null)"
[[ ! -s $test_dir/register-output && ! -s $test_dir/wakeups.jsonl && -z $(deleted_ids) ]]
register_ci "$(ci_rule spent monitor continuous checks_finished false null)"
assert_jq -s 'length == 1' "$test_dir/wakeups.jsonl"
[[ $(deleted_ids) == spent ]]
echo 'PASS ci 登録: 有効な規則があれば登録せず、有効でない規則は消して入れ直す'

# 見張り役・continuous・checks_finished 以外の規則は、登録を止めず、消さない。
register_ci "$(ci_rule other-agent other continuous checks_finished true null)" \
	"$(ci_rule once monitor once checks_finished true null)" \
	"$(ci_rule other-event monitor continuous conflicts true null)" \
	"$(ci_rule no-condition monitor continuous '' true null)" \
	"$(ci_rule other-paused other continuous checks_finished false '"loop"')" \
	"$(ci_rule target monitor continuous checks_finished false null)"
assert_jq -s 'length == 1' "$test_dir/wakeups.jsonl"
[[ $(deleted_ids) == target && $(<"$test_dir/register-output") == *'"id"'* ]]
echo 'PASS ci 登録: 別の役・once・別の条件・条件なしの規則は登録を止めず、消さない'

# 記録のスレッドが読めるときは、metadata を書き換えず、そのスレッドへ戻す。
register_ci
[[ $(metadata_writes) == 0 ]]
assert_jq -s 'length == 1 and (.[0].args | index("--parent") as $i | .[$i+1] == "ci-thread")
	and (.[0].body | contains("記録のスレッド: ci-thread（0 以外で終わったときの返信先）"))
	and (.[0].args | index("--mode") as $i | .[$i+1] == "continuous")' "$test_dir/wakeups.jsonl"
echo 'PASS ci 登録: 記録のスレッドがあれば metadata を書かず、そのスレッドへ返信先を向ける'

# conflicts は、conflicts の規則だけを消して入れ直し、CI などほかの条件の規則を残す。
reset_fixture
printf '%s\n' "$(ci_rule c1 monitor continuous conflicts true null)" "$(ci_rule c2 other once conflicts false null)" \
	"$(ci_rule ci monitor continuous checks_finished true null)" "$(ci_rule none monitor continuous '' true null)" | jq -s '.' >"$test_dir/rules.json"
(cd "$test_dir" && bash "$script" conflicts test-issue) >"$test_dir/output"
[[ $(deleted_ids) == c1,c2 ]]
assert_jq -s 'length == 1' "$test_dir/wakeups.jsonl"
echo 'PASS conflicts 登録: conflicts の規則だけを消して入れ直し、CI などほかの条件の規則を残す'

# 通知の参照先を実際に展開したリーダーからたどり、残る系統の修正役だけへ進める。
source "$root/lib/render.sh"
section=$(jq -sr '.[0].body | capture("リーダーの「(?<section>[^」]+)」").section' "$test_dir/wakeups.jsonl")
for family in claude codex; do
	enabled="orchestrator $family-implementer $family-fixer"
	template_filter "$enabled" "$root/common/agents/orchestrator.md" >"$test_dir/orchestrator-filtered"
	jq -n --arg family "$family" '{project_key:"demo", member_key:"member-a", project_name:"Demo",
		project_id:"project-a", repository:"example/project", repositories:"`example/project`、`example/client`", squad_id:"squad-a",
		squad_mention:"[@Squad](mention://squad/squad-a)", owner_mention:"[@Owner](mention://member/member-a)"}
		+ (reduce ["orchestrator", ($family+"-implementer"), ($family+"-fixer")][] as $role ({};
			. + {("agent."+$role+".id"): ("agent-"+$role),
				("agent."+$role+".name"): ("demo-"+$role+"-member-a"),
				("agent."+$role+".mention"): ("[@Role](mention://agent/agent-"+$role+")")}))' >"$test_dir/template-values.json"
	template_apply "$test_dir/template-values.json" "$test_dir/orchestrator-filtered" >"$test_dir/orchestrator"
	# 通知の手順名は参照の題名に残り、索引から案内される。
	ref="$root/common/skills/squad-handoff/references/leader-dispatch.md"
	grep -qxF "# リーダーの手順: $section" "$ref"
	grep -qF 'leader-dispatch.md' "$test_dir/orchestrator"
	if [[ $family == claude ]]; then family_name=Claude; else family_name=Codex; fi
	grep -qF "$family_name 系統だけがある" "$test_dir/orchestrator"
	awk -v heading="### $family_name 系統だけのとき" '$0==heading {inside=1; next} inside && /^##/ {exit} inside {print}' \
		"$ref" >"$test_dir/dispatch-instructions"
	grep -qF 'squad-usage-read' "$test_dir/dispatch-instructions"
	grep -qF '80%' "$test_dir/dispatch-instructions"
	grep -qF 'それ以外はこの系統の対応する実装・修正の役へ回す' "$test_dir/dispatch-instructions"
	grep -qF '読めなければこの系統に固定して選んだことと理由を書く' "$test_dir/dispatch-instructions"
	# 両系統用の選択コマンドも、外した系統の役も残らない。
	if grep -qF 'squad-dispatch-pick' "$test_dir/dispatch-instructions"; then exit 1; fi
	fixers=$(awk '/^- `[^`]+-fixer`:/ {print}' "$test_dir/orchestrator")
	[[ $fixers == "- \`$family-fixer\`: [@Role](mention://agent/agent-$family-fixer)" ]]
	other=codex
	[[ $family != codex ]] || other=claude
	if grep -qF "$other-fixer" "$test_dir/orchestrator"; then exit 1; fi
	echo "PASS conflicts: $family のみでは通知から単一系統の使用率判定と有効な修正役へたどれる"
done

# conflicts-check: 今の head と mergeable を読み、値と head の 1 行を必ず出す。
# gh・sleep・date を差し替え、実際には待たない。gh は決めた順に応答を返し、最後の応答は繰り返す。
clock_dir="$test_dir/clock"
mkdir -p "$clock_dir"
cat >"$clock_dir/gh" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
dir=$PR_WATCH_TEST_DIR
[[ "$*" == 'pr view test-pr --json state,headRefOid,mergeable' ]] || exit 1
n=$(($(wc -l <"$dir/gh-calls") + 1))
echo "$n" >>"$dir/gh-calls"
total=$(wc -l <"$dir/gh-responses")
((n <= total)) || n=$total
line=$(sed -n "${n}p" "$dir/gh-responses")
if [[ $line == FAIL ]]; then
	echo 'gh mock failure' >&2
	exit 1
fi
printf '%s\n' "$line"
EOF2
cat >"$clock_dir/sleep" <<'EOF2'
#!/usr/bin/env bash
echo "$1" >>"$PR_WATCH_TEST_DIR/sleeps"
EOF2
cat >"$clock_dir/date" <<'EOF2'
#!/usr/bin/env bash
if [[ ${1:-} == +%s ]]; then
	slept=$(awk '{s += $1} END {print s + 0}' "$PR_WATCH_TEST_DIR/sleeps")
	echo $((1000000 + slept))
else
	exec /bin/date "$@"
fi
EOF2
chmod +x "$clock_dir/gh" "$clock_dir/sleep" "$clock_dir/date"

# 呼び出しごとの応答を並べて登録する。応答は STATE:HEAD:MERGEABLE か FAIL。実物から作った見本の値だけを差し替える。
cc_responses() {
	: >"$test_dir/gh-responses"
	: >"$test_dir/gh-calls"
	: >"$test_dir/sleeps"
	local r
	for r in "$@"; do
		if [[ $r == FAIL ]]; then
			echo FAIL >>"$test_dir/gh-responses"
		else
			IFS=: read -r state head mergeable <<<"$r"
			fixture gh-pr-mergeable | jq -c --arg s "$state" --arg h "$head" --arg m "$mergeable" '.state = $s | .headRefOid = $h | .mergeable = $m' >>"$test_dir/gh-responses"
		fi
	done
}

# 終了コード 0 で、標準出力がちょうど 1 行であることを確かめ、その行を出す。
cc_run() {
	local out status=0
	out=$(cd "$test_dir" && PATH="$clock_dir:$PATH" bash "$script" conflicts-check test-issue) || status=$?
	((status == 0)) || { echo "終了コード $status" >&2; exit 1; }
	[[ $(printf '%s\n' "$out" | wc -l) -eq 1 && -n $out ]] || { printf '出力が 1 行でない:\n%s\n' "$out" >&2; exit 1; }
	printf '%s' "$out"
}
cc_no_nashi() { if [[ $1 == *なし* ]]; then printf '「なし」を含む: %s\n' "$1" >&2; exit 1; fi; }

head_x=0123456789abcdef0123456789abcdef01234567
head_y=fedcba9876543210fedcba9876543210fedcba98

# 受け入れ条件 1: CONFLICTING
reset_fixture
cc_responses "OPEN:$head_x:CONFLICTING"
line=$(cc_run)
[[ $line == "コンフリクト: CONFLICTING head: $head_x" ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
[[ ! -s $test_dir/sleeps ]]
echo 'PASS conflicts-check: CONFLICTING は head と値を 1 行で出す'

# 受け入れ条件 2: MERGEABLE
reset_fixture
cc_responses "OPEN:$head_x:MERGEABLE"
line=$(cc_run)
[[ $line == "コンフリクト: MERGEABLE head: $head_x" ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
echo 'PASS conflicts-check: MERGEABLE は head と値を 1 行で出す'

# 受け入れ条件 3: UNKNOWN のあと読み直して CONFLICTING
reset_fixture
cc_responses "OPEN:$head_x:UNKNOWN" "OPEN:$head_x:CONFLICTING"
line=$(cc_run)
[[ $line == "コンフリクト: CONFLICTING head: $head_x" ]] || { echo "$line" >&2; exit 1; }
[[ $(<"$test_dir/sleeps") == 10 ]]
echo 'PASS conflicts-check: UNKNOWN のあと 10 秒待って読み直し、CONFLICTING を出す'

# 読み直しの間に head が変わったときは、最後に読んだ head を書く
reset_fixture
cc_responses "OPEN:$head_x:UNKNOWN" "OPEN:$head_y:MERGEABLE"
line=$(cc_run)
[[ $line == "コンフリクト: MERGEABLE head: $head_y" ]] || { echo "$line" >&2; exit 1; }
echo 'PASS conflicts-check: 読み直しで head が変わったら最後に読んだ head を出す'

# 受け入れ条件 4: UNKNOWN が続く。待ちの合計は 60 秒以内で、読み取りは 7 回以内
reset_fixture
cc_responses "OPEN:$head_x:UNKNOWN"
line=$(cc_run)
[[ $line == "コンフリクト: 未確認 head: $head_x 理由: mergeable が 60 秒たっても UNKNOWN" ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
total=$(awk '{s += $1} END {print s + 0}' "$test_dir/sleeps")
((total <= 60 && total > 0))
(($(wc -l <"$test_dir/gh-calls") <= 7))
echo 'PASS conflicts-check: UNKNOWN が続くと 未確認 と head を出し、待ちの合計は 60 秒以内'

# 受け入れ条件 5: gh の失敗、pr_url なし、タスクを読めない
reset_fixture
cc_responses FAIL
line=$(cc_run 2>/dev/null)
[[ $line == 'コンフリクト: 未確認 head: 不明 理由: PR を読めない（gh の失敗か必須欄の欠落）' ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
# 読み直しの途中で読めなくなったときは、最後に読めた head を書く
cc_responses "OPEN:$head_x:UNKNOWN" FAIL
line=$(cc_run 2>/dev/null)
[[ $line == "コンフリクト: 未確認 head: $head_x 理由: PR を読めない（gh の失敗か必須欄の欠落）" ]] || { echo "$line" >&2; exit 1; }
# head が空の応答
: >"$test_dir/gh-calls"
printf '%s\n' '{"state":"OPEN","headRefOid":"","mergeable":"MERGEABLE"}' >"$test_dir/gh-responses"
line=$(cc_run)
[[ $line == 'コンフリクト: 未確認 head: 不明 理由: PR を読めない（gh の失敗か必須欄の欠落）' ]] || { echo "$line" >&2; exit 1; }
# 必須欄が欠けた応答（実物から作った見本から 1 欄だけ消す）は、MERGEABLE とは報告せず「未確認」の 1 行にする
for missing in state headRefOid mergeable; do
	cc_responses "OPEN:$head_x:MERGEABLE"
	fixture gh-pr-mergeable | jq -c --arg k "$missing" 'del(.[$k])' >"$test_dir/gh-responses"
	: >"$test_dir/gh-calls"
	line=$(cc_run 2>/dev/null)
	[[ $line == 'コンフリクト: 未確認 head: 不明 理由: PR を読めない'* ]] || { echo "$missing 欠落: $line" >&2; exit 1; }
	[[ $line != *MERGEABLE* && $line != *CONFLICTING* ]] || { echo "$missing 欠落: $line" >&2; exit 1; }
	cc_no_nashi "$line"
	echo "PASS conflicts-check: $missing が欠けた応答は 未確認 の 1 行"
done
# null の必須欄も、値として補わない
fixture gh-pr-mergeable | jq -c '.mergeable = null' >"$test_dir/gh-responses"
: >"$test_dir/gh-calls"
line=$(cc_run 2>/dev/null)
[[ $line == 'コンフリクト: 未確認 head: 不明 理由: PR を読めない'* ]] || { echo "mergeable null: $line" >&2; exit 1; }
reset_fixture
jq '.metadata = {}' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
cc_responses "OPEN:$head_x:MERGEABLE"
line=$(cc_run)
[[ $line == 'コンフリクト: 未確認 head: 不明 理由: metadata に pr_url がない' ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
[[ ! -s $test_dir/gh-calls ]]
reset_fixture
printf '%s' 'issue get test-issue' >"$test_dir/fail"
line=$(cc_run 2>/dev/null)
[[ $line == 'コンフリクト: 未確認 head: 不明 理由: タスクを読めない' ]] || { echo "$line" >&2; exit 1; }
cc_no_nashi "$line"
rm -f "$test_dir/fail"
echo 'PASS conflicts-check: gh の失敗・pr_url なし・タスクを読めないときは 未確認 を出す'

# PR がマージ済みか閉じている
for state in MERGED CLOSED; do
	reset_fixture
	cc_responses "$state:$head_x:UNKNOWN"
	line=$(cc_run)
	[[ $line == "コンフリクト: 未確認 head: $head_x 理由: PR がマージ済みか閉じている" ]] || { echo "$line" >&2; exit 1; }
done
echo 'PASS conflicts-check: マージ済みか閉じている PR は 未確認 を出す'

# UNKNOWN 以外の想定外の値は、読み直さずに 未確認
reset_fixture
cc_responses "OPEN:$head_x:SURPRISE"
line=$(cc_run)
[[ $line == "コンフリクト: 未確認 head: $head_x 理由: mergeable が想定外の値 SURPRISE" ]] || { echo "$line" >&2; exit 1; }
[[ ! -s $test_dir/sleeps ]]
echo 'PASS conflicts-check: 想定外の mergeable は読み直さず 未確認 を出す'

# gh・jq・multica が見つからないときも、未確認の 1 行を 0 で出す
for missing in gh jq multica; do
	reset_fixture
	cc_responses "OPEN:$head_x:MERGEABLE"
	bare="$test_dir/bare-$missing"
	mkdir -p "$bare"
	ln -sf "$(command -v dirname)" "$bare/dirname"
	for cmd in jq multica gh; do
		[[ $cmd == "$missing" ]] && continue
		case $cmd in
		gh) ln -sf "$clock_dir/gh" "$bare/gh" ;;
		# 共通のスタブは python3 などを PATH から呼ぶので、ここではタスクを返すだけの 1 本に替える。
		multica) printf '#!%s\nprintf "%%s\\n" "$(<"$PR_WATCH_TEST_DIR/task.json")"\n' "$BASH" >"$bare/multica" && chmod +x "$bare/multica" ;;
		*) ln -sf "$(command -v "$cmd")" "$bare/$cmd" ;;
		esac
	done
	# BASH_ENV などが PATH を足さないよう、環境を空にして実物の見張りを呼ぶ。
	line=$(cd "$test_dir" && env -i PATH="$bare" PR_WATCH_TEST_DIR="$test_dir" "$BASH" "$script" conflicts-check test-issue)
	[[ $line == "コンフリクト: 未確認 head: 不明 理由: $missing が見つからない" ]] || { echo "$line" >&2; exit 1; }
	cc_no_nashi "$line"
done
echo 'PASS conflicts-check: コマンドが見つからないときも 未確認 の 1 行を出す'

# 確認は読むだけ。wakeup の規則・metadata・コメントを書かない
reset_fixture
cc_responses "OPEN:$head_x:CONFLICTING"
cc_run >/dev/null
assert_jq -s 'length == 1 and (.[0][0:2] == ["issue", "get"])' "$test_dir/calls.jsonl"
[[ ! -s $test_dir/wakeups.jsonl && ! -s $test_dir/posted.jsonl ]]
echo 'PASS conflicts-check: multica はタスクの読み取りだけを呼び、規則・metadata・コメントを書かない'

# 引数の数が違うと、使い方を標準エラーに出し、終了コード 2 で標準出力は空
for args in "" "a b"; do
	status=0
	# shellcheck disable=SC2086
	out=$(cd "$test_dir" && bash "$script" conflicts-check $args 2>"$test_dir/usage-err") || status=$?
	[[ $status -eq 2 && -z $out ]]
	grep -qF 'conflicts-check' "$test_dir/usage-err"
done
echo 'PASS conflicts-check: 引数の数が違うと終了コード 2 で、標準出力は空'

# 通知先は、担当のスクワッドではなく、渡された役をリーダーとする有効な候補で選ぶ。
reset_fixture
jq '.[0] as $base | . + [$base + {id:"archived",archived_at:"2026-01-01T00:00:00Z"},
 $base + {id:"other",leader_id:"other-leader"}]' "$test_dir/squads.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/squads.json"
jq '.assignee_type = null | .assignee_id = null' "$test_dir/task.json" >"$test_dir/updated.json"
mv "$test_dir/updated.json" "$test_dir/task.json"
check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた'
assert_jq -s 'length == 1 and (.[0].body | contains("[@Demo](mention://squad/test-squad)"))
 and (.[0].body | contains("mention://agent/") | not)' "$test_dir/posted.jsonl"
echo 'PASS 通知先: 有効なスクワッドをリーダーの ID で選び、担当なしでも同じ通知先にする'

for count in 0 2; do
 reset_fixture
 jq --argjson count "$count" '.[0] as $base | if $count == 0 then [] else . + [$base + {id:"second"}] end' \
  "$test_dir/squads.json" >"$test_dir/updated.json"
 mv "$test_dir/updated.json" "$test_dir/squads.json"
 check_ci $'/note\nCI abcdef0: 失敗をリーダーに知らせた' 2>"$test_dir/error"
 assert_jq -s 'length == 1 and (.[0].body | contains("[@demo-orchestrator-test](mention://agent/orchestrator)"))
  and (.[0].body | contains("mention://squad/") | not)' "$test_dir/posted.jsonl"
 [[ $(<"$test_dir/error") == *"${count} 件"* ]]
done
echo 'PASS 通知先: 0 件・複数なら従来のエージェントのメンションへ戻す'

# 人の source_task_id と直接開始の trigger_comment_id は、実物どおりなくてもよい。
reset_fixture
fixture issue-comments member | jq '[del(.source_task_id)]' >"$test_dir/comments.json"
fixture issue-runs direct | jq '[del(.trigger_comment_id) + {agent_id:"fixer",status:"running"}]' >"$test_dir/runs.json"
check_ci $'/note\nCI abcdef0: 失敗あり（demo-codex-fixer-test の作業中なので保留）'
check_held $'CI / test\nexternal'
assert_jq -s 'all(.[] | select(.[0:3] == ["issue","comment","list"]);
 index("--full") != null and index("--compact") == null)' "$test_dir/calls.jsonl"
echo 'PASS 条件付き: 正常な省略を受け入れ、ci-check と ci-held は compact を使わない'

for defect in task-status task-category comment-source run-kind run-trigger wakeup-instruction wakeup-event agent-name check-name check-workflow check-conclusion context-name squad-name; do
 reset_fixture
 touch "$test_dir/allow-missing-fields"
 action=ci-check
 args=(test-issue orchestrator monitor)
 case $defect in
 task-status) source=task; reading=issue-get; field=status; filter='del(.status)' ;;
 task-category) source=task; reading=issue-get; field=status_category; filter='del(.status_category)' ;;
 comment-source)
  fixture issue-comments agent | jq '[.]' >"$test_dir/comments.json"
  source=comments; reading=issue-comments; field=source_task_id; filter='map(del(.source_task_id))' ;;
 run-kind|run-trigger)
  fixture issue-runs comment | jq '[. + {agent_id:"fixer",status:"running"}]' >"$test_dir/runs.json"
  source=runs; reading=issue-runs; field=kind
  [[ $defect != run-trigger ]] || field=trigger_comment_id
  filter="map(del(.$field))" ;;
 wakeup-instruction|wakeup-event)
  fixture issue-wakeups | jq '[. + {condition:{type:"pull_request",event:"conflicts"}}]' >"$test_dir/rules.json"
  source=rules; reading=issue-wakeups; field=instruction
  [[ $defect != wakeup-event ]] || field=condition.event
  filter="map(del(.$field))"; action=conflicts; args=(test-issue) ;;
 agent-name) source=agents; reading=agent-get; field=name; filter='map(del(.name))' ;;
 check-name|check-workflow|check-conclusion)
  source=pr; reading=gh-pr-checks; field=name
  [[ $defect != check-workflow ]] || field=workflowName
  [[ $defect != check-conclusion ]] || field=conclusion
  filter="del(.statusCheckRollup[0].$field)" ;;
 context-name) source=pr; reading=gh-pr-checks; field=context; filter='del(.statusCheckRollup[1].context)' ;;
 squad-name) source=squads; reading=squad-list; field=name; filter='map(del(.name))' ;;
 esac
 jq "$filter" "$test_dir/$source.json" >"$test_dir/updated.json"
 mv "$test_dir/updated.json" "$test_dir/$source.json"
 status=0
 (cd "$test_dir" && bash "$script" "$action" "${args[@]}") >"$test_dir/output" 2>"$test_dir/error" || status=$?
 [[ $status == 1 && ! -s $test_dir/output && ! -s $test_dir/posted.jsonl && ! -s $test_dir/wakeups.jsonl ]]
 expected_field=$field
	[[ $reading != gh-pr-checks ]] || expected_field="statusCheckRollup[].$field"
	[[ $(<"$test_dir/error") == *"CLI の出力に欄がありません: $reading の $expected_field"* ]]
 [[ $(<"$test_dir/error") == *'fixture-version'* ]]
 echo "PASS contract: $reading の $field がなければ欄名で失敗し、後続の書き込みをしない"
done

# 書き込みの応答の検証で失敗しても、登録し直さない。
reset_fixture
touch "$test_dir/allow-missing-fields"
fixture issue-wakeup-create | jq 'del(.id)' >"$test_dir/wakeup-response.json"
if (cd "$test_dir" && bash "$script" conflicts test-issue) >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ ! -s $test_dir/output && $(<"$test_dir/error") == *'issue-wakeup-create の id'* ]]
assert_jq -s 'length == 1' "$test_dir/wakeups.jsonl"
echo 'PASS contract: wakeup の応答に id がなければ失敗し、登録を重ねない'

for failure in squad gh; do
 reset_fixture
 if [[ $failure == squad ]]; then printf 'squad list --output' >"$test_dir/fail"; else touch "$test_dir/fail-gh"; fi
 if (cd "$test_dir" && bash "$script" ci-check test-issue orchestrator monitor) >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
 [[ ! -s $test_dir/output && ! -s $test_dir/posted.jsonl ]]
 [[ $(<"$test_dir/error") == *'mock failure'* ]]
done
echo 'PASS CLI 失敗: スクワッドと GitHub の読み取り失敗で、通知先の代替や成功の応答を返さない'

reset_fixture
fixture issue-wakeups | jq '[. + {condition:{type:"pull_request",event:"conflicts",invented_field:true}}]' >"$test_dir/invented.json"
if python3 "$root/tests/pr-watch-fixture.py" emit issue-wakeups "$test_dir/invented.json" >"$test_dir/output" 2>"$test_dir/error"; then exit 1; fi
[[ $(<"$test_dir/error") == *'見本とケースの鍵が違います'* ]]
echo 'PASS fixture: 実物にない入れ子の欄を追加したケースを拒否する'
