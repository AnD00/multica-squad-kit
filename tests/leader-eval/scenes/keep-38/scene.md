- 場面の ID: keep-38
- 型: 保

## 元の出来事

共通 4 で印を付けたあとの見直しが ✅ で返ったら、止めていた 4 回目を確認せずに出す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-note` で起きました。返信は `--parent c-note` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、ラベル `重要` が付いていて、`c-mark4` に `重要の印:` の行があります。タスクは `in_progress` です。4 回目の前に、リーダーが共通 4 で印を付け（`c-mark4`）、最上位の役に設計と PR の見直しを頼みました。最上位の役の結果（`c-prin`）は ✅ で、指摘はありません。`c-note` は `squad-review-wait report` が書いた知らせで、`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。止めていた 4 回目は、`src/cart/store.ts:addItem` への `c-rev4` の ❌ に対する依頼です。`修正の依頼:` の行は 3 つあります。

## 合格の基準

1. [記録] 返事を受けて次に進み、確認せずに `修正の依頼: 4 回目` で修正の役へ頼んでいる。 `判定: called: ^squad-review-wait proceed issue-shop-1 && called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/store\.ts:addItem 1 回目$ && posted: ^修正の依頼: 4 回目$`
2. [記録] 続行の確認の行を置かず、人間を呼ばず、in_review にせず、印を付け直していない。 `判定: not-posted: ^修正の続行の確認: && not-posted: mention://member/member1 && not-called: ^multica issue status .* in_review && not-called: ^multica issue label add && not-posted: ^重要の印:`
