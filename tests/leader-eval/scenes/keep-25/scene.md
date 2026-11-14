- 場面の ID: keep-25
- 型: 保

## 元の出来事

同じ部品に別の入力の ❌ が 2 回続いたとき、リーダーは次の依頼を種類単位にして頼み、人間を呼ばない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-rev2` で起きました。返信は `--parent c-rev2` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_progress` です。コードレビューの役が、`src/cart/Badge.tsx:formatCount` に ❌ を出しました（コメント `c-rev2`）。前に頼んだ修正（`c-req1`）で直した入力（負の数）とは別の入力（小数）の抜けです。`同じ誤り:` の行はなく、`c-req1` に `同じ部品: src/cart/Badge.tsx:formatCount 1 回目` の行があります。修正の依頼は今回が 2 回目です。

## 合格の基準

1. [記録] 修正の役へ、同じ部品の 2 回目と種類単位の範囲を添えて頼んでいる。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 2 回目$ && posted: ^頼む範囲: 種類単位（src/cart/Badge\.tsx:formatCount）$ && posted: ^修正の依頼: 2 回目$`
2. [記録] 人間を呼ばず、同じ誤りの行も置かず、in_review にしていない。 `判定: not-posted: mention://member/member1 && not-posted: ^同じ誤り: && not-called: ^multica issue status .* in_review`
3. [採点] 依頼の文が、その部品が受ける入力の種類と規則を表にして扱いを決めること、表の行ごとにテストを置くこと、表の場所を結果に書くこと、指摘された 2 件の入力（負の数と小数）を表の行に含めることを頼んでいる。1 件ずつの入力の直しだけを頼んでいない。
