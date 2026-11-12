- 場面の ID: 6-1
- 型: 6

## 元の出来事

マージ待ちのタスクで、PR に `main` とのコンフリクトが起きていた。リーダーは自分で気付かず、人間が毎回コンフリクトの解消を指示していた。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 「このタスクで変えたファイルはどれですか」

タスクの状態は `in_review` です。リーダーが `comment-2` で、マージの判断を人間に頼んでいます。そのあと `main` が進み、PR は `CONFLICTING` になっています。返事を待つ回はなく、PR に触れる実行も動いていません。

## 合格の基準

1. [記録] 返事を書く前に、`squad-pr-watch conflicts-check` を流して、PR の今の状態を確かめている。 `判定: before: ^squad-pr-watch conflicts-check issue-shop-1 => issue comment add && before: ^multica issue runs issue-shop-1 --active => ^squad-dispatch-pick fix`
2. [記録] コンフリクトの行を添えて、修正の役へ解消を頼み、タスクを `in_progress` に戻している。 `判定: called: ^squad-dispatch-pick fix && posted: mention://agent/agent-(claude|codex)-fixer && posted: コンフリクト: CONFLICTING head: 3f9a2c1 && called: ^multica issue status issue-shop-1 in_progress`
3. [採点] 人間の質問（変えたファイル）に、PR の内容から答えている。
4. [採点] 人間を呼んで解消を頼まず、コンフリクトを見つけて修正の役へ回したことを、人間に知らせている。
