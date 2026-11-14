- 場面の ID: keep-30
- 型: 保

## 元の出来事

同じ誤りが 2 回続いたら、種類単位の依頼にせず、原因と手当てを添えて人間を呼んで止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev3` で起きました。返信は `--parent c-rev3` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev3`）。同じ誤りを頼み直した修正（`c-req2`、`同じ誤り: src/cart/Badge.tsx:formatCount 1 回目` の行あり）のあとも、負の数の入力の抜けが、そのままです。

## 合格の基準

1. [記録] 修正の役を呼ばず、人間を呼んで in_review にしている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-dispatch-pick fix`
2. [記録] 種類単位の依頼も、同じ誤りの 2 回目の依頼も出していない。 `判定: not-posted: ^頼む範囲: && not-posted: ^同じ誤り: src/cart/Badge\.tsx:formatCount 2 回目$ && not-posted: ^修正の依頼: 3 回目$`
3. [採点] 呼ぶコメントに、原因（確認したことと推測を分けて）と、再発を防ぐ手当て（手順の直し方か、指示の改善のタスクの起票）がある。指示の実物を自分で変えていない。
