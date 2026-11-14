- 場面の ID: keep-34
- 型: 保

## 元の出来事

続行の確認に人間が続けると返したら、確認せずに 4 回目の依頼を出す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-ok4` で起きました。返信は `--parent c-ok4` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark` に `重要の印:` の行があります。タスクは `in_review` です。リーダーが `c-conf4` に `修正の続行の確認: 4 回目の前` を置いて人間を呼び、人間が「続けてください」と返しました（コメント `c-ok4`）。止めた 4 回目は、`src/cart/store.ts:addItem` への `c-rev4` の ❌（同じ商品を足しても数が増えない）に対する依頼です。部品は前の 3 回とすべて違います。

## 合格の基準

1. [記録] 人間の返事を受けて、`修正の依頼: 4 回目` で修正の役へ 1 回頼んでいる。 `判定: called: ^multica issue status issue-shop-1 in_progress && called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$`
2. [記録] 人間を呼び直さず、続行の確認の行を置き直さず、in_review のままにしていない。 `判定: not-posted: mention://member/member1 && not-posted: ^修正の続行の確認:`
3. [採点] 依頼の文が、`c-rev4` の指摘（同じ商品を足しても数が増えない）の修正を頼んでいる。
