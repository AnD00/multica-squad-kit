# アクションの勧告の実応答

公開の GitHub API から取得した応答を保存する。採取の時刻、CLI のバージョン、コマンドは `CAPTURE.json` にある。JSON は `--paginate --slurp` の出力なので、ページごとの配列になっている。説明の自由文とクレジットのユーザーは、鍵と型を保って匿名化している。勧告の ID・要約・対象・範囲と、SHA の実応答はそのまま残す。

`vulnerable.json` は `actions/download-artifact@4.1.2` の勧告、`fixed.json` は修正済みの 4.1.3 の空の応答である。`mixed.json` は両方をまとめて照会した応答で、同じ勧告が返る。テストはこの応答とバージョン範囲を使い、脆弱なバージョンの行だけが検出されることを確認する。

取り直すときは、原本のルートで次を流す。`CAPTURE.json` の採取の時刻と CLI のバージョンも更新する。

```bash
python3 -I - <<'PY'
import json
import subprocess
from pathlib import Path

root = Path('tests/fixtures/action-advisories')
for name, command in json.loads((root / 'CAPTURE.json').read_text())['commands'].items():
    result = subprocess.run(command, check=True, capture_output=True)
    if name.endswith('.json'):
        pages = json.loads(result.stdout)
        for page in pages:
            for advisory in page:
                advisory['description'] = '公開された勧告の説明（匿名化済み）'
                for credit in advisory['credits']:
                    for key, value in credit['user'].items():
                        if key == 'id':
                            credit['user'][key] = 1
                        elif key in ('login', 'node_id'):
                            credit['user'][key] = 'fixture-author'
                        elif 'url' in key and value:
                            credit['user'][key] = 'https://example.invalid/author'
        (root / name).write_text(json.dumps(pages, ensure_ascii=False, indent=2) + '\n')
    else:
        (root / name).write_bytes(result.stdout)
PY
```

勧告の照会は [GitHub の API の仕様](https://docs.github.com/en/rest/security-advisories/global-advisories)に従う。まとめた応答から行を対応付ける際の範囲の比較は、[バージョン範囲の仕様](https://docs.github.com/en/code-security/tutorials/fix-reported-vulnerabilities/write-security-advisories#affected-versions)に従う。検査は安定したバージョンの X.Y.Z を対象にし、読めない範囲や応答は検査不能として終了コード 2 にする。
