#!/usr/bin/env bash
# 公開のテストの準備と照合を共有する。CLI は一時のリポジトリとスタブに置き換える。
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/release-assertions.sh"

expect_failed_verification() {
	local name=$1
	python3 - "$case_dir/out" "$name" <<'PYVERIFY'
from pathlib import Path
import sys
lines=Path(sys.argv[1]).read_text().splitlines()
failed=[line for line in lines if line.startswith('      ✖ ')]
if sys.argv[2]:
    assert len(failed)==1 and failed[0].startswith('      ✖ '+sys.argv[2]+'  '),failed
    assert not any(line.startswith('      ✔ '+sys.argv[2]+'  ') for line in lines),lines
else:
    assert not failed,failed
assert '  ✖ 配布物を検証する' in lines
assert not any(line.startswith('✔ v1.6.0  ') for line in lines)
PYVERIFY
}

# 公開の前の検証が失敗する: 何が合わなかったかを出し、release edit も削除も呼ばない。下書きと配布物は残り、流し直さないことを出す。
# expect_verify_stop <理由に含む文字>: 配布物のそろった下書きから流して、確認で止まったことを確認する。
expect_verify_stop() {
	run_release "$test_dir/answer-y"
	[[ $rc == 1 ]]
	grep -qF "$1" "$case_dir/err"
	grep -qF '公開しません。下書きと配布物は残してあります。' "$case_dir/err"
	grep -qF '人が確認するまで流し直さないでください。' "$case_dir/err"
	log_lacks '^release \(edit\|delete\)'
	log_lacks '^api -X\|^api --method'
	log_lacks '^workflow run'
	[[ $(draft_flag) == true ]]
	[[ $(jq -r '.[] | select(.tag_name == "v1.6.0") | .assets | length' "$GH_RELEASES") == 4 ]]
	no_leftover
	expect_failed_verification "${2-}"
}
# 束での証明が通らない: タグの install.sh の検証（束なし）は通り、配布物ごとの束での確認で止まる。
for file in install.sh SHA256SUMS multica-squad-kit-v1.6.0.tar.gz; do
	make_case "verify-bundle-$file"
	tag_here
	add_release true
	seed_assets
	if [[ $file == install.sh ]]; then failed_item='配布物の install.sh'; else failed_item=証明; fi
	GH_ATTEST_FAIL=$file GH_ATTEST_FAIL_WITH=bundle expect_verify_stop "証明の束で、$file の証明を検証できませんでした。" "$failed_item"
	grep -qF 'stub: attestation failed' "$case_dir/err"
done
# 使う人の入口と同じ検証（束なしの証明）が通らない: タグの install.sh の --verify が止める。
make_case verify-nobundle
tag_here
add_release true
seed_assets
GH_ATTEST_FAIL=SHA256SUMS GH_ATTEST_FAIL_WITH=nobundle expect_verify_stop 'タグの install.sh の --verify が通りませんでした。' 'タグの install.sh'
grep -qF '証明を検証できませんでした: SHA256SUMS' "$case_dir/err"
# 隠していた install.sh の出力は、灰の「$ コマンドの 1 行」の次にそのまま出て、そのあとに止まるときの案内が出る。通った確認の行は出ない。
python3 - "$case_dir/err" <<'PY'
from pathlib import Path
import re
import sys
output = Path(sys.argv[1]).read_text(encoding='utf-8')
# 先頭は同じ行に続く確認の問い（端末なら入力の改行で終わる）なので、行頭には合わせない。
command = re.search(r'\$ bash \S+/verify/tag-install\.sh --verify v1\.6\.0 \S+/verify/assets$', output, re.M)
assert command
guide = output.index('エラー: タグの install.sh の --verify が通りませんでした。')
assert command.end() < output.index('証明を検証できませんでした: SHA256SUMS') < guide
assert '出力 ここから' not in output
PY
grep -qxF '  ✖ 配布物を検証する' "$case_dir/out"
! grep -q '^      ✔ ' "$case_dir/out"
log_lacks '^attestation verify .* --bundle '
# チェックサムが合わない: 配布物が SHA256SUMS と違う。
make_case verify-checksum
tag_here
add_release true
seed_assets sums
expect_verify_stop 'タグの install.sh の --verify が通りませんでした。' 'タグの install.sh'
grep -qF 'のチェックサムが、SHA256SUMS と違います' "$case_dir/err"
# 配布物の install.sh がタグと違う（SHA256SUMS は合っている）。
make_case verify-install-differs
tag_here
add_release true
seed_assets install
expect_verify_stop '配布物の install.sh が、タグの install.sh と違います。' '配布物の install.sh'
# 通った確認の行だけが出る: タグの install.sh での確認は通り、配布物の install.sh の行は出ない。
grep -qxF '      ✔ タグの install.sh    証明  チェックサム  tar.gz の中の一覧' "$case_dir/out"
! grep -qF '✔ 配布物の install.sh ' "$case_dir/out"
grep -qxF '  ✖ 配布物を検証する' "$case_dir/out"
# 配布物の install.sh が SHA256SUMS と違う。
make_case verify-install-sum
tag_here
add_release true
seed_assets install-sum
expect_verify_stop 'install.sh のチェックサムが、SHA256SUMS と違います。' '配布物の install.sh'
# 配布物の中身が、git archive で取り出したタグの中身と違う（ほかの確認は通る）。違いの先頭を出す。
make_case verify-content
tag_here
add_release true
seed_assets content
expect_verify_stop '配布物の中身が、git archive で取り出したタグの中身と違います。' '配布物の中身'
grep -qF 'evil.txt' "$case_dir/err"
expect_failed_verification '配布物の中身'
# 配布物を取得できない
make_case verify-download
tag_here
add_release true
seed_assets
GH_DL_FAIL=104 expect_verify_stop '配布物を取得できませんでした: multica-squad-kit-v1.6.0.sigstore.json'
# ワークフローを経た流れでも、差し替えられた配布物は公開しない。
make_case verify-after-workflow
GH_TAMPER=content run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF '配布物の中身が、git archive で取り出したタグの中身と違います。' "$case_dir/err"
log_lacks '^release edit'
[[ $(draft_flag) == true ]]
! grep -qF '✔ v1.6.0  ' "$case_dir/out"

# ゲージ: 端末でだけ、ワークフローの待ちの間に run view でステップの進みを読み、件数を出さずにゲージで描く。
# 読めない・ステップがないときは前の比率を保ち、成功かどうかは run watch の終了コードだけで決める。
make_case gauge-live
GH_WATCH_DELAY=3 GH_JOBS_DONE=4 run_release_tty "$test_dir/answer-y" RELEASE_PROGRESS_INTERVAL=1 GH_WATCH_DELAY=3 GH_JOBS_DONE=4
[[ $rc == 0 ]]
[[ $(log_count '^run view 4242 --repo example/kit --json jobs --jq ') -ge 2 ]]
python3 - "$case_dir/out" <<'PY'
from pathlib import Path
import re
import sys
data = Path(sys.argv[1]).read_bytes().decode()
esc = '\x1b'
# 10 件のうち 4 件が済み: 18 セルのうち 7 セルが青い。件数（4/10）は出さない。
assert f'{esc}[38;5;32m━━━━━━━{esc}[0m{esc}[38;5;244m───────────{esc}[0m' in data
assert '4/10' not in data
PY
make_case gauge-live-fail
GH_JOBS_MODE=fail GH_WATCH_DELAY=2 run_release_tty "$test_dir/answer-y" RELEASE_PROGRESS_INTERVAL=1 GH_WATCH_DELAY=2 GH_JOBS_MODE=fail
[[ $rc == 0 ]]
[[ $(log_count '^run view ') -ge 1 ]]
python3 - "$case_dir/out" "$published_url" <<'PY'
from pathlib import Path
import re
import sys
plain=re.sub(r'\x1b\[[0-9;]*m','',Path(sys.argv[1]).read_text())
assert f'✔ v1.6.0  {sys.argv[2]}' in plain
PY
make_case gauge-live-empty
run_release_tty "$test_dir/answer-y" RELEASE_PROGRESS_INTERVAL=1 GH_WATCH_DELAY=2 GH_JOBS_MODE=empty
[[ $rc == 0 ]]
[[ $(log_count '^run view ') -ge 1 ]]
# 端末でなければ、ゲージを読まない（run view を呼ばない）。
make_case gauge-notty
GH_WATCH_DELAY=2 run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^run view '
# 読む間隔は RELEASE_PROGRESS_INTERVAL で決まり、大きければ待ちの間に読まない。
make_case gauge-interval
run_release_tty "$test_dir/answer-y" RELEASE_PROGRESS_INTERVAL=600 GH_WATCH_DELAY=2
[[ $rc == 0 ]]
log_lacks '^run view '

# 色: 確認の印は緑、完了の印と名前は太字の青緑、値は灰、止まるときの行は赤にする。
# 色の番号は manual.md の「表示の色と印」と同じ（成功 28、完了の案内 太字の 30、エラー 太字の 196）。
esc=$(printf '\033')
make_case color-success
tag_here
add_release true
seed_assets
run_release_tty "$test_dir/answer-y"
[[ $rc == 0 ]]
tr -d '\r' <"$case_dir/out" >"$case_dir/screen"
grep -qxF "  ${esc}[38;5;28m✔${esc}[0m 道具              ${esc}[38;5;244mgit gh tar shasum diff cmp  gh 2.102.0  2.102.0 以上${esc}[0m" "$case_dir/screen"
grep -qxF "  ${esc}[1mv1.6.0${esc}[0m  ${esc}[38;5;244mexample/kit${esc}[0m" "$case_dir/screen"
grep -qxF "  ${esc}[38;5;244m│${esc}[0m 新しいバージョンの 1 段落目。" "$case_dir/screen"
# 端末では、手順の行をその場で書き換えるので、動きの制御の文字が混ざる。終わった手順の緑の ✔ と名前が、最後の描き直しにある。
grep -qF "${esc}[38;5;28m✔${esc}[0m Release を公開する" "$case_dir/screen"
grep -qF "${esc}[38;5;28m✔${esc}[0m 配布物を検証する" "$case_dir/screen"
grep -qxF "${esc}[1;38;5;30m✔ v1.6.0${esc}[0m  $published_url" "$case_dir/screen"
# 確認の記号は緑、値と完全な SHA は灰。最後に実行が見つからなくても、橙の ! を出して成功で終わる。
grep -qF "${esc}[38;5;28m✔${esc}[0m タグの install.sh    ${esc}[38;5;244m証明  チェックサム  tar.gz の中の一覧${esc}[0m" "$case_dir/screen"
grep -qxF "  ${esc}[38;5;244m$(git -C "$work" rev-parse v1.6.0^{commit})${esc}[0m" "$case_dir/screen"
grep -qxF "  ${esc}[1;38;5;166m!${esc}[0m 発行のワークフローの実行が見つかりません。GitHub の Actions の画面で確認してください。" "$case_dir/screen"
# 色の制御以外の動きの文字（カーソルの移動、行の消去）は、色の文字と別に数える。
[[ $(sed "s/${esc}\[[0-9;]*m//g" "$case_dir/screen" | grep -c "$esc" || true) -gt 0 ]]
make_case color-stop
tag_here
add_release true
seed_assets install
run_release_tty "$test_dir/answer-y"
[[ $rc == 1 ]]
tr -d '\r' <"$case_dir/err" >"$case_dir/screen"
# 先頭は同じ行に続く確認の問いなので、行頭には合わせない。
grep -qF "${esc}[1;38;5;196mエラー: 配布物の install.sh が、タグの install.sh と違います。" "$case_dir/screen"
grep -qF "${esc}[1;38;5;196m✖${esc}[0m 配布物の install.sh" "$case_dir/out"
grep -qF "${esc}[1;38;5;196m✖${esc}[0m 配布物を検証する" "$case_dir/out"
# NO_COLOR を付けると、端末でも色の制御文字を出さない。結果の語と印だけで種類が分かる。
make_case color-none
tag_here
add_release true
seed_assets
run_release_tty "$test_dir/answer-y" NO_COLOR=1
[[ $rc == 0 ]]
! grep -q "$esc" "$case_dir/out" "$case_dir/err"
grep -qF '      ✔ 証明                 配布物  SHA256SUMS' "$case_dir/out"
grep -qF "✔ v1.6.0  $published_url" "$case_dir/out"
make_case color-none-stop
tag_here
add_release true
seed_assets install
run_release_tty "$test_dir/answer-y" NO_COLOR=1
[[ $rc == 1 ]]
! grep -q "$esc" "$case_dir/out" "$case_dir/err"
grep -qF 'エラー: 配布物の install.sh が、タグの install.sh と違います。' "$case_dir/err"

# 公開が失敗する: 下書きが残り、1 で終わる。流し直すと、配布物を検証し直して公開する。
make_case edit-fails
tag_here
add_release true
seed_assets
GH_EDIT_FAIL=1 run_release "$test_dir/answer-y"
[[ $rc == 1 ]]
grep -qF 'Release の公開に失敗しました。下書きは残してあります。' "$case_dir/err"
[[ $(draft_flag) == true ]]
rm -f "$case_dir/gh.log"
run_release "$test_dir/answer-y"
[[ $rc == 0 ]]
log_lacks '^release create'
log_lacks '^workflow run'
[[ $(log_count 'releases/assets/') == 4 ]]
log_has '^release edit v1.6.0 --repo example/kit --draft=false$'
expect_steps 4
[[ $(draft_flag) == false ]]

# 引数: 知らない引数と余分な引数は、使い方を出して 2 で終わる。--help と -h は、使い方を出して 0 で終わる。
make_case args
for args in "foo" "--yes" "--help extra" "-h --help"; do
	run_release_notty $args
	[[ $rc == 2 ]]
	grep -qF '使い方: bash scripts/release.sh' "$case_dir/err"
	no_tag
	[[ ! -e $case_dir/gh.log ]]
done
for flag in --help -h; do
	run_release_notty "$flag"
	[[ $rc == 0 ]]
	grep -qF '使い方: bash scripts/release.sh' "$case_dir/out"
	no_tag
	[[ ! -e $case_dir/gh.log ]]
done
echo 'PASS release-display: 失敗した確認の行、ゲージ、完了の印と値、色と引数を確認した'
