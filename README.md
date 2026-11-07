# multica-squad-kit

Multica のスクワッドを、プロジェクトごとに導入して更新するための原本。

セットアップは導入の状態を読み直し、Dependabot の役を残したときは Webhook を登録して配信を確かめます。人間に残る作業は対象のプロジェクトに issue として起票し、確認・登録・起票の結果を完了時に表示します。イベントフィルターやひな形の記入は、起票された issue に従って進めてください。

対応する範囲は、macOS と Linux（WSL 2 を含む）、標準の bash・zsh、Claude Code と Codex の一方または両方、GitHub、日本語での利用です。WSL 1、WSL を使わない Windows、英語、GitHub 以外は対象外です。

自動テストで確かめる範囲は、macOS と Ubuntu 24.04 のセットアップ・再実行、導入の確認、Webhook の登録・配信確認、起票、関所の許可と拒否、見張り、シェル設定と時刻の読み取りです。CI でも両 OS に同じテストを流します。外部 CLI とサーバーはスタブを使います。認証済みのデーモン・ランタイムの実行と、WSL 実機の動作は未確認です。WSL 2 は Linux との互換性と各ツールの公式対応に基づく対応です。

公開リポジトリを clone してタグを取り出し、`bash setup.sh` を実行します。[導入と更新](manual.md)、[拡張の形式](EXTENSIONS.md)、[変更の進め方](CONTRIBUTING.md) を参照してください。

ZIP で導入済みの場合は、人がその関所・見張り・シェル設定と、対象プロジェクトの保存済み回答を消してから入れ直してください。回答の既定の保存先は `~/.multica-agent/template/answers/<workspace-id>/<project-key>.json` です。対象の確認と手順は [導入済みの配布物を入れ直す](manual.md#導入済みの配布物を入れ直す) を参照してください。
