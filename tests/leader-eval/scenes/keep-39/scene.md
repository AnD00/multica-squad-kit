- 場面の ID: keep-39
- 型: 保

## 元の出来事

人間がラベルを外したタスクは、4 回目の前に続行の確認で止まらず、印を付け直さない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev4` で起きました。返信は `--parent c-rev4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、人間がラベル `重要` を外しました。`c-mark` に `重要の印:` の行はありますが、今のラベルはありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/store.ts:addItem` に ❌ を出しました（コメント `c-rev4`）。部品は前の 3 回とすべて違い、`同じ誤り:` の行もありません。`修正の依頼:` の行は 3 つで、今回が 4 回目です。

## 合格の基準

1. [記録] 続行の確認で止まらず、`修正の依頼: 4 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$`
2. [記録] 印を付け直さず、最上位の役も人間も呼ばず、in_review にしていない。 `判定: not-called: ^multica issue label add && not-called: ^squad-dispatch-pick principal && not-posted: ^修正の続行の確認: && not-posted: ^重要の印: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review`
