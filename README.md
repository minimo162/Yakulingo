# YakuLingo（ECM資料英訳ツール）

Microsoft 365 Copilot の画面を Edge DevTools Protocol（CDP）で操作し、テキストおよび Excel/CSV 資料を翻訳するローカル業務ツールです。

このリポジトリは、共有フォルダ `ECM資料英訳ツール/` に配置される配布物一式をそのままの構成で管理します。

## 構成

```
.
├── YakuLingo起動.cmd      # 利用者が起動するランチャー。bootstrap.ps1 を呼ぶ
├── YakuLingo起動.vbs      # .cmd へ転送する互換シム（VBScript廃止予定のため将来削除）
├── bootstrap.ps1          # 配布物をローカルへ複製・検証してから起動する
├── アップロード用フォルダ作成.cmd  # 共有フォルダへ上げる用のフォルダを作る（管理者用）
├── New-YakuUploadFolder.ps1        # 同上の本体。作業ツリーは変更しない
├── current.txt            # 現行バージョン名（1行）。切替はこのファイルの書き換えのみ
├── 共有フォルダ配置手順.md  # 共有フォルダへの配置・更新・ロールバック手順
├── _docs/                 # 修正指示書・実装記録（バージョン横断で集約）
└── V91.61/                # 現行版（既定のアップロード対象）
    ├── YakuLingo起動.cmd  # 保守用。共有フォルダ上で直接起動する
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
| `tools/` | エンコーディング検査・回帰テスト・パッケージ作成などの補助スクリプト |
| `README.md` / `DESIGN.md` | 利用者・保守者向けドキュメント |

利用者設定（`user_settings.json`）、出力、ログ、履歴はアプリフォルダではなく `%USERPROFILE%\.yakulingo-ps\` 配下に保存されます（V91.59以降）。

配布物に会社・資料固有の用語集、翻訳メモリ、コーパス、固有名詞一覧は同梱しません。資料翻訳で利用者が登録した用語と、利用者が確認済みにした訳文だけが、その端末の `%USERPROFILE%\.yakulingo-ps\` 配下に蓄積されます。アプリの更新はこれらの利用者データを削除・初期化しません。

## バージョン運用

- 新版は必ず別フォルダへ展開し、使用中のバージョンフォルダを上書きしません。
- 切替は `current.txt` の1行を書き換えるだけです。ロールバック版を共有フォルダへ置く場合は、同梱用語・固有名詞・コーパスを含まない検査済みパッケージだけを明示指定します。
- パッケージ作成時は `current.txt` と `app/config/build.txt` の両方を新バージョンへ更新します。
- `tools/New-YakuPackage.ps1` はバージョンフォルダ直下に `manifest.json`（全ファイルのサイズとSHA-256）を生成し、`tools/Test-YakuPackage.ps1` がZIPと突合して検証します。`manifest.json` は派生物のためリポジトリには含めません。
- ルートの `bootstrap.ps1` はバージョンフォルダの外にあるため、パッケージ更新とは別に配置します。
- 共有フォルダへ上げるときは `アップロード用フォルダ作成.cmd` を実行します。作業ツリーを変更せず、上げてよいものだけを複製した新しいフォルダを作り、`manifest.json` を実体に合わせて作り直します。`.git` やリポジトリ用の `README.md`、利用者設定、作業ファイルは複製されません。
- 詳細は `共有フォルダ配置手順.md` を参照してください。
- アップロード用フォルダは既定で現行版だけを含めます。検査済みのロールバック版を併置する場合だけ `-Versions` で明示指定します。詳細は `共有フォルダ配置手順.md` を参照してください。

## 起動

1. ルートの `YakuLingo起動.cmd` をダブルクリックします。
2. Edge で Microsoft 365 Copilot へサインインします。
3. 画面右上が Ready になったら翻訳できます。
4. 停止は起動中の PowerShell 画面で `Ctrl+C` を押します。

初回起動時、`bootstrap.ps1` が現行版を `%LOCALAPPDATA%\YakuLingo\versions\<版>-<manifestハッシュ>` へ複製し、`manifest.json` で全ファイルの SHA-256 を照合してからローカルで起動します。以降アプリは共有フォルダを参照しないため、**利用者が作業中でも共有フォルダのバージョンを更新できます**（反映は次回起動時）。共有フォルダへ到達できないときは導入済みのローカル版で起動します。

Windows + PowerShell 5.1 + Microsoft Edge が前提です。CSV 以外のファイル処理には Microsoft Excel が必要です。出力は `%USERPROFILE%\.yakulingo-ps\outputs` に作成され、元ファイルは更新しません。

## 開発時のエンコーディング

- `*.ps1`、`prompts/*.txt`、`www/` 配下の HTML/CSS/JS、`config/settings.template.json` は **UTF-8 BOM付き・CRLF** で保存します。
- Markdown は UTF-8（BOMなし）です。`.vscode/settings.json` に既定を設定しています。
- コミット・配布前に `powershell -ExecutionPolicy Bypass -File .\V91.59\app\tools\Check-Encoding.ps1` を実行します。
- BOM違反は `V91.59\app\tools\Repair-YakuEncoding.ps1 -WhatIfOnly` で確認し、引数なし実行で一括修復できます。
- 本リポジトリの `.gitattributes` で改行コードの自動変換を無効化しています。配布物のバイト列をそのまま保持してください。
