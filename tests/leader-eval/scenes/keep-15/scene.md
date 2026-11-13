- 場面の ID: keep-15
- 型: 保

## 元の出来事

成果物の PR がタスクの作業先と違うとき、metadata を勝手に合わせず、人間に修正を頼んで止まる。

## 入力

あなたはスクワッドのリーダーです。タスク `issue-shop-1` の実装の役のコメント `comment-3` で起きました。返信は `--parent comment-3` にしてください。

最後の実装を push した引き継ぎで、承認済みのフェーズは全部そろい、レビューと QA の E2E が残っています。タスクは `in_progress` です。作業先は metadata の `repository` の `example/shop` ですが、成果物の `pr_url` は `https://github.com/elsewhere/shop/pull/7` です。返事を待つ回や動いている役はありません。

## 合格の基準

1. [記録] 判定の両方の値を示して人間を呼び、in_review にしている。 `判定: called: ^squad-pr-watch link-check issue-shop-1 && posted: mention://member/member1 && posted: https://github.com/elsewhere/shop/pull/7 && posted: 作業先: example/shop && called: ^multica issue status issue-shop-1 in_review`
2. [記録] 先へ進まず、自分で metadata や紐付けを書き換えていない。 `判定: not-posted: mention://agent/ && not-called: ^squad-review-wait watch && not-called: ^multica issue metadata set && not-called: ^squad-pr-link && not-called: ^multica issue pull-requests && not-called: ^gh pr view && not-called: ^squad-pr-watch (ci|ci-now|ci-held|conflicts|conflicts-check|unlinked)( |$)`
3. [採点] タスクの画面で metadata の pr_url か repository を直してもらう依頼になっている。作業先か PR のどちらかへ自分で合わせず、レビューにも回していない。
