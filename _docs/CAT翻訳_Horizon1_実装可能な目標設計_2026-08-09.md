# YakuLingo CAT翻訳 Horizon 1 実装可能な目標設計

作成日: 2026-08-09

対象: V91.61 からの次期基盤

状態: 実装設計の基準
上位構想: `CAT翻訳_目標設計_2026-08-09.md`

## 1. Horizon 1の成果

Horizon 1では、廃止済みファイル翻訳へのCAT依存を解消し、Quickと保存型翻訳作業が同じ安全基盤を使う状態までを完成させる。

実装する:

- 一つのホームからQuick翻訳、Excel作業、作業再開へ進む導線
- Quickの非プロジェクト型ライフサイクル
- QuickからCAT projectへの明示的・無損失な昇格
- CAT専用翻訳サービスとプロンプト契約
- 数値・固有名詞保護、送信、応答検査の共通基盤
- 安定segment ID、project revision、部分成功、checkpoint、再開
- 編集、レビュー、QCを分けた状態
- Excel取込・書戻しの現行能力維持
- 確認済み訳文一覧の出力
- 旧`/api/translate-file`、旧JS、ワーカー、旧プロンプトの削除

実装しない:

- Word取込・完成DOCX
- 前版日英と現版日本語の3-way更新
- `ApprovedTranslationStore`
- 複数年・四半期の基準版取込
- 組織的な承認・外部release
- 自動体裁3-wayマージ
- `billion/million`への未実装の確定換算

これらはHorizon 1の出荷条件にしない。

## 2. 製品モデル

### 2.1 ホーム

```text
ホーム
├─ テキストを貼る → 標準訳案（AI訳・未確認）
│                    ├─ コピー
│                    ├─ 省スペース案を作る
│                    └─ 作業として保存して詳しく仕上げる
├─ Excelを開いて仕上げる
└─ 前回の作業を続ける
```

主要UIに`CAT`、`FULL`、`BRIEF`、`ファイル翻訳`を表示しない。

### 2.2 Quick

- 利用者表示は「標準訳案」「AI訳・未確認」とする。
- `complete`は「省略していない英文」という内部属性であり、承認済みを意味しない。
- 明示的な昇格までCAT project、TM、コーパスへ書き込まない。
- Quick artifactは原則メモリ内に置き、アプリ終了時に削除する。
- 障害復旧のためディスクへ置く場合は、保存場所、TTL、即時削除を画面と設定に明示する。
- blockerがある結果はコピーできない。
- Quickから承認・release・Excel書戻しを行わない。

### 2.3 翻訳作業

- プロジェクトとして明示的に保存する。
- 原文と訳文を1件ずつ確認、編集できる。
- 保存状態、未確認件数、QC findingを表示する。
- Excelは最初から翻訳作業として開く。
- 手編集はレビュー済みを意味しない。
- Horizon 1の正式成果物は「確認済み訳文一覧」であり、組織承認済みや公表可能とは表示しない。

## 3. セキュリティ境界

### 3.1 保護済み送信口

すべてのCopilot送信は一つの`ProtectionService`と送信アダプターを通す。送信アダプターは、生文字列ではなく版付き`ProtectedPayload`だけを受け付ける。保護対象は原文だけではなく、用語、参考訳、TM、文脈、追加指示、メタデータを含む最終serialized request全体とする。`PromptContractBuilder`が保護処理後に生データを追加できない型・API境界にする。

```text
ProtectedPayload
  payload_id
  protection_contract_version
  masked_text
  placeholder_expectations
  source_hash_hmac
  metadata_allowlist
```

ファイル名、パス、文書プロパティ、作成者等は既定で送信しない。

### 3.2 外部送信可否

組織ルール上、Copilotへの機密情報の送信は許可されている。未公開財務数値を含む本文はマスキング前は送信不可だが、数値を完全にマスクした後は送信できる。

したがって文書を`public / business / local_only`のように利用者が分類するgateは置かない。判定は一つだけである。

```text
マスキング前 = 送信不可
数値マスクとpayload検証の完了後 = 送信可
```

固有名詞辞書は送信可否の分類ではなく、英語表記の正確性と完全一致再利用のために使う。未登録固有名詞だけを理由に送信を止めない。

`ExternalSendGate`は次を確認する。

- 組織が承認したプロバイダー・テナントである
- 保存、学習利用、保持期間、リージョンが組織方針に適合する
- 送信payloadが数値マスク済みで、保護契約の検証に合格している
- metadata allowlistに違反しない
- 利用者へ現在の送信可否が表示されている

保護済みという判定は、保護サービスが付与する版付き契約と、prompt内にマスク元の財務数値が残っていないことの実測検査から取得する。利用者の選択値で許可へ変更できない。

マスキングが無効、保護契約が欠落、またはpromptに実数値が残る場合は送信を停止する。

core blockerに管理者例外を設けない。

## 4. 状態モデル

### 4.1 Segment

```text
untranslated
  -> machine_draft
  -> human_edited
  -> reviewed
  -> stale
```

QCは状態とは別に`not_run / passed / warning / failed`を持つ。編集、再翻訳、原文変更、結合・分割でreviewedとQCを失効させる。

Horizon 1では`approved`、`inherited_approved`、`release_approved`を使わない。

### 4.2 Quick

```text
idle -> protected -> generating -> qc_passed_draft
                                   -> qc_blocked
```

コピーは状態ではなくイベントとする。

### 4.3 出力可否

単一の`Exportable`を保存しない。現在の状態から次を計算する。

- `translation_list_eligibility`: 対象segmentがすべて`reviewed`、各`source_revision`に対する最新QCが`passed`、`stale`・未訳・原文fallback・core blockerが0件の場合だけ真
- `excel_draft_eligibility`: `translation_list_eligibility=true`に加え、Excel inventoryが対応プロファイル内、原本hash一致、再対応付け成功、書戻し・再取込検証が成功した場合だけ真

Horizon 1に`verified_document_eligibility`と`external_release_eligibility`は含めない。

警告は理由コード付きで一覧へ含められるが、数値、placeholder、登録済み固有名詞の欠落、空訳、原文fallback、日本語残存、構造破損はcore blockerであり、訳文一覧にもDRAFT Excelにも問題のある訳を成果物として混入させない。未登録固有名詞は送信blockerにはしない。

## 5. 目標アーキテクチャ

```text
TranslationHome
├─ QuickTranslationService
└─ CatProjectService
   ├─ CatTranslationService
   ├─ CatReviewService
   └─ ExcelAdapter

共通基盤
├─ TranslationKernel
│  ├─ ProtectionService
│  ├─ PromptContractBuilder
│  ├─ BatchRunner
│  └─ CopilotClient
├─ ValidationService
├─ ExternalSendGate
├─ TranslationCache
├─ ProjectRepository
└─ JobService
```

| モジュール | 責務 |
| --- | --- |
| `TranslationKernel` | 保護済み要求からプロンプト生成、バッチ送信、応答取得 |
| `ProtectionService` | 単位正規化、マスク、placeholder map、復元 |
| `ValidationService` | 応答契約、数値、固有名詞、言語、構造の検査 |
| `QuickTranslationService` | Quick固有の分割、標準訳案の結合、短縮派生 |
| `CatTranslationService` | CAT対象選択、重複排除、部分成功、checkpoint |
| `CatProjectService` | 昇格、編集、review、状態計算 |
| `ProjectRepository` | project revision、segments、QC、checkpointの永続化 |
| `ExcelAdapter` | 現行Excel inventory、extract、apply、整合性検査 |
| `JobService` | 長時間処理、取消、進捗、結果artifact、再開 |

CATは`Invoke-YakuFileTranslationItems`と`New-YakuFilePrompt`を呼ばない。

## 6. 契約

### 6.1 正本翻訳

```text
CanonicalTranslationRequest
  request_id
  workflow: quick | cat
  direction
  protected_units[]
  style_policy_version
  terminology_snapshot_hash
  actual_reference_snapshot_hash
  prompt_contract_hash
```

`assurance`、`distribution`、金額表示を正本翻訳要求へ入れない。

### 6.2 短縮

```text
CompactionRequest
  canonical_target_hash
  source_facts_hash
  compaction_policy_version
```

短縮は正本訳からだけ作る。正本と別にQC・review状態を持つ。

### 6.3 Segment ID

- `segment_id`: CAT project内で安定
- `source_revision`: 原文変更ごとに増加
- `source_integrity_hash`: 現在原文の安定SHA-256。プロジェクト内部の競合・整合性判定だけに使い、ログや外部送信へ出さない
- `log_source_id`: ローカル秘密鍵付きHMAC。通常ログの相関だけに使う
- ジョブ結果適用条件: `segment_id + source_revision + source_integrity_hash + expected_project_revision`

待機中の編集、結合、分割後に旧結果を適用しない。

HMAC鍵はOS資格情報ストアまたは同等のユーザー単位保護領域に保存し、平文ファイルへ置かない。鍵更新はログ相関を切り替えるだけとし、projectの整合性や再開可能性へ影響させない。

### 6.4 キャッシュ

キャッシュキーには少なくともworkflow、正規化原文HMAC、方向、style、用語・参照snapshot、prompt contract、model/deployment、mask contract、validation contractを含める。短縮はさらに正本訳hashとcompaction contractを含め、正本翻訳キャッシュと分離する。

cache hitでも現在版の復元・QCを再実行する。キャッシュは訳案だけを返し、`reviewed`、QC結果、出力可否を継承しない。契約版が不明または一致しない既存cacheは隔離し、自動採用しない。

## 7. 永続化

現行の単一JSON全量書換えを長期構造にしない。Horizon 1では少なくとも次へ分ける。

```text
project/
  project.json
  segments.jsonl
  qc/<qc-run-id>.jsonl
  checkpoints/<job-id>.json
```

各書込みは一時ファイルから原子的に置換し、project revisionを更新する。起動時に未完了checkpointを検出し、最後に成功したbatchから再開できる。

本文を通常ログへ残さない。ログ用原文・訳文識別子には平文hashではなく、ローカル秘密鍵付きHMACを使う。

project、checkpoint、Quick一時artifact、キャッシュを利用者が削除できる。

## 8. APIとジョブ

```text
POST   /api/artifacts
GET    /api/artifacts/{id}
DELETE /api/artifacts/{id}

POST   /api/quick-translations
POST   /api/quick-translations/{id}/compact
POST   /api/projects/from-quick

POST   /api/projects
GET    /api/projects/{id}
PATCH  /api/projects/{id}/segments/{segment_id}
DELETE /api/projects/{id}

POST   /api/projects/{id}/translation-jobs
POST   /api/projects/{id}/validation-jobs
POST   /api/projects/{id}/translation-lists
POST   /api/projects/{id}/excel-drafts

GET    /api/jobs/{id}
DELETE /api/jobs/{id}
```

長時間操作は`202 Accepted + job_id`を返す。更新系は`If-Match`または`expected_project_revision`と`Idempotency-Key`を必須にする。

## 9. Excel成果物

Horizon 1は現行Excel書戻し能力を維持するが、「体裁検証済み完成ファイル」とは呼ばない。

- 構造round-tripが安全な現行対応範囲だけ`DRAFT` Excelを出せる。
- 原本を上書きしない。
- ファイル名と文書内に`DRAFT`を表示する。
- 未確認・QC finding一覧を同時に示す。
- 構造破損の可能性、原文再対応付け失敗、未対応要素があればExcelを出さず、訳文一覧だけを出す。

## 10. 移行ゲート

### Gate A: CAT経路分離

- CAT本番・試験から旧FileTranslation内部関数への参照が0件
- CAT専用prompt契約
- Quick/CATの全Copilot送信が共通保護済み送信口を通る
- 数値・固有名詞マスクとplaceholder QCが本番入口で通る
- 部分成功、再試行、cache、checkpointが現行同等以上

不合格なら次へ進まない。

### Gate B: 状態・永続化

- 安定segment ID、source revision、project revision
- 待機中の編集・結合・分割を旧ジョブが上書きしない
- worker強制終了後、最後の成功batchから再開できる
- 2,000 segment級でopen/save/filterの性能予算を満たす
- project、artifact、checkpoint、cacheを削除できる

### Gate C: 旧ルート削除

- `/api/translate-file`のルート定義が存在せず、404または明示した廃止応答以外を返さない
- 旧JS、`FileWorker.ps1`、旧prompt、旧ファイル翻訳専用関数が製品コードから削除済み、または到達不能であることを静的検査と実行時テストで証明
- Excel取込、翻訳、DRAFT書戻しがCAT専用経路で通る
- 一版の実機運用で重大退行がない

旧ルート削除をWord・版間再利用の完成まで待たせない。

## 11. 受入基準

### 利用者

- 初心者がQuickを承認済み・公表可能な完成品と誤認しない。
- Quick一時データの保存場所・保持時間・削除条件を説明できる。
- QuickからCATへ原文・訳文・方向を失わず、再翻訳なしで昇格できる。
- Excel作業と作業再開へホームから一操作で到達できる。
- 主要画面に`CAT`、`FULL`、`BRIEF`、`ファイル翻訳`を表示しない。
- 現行CATの用語集完全一致、過去公表訳・TM候補、修正指示、segment結合・分割、未確認絞り込み、キーボード確認を維持する。
- 参照文例には出典と信頼区分を表示し、候補と現在の確認済み訳を区別できる。

### 安全・品質

- マスク元の未公開財務数値を含む送信をテストダブルが拒否する。
- 外部送信不可分類の文書をCopilotへ送れない。
- blockerがあるQuick結果をコピーできない。
- 数値、placeholder、未訳、構造blockerを権限で上書きできない。
- 手編集だけでreviewedにならない。
- 短縮版は正本と独立してQC・reviewされる。
- 通常ログに本文、復元表、平文hashを残さない。

### 回復・性能

- 2,000 segmentで性能予算を満たす。具体値は着手前に現行実測から固定する。
- job取消、アプリ終了、worker強制終了後に破損projectを残さない。
- project revision不一致の更新を拒否する。
- Excel原文が変わった場合に曖昧な書戻しを停止する。

### 回帰

- 用語集完全一致、過去公表訳・TM候補表示、修正指示、結合・分割、未確認絞り込み、キーボード確認、参照文例と出典表示のゴールデンテストが通る。
- 旧ルート削除前に、旧実装が防いでいた数値・placeholder・部分失敗・Excel再対応付けの失敗例を新経路の評価セットへ移す。

## 12. Horizon 2へ進む条件

Horizon 1を一版以上実機運用し、次を満たすこと。

- CAT専用経路に重大な安全退行がない
- 状態・QC・checkpoint・削除が運用上成立する
- Excel利用者がQuick/CAT境界を理解できる
- 旧ファイル翻訳への到達がない
- 直近の日英一組を使った版間再利用の評価セットが用意できる

条件を満たすまで、Word、基準版取込、版間再利用、組織承認、完成ファイル保証を本体へ追加しない。
