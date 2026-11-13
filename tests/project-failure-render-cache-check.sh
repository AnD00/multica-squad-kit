#!/usr/bin/env bash
# 元の 13 個の PASS 行は増やさず、展開結果を再利用できる境界を確認する。
set -euo pipefail
scratch=$1/render-check
repo=$2
mkdir -p "$scratch/cache"
export TEST_PROJECT_RENDER_CACHE="$scratch/cache"
source "$repo/lib/render.sh"
definition=$(declare -f template_apply)
eval "original_template_apply${definition#template_apply}"
template_apply() {
 printf 'call\n' >>"$scratch/calls"
 original_template_apply "$@"
}
source "$repo/tests/project-failure-render-cache.sh"
printf '{"name":"one"}\n' >"$scratch/values"
printf '{{name}}\n' >"$scratch/template"
template_apply "$scratch/values" "$scratch/template" >"$scratch/first"
template_apply "$scratch/values" "$scratch/template" >"$scratch/second"
cmp "$scratch/first" "$scratch/second"
cp "$scratch/values" "$scratch/copied-values"
cp "$scratch/template" "$scratch/copied-template"
template_apply "$scratch/copied-values" "$scratch/copied-template" >"$scratch/second"
cmp "$scratch/first" "$scratch/second"
[[ $(wc -l <"$scratch/calls") -eq 1 ]]
# 値とひな形がそれぞれ変わったときは、元の展開を通す。
printf '{"name":"two"}\n' >"$scratch/values"
[[ $(template_apply "$scratch/values" "$scratch/template") == two ]]
printf 'changed:{{name}}\n' >"$scratch/template"
[[ $(template_apply "$scratch/values" "$scratch/template") == changed:two ]]
[[ $(wc -l <"$scratch/calls") -eq 3 ]]
# 失敗の終了コード・両出力を保ち、失敗した結果を再利用しない。
printf '{{missing}}\n' >"$scratch/template"
expected_code=0
original_template_apply "$scratch/values" "$scratch/template" >"$scratch/expected-out" 2>"$scratch/expected-err" || expected_code=$?
[[ $expected_code != 0 ]]
for attempt in 1 2; do
 actual_code=0
 template_apply "$scratch/values" "$scratch/template" >"$scratch/out" 2>"$scratch/err" || actual_code=$?
 [[ $actual_code == "$expected_code" ]]
 cmp "$scratch/expected-out" "$scratch/out"
 cmp "$scratch/expected-err" "$scratch/err"
done
[[ $(wc -l <"$scratch/calls") -eq 5 ]]
# 呼び出し元が失敗を条件式で受けない場合も、診断を出して終了する。
actual_code=0
/bin/bash -c 'set -euo pipefail; source "$1/lib/render.sh"; source "$1/tests/project-failure-render-cache.sh"; template_apply "$2/values" "$2/template"' _ "$repo" "$scratch" >"$scratch/out" 2>"$scratch/err" || actual_code=$?
[[ $actual_code == "$expected_code" ]]
cmp "$scratch/expected-out" "$scratch/out"
cmp "$scratch/expected-err" "$scratch/err"
