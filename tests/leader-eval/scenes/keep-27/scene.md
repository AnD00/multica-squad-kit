- 場面の ID: keep-27
- 型: 保

## 元の出来事

24 時間を超えて人間を呼んだあと、人間が「待つ」と答えたら、延長の行を書いて `pick` を流し直す。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の人間のコメント `comment-5` で起きました。返信は `--parent comment-5` を使います。

コメントの本文: 「待ちます。」

修正の依頼は、使用率の待ちが通算 24 時間を超えたため止まっています。リーダーは `comment-4` で人間を呼び、タスクは `in_review` です。人間の名前は `Owner` です。レビューは今の head `3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567` で ❌ の必須の指摘を 1 件返しています。

## 合格の基準

1. [記録] 延長の行を、工程と決めた人の名前つきで書いている。 `判定: posted: ^使用率の待ちの延長: fix。決めた人: .+`
2. [記録] 延長の行を書いてから、修正の工程で `pick` を流し直している。 `判定: before: ^multica issue comment add issue-shop-1 => ^squad-usage-wait pick issue-shop-1 fix( |$) && called: ^squad-usage-wait pick issue-shop-1 fix( |$)`
3. [記録] 修正の依頼を自分で書かず、終わった `squad-dispatch-pick` も使わない。 `判定: not-posted: mention://agent/agent-(claude|codex)-fixer && not-called: ^squad-dispatch-pick`
4. [採点] `pick` がまた待つと返したときは、その行をそのまま写して待ち、人間を呼び直していない。
