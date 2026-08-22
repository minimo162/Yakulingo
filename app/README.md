# YakuLingo V91.2

Microsoft 365 Copilotの画面をEdge DevTools Protocol（CDP）で操作し、テキスト、Word、Excel/CSV資料の英訳・和訳を確認しながら仕上げるローカル業務ツールです。Copilotへ送る前に数値をマスクし、保存型の作業では原文と訳文に結び付いたQCと人の確認を必須にします。

V85では、テキスト翻訳の既定バッチ上限を1,000字から3,000字へ変更しました。保存済み設定が旧既定値1,000字のままの場合は、初回読込時に3,000字へ一度だけ移行します。明示的に別の値を設定している場合は変更しません。複数バッチの進捗はジョブ全体の範囲へ配分し、バッチ番号と入力文字数を表示したまま単調に進みます。

V86では、和訳（`to_jp`）の必須ラベル配列がPowerShellによって文字列へ展開され、正しい `JAPANESE_TEXT` 応答を全件誤拒否していた契約検証バグを修正しました。英訳・和訳の両方向を直接検証する回帰テストと配列型ガードを追加し、契約エラーによる再試行も進捗画面へ表示します。

V87では、日本語・中国語・英語の方向判定を強化し、低確度表示と手動方向指定を追加しました。テキスト用プロンプトを方向別に分割し、数値規則を必要時だけ挿入して送信量も削減しています。

V87.1では、新規プロンプトのUTF-8 BOM欠落を修正しました。エンコーディング違反の一括表示、修復ツール、VS Code設定も追加しています。

V88では、指定シートの不存在を検出して空の翻訳処理を防止し、対象0件時の書き戻しと完全性検証を軽量化しました。方向セグメントの罫線、シート全解除、ファイル方向推定反映などのUI/UXも改善しています。

V89では、テキスト入力欄が空の状態でも「日→英」「英他→日」を先に選択できるよう、方向メタ更新時の「自動」強制リセットを削除しました。

V90では、BRIEF英訳の目標長をFULL訳比20〜30%へ引き上げ、全文への電文体適用、財務略語、冗長句の短縮、意味保全ルールを強化しました。

V90.1では、BRIEFがFULLの半分を超えた場合の自己書き直し、FULL→BRIEF模範例、3段階の圧縮手順を追加し、増減表記を誤読しにくい `up X / down X` に統一しました。

V90.2では、事実完全性を最優先に固定し、BRIEFを5つの機械的変換だけで短縮する方式へ変更しました。長さは診断指標とし、限定・条件・原因・モダリティを保持する3種類の模範例と文単位の最終照合を追加しています。

V90.3では、Copilot準備状態の書き込みをアトミック化し、最大5回のリトライを追加しました。Ready状態の保存成功時のみ準備ワーカーを終了し、読み取り側は共有モードと最後の正常状態を使って一過性の競合を吸収します。

V90.4では、BRIEFの略語を見出し・ラベルにも適用し、符号付き寄与額、四半期トークン、数値間の矢印表記を原文に合わせて保持するよう調整しました。用語集は訳語の同一性を維持しつつ、一般語の大文字小文字を本文と見出しの文脈に適応させます。

V90.5では、符号付き内訳項目の項目名と数値を1スペースで結び、原文にない `impact`、`of`、コロンの挿入を禁止しました。増減動詞に付く数値は符号なしの大きさに統一し、文中の内訳項目はラベルでなく小文字の本文として扱います。FULLとBRIEFの両方で原文の期間トークンと数値間矢印も保持します。

V90.6では、増益・減益等の方向語が原文の `+` / `▲` を吸収し、数値を符号なしの大きさに統一しました。内訳のトップレベル区切りをセミコロン、括弧内をカンマに固定し、同一原語は回答全体で同一表記にします。四半期表記は原文固定ではなく用語集を優先し、全大文字の頭字語と一般語の短縮形を区別してcasingを適用します。

V90.8では、長文翻訳の見出し・箇条書きの構造自己検査、万台の `k units` 変換、同一の前置詞・限定語に支配される `and` の保持を追加しました。

現行版の配布物は、会社・資料固有の用語集、翻訳メモリ、コーパス、固有名詞一覧を同梱しません。内部資料の表現が外部公表資料へ、またはその逆へ、出所や意図が分からないまま混入することを防ぐためです。

資料翻訳の用語集と翻訳メモリは空の状態から始まります。用語は原文と訳文の必要な箇所を選んで登録します。文・セグメント全体は、機械チェック後に利用者が「確認済み」にしたときだけ、その端末の翻訳メモリへ自動保存されます。機械下訳、候補の挿入、前回版の読込だけでは保存しません。

用語は「この資料だけ」または「今後の資料でも使用」の範囲を登録時に選びます。文中用語は候補・訳案作成条件・機械チェックに使い、セル全体の固定訳は完全一致するセルにだけ使います。文中の一部を機械的に置換して活用や文法を壊すことはしません。

前回版は利用者がその作業へ明示的に読み込んだ場合だけ、「前回版」と出所を明示して候補表示します。訳文への自動反映や翻訳メモリへの自動昇格はしません。ちょっと翻訳は、用語集・翻訳メモリ・前回版を参照も保存もしません。

V91では、テキスト英訳の原文とFULL/BRIEFの見出し・箇条書き数をコード側で照合します。不一致は従来の応答再試行に組み込み、上限後も翻訳結果を返しつつ確認警告を表示します。

V91.1では、Copilotのレンダラーが半角山括弧見出しをHTMLタグとして隠す問題を修正しました。モデル応答では全角 `＜＞` を使い、受信後に半角 `<>` へ復元してから構造照合します。

V91.2では、M365 Copilotの新しい `loading-message` 思考表示と停止ボタンを生成活動として検知し、生成中の回答をsilent-start-timeoutで誤停止する問題を修正しました。初動待機は従来どおり10秒を既定とし、必要な場合のみ設定で変更できます。

## 開発時のエンコーディング

- `*.ps1`、`prompts/*.txt`、`www/` 配下のHTML/CSS/JS、`config/settings.template.json` はUTF-8 BOM付き・CRLFで保存します。
- 新規ファイルは `$utf8Bom = New-Object System.Text.UTF8Encoding($true)` と `[System.IO.File]::WriteAllText($path, $text, $utf8Bom)` を使って明示的に保存します。
- コミット・配布前に `powershell -ExecutionPolicy Bypass -File .\tools\Check-Encoding.ps1` を実行します。
- BOM違反は `tools\Repair-YakuEncoding.ps1 -WhatIfOnly` で確認し、同スクリプトを引数なしで実行して一括修復できます。

## 起動と停止

1. 共有ルートの `YakuLingo起動.cmd` をダブルクリックします。起動口はこの1つだけです。
2. PowerShellサーバーが起動し、YakuLingoが利用者の通常Edgeに1つのタブとして開きます。通常版は独自EXEとWebView2を配布しません。
3. 画面右上が「Copilot：準備完了」になったら翻訳できます。サインインが必要な場合は、同じ場所の「Copilot画面を開く」を押します。
4. YakuLingoのタブを閉じると完全に終了します。翻訳中だけ終了確認を表示し、終了時はPowerShellサーバーとYakuLingo専用Copilot Edgeを閉じます。利用者の通常Edgeとほかのタブは閉じません。

二重起動時は新しいサーバーを作らず、既存プロセスのPID・開始時刻・インスタンスIDを確認して通常Edgeにタブを追加します。Windowsサインイン時の自動起動と通知領域常駐は行いません。

## 対応機能

- テキスト: 省略しない標準訳案。必要な場合だけ確認作業として保存
- 前版更新: 前回の日英と今回の日本語を段落単位で比較し、完全一致訳と厳格に対応できる数値変更だけを再利用（いずれも現版で再確認）
- ファイル: `.docx`、`.xlsx`、`.xlsm`、`.csv`
- Word対象: 本文、見出し、通常表。対応能力を取込時に検査し、構造往復に合格した文書だけDRAFT Wordを生成
- Excel対象: 文字列セル、図形テキスト、グラフタイトル・軸タイトル
- Word出力対象外: ヘッダー・フッター・脚注等に文字がある文書、テキストボックス、変更履歴、フィールド、リンク、数式、複数文字書式を含む段落。この場合は確認済み訳文一覧だけをコピー
- Excel対象外: `.xls`、数式セル、SmartArt、パスワード保護ブック、データラベル、凡例、系列名

元ファイルは更新しません。作業開始時に原本をプロジェクト専用領域へコピーし、出力は `%USERPROFILE%\.yakulingo-ps\outputs` に作成します。Excel/CSV処理にはMicrosoft Excelが必要です。WordはOOXMLを直接扱い、Microsoft Wordを自動操作しません。

## V64の安全設計

- 起動ごとの256bitセッショントークンをHTMLへ埋め込み、APIは `X-Yaku-Session`、Host、Origin/Referer、Sec-Fetch-Siteを検証します。
- 状態変更はJSONまたはバイナリのPOSTに限定し、単純フォームPOSTを拒否します。
- Copilot接続先は `https://m365.cloud.microsoft/chat/` のみです。入力・送信・応答読取りの直前にもURLを再確認します。
- Edgeは `127.0.0.1` のCDPポートへだけバインドし、専用プロファイルを持つEdgeプロセスとの所有関係を確認します。
- ファイルはBase64化せず、バイナリストリームで一度だけアップロードします。以後は短命なファイルハンドルを使用します。
- UNCとデバイスパスは既定で拒否します。相対パスと未対応拡張子も拒否します。
- 文書は保存型の翻訳作業として取り込み、セグメント単位の途中保存・再開・確認・QCを行います。
- Excel COMアドインの接続状態は変更しません。

## 出力の完了状態

| 状態 | 意味 | 出力 |
|---|---|---|
| `done` | 書戻しと完全性検査を通過 | 通常名で公開 |
| `completed_with_warnings` | 未翻訳・抽出スキップ等あり | `_INCOMPLETE` 付き。画面に常時警告 |
| `failed` / `interrupted` | ワーカー、検査、保存等に失敗 | 完成名へ公開しない |
| `cancelled` | 利用者がキャンセル | 一時出力を削除し、出力パスを公開しない |

Excel/CSV出力はジョブ専用一時ディレクトリへ書き、書込件数、Open XML全シートの再読込、シート構成、数式、VBAプロジェクト、ファイルサイズを検査後、同一ボリュームで完成パスへ移動します。保存後に2回目のExcel COMセッションは起動しません。

## 応答契約

各Copilot要求はランダムな128bit要求IDを持ちます。通常の英訳では非空の `FULL_TEXT`、英訳後に「短く」を実行した場合は非空の `BRIEF_TEXT`、和訳では非空の `JAPANESE_TEXT` が必要です。CAT翻訳では全IDの件数・順序・重複を検査します。テキスト応答に不可視制御文字、ラベルのMarkdown強調・全角コロン、行内終端マーカー、マーカー後のCopilot停止表示が混入した場合は、契約検証前に安全な形へ正規化します。ラベルの存在・順序、要求ID、終端マーカーの一意性は緩和しません。先頭に別テキストが残る応答を救済できた場合は警告を表示します。契約エラー時は全文診断が無効でも本文を含まない構造メタデータを記録し、原文・正規化全文の記録は全文診断が有効な場合だけ行います。

## データ保存と消去

実行時データは `%USERPROFILE%\.yakulingo-ps` にあります。

| データ | 既定の内容・寿命 |
|---|---|
| アップロード原本 | 処理終了・失敗・キャンセル後に削除。孤立分は起動後の走査で1時間超を削除 |
| 翻訳履歴 | 通常画面には保存・表示しない |
| 通常ログ | 原文・訳文・プロンプト全文を含めず、5MBでローテーション、既定30日 |
| 全文診断 | 既定無効。管理用設定で有効化した場合のみ保存、保持1～7日（既定1日） |
| ジョブ状態 | 完了後30分。アップロード原本の寿命とは分離 |
| 用語集 | 資料翻訳で利用者が登録した用語と版・出典。利用者が無効化するまで保持 |
| 翻訳メモリ | 利用者が確認済みにした文・セグメントと出典。候補を無効化しても利用履歴は保持 |

Copilotへは翻訳対象本文、その原文に実際に一致した利用者登録用語のうち送信条件を満たすもの、翻訳指示を送ります。翻訳メモリや前回版の全文は、候補表示しただけで自動送信しません。ECM資料を扱う前に、組織のMicrosoft 365利用規程と情報管理規程を確認してください。

## 設定

設定は `%USERPROFILE%\.yakulingo-ps\config\user_settings.json` へ原子的に保存されます（V91.59以降。旧版の `<アプリ>\config\user_settings.json` は初回起動時に一度だけ引き継ぎ、旧ファイルは削除しません）。型、範囲、列挙値はサーバー側でも検証します。不正JSONは日時付きバックアップへ移し、既定値へ復旧します。主な既定値は次のとおりです。

- ファイル上限: 50MB（1～200MB）
- Copilot応答タイムアウト: 240秒
- Excel抽出タイムアウト: 300秒
- ワーカーハートビート停止判定: 180秒
- CDPポート: 9433（1024～65535）
- UNC許可: 無効
- 全文診断: 無効
- テキスト翻訳バッチ文字数: 3,000字

## テスト

Windows PowerShellで次を実行します。

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Smoke-Test.ps1
powershell -ExecutionPolicy Bypass -File .\tools\Wait-YakuCopilotResponse-Watcher-Test.ps1
powershell -ExecutionPolicy Bypass -File .\tools\V64-HTTP-Boundary-Test.ps1
powershell -ExecutionPolicy Bypass -File .\tools\V65-Saving-Validation-Test.ps1
```

V69のCopilot実機確認では `tools\Test-CopilotAutomation.ps1` を実行し、入力・送信・回答取得が成功することを確認してください。通常ログの `Copilot fresh chat diagnostic` と `Copilot fresh chat accepted` で、新規チャット操作前後の応答件数・入力状態・採用理由を確認できます。用語集については `Glossary occurrence audit` または `Text glossary occurrence audit` を確認してください。設定で全文診断を有効にした場合、違反した原語、指定訳、対象位置、原文、実訳を `copilot-glossary-diagnostic-*.jsonl` に保存します。

HTTP境界試験はYakuLingo本体を停止した状態で実行してください。

起動時にも全 `.ps1` のPowerShell構文とUTF-8 BOMを検査します。配布前には `docs\V64_TEST_RESULTS.md` のWindows/Excel/Edge実機試験を完了してください。

## 制約

- CDP画面構造はMicrosoft 365 Copilot側の変更に影響されます。
- 図形内の部分書式はExcel COMの制約で先頭ランの書式へ均される場合があります。
- 文字溢れの自動縮小・図形リサイズは行いません。
- `completed_with_warnings` は完成品ではありません。必ず警告一覧と原本を照合してください。
## V91.32 progress calibration

Expected Copilot answer length is estimated separately for text and file translation. The legacy `copilotAnswerRatio` setting is ignored; use `copilotAnswerRatioText`, `copilotAnswerBaseText`, `copilotAnswerRatioFile`, and `copilotAnswerBaseFile`.


## V91.33 progress numerator and file calibration

Progress now measures only the response text after the echoed-input end marker, so the displayed numerator starts at zero and is no longer capped by the 2,000-character diagnostic tail. File translation now sets its own expected answer length and logs per-batch actual answer ratios for calibration.


## V91.34 input-length guard and progress display

YakuLingo assumes an M365 Copilot licensed environment. The fixed prompt portion is approximately 9,300 characters, so an environment limited to about 8,000 input characters is not supported. After filling the Copilot input, YakuLingo compares the requested and actual character counts and stops with `PROMPT_TRUNCATED_BY_INPUT_LIMIT` instead of sending a silently truncated prompt.

Set `copilotPromptCharLimit` to a known input limit when required. The default is `0` (disabled). When enabled, prompts exceeding the configured limit stop before submission. File-translation generation now uses the same live answer-character progress path as text translation.


## V91.37
- 億円の数値は桁を変換せず、そのまま `oku` として転記します。
- Edgeウィンドウ閉鎖後は余剰Copilotタブを整理し、短いCDP pingと再接続で凍結タブの回復を試みます。
- 入力欄の残存テキストを送信前に消去し、残存競合と入力上限による切詰めを別エラーで通知します。

## V91.37 numeric-unit preprocessing

Japanese numeric units are converted deterministically before batching: 億円/兆円 to `oku`, 千台/万台 to `k units`, and 千円/万円 to `k yen`. Numeric integrity checks now verify the generated English tokens. `oku yen` is no longer used. Masked values that require arithmetic, such as `xxx万台`, are left unchanged with a warning.


## V91.38 ratio recalibration and full-width numeric preprocessing

- Text expected-answer ratio default is recalibrated from 4.5 to 4.0.
- `単価改善` is fixed as `per-unit price improvement` in both glossaries.
- Numeric-unit preprocessing accepts full-width digits, commas, decimal points, and x/X masks, normalizing them to ASCII before token generation.
- `品質関連費用` occurrence translations are aligned to `warranty exp.`.

## V91.56 changes

- Separated FULL and BRIEF terminology more strictly: FULL spells out ordinary/internal shorthand, while BRIEF consistently uses approved abbreviations.
- Added FC, VC, VP, and VP (Veh.) mode-specific glossary variants and BRIEF rules.
- Preserved established financial acronyms such as EBITDA, FCF, and ROE in FULL.
- Added regression checks for glossary candidate order, prompt injection, and abbreviation consistency.


## V91.57 changes

- Standardized promotion-cost terminology: FULL uses `sales promotion costs` / `fixed sales promotion costs`; BRIEF uses `Promo. Costs` / `Fixed Promo. Costs`.
- Removed `MKT`, `Fixed MKT`, and `Fixed Marketing` as renderings of promotion costs while preserving genuine marketing terminology.
- Added exact-match labels `子会社 固定販促費` and `子会社固定販促費` -> `Subs. Fixed Promo. Costs`.
- Updated `販売奨励金/固定販促費` -> `VM / Fixed Promo. Costs` and added regression checks.


## V91.58
- Shortened file-translation exact-match table labels: `固定販促費` -> `Fixed Promo.`, subsidiary variants -> `Subs. Fixed Promo.`, and `販売奨励金/固定販促費` -> `VM / Fixed Promo.`.
- Added `国内その他` -> `Dom. Oth.` and shortened `連結調整他` -> `Cons. Adj.`.
- FULL/BRIEF prose terminology rules remain unchanged.


## V91.59
- Moved `user_settings.json` out of the app folder into `%USERPROFILE%\.yakulingo-ps\config\`, so settings are per user and survive version updates.
- Legacy settings inside the app folder are migrated once on first read. The legacy file is never modified or deleted, so users still on an older version are unaffected.
- Added the `YAKULINGO_DATA_DIR` override so regression tests can redirect the data directory instead of touching real user data.
- Added `tools\Test-YakuV9159SettingsPath.ps1` and extended `tools\Smoke-Test.ps1` to guard the new location.
- `tools\New-YakuPackage.ps1` now emits a `manifest.json` next to `app/` listing every packaged file with its size and SHA-256, so a local copy of the package can be verified before it is used.
- `tools\New-YakuPackage.ps1` refuses to package a tree containing `user_settings*`, `*.bak`, or `*.tmp`.
- `tools\Test-YakuPackage.ps1` verifies the manifest against the archive: build ID agreement, per-file size and SHA-256, and that no packaged file is missing from or unlisted in the manifest.
- Packages are now built directly from the manifest file list instead of `Compress-Archive`, so the archive and the manifest always agree (hidden files included).
- Replaced the VBScript launcher with `YakuLingo起動.cmd`. Current packages contain only the CMD launcher.
- The shared root now carries `bootstrap.ps1`, which copies this package to `%LOCALAPPDATA%\YakuLingo\versions\<version>-<manifest hash>`, verifies every file against the manifest, and runs it locally. The shared folder can then be updated while users are working.
- `tools\Create-Desktop-Shortcut.ps1` targets the shared `.cmd` (via `YAKULINGO_SHARED_ROOT` when available) and uses a local working directory to avoid the cmd.exe UNC warning.
- Added `tools\Test-YakuBootstrap.ps1` covering install, reuse, update, tamper detection, offline fallback, direct flat-layout startup, and rejection of obsolete nested version folders.
