# 変更の進め方

原本への変更は PR にし、人のレビューと CI を通す。マージ、配るタグの作成と移動の判断は人間が行う。エージェントは draft PR と検証結果を渡す。タグは動かさず、修正は新しいタグにする。

## タグを発行する

人間が、レビューと CI を通した変更のマージ後に行う。作業ディレクトリに未コミットの変更がないことを確認し、`release_tag` を発行するタグ名に置き換えて、原本のリポジトリで次を実行する。

```bash
(
  set -eu
  git switch main
  git pull --ff-only origin main
  test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
  release_tag=v1.0.0
  test "$(cat VERSION)" = "$release_tag"
  test "$(awk '/^## / {print $2; exit}' CHANGELOG.md)" = "$release_tag"
  git tag -a "$release_tag" -m "$release_tag"
  git push origin "refs/tags/$release_tag"
)
```

タグを付ける main が `origin/main` と一致しなければ、タグを作らずに止まる。未公開コミットがある場合は、その変更を PR でレビュー・マージしてからやり直す。

`VERSION` と `CHANGELOG.md` の先頭の版がタグ名と一致しなければ、タグを作らずに止まる。一致しない場合は、版と変更の記録を直す PR をレビュー・マージしてからやり直す。タグは注釈付きで作り、発行済みのタグは動かさない。修正は新しいタグで配る。

### Release を作る

タグを push したら、同じ人がそのタグの Release を作る。受け取る人は原本の Watch の「Releases」で新しい版に気付くので、Release のないタグは知らされない。本文は、タグの時点の `CHANGELOG.md` の、その版の節にする。

```bash
(
  set -eu
  release_tag=v1.0.0
  notes=$(git show "$release_tag:CHANGELOG.md" |
    awk -v heading="## $release_tag" '$0 == heading {found = 1; next} found && /^## / {exit} found')
  test -n "$(printf '%s' "$notes" | tr -d '[:space:]')"
  gh release create "$release_tag" --repo AnD00/multica-squad-kit --verify-tag --title "$release_tag" --notes "$notes"
)
```

その版の節が空なら、Release を作らずに止まる。一時ファイルを使わないので、zsh の `noclobber` でも bash でも同じに動く。`--verify-tag` により、原本にまだ push していないタグでも止まる。Release の作成だけが失敗したときは、タグを作り直さず、このコマンドだけを流し直す。Release のないタグが残っていれば、同じ手順で作る。
