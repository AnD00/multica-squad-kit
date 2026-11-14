#!/usr/bin/env bash
# リーダーの指示を、場面ごとに今のバージョンと新しいバージョンで流して比べる。実際のモデルを呼ぶので、手で流す。
# tests/run.sh と CI には入れない。設計は docs/leader-principles.md の「評価」の節。
set -euo pipefail

root=$(cd "$(dirname "$0")/../.." && pwd)
export PYTHONDONTWRITEBYTECODE=1
here="$root/tests/leader-eval"
source "$root/lib/render.sh"

usage() {
	cat <<'USAGE'
使い方: bash tests/leader-eval/run.sh [オプション]
  --baseline REF   今のバージョンにする git の参照（既定: origin/main）
  --scenes IDS     流す場面の ID をコンマで区切る（既定: すべて）
  --runs N         1 場面あたりの回数（既定: 3）
  --runtime NAME   claude か codex（既定: claude。合否の判定は claude の結果で決める）
  --only WHICH     old か new だけを流す（既定: 両方）
  --jobs N         並列数（既定: 4）
  --timeout SEC    1 回の実行の時間切れ（既定: 900）
  --out DIR        結果を置くディレクトリ（既定: tmp/leader-eval.XXXXXX）
USAGE
}

baseline=origin/main
scene_ids=
runs=3
runtime=claude
only=
timeout=900
jobs=4
out=
while (($#)); do
	case $1 in
	--baseline) baseline=${2:?}; shift 2 ;;
	--scenes) scene_ids=${2:?}; shift 2 ;;
	--runs) runs=${2:?}; shift 2 ;;
	--runtime) runtime=${2:?}; shift 2 ;;
	--only) only=${2:?}; shift 2 ;;
	--jobs) jobs=${2:?}; shift 2 ;;
	--timeout) timeout=${2:?}; shift 2 ;;
	--out) out=${2:?}; shift 2 ;;
	-h | --help) usage; exit 0 ;;
	*) usage >&2; exit 2 ;;
	esac
done
case $runtime in claude | codex) ;; *) echo "--runtime は claude か codex です" >&2; exit 2 ;; esac
case $only in '' | old | new) ;; *) echo "--only は old か new です" >&2; exit 2 ;; esac
[[ $runs =~ ^[1-9][0-9]*$ && $timeout =~ ^[1-9][0-9]*$ && $jobs =~ ^[1-9][0-9]*$ ]] || { echo "--runs、--jobs、--timeout は正の整数です" >&2; exit 2; }
if [[ -z $out ]]; then
	mkdir -p "$root/tmp"
	out=$(mktemp -d "$root/tmp/leader-eval.XXXXXX")
fi
mkdir -p "$out"
out=$(cd "$out" && pwd)
helper=("python3" "-I" "-B" "$here/leader_eval.py")

# 場面の一覧。ID の指定がなければ、scenes の下をすべて流す。
scene_list=()
if [[ -n $scene_ids ]]; then
	IFS=, read -r -a scene_list <<<"$scene_ids"
else
	for dir in "$here"/scenes/*/; do scene_list+=("$(basename "$dir")"); done
fi
((${#scene_list[@]})) || { echo "流す場面がありません" >&2; exit 1; }
for id in "${scene_list[@]}"; do
	[[ -f $here/scenes/$id/scene.md && -f $here/scenes/$id/cli.json ]] || { echo "場面がありません: $id" >&2; exit 1; }
	"${helper[@]}" scene "$here/scenes/$id/scene.md" >/dev/null
	jq -e 'if has("ci_monitor") then (.ci_monitor | type == "boolean") else true end' "$here/scenes/$id/cli.json" >/dev/null || {
		echo "ci_monitor は真偽値で指定してください: $id" >&2; exit 1;
	}
done

# 既定ではすべての役が有効。CLI 見本の ci_monitor が false の場面だけ、CI の見張り役を外す。
# どちらも両方のランタイムを使う。
# モデルと思考の深さだけは、評価するランタイムだけで展開した front matter から読む。
enabled=" $template_roles "
runtimes='["claude","codex"]'
export runtimes

# 指示を描き、作業ディレクトリに置く一式を作る。
prepare() { # $1=old|new
	local which=$1 dest="$out/instructions/$1" source_file scene=${2:-} enabled="$enabled"
	if [[ -n $scene ]]; then
		dest="$dest/scenes/$scene"
		enabled=${enabled/ ci-monitor / }
	fi
	mkdir -p "$dest/skills"
	if [[ $which == old ]]; then
		git -C "$root" rev-parse --verify --quiet "$baseline^{commit}" >/dev/null || { echo "baseline が見つかりません: $baseline" >&2; exit 1; }
		source_file="$dest/orchestrator.template.md"
		git -C "$root" show "$baseline:common/agents/orchestrator.md" >"$source_file"
		git -C "$root" archive "$baseline" common/skills/squad-handoff | tar -x -C "$dest/skills" --strip-components=2
	else
		source_file="$root/common/agents/orchestrator.md"
		mkdir -p "$dest/skills/squad-handoff"
		cp -R "$root/common/skills/squad-handoff/." "$dest/skills/squad-handoff/"
	fi
	template_filter "$enabled" "$source_file" >"$dest/filtered.md"
	runtimes="[\"$runtime\"]" template_filter "$enabled" "$source_file" >"$dest/runtime-filtered.md"
	jq -n --arg model "$(template_field "$dest/runtime-filtered.md" model)" \
		--arg thinking "$(template_field "$dest/runtime-filtered.md" thinking_level)" \
		'{model: $model, thinking_level: $thinking} | if .model == "" or .thinking_level == "" then error("model と thinking_level が読めません") else . end' >"$dest/meta.json"
	template_body "$dest/filtered.md" >"$dest/body.md"
	template_filter "$enabled" "$here/runtime-brief.md" >"$dest/brief.md"
	{ cat "$dest/brief.md"; echo; cat "$dest/body.md"; } >"$dest/instructions.template.md"
	template_apply "$here/values.json" "$dest/instructions.template.md" >"$dest/instructions.md"
	if grep -Eq '\{\{|<!-- (IF|ELSE|ENDIF)' "$dest/instructions.md"; then
		echo "差し込みの残りがあります: $which" >&2
		exit 1
	fi
}

versions=(old new)
[[ -z $only ]] || versions=("$only")
for which in "${versions[@]}"; do
	prepare "$which"
	for id in "${scene_list[@]}"; do
		if jq -e '.ci_monitor == false' "$here/scenes/$id/cli.json" >/dev/null; then prepare "$which" "$id"; fi
	done
done
{
	echo "baseline: $baseline ($(git -C "$root" rev-parse --short "$baseline^{commit}" 2>/dev/null || echo なし))"
	echo "new: working tree ($(git -C "$root" rev-parse --short HEAD))"
	echo "runtime: $runtime"
} >"$out/versions.txt"

ids=$(IFS=,; echo "${scene_list[*]}")
versions_csv=$(IFS=,; echo "${versions[*]}")
"${helper[@]}" run-all --out "$out" --scene-ids "$ids" --versions "$versions_csv" --runs "$runs" --jobs "$jobs" \
	--scenes "$here/scenes" --instructions "$out/instructions" --runtime "$runtime" --timeout "$timeout"
"${helper[@]}" summary "$out/runs.jsonl" "$out/summary.md"
cat "$out/summary.md"
echo "結果: $out"
