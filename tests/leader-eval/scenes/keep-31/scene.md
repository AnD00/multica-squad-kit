- 場面の ID: keep-31
- 型: 保

## 元の出来事

部品が違う ❌ が続いたときは、同じ誤りの決まりでも止めず、指摘ごとの依頼にする。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev2` で起きました。返信は `--parent c-rev2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:CartIcon` に ❌ を出しました（コメント `c-rev2`）。前に頼んだ修正（`c-req1`）の部品は `src/cart/Badge.tsx:formatCount` で、部品が違います。`同じ誤り:` の行はなく、`同じ部品: src/cart/Badge.tsx:formatCount 1 回目` の行が 1 つあります。修正の依頼は今回が 2 回目です。

## 合格の基準

1. [記録] 部品が違う指摘として、個別に頼んでいる。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.tsx:CartIcon 1 回目$ && posted: ^修正の依頼: 2 回目$`
2. [記録] 種類単位にせず、同じ誤りの行も置かず、人間を呼んでいない。 `判定: not-posted: ^頼む範囲: && not-posted: ^同じ誤り: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
