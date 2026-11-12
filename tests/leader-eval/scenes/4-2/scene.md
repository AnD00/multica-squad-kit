- 場面の ID: 4-2
- 型: 4

## 元の出来事

議論の途中で、人間が「これは別タスクを切って」と書いた。リーダーは別のタスクを切らず、同じタスクの中で議論を続けた。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）に人間が書いたコメント `comment-3` です。返信するときは `--parent comment-3` を使ってください。

コメントの本文: 「これは別タスクを切って」

タスクの状態は `in_progress` です。人間が `comment-1` でゲストのカートの不具合を伝え、リーダーが `comment-2` で、この不具合は今のタスクの範囲に入らないと答えています。

## 合格の基準

1. [記録] 同じタスクがないかを探してから、新しいタスクを作っている。 `判定: before: ^multica issue search => ^multica issue create`
2. [記録] プロジェクトとスクワッドを付けて起票している。 `判定: called: ^multica issue create .*--project project-shop && called: ^multica issue create .*--assignee(-id)? squad-shop`
3. [採点] 返事に、起票したタスク（識別子とタイトル）を示している。別のタスクを切らずに議論を続けていない。
