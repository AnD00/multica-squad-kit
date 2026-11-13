- 場面の ID: keep-5
- 型: 保

## 元の出来事

ラベル `重要` のタスクで設計の役が設計を返したとき、リーダーは人間ではなく、最上位の役に設計の見直しを頼んだ。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「ログインの有効期限を延ばす」）に設計の役が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 設計の draft PR を作ったという引き継ぎです。PR は紐付いています。

タスクの状態は `in_progress` で、ラベル `重要` が付いています。`comment-2` に `重要の印:` の行があります。

## 合格の基準

1. [記録] 使用率から最上位の役を選んでいる。 `判定: called: ^squad-dispatch-pick principal`
2. [記録] 見直しの依頼のコメントを書く前に、返事の待ちの見張りを入れている。 `判定: before: ^squad-review-wait watch issue-shop-1 \S+ agent-claude-principal => issue comment add`
3. [記録] 依頼に、見直しの種類、返事を待つ役、確認するコミットの行がある。 `判定: posted: ^見直しの種類: 設計の見直し && posted: ^返事を待つ役: .*mention://agent/agent-claude-principal && posted: ^確認するコミット: [0-9a-f]{40}`
4. [記録] 最上位の役の返事の前に、人間を呼ばず、タスクを `in_review` にしていない。 `判定: not-posted: mention://member/member1 && not-called: ^multica issue status issue-shop-1 in_review`
