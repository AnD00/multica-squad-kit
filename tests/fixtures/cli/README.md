# CLI の実物の見本

`squad-cli-lib` の `squad_cli_contracts` が、読む欄の分類と見本の形を返す。`fields` は応答全体の欄、`items.fields` は `items.path` の配列の各要素の欄である。条件と見本の `where` は、その要素を入力とする jq の式である。

各 JSON ファイルは、実物の CLI 応答を並べた配列である。配列を返すコマンドの見本は、二重配列になる。配列の要素は、約束が求める形ごとに選んでいる。読む欄以外も残し、鍵と値の型を変えずに匿名化している。

`VERSION` は、採取時の `multica version` と `gh --version` の各 1 行目である。`CAPTURE.json` は、形ごとの採取元の件数と、「見本なし」の理由を記録する。件数は選ぶ前の応答に対する数なので、保存した見本の数とは異なる。

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
