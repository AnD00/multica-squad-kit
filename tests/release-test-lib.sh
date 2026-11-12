#!/usr/bin/env bash
# release-test.sh と画面の画像の仕組みが共有する準備。単独では実行しない。
# 呼び出し元は root（原本のルート）と test_dir（自分の一時ディレクトリ）を用意し、片付けも行う。
# 手元の Git の設定（環境変数で入る GIT_CONFIG_COUNT 以降を含む）から切り離す。push は一時の bare にだけ届く。
unset GIT_CONFIG_COUNT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Test User' GIT_AUTHOR_EMAIL=test@example.test
export GIT_COMMITTER_NAME='Test User' GIT_COMMITTER_EMAIL=test@example.test
# 起こしたワークフローの実行を探す間隔は、待たずに読み直させる。
export RELEASE_RUN_FIND_INTERVAL=0

# スタブの gh は、受けた引数を GH_LOG に 1 行で残す。状態は GH_RELEASES（Release の一覧の JSON）と GH_STATE にある。
# ケースごとに、環境変数で成否を切り替える。
#   GH_VERSION_OUT / GH_VERSION_FAIL: --version の出力と失敗
#   GH_LIST_FAIL: Release の一覧を読めない
#   GH_CREATE_FAIL / GH_WORKFLOW_FAIL / GH_WATCH_FAIL / GH_EDIT_FAIL: release create、workflow run、run watch、release edit の失敗
#   GH_RUNS_MODE: run list の返し方（空: 1 件 / none: 見つからない / dup: 2 件 / fail: 読めない）、GH_RUNS_DELAY: 見つかるまでの空振りの回数
#   GH_TAMPER: 配布物の差し替え（content / sums / install / install-sum）
#   GH_ATTEST_FAIL: 証明を拒むファイル名、GH_ATTEST_FAIL_WITH: bundle（--bundle ありだけ）/ nobundle / 空（どちらも）
#   GH_DL_FAIL: 取得に失敗する配布物の ID
#   GH_WATCH_DELAY: run watch が終わるまで待つ秒数（空なら待たない）
# __seed <差し替え>: テストが、下書きの Release に配布物を載せた状態を作るために呼ぶ（記録しない）。
mkdir -p "$test_dir/bin"
# タグの push だけ、v1.10.0 の公開ログ（タスクの本文）の文面を出す。
# 本物の git の場所は、スタブを PATH に入れる前に控える。ほかの呼び出しと失敗はそのまま返す。
RELEASE_TEST_GIT=$(command -v git)
export RELEASE_TEST_GIT
cat >"$test_dir/bin/git" <<'STUB'
#!/bin/bash
if [[ $# == 3 && $1 == push && $2 == origin && $3 == refs/tags/* ]]; then
	"$RELEASE_TEST_GIT" "$@" >"$GH_STATE/git-push.log" 2>&1
	rc=$?
	if [[ $rc != 0 ]]; then
		cat "$GH_STATE/git-push.log" >&2
		exit "$rc"
	fi
	tag=${3#refs/tags/}
	cat >&2 <<OUTPUT
Enumerating objects: 1, done.
Counting objects: 100% (1/1), done.
Writing objects: 100% (1/1), 170 bytes | 170.00 KiB/s, done.
Total 1 (delta 0), reused 0 (delta 0), pack-reused 0 (from 0)
To https://github.com/example/kit.git
 * [new tag]         $tag -> $tag
OUTPUT
	exit 0
fi
exec "$RELEASE_TEST_GIT" "$@"
STUB
chmod +x "$test_dir/bin/git"
cat >"$test_dir/bin/gh" <<'STUB'
#!/bin/bash
# upload_assets <差し替え>: 来歴のタグに scripts/build-assets.sh を流して配布物を作り、下書きの Release に載せる。
upload_assets() {
	local tamper=$1 tag=$GH_TAG out=$GH_STATE/built clone=$GH_STATE/clone tarf ex assets_json
	tarf=multica-squad-kit-$tag.tar.gz
	rm -rf "$out" "$clone" "$GH_STATE/tamper"
	git clone -q "$GH_ORIGIN" "$clone" || return 1
	git -C "$clone" checkout -q --detach "$tag" || return 1
	(cd "$clone" && bash scripts/build-assets.sh "$tag" "$out") >/dev/null || return 1
	case $tamper in
	content)
		# 配布物に、タグにないファイルを足す。SHA256SUMS は作り直し、ほかの確かめは通す。
		ex=$GH_STATE/tamper
		mkdir -p "$ex"
		tar -xzf "$out/$tarf" -C "$ex"
		printf 'evil\n' >"$ex/multica-squad-kit-$tag/evil.txt"
		COPYFILE_DISABLE=1 tar -czf "$out/$tarf" -C "$ex" "multica-squad-kit-$tag"
		(cd "$out" && shasum -a 256 "$tarf" install.sh >SHA256SUMS)
		;;
	sums) printf 'x' >>"$out/$tarf" ;;
	install)
		printf '# changed\n' >>"$out/install.sh"
		(cd "$out" && shasum -a 256 "$tarf" install.sh >SHA256SUMS)
		;;
	install-sum) printf '# changed\n' >>"$out/install.sh" ;;
	esac
	mkdir -p "$GH_STATE/assets"
	cp "$out/$tarf" "$GH_STATE/assets/101"
	cp "$out/install.sh" "$GH_STATE/assets/102"
	cp "$out/SHA256SUMS" "$GH_STATE/assets/103"
	printf '{"stub":"bundle"}\n' >"$GH_STATE/assets/104"
	assets_json=$(printf '[{"id":101,"name":"%s"},{"id":102,"name":"install.sh"},{"id":103,"name":"SHA256SUMS"},{"id":104,"name":"multica-squad-kit-%s.sigstore.json"}]' "$tarf" "$tag")
	jq --arg tag "$tag" --argjson assets "$assets_json" '(.[] | select(.tag_name == $tag and .draft == true)).assets = $assets' "$GH_RELEASES" >"$GH_RELEASES.new" && mv "$GH_RELEASES.new" "$GH_RELEASES"
}

if [[ ${1:-} == __seed ]]; then
	upload_assets "${2:-}"
	exit $?
fi
printf '%s\n' "$*" >>"$GH_LOG"

if [[ ${1:-} == --version ]]; then
	[[ -z ${GH_VERSION_FAIL:-} ]] || exit 1
	printf '%s\n' "$GH_VERSION_OUT"
	exit 0
fi

# Release の一覧: --jq の式は、本物の jq で一覧の JSON に当てる。
if [[ ${1:-} == api && ${2:-} == --paginate && ${3:-} == 'repos/example/kit/releases?per_page=100' && ${4:-} == --jq ]]; then
	[[ -z ${GH_LIST_FAIL:-} ]] || { echo 'gh: Bad credentials (HTTP 401)' >&2; exit 1; }
	jq -r "$5" "$GH_RELEASES"
	exit $?
fi

# 配布物の取得: 配布物の ID のファイルをそのまま返す。
if [[ ${1:-} == api && ${2:-} == -H && ${3:-} == 'Accept: application/octet-stream' && ${4:-} == repos/example/kit/releases/assets/* ]]; then
	id=${4##*/}
	[[ ${GH_DL_FAIL:-} != "$id" ]] || { echo 'gh: download failed' >&2; exit 1; }
	[[ -f $GH_STATE/assets/$id ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
	cat "$GH_STATE/assets/$id"
	exit 0
fi

if [[ ${1:-} == release && ${2:-} == create ]]; then
	[[ -z ${GH_CREATE_FAIL:-} ]] || { echo 'intentional release failure' >&2; exit 1; }
	tag=${3:-}
	git -C "$GH_ORIGIN" rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || { echo "gh: tag $tag not found on the remote" >&2; exit 1; }
	url=https://github.com/example/kit/releases/tag/untagged-0123456789ab
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --notes-file ]]; then cp "$2" "$GH_NOTES"; fi
		shift
	done
	jq --arg tag "$tag" --arg url "$url" '. + [{tag_name: $tag, draft: true, html_url: $url, assets: []}]' "$GH_RELEASES" >"$GH_RELEASES.new" && mv "$GH_RELEASES.new" "$GH_RELEASES"
	echo "$url"
	exit 0
fi

if [[ ${1:-} == workflow && ${2:-} == run ]]; then
	[[ -z ${GH_WORKFLOW_FAIL:-} ]] || { echo 'intentional workflow failure' >&2; exit 1; }
	[[ ${3:-} == release-assets.yml ]] || { echo "unexpected workflow: ${3:-}" >&2; exit 1; }
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --ref ]]; then printf '%s' "$2" >"$GH_STATE/dispatched"; fi
		shift
	done
	cat <<'OUTPUT'
✓ Created workflow_dispatch event for release-assets.yml at v1.6.0
https://github.com/example/kit/actions/runs/4242

To see the created workflow run, try: gh run view 4242
To see runs for this workflow, try: gh run list --workflow="release-assets.yml"
OUTPUT
	exit 0
fi

# 実行の一覧: 起こしたあとなら、条件に合う実行が 1 件（dup なら 2 件）出る。ほかの実行も混ぜ、絞り込みを確かめる。
if [[ ${1:-} == run && ${2:-} == list ]]; then
	filter=
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --jq ]]; then filter=$2; fi
		shift
	done
	[[ ${GH_RUNS_MODE:-} != fail ]] || { echo 'gh: run list failed' >&2; exit 1; }
	calls=$(($(cat "$GH_STATE/runs-calls" 2>/dev/null || echo 0) + 1))
	printf '%s' "$calls" >"$GH_STATE/runs-calls"
	ref=$(cat "$GH_STATE/dispatched" 2>/dev/null || echo none)
	now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	extra='[]'
	if [[ -f $GH_STATE/dispatched && ${GH_RUNS_MODE:-} != none && $calls -gt ${GH_RUNS_DELAY:-0} ]]; then
		extra='[{"databaseId":4242,"headBranch":"'$ref'","createdAt":"'$now'","event":"workflow_dispatch","url":"https://github.com/example/kit/actions/runs/4242"}]'
		if [[ ${GH_RUNS_MODE:-} == dup ]]; then
			extra='[{"databaseId":4242,"headBranch":"'$ref'","createdAt":"'$now'","event":"workflow_dispatch","url":"https://github.com/example/kit/actions/runs/4242"},{"databaseId":4243,"headBranch":"'$ref'","createdAt":"'$now'","event":"workflow_dispatch","url":"https://github.com/example/kit/actions/runs/4243"}]'
		fi
	fi
	jq -n --arg ref "$ref" --arg now "$now" --argjson extra "$extra" '[
		{databaseId: 1, headBranch: $ref, createdAt: "2020-01-01T00:00:00Z", event: "workflow_dispatch", url: "https://github.com/example/kit/actions/runs/1"},
		{databaseId: 2, headBranch: "main", createdAt: $now, event: "workflow_dispatch", url: "https://github.com/example/kit/actions/runs/2"},
		{databaseId: 3, headBranch: $ref, createdAt: $now, event: "push", url: "https://github.com/example/kit/actions/runs/3"}
	] + $extra' | jq -r "$filter"
	exit 0
fi

# 実行を待つ: 成功すると、ワークフローが配布物を載せたことにする。
if [[ ${1:-} == run && ${2:-} == watch ]]; then
	[[ ${3:-} == 4242 ]] || { echo "unexpected run id: ${3:-}" >&2; exit 1; }
	[[ -z ${GH_WATCH_DELAY:-} ]] || sleep "$GH_WATCH_DELAY"
	mark=✓ conclusion=success
	[[ -z ${GH_WATCH_FAIL:-} ]] || { mark=X; conclusion=failure; }
	cat <<OUTPUT
$mark v1.6.0 Release assets · 4242
Triggered via workflow_dispatch less than a minute ago

JOBS
$mark assets in 12s (ID 130947266040)
  ✓ Set up job
  ✓ Check the tag and the draft Release
  ✓ Check out the tag
  ✓ Check the checkout
  $mark Build the assets
  $mark Attest the assets
  $mark Upload to the draft Release
  ✓ Post Check out the tag
  ✓ Complete job

$mark Run Release assets (4242) completed with '$conclusion'
OUTPUT
	[[ -z ${GH_WATCH_FAIL:-} ]] || { echo 'intentional run failure' >&2; exit 1; }
	upload_assets "${GH_TAMPER:-}"
	exit $?
fi

if [[ ${1:-} == release && ${2:-} == edit ]]; then
	[[ -z ${GH_EDIT_FAIL:-} ]] || { echo 'intentional edit failure' >&2; exit 1; }
	[[ ${3:-} == v1.6.0 && ${4:-} == --repo && ${5:-} == example/kit && ${6:-} == --draft=false ]] || { echo "unexpected release edit: $*" >&2; exit 1; }
	jq '(.[] | select(.tag_name == "v1.6.0")).draft = false | (.[] | select(.tag_name == "v1.6.0")).html_url = "https://github.com/example/kit/releases/tag/v1.6.0"' "$GH_RELEASES" >"$GH_RELEASES.new" && mv "$GH_RELEASES.new" "$GH_RELEASES"
	echo 'https://github.com/example/kit/releases/tag/v1.6.0'
	exit 0
fi

# 証明: --bundle の有無を見て、GH_ATTEST_FAIL のファイルだけ拒む。
if [[ ${1:-} == attestation && ${2:-} == verify ]]; then
	file=${3:-}
	bundle=no
	for arg in "$@"; do
		[[ $arg != --bundle ]] || bundle=yes
	done
	if [[ -n ${GH_ATTEST_FAIL:-} && ${file##*/} == "$GH_ATTEST_FAIL" ]]; then
		if [[ -z ${GH_ATTEST_FAIL_WITH:-} || (${GH_ATTEST_FAIL_WITH} == bundle && $bundle == yes) || (${GH_ATTEST_FAIL_WITH} == nobundle && $bundle == no) ]]; then
			echo 'stub: attestation failed' >&2
			exit 1
		fi
	fi
	exit 0
fi

echo "unexpected gh call: $*" >&2
exit 1
STUB
chmod +x "$test_dir/bin/gh"

changelog_default() {
	cat <<'CHANGELOG'
# 変更の記録

## v1.6.0


新しいバージョンの 1 段落目。

- 項目 1
- 項目 2


## v1.5.0

古いバージョンの本文。
CHANGELOG
}
notes_expected=$'新しいバージョンの 1 段落目。\n\n- 項目 1\n- 項目 2'
draft_url=https://github.com/example/kit/releases/tag/untagged-0123456789ab
published_url=https://github.com/example/kit/releases/tag/v1.6.0
run_url=https://github.com/example/kit/actions/runs/4242
gh_env_vars='GH_TAMPER GH_WATCH_FAIL GH_EDIT_FAIL GH_CREATE_FAIL GH_WORKFLOW_FAIL GH_LIST_FAIL GH_VERSION_FAIL GH_ATTEST_FAIL GH_ATTEST_FAIL_WITH GH_DL_FAIL GH_RUNS_MODE GH_RUNS_DELAY GH_WATCH_DELAY'

# make_case <名前> [origin の URL]: bare の origin と、その URL を insteadOf で bare に向けた作業コピーを作る。
# 作業コピーは、配布物を作るスクリプトと本物の install.sh を持つ。一覧には、別のバージョンの公開済みの Release だけがある。
make_case() {
	local url=${2:-https://github.com/example/kit.git} v
	case_dir="$test_dir/$1"
	bare="$case_dir/origin.git"
	work="$case_dir/work"
	mkdir -p "$case_dir/tmp" "$case_dir/gh/assets"
	git init -q --bare -b main "$bare"
	git init -q -b main "$work"
	mkdir -p "$work/scripts" "$work/lib"
	cp "$root/scripts/release.sh" "$root/scripts/build-assets.sh" "$root/scripts/manifest.sh" "$work/scripts/"
	cp "$root/lib/ui.sh" "$work/lib/ui.sh"
	cp "$root/install.sh" "$work/install.sh"
	printf '#!/bin/sh\necho setup\n' >"$work/setup.sh"
	chmod +x "$work/setup.sh"
	printf 'v1.6.0\n' >"$work/VERSION"
	changelog_default >"$work/CHANGELOG.md"
	printf 'tracked\n' >"$work/tracked.txt"
	(cd "$work" && bash scripts/manifest.sh)
	rm -rf "$work/tmp"
	git -C "$work" add -A
	git -C "$work" commit -qm 'Release content'
	git -C "$work" remote add origin "$url"
	git -C "$work" config "url.$bare.insteadOf" "$url"
	git -C "$work" push -q origin main
	printf '[{"tag_name":"v1.5.0","draft":false,"html_url":"https://github.com/example/kit/releases/tag/v1.5.0","assets":[{"id":1,"name":"old.tar.gz"}]}]\n' >"$case_dir/gh/releases.json"
	export GH_LOG="$case_dir/gh.log" GH_NOTES="$case_dir/gh.notes" GH_TAG=v1.6.0 GH_ORIGIN="$bare" GH_STATE="$case_dir/gh" GH_RELEASES="$case_dir/gh/releases.json"
	export GH_VERSION_OUT='gh version 2.102.0 (2026-01-01)'
	for v in $gh_env_vars; do export "$v="; done
}

# commit_work <メッセージ>: 作業コピーの変更をコミットして origin に push する。
commit_work() {
	git -C "$work" add -A
	git -C "$work" commit -qm "$1"
	git -C "$work" push -q origin main
}

# tag_here: 手元の main の先頭に注釈付きのタグを作り、origin に push する。
tag_here() {
	git -C "$work" tag -a v1.6.0 -m v1.6.0
	git -C "$work" push -q origin refs/tags/v1.6.0
}

# add_release <draft: true|false>: Release の一覧に、そのバージョンの Release を 1 件足す（配布物なし）。
add_release() {
	local url=$published_url
	[[ $1 == false ]] || url=$draft_url
	jq --argjson draft "$1" --arg url "$url" '. + [{tag_name: "v1.6.0", draft: $draft, html_url: $url, assets: []}]' "$GH_RELEASES" >"$GH_RELEASES.new"
	mv "$GH_RELEASES.new" "$GH_RELEASES"
}
# seed_assets [差し替え]: 下書きの Release に、タグから作った 4 つの配布物を載せる。タグを origin に push してから呼ぶ。
seed_assets() {
	"$test_dir/bin/gh" __seed "${1:-}"
}
# edit_assets <jq の式>: 一覧のそのバージョンの配布物を、式で書き換える。
edit_assets() {
	jq "(.[] | select(.tag_name == \"v1.6.0\")).assets |= ($1)" "$GH_RELEASES" >"$GH_RELEASES.new"
	mv "$GH_RELEASES.new" "$GH_RELEASES"
}
# draft_flag: そのバージョンの Release が下書きかどうか（true か false）。
draft_flag() { jq -r '.[] | select(.tag_name == "v1.6.0") | .draft' "$GH_RELEASES"; }

# snapshot: 手元と origin のブランチとタグを 1 つの文字にする。
snapshot() {
	git -C "$work" for-each-ref refs/heads refs/tags
	git -C "$bare" for-each-ref refs/heads refs/tags
}

# run_release <入力のファイル> [引数...]: 標準入力を疑似端末につないで流す。終了コードを rc に置く。
# 一時の置き場は $case_dir/tmp の下に作らせる。実行環境の BASH_ENV が PATH の先頭へ本物の gh を戻すことがあるので、外す。
run_release() {
	local input=$1
	shift
	rm -f "$case_dir/rc"
	(cd "$work" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" \
		python3 "$root/tests/ui-pty.py" none "$case_dir/out" "$case_dir/err" --stdin-tty "$input" -- \
		/bin/bash -c 'rc=0; /bin/bash scripts/release.sh "$@" || rc=$?; printf "%s" "$rc" >"$0"' "$case_dir/rc" "$@")
	rc=$(<"$case_dir/rc")
}

# run_release_notty <引数...>: 標準入力を /dev/null にして流す（端末でない）。
run_release_notty() {
	rc=0
	(cd "$work" && env -u BASH_ENV PATH="$test_dir/bin:$PATH" TMPDIR="$case_dir/tmp" \
		/bin/bash scripts/release.sh "$@") </dev/null >"$case_dir/out" 2>"$case_dir/err" || rc=$?
}
