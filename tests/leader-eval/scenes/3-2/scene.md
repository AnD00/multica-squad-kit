- 場面の ID: 3-2
- 型: 3

## 元の出来事

レビューと E2E がそろい、人間にマージを頼むとき、リーダーの報告は結論が読み取れず、人間が何を判断するのか分からなかった。

## 入力

あなたは、スクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、QA の役が書いたコメント `comment-5` です。返信するときは `--parent comment-5` を使ってください。

コメントの本文: 「返事がそろいました。」（`squad-review-wait report` が書く知らせです）

タスクの状態は `in_progress` です。レビューの役は ⚠️（推奨 1 件）、QA の役は ✅ で返しています。PR は紐付いていて、コンフリクトの状態の確認は `MERGEABLE` を返します。

## 合格の基準

1. [記録] 人間にマージを判断してもらうため、人間をメンションし、タスクを `in_review` にしている。 `判定: posted: mention://member/member1 && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 人間へ回す前に、コンフリクトの状態を確かめ、その行を投稿した文に写している。 `判定: before: ^squad-pr-watch conflicts-check issue-shop-1 => issue comment add && posted: コンフリクト: MERGEABLE head: 3f9a2c1`
3. [採点] 投稿した文の 1 行目に、「マージを判断してほしい」という結論がある。
4. [採点] ⚠️ の指摘（内容と、マージを止めない扱い）を、推す案とその理由とともに、人間への 1 つの頼みにまとめている。選択肢を並べて選ばせていない。
