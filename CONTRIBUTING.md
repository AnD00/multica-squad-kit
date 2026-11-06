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
