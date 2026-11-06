# multica-squad-kit

Multica のスクワッドを、プロジェクトごとに導入して更新するための原本。

初版で確かめた範囲は、macOS、標準の bash・zsh、Claude Code と Codex の両方のランタイム、GitHub、日本語での利用です。WSL を使わない Windows、英語、GitHub 以外は対象外です。Linux（WSL を含む）と、片方だけのランタイムへの対応は次の版で追加します。

公開リポジトリを clone してタグを取り出し、`bash setup.sh` を実行します。[導入と更新](manual.md)、[拡張の形式](EXTENSIONS.md)、[変更の進め方](CONTRIBUTING.md) を参照してください。

ZIP で導入済みの場合は、人がその関所・見張り・シェル設定と、対象プロジェクトの保存済み回答を消してから入れ直してください。回答の既定の保存先は `~/.multica-agent/template/answers/<workspace-id>/<project-key>.json` です。対象の確認と手順は [導入済みの配布物を入れ直す](manual.md#導入済みの配布物を入れ直す) を参照してください。
