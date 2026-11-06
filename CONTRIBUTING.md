# 変更の進め方

原本への変更は PR にし、人のレビューと CI を通す。マージ、配るタグの作成と移動の判断は人間が行う。エージェントは draft PR と検証結果を渡す。タグは動かさず、修正は新しいタグにする。

## テストを流す

`bash tests/run.sh` は、`tests/*-test.sh` を並べて流す。すべて通れば 0、1 本でも失敗すれば 1 で終わる。CI も同じコマンドを流す。

```bash
bash tests/run.sh                            # 並べて流す
SQUAD_KIT_TEST_JOBS=4 bash tests/run.sh      # 並列数を 4 にする
SQUAD_KIT_TEST_JOBS=1 bash tests/run.sh      # 1 本ずつ流す
bash tests/run.sh tests/project-test.sh      # 選んだファイルだけ流す
```

並列数は、指定しなければ論理 CPU の数になる。1 本ずつ流しても、起こす順と出力は並べたときと同じで、途中で失敗しても最後まで流す。並べたときだけ失敗するかを確かめるときに使う。

失敗したファイルのログは最後にまとめて出て、失敗した場所と直前に通ったケースが添えられる。流している間の出力を見たいときは、`bash tests/project-test.sh` のようにファイルを直接流す。

仕組みは、`tests/run.sh` の冒頭のコメントを参照する。

### テストを書く決まり

テストは、ファイルごとに別の `HOME` と `TMPDIR` で流れる。テストのファイルは、次を守る。

- 一時ファイルとディレクトリは、置き場所を明示して作る。`tmp/` の下に `mktemp -d` で作った自分のディレクトリか、`mktemp "$TMPDIR/名前.XXXXXX"` のように `TMPDIR` の下に作る。置き場所を指定しない `mktemp` と `mktemp -t` は使わない
- `HOME` の下の利用者の設定に頼らない。Git の名前とメールが要るときは、`git -c user.name=… -c user.email=…` で渡す
- 原本の `tmp/` 以外のファイルを書き換えない。決まった名前のファイルを共有の場所に作らず、プロセスを名前で止めない

## 版を出す前に VM で確かめる

VM を作るスクリプト（`vm/lima.sh` と `vm/wsl.ps1`）と、中で流すセットアップは、スタブを使う自動テストでは、実機の動作を確かめきれない。版を出す前に、人が Mac と Windows の実機で次を確かめ、結果を版を上げる PR に書く。`manual.md` の「閉じ込めて動かす」の手順を使う。

1. スクリプトで VM を作り、中でセットアップを最後まで流す
2. 中のエージェントが、許したリポジトリの checkout と PR の作成までできる
3. `verify` が通る。中で MySQL のコンテナを立てたあとも通る
4. VM を止めて起動し直し、中に入らずに、デーモンがオンラインになってタスクが動く。WSL では、窓をすべて閉じたあとも動く
5. VM を消したあと、ホストのホームに、セットアップが書いたファイル（`~/.multica-agent`、`~/.multica`、`~/multica_workspaces`）がない

Mac は Lima、Windows は WSL の専用のディストリで、それぞれ確かめる。片方の実機が使えないときは、確かめなかった側と理由を PR に書き、そのまま版を出すかを人が決める。

## タグを発行する

人間が、レビューと CI を通した変更のマージ後に行う。作業ディレクトリに未コミットの変更がないことを確認し、原本のリポジトリで次を実行する。発行するタグ名は `VERSION` から読む。

```bash
(
  set -eu
  git switch main
  git pull --ff-only origin main
  test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
  release_tag=$(cat VERSION)
  test "$(cat VERSION)" = "$release_tag"
  test "$(awk '/^## / {print $2; exit}' CHANGELOG.md)" = "$release_tag"
  git tag -a "$release_tag" -m "$release_tag"
  git push origin "refs/tags/$release_tag"
)
```

タグを付ける main が `origin/main` と一致しなければ、タグを作らずに止まる。未公開コミットがある場合は、その変更を PR でレビュー・マージしてからやり直す。

`VERSION` と `CHANGELOG.md` の先頭の版がタグ名と一致しなければ、タグを作らずに止まる。一致しない場合は、版と変更の記録を直す PR をレビュー・マージしてからやり直す。タグは注釈付きで作り、発行済みのタグは動かさない。修正は新しいタグで配る。

### Release を作る

タグを push したら、そのタグの Release を作る。`VERSION` が発行したタグ名のままであることを確認してから実行する。本文は、`CHANGELOG.md` のその版の節になる。

```bash
(
  set -eu
  release_tag=$(cat VERSION)
  notes=$(git show "$release_tag:CHANGELOG.md" |
    awk -v heading="## $release_tag" '$0 == heading {found = 1; next} found && /^## / {exit} found')
  test -n "$(printf '%s' "$notes" | tr -d '[:space:]')"
  gh release create "$release_tag" --repo AnD00/multica-squad-kit --verify-tag --title "$release_tag" --notes "$notes"
)
```

その版の節が空なら、Release を作らずに止まる。Release の作成だけが失敗したときは、タグを作り直さず、このコマンドだけを流し直す。
