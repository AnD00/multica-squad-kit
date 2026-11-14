- 場面の ID: keep-26
- 型: 保

## 元の出来事

種類単位で頼んだ修正が返ったとき、再確認の依頼に、その部品を指摘したレビューの役へ向けた `列挙を頼む部品:` の行を置く。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-fix2` で起きました。返信は `--parent c-fix2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。修正の役が、種類単位で頼んだ `src/cart/Badge.tsx:formatCount` の直し（`c-req2`、`頼む範囲: 種類単位` の行あり）を push したと返しました（コメント `c-fix2`）。入力の種類の表をテストに沿わせたと書かれています。直したコミットは `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で、レビューを頼み直す番です。

## 合格の基準

1. [記録] 修正を指摘したコードレビューの役へ、列挙を頼む部品を添えて再確認を頼んでいる。 `判定: called: ^squad-review-wait watch issue-shop-1 c-fix2 agent-code-reviewer && posted: mention://agent/agent-code-reviewer && posted: ^列挙を頼む部品: src/cart/Badge\.tsx:formatCount$`
2. [記録] 人間を呼ばず、修正の役へ回し直していない。 `判定: not-posted: mention://member/member1 && not-posted: mention://agent/agent-claude-fixer && not-called: ^multica issue status .* in_review`
