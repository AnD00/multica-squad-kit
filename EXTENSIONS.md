# プロジェクトの拡張

セットアップの最初の質問でディレクトリを指定する。原本の役の指示、モデル、共通スキル、関所は置き換えられない。指示は末尾への追記、スキルと MCP は追加だけを行う。

```text
extension/
  kit-version
  additions.json
  instructions/qa.md
  agents/helper.md
  autopilots.md
  monitor/squad-custom-check
  skills/verify/SKILL.md
  skills/verify/scripts/check.sh
```

`kit-version` は使うタグ（初版なら `v1.0.0`）を一行で書く。これ以外は必要なものだけ置く。原本の `VERSION` と違うと、サーバーの設定やホストへの配置を始める前に止まる。

`agents` は原本にない役を、`common/agents/FORMAT` と同じ形式で置く。ファイル名を役のキーにし、名前を `{{project_key}}-helper-{{member_key}}` の形にする。追加した役は毎回登録し、指示を流し直す。モデルの条件分岐なども原本と同じ形式を使える。

`additions.json` は役ごとの追記である。次のキー以外は拒否する。

```json
{
  "qa": {
    "skills": ["browser-check"],
    "max_concurrent_tasks": 2,
    "mcp_config": {"mcpServers": {"browser": {"command": "browser-tool"}}},
    "instructions_file": "instructions/qa.md"
  }
}
```

追加するスキルにはプロジェクトの接頭辞を付けない。`skills/browser-check/SKILL.md` の `name` は `browser-check` にし、登録時にプロジェクトの接頭辞を付ける。共通のスキルを外す指定は受け付けない。MCP の設定は役ごとに足す。追記のファイルでも、原本と同じ値の差し込みを使える。

`autopilots.md` は原本と同じ節と条件の印で書く。名前にプロジェクトとメンバーの値を含め、リポジトリごとの節は 空白と `{{repository}}` で終える。`monitor` は原本と違う `squad-*` の名前で、`# multica-squad-kit-managed` の印を付ける。

プロジェクトのスキルは、流し直すたびに手元の内容と合わせる。本文、補助ファイルの追加・変更・削除を行い、スキル ID と割り当てを保つ。URL の取得を使わず、共通スキルの API の回数にも加算しない。更新できない人には表示して、ほかの登録を続ける。

拡張から消した役はスクワッドから外し、エージェントは残す。消したオートパイロットは停止し、履歴を残す。削除は人間が判断する。前の管理対象の名前は、回答の保存先と同じディレクトリの、プロジェクトとメンバーごとの管理ファイルに保存する。管理していない名前の設定は変えない。
