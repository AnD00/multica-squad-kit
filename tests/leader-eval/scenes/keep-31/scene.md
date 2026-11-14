- 場面の ID: keep-31
- 型: 保

## 元の出来事

返事がそろった知らせに、`コンフリクト:` の理由で `次の依頼を決められません:` があるとき、リーダーがコンフリクトの手順で修正の役へ解消を頼む。

## 入力

あなたはスクワッドのリーダーとして起こされました。きっかけは、タスク `issue-shop-1`（SHOP-1「カートに商品数を出す」）で、コードレビューの役が書いたコメント `comment-6` です。返信するときは `--parent comment-6` を使ってください。

コメントの本文は次のとおりです。`squad-review-wait report` が、全員の返事がそろったときに書く知らせです。

```text
返事がそろいました。
次の依頼を決められません: コンフリクト: CONFLICTING head: 3f9a2c1d4b5e6f708192a3b4c5d6e7f801234567
```

タスクは `in_progress` です。レビューは今の head で ✅ を返しています。この回に返事の待ちは残っておらず、`squad-review-wait proceed` は `返事の待ち: 次に進む` を返します。`squad-pr-watch conflicts-check` も今は `CONFLICTING` を返し、ほかの役は動いていません。解消を頼むのは今回が最初です。

## 合格の基準

1. [記録] 次へ進む前に `proceed` を流し、コンフリクトの状態を `conflicts-check` で読み直したうえで、修正の役を `pick` で選んでいる。 `判定: before: ^squad-review-wait proceed issue-shop-1 comment-6 => ^squad-usage-wait pick issue-shop-1 fix && called: ^squad-pr-watch conflicts-check issue-shop-1 && before: ^squad-pr-watch conflicts-check issue-shop-1 => ^squad-usage-wait pick issue-shop-1 fix`
2. [記録] `pick` が選んだ役（`claude-fixer`）へ、コンフリクトの行を添えて解消を頼んでいる。 `判定: posted: mention://agent/agent-claude-fixer && posted: コンフリクト: CONFLICTING head: 3f9a2c1 && posted: ^振り分け:`
3. [記録] マージを頼まず、人間も呼ばず、レビューを回し直していない。 `判定: not-posted: mention://member/member1 && not-posted: ^マージの依頼 && not-called: ^squad-review-next request && not-called: ^squad-dispatch-pick`
4. [採点] `decide` の理由（コンフリクト）を読み、人間を呼ばずに修正の役へ解消を頼んでいる。解消の中で設計や挙動を変えない前提を添えている。
