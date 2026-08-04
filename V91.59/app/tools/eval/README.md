# 翻訳評価ハーネス

プロンプトや用語集を変えたとき、**狙った改善が起き、他が壊れていないこと**を
機械的に確認するための仕組み。`_docs/設計方針_翻訳アーキテクチャ見直し.md` §4-E の実装。

## 何ができて、何ができないか

**できること**: プロンプト・用語集・規則を変えたときの相対比較。
変更前後で指標を並べ、悪化した項目を見つける。

**できないこと**: **M365 Copilot の挙動の再現。**
このハーネスは評価用の代替モデルへプロンプトを渡す。Copilot とは別のモデルなので、

- 合否の絶対値は Copilot へ転移しない。**比較にのみ使う。**
- Copilot 固有の事象（レンダラーが半角山括弧を隠す、応答の途中切れ、
  生成中の停止検知など）は再現できない。
- 最終確認は必ず実機（Copilot）で行う。

## 使い方

### 1. プロンプトを生成する

```
powershell -ExecutionPolicy Bypass -File .\tools\eval\Build-YakuEvalPrompts.ps1
```

`evalset.json` の各ケースについて、**アプリが実際に送るのと同じプロンプト**を
`prompts/<id>.prompt.txt` へ書き出す。`New-YakuTextPrompt` をそのまま呼ぶため、
用語集の注入・数値規則・BRIEF規則がすべて入る（1件あたり約13,000〜14,000字）。

`prompts/_index.json` にケースIDと `request_id` の対応が入る。

### 2. 翻訳させる

`prompts/<id>.prompt.txt` の中身を翻訳エンジンへ渡し、応答をそのまま
`responses/<id>.response.txt` へ保存する。

- 実機確認: Copilot へ貼り付ける
- 反復作業: 評価用の代替モデルへ渡す（応答の形式はプロンプトが指定しているので、
  モデルが指示に従えば形式は揃う）

### 3. 採点する

```
powershell -ExecutionPolicy Bypass -File .\tools\eval\Measure-YakuEvalResponses.ps1
```

`report.json` に結果が出る。

## 採点の中身

**アプリ本体と同じ関数を使う。** 評価用に別基準を作らない。

| 指標 | 使う関数 |
| --- | --- |
| 応答契約（ラベル・終端マーカー・request_id 照合） | `Parse-YakuTextTranslationResponse` |
| 数値整合 | `Test-YakuNumericIntegrity` |
| 構造整合（見出し・箇条書き） | `Test-YakuTextStructureIntegrity` |
| 用語集遵守率 | `Get-YakuAppliedGlossaryEntries` の `Target` が訳文にあるか |

これに評価セット固有の検査を加える。

| キー | 対象 | 意味 |
| --- | --- | --- |
| `must_contain_any` | FULL+BRIEF | いずれかが含まれること |
| `must_not_contain` | FULL+BRIEF | 含まれないこと |
| `full_must_contain_any` / `full_must_not_contain` | FULL | 同上 |
| `brief_must_contain_any` | BRIEF | 同上 |
| `raw_must_contain_any` | **生応答** | パーサが変換する前の形を見る |

`raw_must_contain_any` は全角山括弧のために用意した。プロンプトは応答に全角 `＜＞` を
要求し、`Parse-YakuTextTranslationResponse` が半角 `<>` へ復元する。
どちらを検査したいのかで対象が変わる。

禁止語は全ケース共通で `billion` / `million` / `trillion` / `bn` / `tn` を見る
（`oku` 固定の方針に反するもの）。

## ケースを足すとき

`evalset.json` へ追記する。**規則を消す前に、その規則が防いでいた失敗例を
ここへ足し、捕まえられることを確認する**（設計方針 §6）。

`origin` に出典を書く。`開示資料` は公開済みの決算短信、`社内回帰例文` は
`tools/regression/` の非機密化済みデータ、`合成` は規則の検証用に作った文。

**機密の数値・固有名詞をこのファイルへ書かないこと。** リポジトリに入る。

## 注意

期待文字列は狭く書きすぎない。`plans to` と書くと `We plan to` を取りこぼす。
評価セット側の誤りで「失敗」が出ることがあるため、失敗を見たら
**まず訳文を読んで、訳が悪いのか期待が悪いのかを判断する。**
