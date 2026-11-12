- 場面の ID: 保-3
- 型: 保

## 元の出来事

実装の役が PR を返したが、PR がタスクに紐付いていなかった。リーダーは紐付けの一覧を読んで気付き、レビューを頼まずに止まった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に実装の役が書いたコメント `comment-1` です。返信するときは `--parent comment-1` を使ってください。

コメントの本文: 実装を push したという引き継ぎです。PR の URL はありますが、紐付けについては何も書かれていません。

タスクの状態は `in_progress` です。metadata には `pr_url` がありません。

## 合格の基準

1. [記録] 紐付けの一覧を読んでいる。 `判定: called: ^multica issue pull-requests issue-shop-1`
2. [記録] レビューを頼まず、`squad-pr-link` も呼ばず、ほかの役を呼んでいない。 `判定: not-called: ^squad-pr-link && not-called: ^squad-review-wait watch && not-posted: mention://agent/`
3. [記録] 人間をメンションし、タスクを `in_review` にして止まっている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
4. [採点] 人間への頼みが、タスクの画面で PR の URL を紐付けてもらう 1 つになっている。
