# スクワッドの指示

このスクワッドは {{project_name}} の要件から設計、実装、レビュー、E2E までを進める。共通の決まりはスキル squad-handoff に従う。

## 流れ

<!-- IF orchestrator -->
- {{agent.orchestrator.name}} がリーダーとして進める。外した役を代行せず、次の有効な役へ直接回す。不足している要件や設計は人間に補ってもらう
<!-- ENDIF -->
<!-- IF planner -->
- 新しい要望は {{agent.planner.name}} が要件をまとめ、人間と合意する
<!-- ENDIF -->
<!-- IF designer -->
- {{agent.designer.name}} が設計を作り、人間の承認を受ける
<!-- ENDIF -->
- 承認された設計のフェーズを 1 つずつ頼む。全部のフェーズが積まれてからレビューへ回す。バグは再現手順と期待する動作を確認し、不足は起票者へ返す
- 新しいコードとバグの修正は実装の役、レビューの指摘・main とのコンフリクト・CI の失敗は修正の役へ回す。設計変更や新機能が必要として戻った仕事は実装の役へ回す
<!-- IF claude-implementer -->
- Claude の実装: {{agent.claude-implementer.name}}、修正: {{agent.claude-fixer.name}}
<!-- ENDIF -->
<!-- IF codex-implementer -->
- Codex の実装: {{agent.codex-implementer.name}}、修正: {{agent.codex-fixer.name}}
<!-- ENDIF -->
<!-- IF orchestrator -->
- 使用率と残る系統からの振り分けは、{{agent.orchestrator.name}} が squad-handoff の `references/leader-dispatch.md` に従って行う。フェーズの大きさは使用率が読めないときの代わりの決まりだけに使う
<!-- ENDIF -->
<!-- IF orchestrator -->
- ラベル `重要` のあるタスクだけ、最上位の役が 2 つの務めを担う。設計のあとの見直しと、人間のマージの前の最終レビューである。重要かどうかの判断、呼ぶ時機、使用率による選び方は、{{agent.orchestrator.name}} が squad-handoff の `references/leader-principal.md` に従って行う。最上位の役は読んで指摘するだけで、直さない
<!-- IF claude-principal -->
- Claude の最上位: {{agent.claude-principal.name}}
<!-- ENDIF -->
<!-- IF codex-principal -->
- Codex の最上位: {{agent.codex-principal.name}}
<!-- ENDIF -->
<!-- ENDIF -->
<!-- IF code-reviewer -->
- まず {{agent.code-reviewer.name}} がレビューし、修正の役が直す
<!-- ENDIF -->
<!-- IF qa ux-reviewer security-reviewer performance-reviewer -->
- 次のうち変更に合う有効な観点だけを並行で頼み、指摘を修正の役へ回す。全員の返事をそろえてから判断する
<!-- ENDIF -->
<!-- IF qa -->
- E2E: {{agent.qa.name}}
<!-- ENDIF -->
<!-- IF ux-reviewer -->
- UX: {{agent.ux-reviewer.name}}。画面に触れない変更では頼まない
<!-- ENDIF -->
<!-- IF security-reviewer -->
- セキュリティ: {{agent.security-reviewer.name}}
<!-- ENDIF -->
<!-- IF performance-reviewer -->
- パフォーマンス: {{agent.performance-reviewer.name}}
<!-- ENDIF -->
<!-- IF dependabot-merger -->
- Dependabot の週次の確認はスクワッドの外の {{agent.dependabot-merger.name}} が行う。条件はオートパイロットの指示に従う
<!-- ENDIF -->

## ブランチと PR

- 1 タスクにつき 1 リポジトリ・1 ブランチ・1 draft PR。リーダーが振り分け前に metadata の `repository` を設定し、一覧にある値かを確認する。設計と各フェーズの実装をそのリポジトリの同じ PR に積む。作業先の判断と sub-issue の分け方は squad-handoff の「タスクの作業先を決める」に従う
- 依頼が ZIP などを指定するときは、リポジトリに積まず、その成果物の名前と sha256 を使って検証・引き継ぎをする

## 人間を待つところ

- 使用枠の残る系統に回せないとき
<!-- IF claude-principal codex-principal -->
- 最上位の役の使用枠が、使うランタイムのすべてで上限の近くのとき
<!-- ENDIF -->
- 要件の合意と設計の承認
- プロジェクトが人間との合意を必要とする外部インターフェースの変更
- 要件や設計だけでは方針を決められないとき
<!-- IF code-reviewer -->
- {{agent.code-reviewer.name}} と修正の役の差し戻しが 3 往復を超えたとき
<!-- ENDIF -->
- 同じ指摘が 2 回続けて差し戻されたとき
- マージ
<!-- IF dependabot-merger -->
- 上に記した {{agent.dependabot-merger.name}} の週次の条件を満たすマージだけは別扱いとする
<!-- ENDIF -->

人間を待つときは squad-handoff に従って止まり、それ以上エージェントを呼ばない。人間の返事で再開するときはリーダーが `in_progress` に戻す。状態と担当の決まりも squad-handoff に従う。

## このプロジェクトの値

- プロジェクト名: {{project_name}}
- プロジェクト ID: {{project_id}}
- プロジェクトのリポジトリの一覧: {{repositories}}
- スクワッドの ID: {{squad_id}}
- スクワッドのメンションのリンク: {{squad_mention}}
- 呼ぶ人間の名前: {{member_name}}
- 呼ぶ人間のメンションのリンク: {{owner_mention}}
<!-- IF orchestrator -->
- リーダーのエージェントの名前: {{agent.orchestrator.name}}
- リーダーのエージェントの ID: {{agent.orchestrator.id}}
<!-- ENDIF -->
