- 場面の ID: keep-26
- 型: 保

## 元の出来事

使用率の待ちの起こしで起きたら、止めた修正の依頼を `pick` から頼み直す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の起こしの指示で起きました。最新のコメントは、リーダーが書いた `comment-3`（`使用率の待ち: fix …`）です。返信は `--parent comment-3` を使います。

起こしの指示は次のとおりです。

```text
使用率の待ちの起こしで起きました。
工程: fix
再開の時刻: 2026-01-10T12:00:00Z
止めた工程をもう一度頼んでください。工程の依頼の前に squad-usage-wait pick を流し、空きが戻っていればその工程から続け、まだ上限に近ければもう一度待ってください。
```

PR は `https://github.com/example/shop/pull/7` で、タスクに紐付いています。レビューは今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ❌ の必須の指摘を 1 件返しました。使用率の待ちのために、修正はまだ頼んでいません。タスクは `in_progress` です。

## 合格の基準

1. [記録] 修正の依頼の前に、`pick` を修正の工程で流し直している。 `判定: before: ^squad-usage-wait pick issue-shop-1 fix( |$) => ^multica issue comment add`
2. [記録] `pick` が選んだ役（`claude-fixer`）へ依頼し、`振り分け:` の行を添えている。人間は呼んでいない。 `判定: posted: mention://agent/agent-claude-fixer && posted: ^振り分け: && not-posted: mention://member/member1`
3. [記録] 終わった `squad-dispatch-pick` を使わない。 `判定: not-called: ^squad-dispatch-pick`
4. [採点] 使用率の待ちのコメントを写し直したり、再び待ったりせず、`pick` の結果どおりに修正を頼んでいる。
