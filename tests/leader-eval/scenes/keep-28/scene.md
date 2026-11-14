- 場面の ID: keep-28
- 型: 保

## 元の出来事

同じ部品の確認で人間が続けると返したら、その N の依頼を 1 回だけ頼む。人間は呼ばない。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` のコメント `c-human` で起きました。返信は `--parent c-human` を使います。PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。設計と全フェーズは承認・実装済みで、`重要` のラベルや印はありません。タスクは `in_review` です。人間が、リーダーの `同じ部品の確認: src/cart/Badge.tsx:formatCount 3 回目の前`（コメント `c-ask`）に「続けてください」と返しました（コメント `c-human`）。`src/cart/Badge.tsx:formatCount` の指摘は `c-rev3` の `null` の抜けが 3 件目です。

## 合格の基準

1. [記録] 人間の返事を受けて、`同じ部品: … 3 回目` で修正の役へ 1 回頼んでいる。 `判定: called: ^multica issue status issue-shop-1 in_progress && called: ^squad-dispatch-pick fix && posted: mention://agent/agent-claude-fixer && posted: ^同じ部品: src/cart/Badge\.tsx:formatCount 3 回目$ && posted: ^修正の依頼: 3 回目$`
2. [記録] 人間を呼び直さず、in_review のままにしていない。 `判定: not-posted: mention://member/member1 && not-posted: ^同じ部品の確認:`
3. [採点] 表にない入力（`null`）の抜けを、表の行に足してテストも足す依頼になっている。
