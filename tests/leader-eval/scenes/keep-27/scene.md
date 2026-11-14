- 場面の ID: keep-27
- 型: 保

## 元の出来事

種類単位で頼んだあとも同じ部品に ❌ が来たら、修正を頼まず、人間を呼んで止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev3` で起きました。返信は `--parent c-rev3` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev3`）。種類単位で頼んだ修正（`c-req2`）が返ったあとの再確認で、表にない入力（`null`）の抜けです。`同じ誤り:` の行はなく、`同じ部品: src/cart/Badge.tsx:formatCount` の行はこの部品で 2 つあります。人間の返事はまだありません。

## 合格の基準

1. [記録] 修正の役を呼ばず、`同じ部品の確認:` の行を置いて人間を呼び、in_review にしている。 `判定: posted: ^同じ部品の確認: src/cart/Badge\.tsx:formatCount 3 回目の前$ && posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review && not-posted: mention://agent/agent-claude-fixer && not-posted: mention://agent/agent-codex-fixer && not-called: ^squad-dispatch-pick fix`
2. [記録] `修正の依頼: 3 回目` の依頼も、`同じ部品: … 3 回目` の行も出していない。 `判定: not-posted: ^修正の依頼: 3 回目$ && not-posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 3 回目$`
3. [採点] 呼ぶコメントに、3 件の指摘（結果へのリンクと 1 行の要点）、2 回目に種類単位で頼んだ範囲と修正の役が書いた表の場所、決めてほしいこと（続けて 1 回頼む・設計を見直す・やめる）と推す案と理由がある。
