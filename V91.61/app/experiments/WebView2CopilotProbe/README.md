# WebView2 Copilot Probe

YakuLingo本体へ組み込む前に、Microsoft 365 CopilotをWebView2で安全に扱えるか確認する独立PoCです。本体コード、本番の専用Edgeプロファイル、翻訳メモリには触れません。

## このPoCで確認すること

1. 専用の永続ユーザーデータフォルダー（UDF）で `https://m365.cloud.microsoft/chat/` を表示できる
2. 認証画面らしい要素や入力欄の有無をDOMから取得できる
3. 2つのWebView2が同じプロファイルを共有できる
4. 第2画面を非表示・再表示しても動作し、アプリ再起動後もCookieが残る

このPoCはCopilotへメッセージを送信しません。DOM診断は入力内容を読まず、要素数・URL・タイトル・読み込み状態だけを記録します。Cookie値も記録しません。

## ビルド

PowerShellでこのフォルダーへ移動し、次を実行します。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Build-Probe.ps1
```

本体に同梱済みのWebView2 DLLを `bin` へコピーし、Windows標準の.NET Framework 4.x C#コンパイラーで `bin\WebView2CopilotProbe.exe` を作ります。NuGetやネットワーク接続は不要です。

ビルドと安全契約の自己テストは次で実行できます。

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-Probe.ps1
```

## UI操作なしの自動診断

次のように結果JSONの保存先を指定すると、画面を表示せず診断して自動終了します。

```powershell
.\bin\WebView2CopilotProbe.exe --auto-diagnose .\logs\auto-result.json
```

自動診断は、2画面の初期化、Copilotへのナビゲーション（最大60秒待機）、入力値を含まないDOM状態、同一プロファイル、第2画面の非表示中と再表示後のDOM状態、Cookie件数とドメインを順に検査します。Copilotへの入力・送信、Cookie値の取得は行いません。

結果JSONの `success`、`errors`、`sameProfile`、`navigation.readyWithin60Seconds`、`domBeforeHide`、`hiddenRestore`、`cookies` を確認してください。企業環境でログイン画面へリダイレクトされた場合も、その時点のDOM状態を結果として保存します。

## 実機評価手順

認証情報の入力やCopilotへの送信は行わず、まず次の範囲を確認します。

1. `bin\WebView2CopilotProbe.exe` を起動する
2. 「1. 2画面を初期化」を押す
   - ログに `INIT_OK` が出る
   - `SAME_PROFILE=True` が出る
   - `PROFILE_A` と `PROFILE_B` のパスが同じ
3. 「2. Copilotを開く」を押す
   - A/Bの両方で `NAV_* success=True` が出る
   - 企業ポリシーや認証によりログイン画面が出ても、この段階では入力しない
4. 「3. DOM状態を診断」を押す
   - `DOM_A` と `DOM_B` が出る
   - `readyState`、`inputCount`、`visibleInputCount`、`authControlLikely` を取得できる
   - 入力内容やアクセストークンがログへ出ていない
5. 「第2画面を隠す」→数十秒待つ→「第2画面を再表示」→DOM診断
   - クラッシュしない
   - 再表示後も `DOM_B` を取得できる
6. 「Cookie持続を診断」を押し、`COOKIE_A/B` の件数を記録する
7. アプリを閉じて再起動し、初期化→Copilotを開く→Cookie診断を行う
   - UDFが同じ
   - 再起動前に存在したCookieの件数・ドメインが再起動後にも存在する

ログは `logs\probe-YYYYMMDD-HHMMSS.log`、専用UDFは `data\CopilotWebView2Profile` に保存されます。どちらもGit管理対象外です。

## 移行可否の追加合格条件

認証を伴う評価は、利用者の明示的な操作と許可の下で別途行います。全面移行には少なくとも次が必要です。

- 会社アカウント、MFA、条件付きアクセスを通過でき、再起動後も安全にセッションを復元できる
- 約8,000文字を欠落なく入力できる（送信前にDOM上の文字数を照合する）
- WebView2を2つ同時に動かしても、バックグラウンド側の入力・応答監視が抑制されない
- ログイン切れ、WebView2プロセスクラッシュ、ネットワーク切断から利用者が自力で復旧できる
- 企業テナントの利用規約・セキュリティポリシー上、埋め込み表示が許可される

## 既知のリスク

- Microsoft 365の認証や条件付きアクセスは、通常のEdgeと埋め込みWebView2で挙動が異なる場合があります。
- Microsoft側のDOM変更で要素検出や自動操作が壊れます。
- 非表示WebView2ではレンダリングやタイマーが抑制される可能性があります。このPoCは抑制軽減フラグを付けますが、長文と並列処理の実測が必要です。
- 同一UDFを複数プロセスから同時利用できません。このPoCを二重起動しないでください。
- `data` には認証Cookie等が保存され得ます。共有・バックアップ・配布対象に含めないでください。
- このPoCは診断用であり、YakuLingo本体の翻訳処理やエラー回復を実装していません。
