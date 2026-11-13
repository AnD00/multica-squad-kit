# CLI の実物の見本

`squad-cli-lib` の `squad_cli_contracts` が、読む欄の分類と見本の形を返す。`fields` は応答全体の欄、`items.fields` は `items.path` の配列の各要素の欄である。条件と見本の `where` は、その要素を入力とする jq の式である。

各 JSON ファイルは、実物の CLI 応答を並べた配列である。配列を返すコマンドの見本は、二重配列になる。配列の要素は、約束が求める形ごとに選んでいる。読む欄以外も残し、鍵と値の型を変えずに匿名化している。

UUID は、同じ採取の全見本で共通の対応表を使って `fixture-id-` と固定桁の連番へ置き換える。元の ID の文字列順に番号を付け、同一性と ID 同士の比較順を保つ。元の ID と対応表は保存しない。値は採取ごとのもので、別の採取の番号とは比較しない。

`VERSION` は、採取時の `multica version` と `gh --version` の各 1 行目である。`CAPTURE.json` は、形ごとの採取元の件数と、「見本なし」の理由を記録する。件数は選ぶ前の応答に対する数なので、保存した見本の数とは異なる。

読み取りの見本は 2026-11-11 に 5 件のタスクから再採取した。書き込みの 3 応答は、初回に CLI 0.7.0 から保存したものを再利用し、同じ対応表で匿名化し直した。今回の CLI のバージョンも `VERSION` と同じである。書き込みを再実行した記録ではない。

原本のルートで、必要な形を含むタスクを複数渡して取り直す。

```bash
bash tests/capture-cli-fixtures.sh <タスク>...
```

書き込みのコマンドは取り込み処理では実行しない。別途、許可された見本用タスクで実行した応答を、作業ディレクトリの中のディレクトリに保存する。ファイル名は `issue-create.json`、`issue-comment-add.json`、`issue-wakeup-create.json` とし、1 ファイルに 1 回の応答をそのまま保存する。

```bash
bash tests/capture-cli-fixtures.sh --write-samples tmp/採取した応答 <タスク>...
```

求める形がないときは、名前を出して失敗し、既存の見本を書き換えない。約束で「見本なし」とした形は、理由と 0 件を知らせる。後から採取できた場合は、その応答を保存する。

現在の「見本なし」は、CI が使わない `StatusContext` である。コメント追加の応答は、承認された見本用タスクに `/note` で投稿して採取した。

## 検証して読む

見張りは `squad-cli-lib` を source し、`squad_cli_read <読み取りの名前> <引数>...` で呼ぶ。引数は約束のコマンドの `{引数}` の順で渡す。その後には `--limit` などを追加できる。`--compact` と JSON の出力指定の上書きは拒否する。

`squad_cli_normalize <読み取りの名前> [<CLI のバージョン>]` は、標準入力の JSON だけを検証・整形する。バージョンを省くと実物の CLI から読む。必須・条件付きの欠落と null の不一致は、すべて標準エラーに書き、出力を返さず失敗する。省略された鍵は補わず、約束外の欄を除いて返す。null 可の親が null なら、その値を維持する。

書き込みも `squad_cli_read` を通せる。応答の検証が失敗しても書き込み自体は済んでいることがあるので、投稿を繰り返さない。

見張りのテストで実物の見本からケースを作るときは、`tests/cli-fixture-lib.py` の `assert_fixture_response` に原本・ケース・その読み取りの約束を渡す。新しい鍵の追加と、必須の鍵の削除を拒否する。`allow_required_deletion=True` は、欠落時の失敗を確かめるケースだけに使う。

追加の採取として、2026-11-11 に同じ CLI のバージョンから、`repository` のないタスクの `issue-get` と `issue-metadata` を追加した。この採取の 2 応答で共通の対応表を使い、ID は `fixture-supplement-id-` で始まる。同じ採取の中の同一性・比較順を保ち、先の採取の ID とは比較しない。`CAPTURE.json` の追加した `repository` の形の件数は、保存済み見本と追加応答で数え、その範囲を `scope` に残した。

`SQUAD_CLI_TEST_KEEP_FIELDS=1` はテストだけの切り替えで、必須・条件付きの検証は行い、約束外の欄を除かずに返す。この切り替えは、ライブラリの約束のテストと GitHub の見本の採取で使う。見張りのテストは整形の後の 1 回だけを流す。欄がないか `null` のときに動作を変える読み方には、欄があって確かめが効くケースを置く。決まりは [CONTRIBUTING.md のテストを書く決まり](../../../CONTRIBUTING.md#テストを書く決まり)に従う。

## GitHub の読み取り

GitHub の見本は `GH-CAPTURE.json` に採取した CLI のバージョン、読み取りのコマンド、形ごとの件数を記録する。公開の `actions/checkout` の Dependabot の PR、`vitejs/vite` の main の規則、公開の GitHub の issue コメントから採取した。`gh-viewer` は認証した利用者の `login` だけを CLI で取り出し、公開前に置き換える。自由文・人名・login・URL・差分の本文は、鍵と型を保って匿名化する。

保存済みのコマンドで取り直すには、次を流す。読み取りだけを許し、採取した全応答が約束と合うことと、必要な見本の形を確認してから保存する。

```bash
mkdir -p tmp
jq .sources tests/fixtures/cli/GH-CAPTURE.json > tmp/gh-sources.json
python3 tests/capture-gh-fixtures.py --sources tmp/gh-sources.json
```

Multica と合わせた取り込みでは、外部で採取した応答のディレクトリを `--read-samples` に渡す。書き込みの応答は従来どおり `--write-samples` に渡す。

`integration_id` がない規則、`patch` がないファイル、commit status は今回の公開元で取れず、約束と採取記録に「見本なし」と理由を残した。commit status は `nodejs/node` の main と `facebook/react` の v16.8.0 でも空だった。テストのその形だけは、[GitHub REST API の status の仕様](https://docs.github.com/en/rest/commits/statuses#list-commit-statuses-for-a-reference)の欄を使う。規則は[ブランチの規則の仕様](https://docs.github.com/en/rest/repos/rules#get-rules-for-a-branch)、ファイルは[PR のファイルの仕様](https://docs.github.com/en/rest/pulls/pulls#list-pull-requests-files)も参照する。

`pagination` のある約束は JSON のページをすべて検証してから連結する。入れ子の `items` は、親の `when` に当たるときだけ中の配列の全要素を検証する。`gh-fixture.py` は見本へケースの値を重ね、見本にない鍵を拒否する。必須欄の欠落を試す `raw` のケースでは重ねずにそのまま返す。

PR・コメントの `user`、チェックの `app` は、[GitHub の公開 OpenAPI](https://github.com/github/rest-api-description/blob/main/descriptions/api.github.com/api.github.com.json)で null 可の必須欄である。PR の `author` も [GraphQL の仕様](https://docs.github.com/en/graphql/reference/pulls)では null 可である。公開元で null の形は取れなかったため「見本なし」と記録し、子の欄を条件付きとしてテストする。

## 使用量の読み取り

`codex-rate-limits.json` と `claude-usage.json` は、2026-11-11 に実物から採取した。バージョン・コマンド・形ごとの件数は `USAGE-CAPTURE.json` にある。Claude の使用率・リセットの表示は残し、診断・提案・作業パスを含む自由文は置き換えた。アカウントとクレジットの ID も匿名化している。

次のコマンドはモデルを呼ばず、使用量を読み直す。保存した実応答を使うときは、`codex-rate-limits.json`（JSON-RPC の `result`）と `claude-usage.json`（CLI の JSON 全体）を置いたディレクトリを `--response-dir` に渡す。

```bash
python3 tests/capture-usage-fixtures.py
```

`values.path` は、名前が値で決まるオブジェクトの各値を検証・整形する。Codex の枠の名前を保ち、その中の `primary`・`secondary` と、null でない枠の各欄を検証する。`usage-fixture.py` は実物にケースの値を重ね、枠の名前以外の新しい鍵を拒否する。非 null の `secondary` は取れなかったため「見本なし」と記録し、同じ枠の型を持つ実物の `primary` からテスト用の値を作る。Claude の表示のテストも、実物の JSON の鍵を保ち、表示の値だけを変える。
