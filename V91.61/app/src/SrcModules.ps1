# 読み込み順序の唯一の出典。
#
# なぜ要るか（2026-08-12 に実測して分かったこと）:
#   Server.ps1 の中に、同じ意味の一覧が4つ手で書き写されていた。本体の30件と、
#   別ランスペースで動くプリロード3か所の22件である。写し間違いは静かに効く。
#   実際 GlossaryVariants.ps1 はどの一覧にも入っておらず、CellAlign.ps1 が
#   ConvertTo-YakuPeriodNeutralName を Get-Command で守って呼んでいたため、
#   その機能は動くアプリの中で一度も実行されていなかった。試験は自分で
#   dot-source して通していたので、緑のまま気づけなかった。
#
# ここは配列を置くだけにする。読み込む処理そのものは各所に2行で書く。
# PowerShell 5.1 では、関数の中で dot-source しても呼び出し元のスコープへ
# 関数が入らない。「読み込む関数」を作ると、その関数を抜けた時点で消える。
#
# 並べ替えないこと。この順序は依存関係にもとづく実測済みの並びで、
# 先に読む側の $script: 変数に後ろが依存している箇所がある。
# 足すときは末尾ではなく、最初に使う場所の直前へ入れる。
#
# 意図して外しているもの（src\*.ps1 の一覧との差は、必ずこの3つだけ）:
#   Server.ps1       入口。自分自身は読み込まない
#   JobObject.ps1    プロセスに1回だけ。Start-YakuLingo.ps1 が読む
#   SrcModules.ps1   このファイル自身
$script:YakuSrcModuleFiles = @(
    'Paths.ps1',
    'Runtime.ps1',
    'Html.ps1',
    'Settings.ps1',
    'PromptBuilder.ps1',
    'EdgeLaunch.ps1',
    'CopilotBudget.ps1',
    'CopilotClient.ps1',
    'Translation.ps1',
    'FileProcessors.ps1',
    'CatBatch.ps1',
    'CatTranslation.ps1',
    'Corpus.ps1',
    'CorpusSearch.ps1',
    'CorpusReference.ps1',
    'BriefStyle.ps1',
    'CellSegments.ps1',
    'GlossaryVariants.ps1',
    'CellAlign.ps1',
    'AlignMask.ps1',
    'Alignment.ps1',
    'Terminology.ps1',
    'PersonalGlossary.ps1',
    'TranslationMemory.ps1',
    'CorpusPairs.ps1',
    'WordAdapter.ps1',
    'CatProject.ps1',
    'QuickArtifact.ps1',
    'Selection.ps1',
    'VersionUpdate.ps1',
    'DesktopIntegration.ps1'
)
