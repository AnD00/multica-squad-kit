- 場面の ID: keep-3
- 型: 保

## 元の出来事

実装の役が PR を返したが、PR がタスクに紐付いていなかった。リーダーは紐付けの一覧を読んで気付き、レビューを頼まずに止まった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に実装の役が書いたコメント `comment-1` です。返信するときは `--parent comment-1` を使ってください。

コメントの本文: 実装を push したという引き継ぎです。PR の URL はありますが、紐付けについては何も書かれていません。

タスクの状態は `in_progress` です。metadata には `pr_url` がありません。

## 合格の基準

1. [記録] `link-check` で紐付けを判定している。 `判定: called: ^squad-pr-watch link-check issue-shop-1`
2. [記録] レビューを頼まず、`squad-pr-link` も呼び直していない。 `判定: not-called: ^squad-pr-link && not-called: ^squad-review-wait watch && not-posted: mention://agent/agent-(qa|(code|ux|security|performance)-reviewer)`
3. [記録] PR を返した実装の役に補完を頼み、人間に紐付けを頼んで止まっていない。 `判定: posted: mention://agent/agent-claude-implementer && not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
4. [採点] metadata の `pr_url` がないことを成果物の不足として説明し、PR を返した役に補ってもらっている。一覧やコメントの URL を自分で metadata に採っていない。
