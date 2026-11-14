#!/usr/bin/env bash
# ZIP のルートから bash tests/squad-usage-wait-test.sh で実行する。
# squad-dispatch-pick と squad-usage-read を差し替え、multica は見本で照合する偽の CLI にする。
# 実際のタスク・規則・エージェントには書き込まない。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p tmp
test_dir=$(mktemp -d "$PWD/tmp/usage-wait-test.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT
export USAGE_WAIT_TEST_DIR=$test_dir USAGE_WAIT_TEST_ROOT=$root REVIEW_WAIT_TEST_DIR=$test_dir
# 呼び出したリーダーは、各ケースが決める。実行している環境の値を使わない。
unset MULTICA_AGENT_ID
source "$root/common/monitor/squad-cli-lib"
squad_cli_contracts >"$test_dir/contracts.json"
fixture() { python3 "$root/tests/review-wait-fixture.py" base "$@"; }

mkdir -p "$test_dir/monitor" "$test_dir/bin"
cp "$root/common/monitor/squad-usage-wait" "$root/common/monitor/squad-cli-lib" "$test_dir/monitor/"
export PATH="$test_dir/bin:$PATH"

# 振り分けの代わり。受けた引数を記録し、決めた出力と終了コードを返す。
cat >"$test_dir/monitor/squad-dispatch-pick" <<'EOF'
#!/usr/bin/env bash
dir=$USAGE_WAIT_TEST_DIR
printf '%s\n' "$*" >>"$dir/dispatch-calls"
cat "$dir/dispatch-out" 2>/dev/null || true
exit "$(<"$dir/dispatch-status")"
EOF
# 使用率の読み取りの代わり。
cat >"$test_dir/monitor/squad-usage-read" <<'EOF'
#!/usr/bin/env bash
dir=$USAGE_WAIT_TEST_DIR
echo x >>"$dir/usage-reads"
cat "$dir/usage.json"
exit "$(<"$dir/usage-status")"
EOF
chmod +x "$test_dir/monitor/squad-dispatch-pick" "$test_dir/monitor/squad-usage-read"

now=1793059200
cat >"$test_dir/bin/date" <<'EOF'
#!/usr/bin/env bash
[[ $# == 1 && $1 == +%s ]] || exit 1
printf '%s\n' "$USAGE_WAIT_TEST_NOW"
EOF
chmod +x "$test_dir/bin/date"
export USAGE_WAIT_TEST_NOW=$now

cat >"$test_dir/bin/multica" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$USAGE_WAIT_TEST_DIR
stub_args=("$@")
stub() { python3 "$USAGE_WAIT_TEST_ROOT/tests/cli-stub.py" review-wait "$dir" multica calls.jsonl "$@" -- ${stub_args[@]+"${stub_args[@]}"}; }
case "${1-} ${2-} ${3-}" in
'version  ') echo 'multica fixture-version' ;;
'issue get test-issue') stub emit issue-get "$dir/issue.json" ;;
'squad list --output') stub emit squad-list "$dir/squads.json" ;;
'squad member list') stub emit squad-member-list "$dir/members.json" ;;
"agent get $3")
	jq --arg id "$3" '.[] | select(.id == $id)' "$dir/agents.json" >"$dir/agent-response.json"
	stub emit agent-get "$dir/agent-response.json" ;;
'issue comment list') stub emit issue-comments "$dir/comments.json" ;;
'issue wakeup list') stub emit issue-wakeups "$dir/rules.json" ;;
'issue wakeup create')
	args=$(jq -cn --args '$ARGS.positional' -- "$@")
	file=$(jq -er 'index("--instruction-file") as $i | .[$i+1]' <<<"$args")
	jq -Rs --argjson args "$args" '{args: $args, instruction: .}' <"$file" >>"$dir/wakeups.jsonl"
	jq --rawfile instruction "$file" '. + [(.[0] + {id: "created", enabled: true, instruction: $instruction})]' "$dir/rules.json" >"$dir/rules.tmp"
	mv "$dir/rules.tmp" "$dir/rules.json"
	stub posted issue-wakeup-create wakeup-created ;;
*) echo "Unexpected mock call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$test_dir/bin/multica"

iso() { jq -nr --argjson epoch "$1" '$epoch | todateiso8601'; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
assert_jq() { jq -e "$@" >/dev/null; }
mark='使用率の待ちの起こしで起きました。'

# --- 名簿。エージェントの名前は <プロジェクトのキー>-<役>-<メンバーのキー> で、スクワッドの名前は DEMO-TEST。
fixture issue-get | jq '. + {assignee_type: "squad", assignee_id: "squad-test"}' >"$test_dir/issue.json"
fixture issue-get | jq '. + {assignee_type: "member", assignee_id: "member-test"}' >"$test_dir/issue-member.json"
fixture squad-list | jq '[. + {id: "squad-test", name: "DEMO-TEST", leader_id: "orchestrator", archived_at: null}]' >"$test_dir/squads.json"
fixture agent-get | jq '. as $base | [
	["claude-implementer", "claude-sonnet-5-5"], ["codex-implementer", "gpt-6.1-sol"],
	["claude-fixer", "claude-sonnet-5-5"], ["codex-fixer", "gpt-6.1-sol"],
	["claude-principal", "claude-fable-5-2"], ["codex-principal", "gpt-6.1-sol"],
	["planner", "claude-opus-5-5"], ["designer", "gpt-6.1-sol"]
	| . as [$role, $model] | $base + {id: $role, name: ("demo-" + $role + "-test"), model: $model, archived_at: null}
] + [
	$base + {id: "archived-codex-implementer", name: "demo-codex-implementer-test", model: "gpt-6.1-sol", archived_at: "2026-01-01T00:00:00Z"},
	$base + {id: "other-codex-fixer", name: "other-codex-fixer-test", model: "gpt-6.1-sol", archived_at: null},
	$base + {id: "orchestrator", name: "demo-orchestrator-test", model: "claude-fable-5-2", archived_at: null}
]' >"$test_dir/agents.json"
set_roster() {
	fixture squad-member-list | jq --args '. as $base | [$ARGS.positional[] | $base + {member_id: ., member_type: "agent"}]' -- "$@" >"$test_dir/members.json"
}
dual=(claude-implementer codex-implementer claude-fixer codex-fixer claude-principal codex-principal planner designer orchestrator)

# --- 起こしの規則とコメント。
fixture issue-wakeups | jq '. as $base | [$base + {id: "ci", enabled: true, instruction: "PR の CI が終わりました。"}]' >"$test_dir/rules.base.json"
fixture issue-comments agent >"$test_dir/comment-agent.json"
fixture issue-comments member >"$test_dir/comment-member.json"
echo '[]' >"$test_dir/comments.json"
add_comment() { # 種類（agent|member） 作者 ID 時刻 本文
	local proto=$test_dir/comment-$1.json
	jq --slurpfile p "$proto" --arg who "$2" --arg id "$3" --arg time "$(iso "$4")" --arg content "$5" \
		'. + [$p[0] + {id: $id, author_id: $who, created_at: $time, content: $content}]' "$test_dir/comments.json" >"$test_dir/comments.tmp"
	mv "$test_dir/comments.tmp" "$test_dir/comments.json"
}
add_rule() { # ID 有効か 指示
	jq --arg id "$1" --argjson enabled "$2" --arg instruction "$3" \
		'. + [(.[0] + {id: $id, enabled: $enabled, instruction: $instruction})]' "$test_dir/rules.json" >"$test_dir/rules.tmp"
	mv "$test_dir/rules.tmp" "$test_dir/rules.json"
}

# 使用率。引数は、Claude の週（%、リセット時刻）、5 時間（%、リセット時刻）、Codex の週（%、リセット時刻）、利用可否。
usage() {
	jq -n --arg read "$(iso "$now")" --argjson cw "$1" --arg cwr "$(iso "$2")" --argjson cs "$3" --arg csr "$(iso "$4")" \
		--argjson xw "$5" --arg xwr "$(iso "$6")" --argjson xa "$7" \
		'{read_at: $read, claude: {week: {used_percent: $cw, resets_at: $cwr}, session: {used_percent: $cs, resets_at: $csr}},
			codex: {week: {used_percent: $xw, resets_at: $xwr}, allowed: $xa}}' >"$test_dir/usage.json"
	echo 0 >"$test_dir/usage-status"
}

status=0
reset() {
	: >"$test_dir/calls.jsonl"
	: >"$test_dir/wakeups.jsonl"
	: >"$test_dir/dispatch-calls"
	: >"$test_dir/usage-reads"
	cp "$test_dir/rules.base.json" "$test_dir/rules.json"
	echo '[]' >"$test_dir/comments.json"
	cp "$test_dir/issue.json" "$test_dir/issue.current.json"
	set_roster "${dual[@]}"
	usage 10 $((now + 100000)) 10 $((now + 10000)) 10 $((now + 100000)) true
	echo 0 >"$test_dir/dispatch-status"
	rm -f "$test_dir/dispatch-out"
}
run() {
	status=0
	: >"$test_dir/dispatch-calls"
	: >"$test_dir/usage-reads"
	(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue "$@") >"$test_dir/out" 2>"$test_dir/err" || status=$?
}
expect_status() {
	[[ $status == "$1" ]] || { printf '終了コード %s を期待したが %s\n出力:\n%s\n標準エラー:\n%s\n' "$1" "$status" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
expect_out() {
	[[ $(<"$test_dir/out") == "$1" ]] || { printf '期待した出力:\n%s\n実際の出力:\n%s\n標準エラー:\n%s\n' "$1" "$(<"$test_dir/out")" "$(<"$test_dir/err")" >&2; exit 1; }
}
wakeup_count() { jq -s length "$test_dir/wakeups.jsonl"; }
dispatch_calls() { paste -sd'|' "$test_dir/dispatch-calls"; }

reset

# ---- 両系統の構成: squad-dispatch-pick へ回す。
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
run implement 小さな
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%。工程: implement'
[[ $(dispatch_calls) == 'implement 小さな' && ! -s $test_dir/usage-reads && $(wakeup_count) == 0 ]]
run implement 大きな
expect_status 0
[[ $(dispatch_calls) == 'implement 大きな' ]]
run fix
expect_status 0
[[ $(dispatch_calls) == 'fix' ]]
grep -qxF '振り分け: Claude（理由）。Claude 週 20%。工程: fix' "$test_dir/out"
run principal Codex
expect_status 0
[[ $(dispatch_calls) == 'principal Codex' ]]
run principal Claude
[[ $(dispatch_calls) == 'principal Claude' ]]
run principal
[[ $(dispatch_calls) == 'principal' ]]
echo 'PASS usage-wait: 両系統の構成では squad-dispatch-pick の選んだ役と振り分けを、工程の印を足して返す。principal の系統の引数もそのまま渡す'

# 回を渡さない直接の呼び出しは、タスクの担当がメンバーでも、呼び出したリーダー（MULTICA_AGENT_ID）のスクワッドの名簿で選ぶ。
# リーダーを決められないときだけ、タスクの担当のスクワッドへ戻る。担当もスクワッドでなければ失敗する。
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
cp "$test_dir/issue.json" "$test_dir/issue.saved.json"
cp "$test_dir/issue-member.json" "$test_dir/issue.json"
status=0
(cd "$test_dir" && MULTICA_AGENT_ID=orchestrator bash monitor/squad-usage-wait pick test-issue implement 小さな) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%。工程: implement'
[[ $(dispatch_calls) == 'implement 小さな' ]]
status=0
(cd "$test_dir" && MULTICA_AGENT_ID=someone-else bash monitor/squad-usage-wait pick test-issue implement 小さな) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
status=0
(cd "$test_dir" && env -u MULTICA_AGENT_ID bash monitor/squad-usage-wait pick test-issue implement 小さな) >"$test_dir/out" 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
# 担当がスクワッドなら、呼び出したリーダーがいなくても、これまでどおり担当のスクワッドで選ぶ。
cp "$test_dir/issue.saved.json" "$test_dir/issue.json"
reset
printf '役: claude-implementer\n振り分け: Claude（理由）。Claude 週 20%%\n' >"$test_dir/dispatch-out"
run implement 小さな
expect_status 0
echo 'PASS usage-wait: 担当がメンバーのタスクでも、呼び出したリーダーのスクワッドの名簿で選び、リーダーを決められなければ担当のスクワッドへ戻る'

# ---- 両系統の構成で、dispatch-pick が両方上限に近いと返したときだけ待つ。
echo 2 >"$test_dir/dispatch-status"
: >"$test_dir/dispatch-out"
# Claude は週 85%（リセット 5 時間後）と 5 時間 90%（1 時間後）、Codex は週 82%（3 時間後）。
usage 85 $((now + 18000)) 90 $((now + 3600)) 82 $((now + 10800)) true
run implement 小さな
expect_status 3
resume=$((now + 10800))
expect_out "使用率の待ち: implement を $(iso "$resume") まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%、Codex 週 82%"
[[ $(wakeup_count) == 1 ]]
assert_jq --arg at "$(iso "$resume")" --arg mark "$mark" '
	.args[0:4] == ["issue", "wakeup", "create", "test-issue"] and
	(.args | index("--kind") as $k | .[$k + 1]) == "at" and
	(.args | index("--at") as $k | .[$k + 1]) == $at and
	(.args | index("--agent-id") as $k | .[$k + 1]) == "orchestrator" and
	(.instruction | startswith($mark + "\n")) and (.instruction | split("\n") | any(. == "工程: implement"))
	and (.instruction | contains("回:") | not)' "$test_dir/wakeups.jsonl"
echo 'PASS usage-wait: 両系統が上限に近いときだけ待ち、系統ごとの再開の時刻の早い方を使う。起こしはリーダーへ、工程つきの指示で置く'

# 週の 80% 以上の枠が複数あれば、遅い方のリセット時刻を使う（Claude だけ近い片系統の構成）。
reset
set_roster claude-implementer
usage 85 $((now + 3600)) 90 $((now + 7200)) 10 $((now + 100000)) true
run implement 小さな
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%"
[[ -z $(dispatch_calls) ]]
reset
set_roster claude-implementer
usage 85 $((now + 9000)) 90 $((now + 7200)) 10 $((now + 100000)) true
run implement 小さな
expect_out "使用率の待ち: implement を $(iso $((now + 9000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 85%・5 時間 90%"
echo 'PASS usage-wait: 複数の枠が上限に近ければ、遅い方のリセット時刻まで待つ'

# Codex が利用不可で週が 80% 未満のときは、60 分後と週のリセット時刻の早い方にする。
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 50 $((now + 36000)) false
run implement 小さな
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 3600))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex は利用不可（週 50%）"
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 50 $((now + 1200)) false
run implement 小さな
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 1200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex は利用不可（週 50%）"
# Codex の週が 80% 以上なら、利用不可でも週のリセット時刻まで待つ。
reset
set_roster codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 90 $((now + 36000)) false
run implement 小さな
expect_status 3
expect_out "使用率の待ち: implement を $(iso $((now + 36000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%・利用不可"
echo 'PASS usage-wait: Codex が利用不可で週が 80% 未満なら 60 分後と週のリセットの早い方、週が 80% 以上なら週のリセットまで待つ'

# 両系統が上限に近いと返されたあと、使用率を読み直せなければ 60 分後に読み直す。
reset
echo 2 >"$test_dir/dispatch-status"
echo 1 >"$test_dir/usage-status"
: >"$test_dir/usage.json"
run fix
expect_status 3
expect_out "使用率の待ち: fix を $(iso $((now + 3600))) まで待つ。待ち始め: $(iso "$now")。両系統が上限に近いと読んだが、読み直した使用率が揃わなかったため、60 分後に読み直す"
echo 'PASS usage-wait: 読み直しに失敗したときは、60 分後に読み直す'

# dispatch-pick の失敗は、待たずに終了 1 にする。
reset
echo 1 >"$test_dir/dispatch-status"
run implement 小さな
expect_status 1
[[ $(wakeup_count) == 0 ]]
grep -qF 'squad-dispatch-pick が失敗した（終了 1）' "$test_dir/err"
echo 'PASS usage-wait: squad-dispatch-pick が失敗したら、待たずに終了 1'

# ---- 片系統の構成。
reset
set_roster claude-implementer
run implement 小さな
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: implement'
[[ -z $(dispatch_calls) && $(wakeup_count) == 0 ]]
reset
set_roster codex-fixer
run fix
expect_status 0
expect_out $'役: codex-fixer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: fix'
# もう一方の系統が上限に近くても、見ない。
usage 90 $((now + 3600)) 90 $((now + 3600)) 10 $((now + 100000)) true
run fix
expect_status 0
reset
set_roster claude-principal
usage 10 $((now + 100000)) 10 $((now + 10000)) 95 $((now + 3600)) false
run principal Codex
expect_status 0
expect_out $'役: claude-principal\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: principal'
[[ -z $(dispatch_calls) ]]
echo 'PASS usage-wait: 片系統の構成では、その系統の使用率だけを見て、上限に近くなければその役を選ぶ'

# 片系統で上限に近ければ待つ。
reset
set_roster codex-principal
usage 10 $((now + 100000)) 10 $((now + 10000)) 90 $((now + 7200)) true
run principal
expect_status 3
expect_out "使用率の待ち: principal を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%"
[[ $(wakeup_count) == 1 && -z $(dispatch_calls) ]]
echo 'PASS usage-wait: 片系統の構成で上限に近ければ待つ'

# ---- planner と designer。系統は役のモデルで決める。
reset
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 7200))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
run designer
expect_status 0
expect_out $'役: designer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: designer'
reset
usage 10 $((now + 100000)) 10 $((now + 100000)) 90 $((now + 5400)) true
run planner
expect_status 0
expect_out $'役: planner\n振り分け: Claude（片系統の構成）。Claude 週 10%・5 時間 10%。工程: planner'
run designer
expect_status 3
expect_out "使用率の待ち: designer を $(iso $((now + 5400))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Codex 週 90%"
[[ -z $(dispatch_calls) ]]
echo 'PASS usage-wait: planner と designer は、名簿の役のモデルの系統が上限に近いときだけ待つ。dispatch-pick は使わない'

# ---- 使用率を読めないときは、待たずにその系統に固定する。
reset
set_roster claude-implementer
echo 1 >"$test_dir/usage-status"
echo 'not json' >"$test_dir/usage.json"
run implement 小さな
expect_status 0
expect_out $'役: claude-implementer\n振り分け: Claude（使用率を読めないため、片系統の構成のその系統に固定した。使用率の出力を JSON として読めなかった）。工程: implement'
[[ $(wakeup_count) == 0 ]]
reset
set_roster codex-implementer
jq -n --arg read "$(iso "$now")" '{read_at: $read, claude: {error: "no claude"}, codex: {error: "no codex"}}' >"$test_dir/usage.json"
run implement 小さな
expect_status 0
grep -qF '振り分け: Codex（使用率を読めないため、片系統の構成のその系統に固定した。Codex: no codex）。工程: implement' "$test_dir/out"
# 読めたのがもう一方の系統だけでも、固定する。
set_roster claude-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 10 $((now + 100000)) true
jq --arg read "$(iso "$now")" '.claude = {error: "no claude"}' "$test_dir/usage.json" >"$test_dir/usage.tmp"
mv "$test_dir/usage.tmp" "$test_dir/usage.json"
run implement 小さな
expect_status 0
grep -qF 'Claude: no claude' "$test_dir/out"
# 30 分より古い使用率も、読めないものとして扱う。
reset
set_roster claude-implementer
usage 95 $((now + 7200)) 95 $((now + 7200)) 10 $((now + 100000)) true
jq --arg read "$(iso $((now - 2000)))" '.read_at = $read' "$test_dir/usage.json" >"$test_dir/usage.tmp"
mv "$test_dir/usage.tmp" "$test_dir/usage.json"
run implement 小さな
expect_status 0
grep -qF '使用率が 30 分より古い' "$test_dir/out"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 使用率を読めないとき、片系統の構成はその系統に固定して理由を書き、待たない'

# ---- 起こしの重複の防止。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_rule other-process true "$mark"$'\n工程: fix\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule disabled false "$mark"$'\n工程: implement\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule same-process true "$mark"$'\n工程: implement\n再開の時刻: 2026-01-02T03:04:05Z'
run implement 小さな
expect_status 3
expect_out "使用率の待ち: implement を 2026-01-02T03:04:05Z まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
[[ $(wakeup_count) == 0 ]]
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_rule other-process true "$mark"$'\n工程: fix\n再開の時刻: 2026-01-01T00:00:00Z'
add_rule disabled false "$mark"$'\n工程: implement\n再開の時刻: 2026-01-01T00:00:00Z'
run implement 小さな
expect_status 3
[[ $(wakeup_count) == 1 ]]
run implement 小さな
[[ $(wakeup_count) == 1 ]]
echo 'PASS usage-wait: 同じ工程の有効な起こしがあれば置き直さず、その時刻を使う。ほかの工程や無効な起こしは数えない'

# decide から呼ぶときは、回のコメントを指示に書く。スクワッドは、タスクの担当でなく、回を書いた役から決める。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_comment agent orchestrator round-7 $((now - 600)) '観点: qa（テスト）'
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue implement 小さな --round round-7) >"$test_dir/out" 2>"$test_dir/err" || status=$?
assert_jq '.instruction | split("\n") | any(. == "回: round-7") and any(contains("squad-review-next decide test-issue round-7"))' "$test_dir/wakeups.jsonl"
# 回を書いた役がどのスクワッドのリーダーでもなければ、担当にせず、起こしを置かずに失敗する。
reset
set_roster claude-implementer
usage 90 $((now + 7200)) 10 $((now + 100000)) 10 $((now + 100000)) true
add_comment agent someone-else round-7 $((now - 600)) '観点: qa（テスト）'
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue implement 小さな --round round-7) >"$test_dir/out" 2>"$test_dir/err" || status=$?
[[ $status == 1 ]] || fail "回のスクワッドを決められないのに失敗しない: $status"
[[ $(wakeup_count) == 0 ]] || fail "起こしを置いてはいけない"
echo 'PASS usage-wait: --round で呼ぶと、起こしの指示に回のコメントと decide の流し直しを書く'

# ---- 24 時間の数え方。planner の片系統で、リセットまでの時間を変えて確認する。
wait_setup() { # リセットまでの秒数
	reset
	set_roster planner
	usage 90 $((now + $1)) 10 $((now + 100000)) 10 $((now + 100000)) true
}
wait_line() { # 工程 再開の時刻 待ち始め
	printf '使用率の待ち: %s を %s まで待つ。待ち始め: %s。上限に近い枠: Claude 週 90%%' "$1" "$(iso "$2")" "$(iso "$3")"
}
exceeded_line() { printf '使用率の待ち: planner の待ちが通算 24 時間を超える。待ち始め: %s' "$(iso "$1")"; }

# 初めての待ちは、今から数える。24 時間ちょうどまでは待ち、超えれば待たずに終了 4 にする。
wait_setup 86400
run planner
expect_status 3
wait_setup 86401
run planner
expect_status 4
expect_out "使用率の待ち: planner の待ちが通算 24 時間を超える。待ち始め: $(iso "$now")"
[[ $(wakeup_count) == 0 ]]

# 待ち始めは、同じ工程の待ちの行が続くあいだ引き継ぐ。
start=$((now - 72000))
wait_setup 10800
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 10800))) まで待つ。待ち始め: $(iso "$start")。上限に近い枠: Claude 週 90%"
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
run planner
expect_status 4
expect_out "$(exceeded_line "$start")"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 待ち始めを同じ工程の待ちの行から引き継ぎ、通算 24 時間を超えたら起こしを置かず終了 4 にする'

# 人間の質問やほかの工程の待ち・ほかの役の結果が間にあっても、待ち始めは変わらない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment member human q1 $((now - 3000)) '進捗は？'
add_comment agent orchestrator c2 $((now - 2000)) "$(wait_line designer $((now + 3000)) $((now - 2000)))"
add_comment agent designer r1 $((now - 1000)) '設計の結果です。'
run planner
expect_status 4
expect_out "$(exceeded_line "$start")"
# 24 時間を超えたあとの質問でも、数え直さない。
add_comment agent orchestrator c3 $((now - 900)) "$(exceeded_line "$start")"
add_comment member human q2 $((now - 800)) '今どうなっていますか。待ちますか？'
run planner
expect_status 4
expect_out "$(exceeded_line "$start")"
echo 'PASS usage-wait: 質問・ほかの工程の待ち・ほかの役の結果、24 時間を超えたあとの質問では、待ち始めを数え直さない'

# 工程の再開（その工程の振り分けの行）で数え直す。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) $'役: planner\n振り分け: Claude（片系統の構成）。Claude 週 10%。工程: planner'
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
# ほかの工程の振り分けの行では数え直さない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) $'役: designer\n振り分け: Codex（片系統の構成）。Codex 週 10%。工程: designer'
run planner
expect_status 4
echo 'PASS usage-wait: その工程の振り分けの行のあとは数え直し、ほかの工程のものでは数え直さない'

# 24 時間を超えたあとの、リーダーが書いた延長の行で数え直す。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 3000)) "$(exceeded_line "$start")"
add_comment agent orchestrator c3 $((now - 2000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
[[ $(wakeup_count) == 1 ]]
# 延長のあとの待ちの行からは、その待ち始めを引き継ぐ。
add_comment agent orchestrator c4 $((now - 1000)) "$(wait_line planner $((now + 18000)) "$now")"
run planner
expect_status 3
expect_out "使用率の待ち: planner を $(iso $((now + 18000))) まで待つ。待ち始め: $(iso "$now")。上限に近い枠: Claude 週 90%"
echo 'PASS usage-wait: 24 時間を超えたあとのリーダーの延長の行で数え直し、その後の待ちの行は新しい待ち始めを引き継ぐ'

# 24 時間を超える前の延長の行、リーダーでない作者の行、ほかの工程の行は数えない。
wait_setup 18000
add_comment agent orchestrator c1 $((now - 72000)) "$(wait_line planner $((now - 70000)) "$start")"
add_comment agent orchestrator c2 $((now - 5000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
add_comment agent orchestrator c3 $((now - 3000)) "$(exceeded_line "$start")"
run planner
expect_status 4
expect_out "$(exceeded_line "$start")"
add_comment agent designer c4 $((now - 2000)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 4
add_comment agent orchestrator c5 $((now - 1000)) $'使用率の待ちの延長: designer。決めた人: 利用者'
run planner
expect_status 4
add_comment member human c6 $((now - 500)) $'使用率の待ちの延長: planner。決めた人: 利用者'
run planner
expect_status 4
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: 24 時間を超える前の延長の行、リーダー以外の行、ほかの工程の行、人間のコメントの行では数え直さない'

# ---- 名簿の読み方。
reset
set_roster claude-implementer archived-codex-implementer
usage 10 $((now + 100000)) 10 $((now + 10000)) 95 $((now + 7200)) false
run implement 小さな
expect_status 0
grep -qxF '役: claude-implementer' "$test_dir/out"
[[ -z $(dispatch_calls) ]]
reset
set_roster claude-fixer other-codex-fixer
run fix
expect_status 0
[[ -z $(dispatch_calls) ]]
grep -qxF '役: claude-fixer' "$test_dir/out"
echo 'PASS usage-wait: アーカイブ済みのエージェントとキーが合わない名前は、名簿に数えない'

reset
set_roster claude-fixer
run implement 小さな
expect_status 1
grep -qF '名簿に工程の役がない: implement' "$test_dir/err"
reset
set_roster claude-implementer
run planner
expect_status 1
grep -qF '名簿に工程の役がない: planner' "$test_dir/err"
reset
cp "$test_dir/issue-member.json" "$test_dir/issue.current.json"
cp "$test_dir/issue.json" "$test_dir/issue.saved.json"
cp "$test_dir/issue-member.json" "$test_dir/issue.json"
run implement 小さな
expect_status 1
grep -qF 'タスクの担当がスクワッドではない' "$test_dir/err"
cp "$test_dir/issue.saved.json" "$test_dir/issue.json"
echo 'PASS usage-wait: 工程の役が名簿になければ、担当がスクワッドでなければ、終了 1'

# ---- リセットを過ぎたのに使用率がまだ上限に近いとき。過去の時刻に起こしを置かず、60 分後の再確認にする。
wait_setup -100
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 3600)) "$now")"
[[ $(wakeup_count) == 1 ]]
assert_jq --arg at "$(iso $((now + 3600)))" '(.args | index("--at") as $k | .[$k + 1]) == $at' "$test_dir/wakeups.jsonl"
# 24 時間の判定は、再確認の時刻までの経過を含む。待ち始めから 24 時間までなら待ち、超えれば待たずに終了 4 にする。
start=$((now - 82800))
wait_setup -100
add_comment agent orchestrator c1 "$start" "$(wait_line planner $((now - 100)) "$start")"
run planner
expect_status 3
expect_out "$(wait_line planner $((now + 3600)) "$start")"
start=$((now - 82900))
wait_setup -100
add_comment agent orchestrator c1 "$start" "$(wait_line planner $((now - 100)) "$start")"
run planner
expect_status 4
expect_out "$(exceeded_line "$start")"
[[ $(wakeup_count) == 0 ]]
echo 'PASS usage-wait: リセットを過ぎても上限に近ければ、60 分後の再確認の時刻に起こしを置き、経過を 24 時間の判定に含める'

# ---- 使い方の誤り。
reset
for bad in '' 'review' 'implement 中くらい' 'principal 小さな' 'principal Gemini' 'fix 小さな' 'planner Claude' 'implement 小さな 余分'; do
	# shellcheck disable=SC2086
	run $bad
	expect_status 1
done
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait) >/dev/null 2>"$test_dir/err" || status=$?
expect_status 1
status=0
(cd "$test_dir" && bash monitor/squad-usage-wait pick test-issue) >/dev/null 2>"$test_dir/err" || status=$?
expect_status 1
grep -qF '使い方: squad-usage-wait pick' "$test_dir/err"
[[ ! -s $test_dir/calls.jsonl ]]
echo 'PASS usage-wait: 工程や引数が不正なら、CLI を呼ばずに終了 1'
