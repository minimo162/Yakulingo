# YakuLingo（ECM資料英訳ツール）

Microsoft 365 Copilot の画面を Edge DevTools Protocol（CDP）で操作し、テキストおよび Excel/CSV 資料を翻訳するローカル業務ツールです。

このリポジトリは、共有フォルダ `ECM資料英訳ツール/` に配置される配布物一式をそのままの構成で管理します。

## 構成

```
.
├── YakuLingo起動.vbs      # ルートのポインタ起動用。current.txt を読んで該当版を起動する
├── current.txt            # 現行バージョン名（1行）。切替はこのファイルの書き換えのみ
├── 共有フォルダ配置手順.md  # 共有フォルダへの配置・更新・ロールバック手順
├── _docs/                 # 修正指示書・実装記録（バージョン横断で集約）
├── V91.59/                # 現行版
│   ├── YakuLingo起動.vbs
│   └── app/
└── V91.58/                # N-1（1世代前）
    ├── YakuLingo起動.vbs
    └── app/
```

`app/` の中身:

| パス | 内容 |
| --- | --- |
| `Start-YakuLingo.ps1` | 起動エントリポイント |
| `src/` | 本体（HTTPサーバー、Copilotクライアント、翻訳、ファイル処理など） |
| `www/` | ローカルUI（HTML / CSS / JS、htmx） |
| `prompts/` | 翻訳プロンプト（方向別・テキスト／ファイル別） |
| `config/` | `settings.template.json`、`build.txt`（バージョン識別子） |
| `glossary.csv` | 表ラベルの完全一致置換用の用語集 |
| `prompt_glossary.csv` | Copilotプロンプト注入用の用語集 |
| `tools/` | エンコーディング検査・回帰テスト・パッケージ作成などの補助スクリプト |
| `README.md` / `DESIGN.md` | 利用者・保守者向けドキュメント |

利用者設定（`user_settings.json`）、出力、ログ、履歴はアプリフォルダではなく `%USERPROFILE%\.yakulingo-ps\` 配下に保存されます（V91.59以降）。

## バージョン運用

- 新版は必ず別フォルダへ展開し、使用中のバージョンフォルダを上書きしません。
- 切替は `current.txt` の1行を書き換えるだけです。ロールバックは1世代前のフォルダ名へ戻します。
- パッケージ作成時は `current.txt` と `app/config/build.txt` の両方を新バージョンへ更新します。
- `tools/New-YakuPackage.ps1` はバージョンフォルダ直下に `manifest.json`（全ファイルのサイズとSHA-256）を生成し、`tools/Test-YakuPackage.ps1` がZIPと突合して検証します。`manifest.json` は派生物のためリポジトリには含めません。
- 共有フォルダには現行版と N-1 だけを保持します。詳細は `共有フォルダ配置手順.md` を参照してください。

## 起動

1. ルートの `YakuLingo起動.vbs` をダブルクリックします。
2. Edge で Microsoft 365 Copilot へサインインします。
3. 画面右上が Ready になったら翻訳できます。
4. 停止は起動中の PowerShell 画面で `Ctrl+C` を押します。

Windows + PowerShell 5.1 + Microsoft Edge が前提です。CSV 以外のファイル処理には Microsoft Excel が必要です。出力は `%USERPROFILE%\.yakulingo-ps\outputs` に作成され、元ファイルは更新しません。

## 開発時のエンコーディング

- `*.ps1`、`prompts/*.txt`、`www/` 配下の HTML/CSS/JS、`config/settings.template.json` は **UTF-8 BOM付き・CRLF** で保存します。
- Markdown は UTF-8（BOMなし）です。`.vscode/settings.json` に既定を設定しています。
- コミット・配布前に `powershell -ExecutionPolicy Bypass -File .\V91.59\app\tools\Check-Encoding.ps1` を実行します。
- BOM違反は `V91.59\app\tools\Repair-YakuEncoding.ps1 -WhatIfOnly` で確認し、引数なし実行で一括修復できます。
- 本リポジトリの `.gitattributes` で改行コードの自動変換を無効化しています。配布物のバイト列をそのまま保持してください。
