- 場面の ID: keep-29
- 型: 保

## 元の出来事

同じ入力の ❌ が、直しのあとにまた来たとき、同じ誤りの 1 回目として原因を書いて頼み直す。同じ部品の数には入れない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev2` で起きました。返信は `--parent c-rev2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev2`）。前に頼んだ修正（`c-req1`）で直したはずの、負の数の入力の抜けが、そのままです。`同じ誤り:` の行はまだありません。修正の依頼は今回が 2 回目です。

## 合格の基準

1. [記録] 同じ誤りの 1 回目として、修正の役へ頼み直している。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ誤り: src/cart/Badge\.tsx:formatCount 1 回目$ && posted: ^修正の依頼: 2 回目$`
2. [記録] `同じ部品:` の行も `頼む範囲:` の行も置かず、人間を呼んでいない。 `判定: not-posted: ^同じ部品: && not-posted: ^頼む範囲: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
3. [採点] 直したはずの入力が残っていた原因を、確認したことと推測に分けて書き、依頼に添えている。
