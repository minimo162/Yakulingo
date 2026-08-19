(function () {
  'use strict';

  /* お手軽翻訳（/palette）。「貼ったら即訳が出る」小窓のための、独立した画面。
     cat.js・quick.js には触れない（別の画面として作る）。

     貼り付け(paste)だけが自動翻訳の引き金。タイプしただけでは送らない
     （1打鍵ごとにCopilotへ送ると、往復も費用も打鍵の数だけ増える）。
     自動で始めたら、続けて 1〜9 / Enter / Esc がキーボードだけで通るように、
     入力欄からフォーカスを外す（外さないと、押した数字がそのまま入力欄へ
     文字として入ってしまう）。 */

  function el(id) { return document.getElementById(id); }

  /* パレットの昇格(「CATで開く」)。移動の直前だけ sessionStorage へ退避し、
     CAT側(cat.js)が起動時に一度だけ読んで消す。quick.js の draft退避
     (draftStorageKey)と同じ流儀——作業や翻訳メモリには保存せず、
     読まれれば消える。 */
  var handoffStorageKey = 'yaku.palette.handoff';

  var input = null;
  var directionSelect = null;
  var handoffButton = null;
  var candidates = [];
  var translateSeq = 0;
  var jobTimer = null;
  var pendingTranslate = null;
  var jobRunning = false;
  var explicitDirection = '';
  // 方向確認(409)の対象になった、まさにそのときの原文。ボタンを押した時点の
  // input.value を当てにすると、待っている間に原文を書き換えた利用者が
  // 「判定していない文章」へ確定方向を適用してしまう(NIT-D)。
  var directionConfirmContext = null;
  var lastSourceText = '';
  var lastMaskedTranslation = '';
  var lastDirection = '';
  var lastStyle = 'full';

  /* 1回の依頼に入る文字数。/cat の確認作業と同じ設定値を、画面側で決め直さない。 */
  function maxBatchChars() {
    var node = document.querySelector('meta[name="yaku-max-batch-chars"]');
    var value = node ? Number(node.getAttribute('content')) : 0;
    return value > 0 ? value : 3000;
  }

  /* 数え方をサーバと揃える。/api/palette/translate は Trim してから
     .Length（UTF-16単位）で見る。ここが Array.from の見た目上の文字数と
     ずれると、画面では送れると出たのにサーバでは断られる、が起きる。 */
  function countChars(text) {
    return String(text || '').trim().length;
  }

  function directionLabel(direction) {
    if (direction === 'to_en') return '日本語 → 英語';
    if (direction === 'to_jp') return '英語 → 日本語';
    return '';
  }

  /* select の値（''=自動 / to_en / to_jp）を、サーバへ渡す direction_intent
     （'auto' / 'to_en' / 'to_jp'）へ揃える。quick.js の explicitDirection と
     同じ考え方：選んだらそれを使い、選んでいなければ自動判定に任せる。 */
  function currentDirectionIntent() {
    return (explicitDirection === 'to_en' || explicitDirection === 'to_jp') ? explicitDirection : 'auto';
  }

  function utf8ToBase64(text) {
    var bytes = new TextEncoder().encode(String(text || ''));
    var binary = '';
    for (var i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
    return btoa(binary);
  }

  function updateCount() {
    var length = countChars(input.value);
    el('palette-count').textContent = length.toLocaleString('ja-JP') + '字';
    var limit = maxBatchChars();
    var notice = el('palette-long-notice');
    if (length > limit) {
      notice.hidden = false;
      notice.textContent = '1回で送れるのは ' + limit.toLocaleString('ja-JP') + '字までです。この文章は ' + length.toLocaleString('ja-JP') + '字あるので、分けて貼り付けてください。';
    } else {
      notice.hidden = true;
    }
    updateHandoffButton();
  }

  /* 「CATで開く」の押せる/押せないを1か所へ集める。本文が無ければ押せない
     （結果の有無は問わない）。翻訳ジョブ実行中も押せない——jobRunning が
     このファイルの busy 概念にあたる(quick.js の busy と同じ役割)。
     busyOverride を渡さないときは現在の jobRunning を見る。
     setChipsBusy と一緒に呼ぶ箇所では、jobRunning がまだ更新される前の
     瞬間があるため、その場のbusy値を明示で渡す。 */
  function updateHandoffButton(busyOverride) {
    if (!handoffButton) return;
    var busy = typeof busyOverride === 'boolean' ? busyOverride : jobRunning;
    handoffButton.disabled = !input.value.trim() || busy;
  }

  function jobLoadingHtml(label, percent, detail) {
    var pct = Math.max(0, Math.min(100, Math.round(Number(percent) || 0)));
    var esc = YakuCommon.escape;
    return '<div class="job-loading"><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase">' + esc(label || '翻訳しています') + '</div><div class="job-percent">' + pct + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳の進み具合" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + pct + '"><span class="job-progress-bar" style="width:' + pct + '%"></span></div>' +
      '<div class="job-bottomline"><div class="job-meta">' + esc(detail || 'Copilotの返事を待っています。') + '</div></div>' +
      '</div></div>';
  }

  /* --- 候補（IME風）--------------------------------------------------- */

  function mainCardText(node) {
    var pre = node.querySelector('[data-yaku-main-text]');
    return pre ? pre.textContent : '';
  }
  function decodeAltText(node) {
    var raw = node.getAttribute('data-yaku-swap') || '';
    try { return YakuCommon.decodeBase64(raw); } catch (error) { return ''; }
  }

  /* 候補の並びは常に「TM完全一致（あれば）→ Copilotの主訳 → 添えの訳」の順。
     TMは自前のカードなので data-yaku-candidate-text を直接持たせる。
     Copilotの2つはサーバが作ったマークアップ（Html.ps1）をそのまま使い、
     そちらは書き換えない。番号は ::before で載せるだけなので、
     マークアップの形には触れない。 */
  function refreshCandidates() {
    var found = [];
    var tmNode = el('palette-tm-candidate');
    if (tmNode) found.push({ node: tmNode, text: tmNode.getAttribute('data-yaku-candidate-text') || '' });
    var main = document.querySelector('#palette-result [data-yaku-main-card]');
    if (main) found.push({ node: main, text: mainCardText(main) });
    var alts = document.querySelectorAll('#palette-result .result-alt[data-yaku-swap]');
    for (var i = 0; i < alts.length; i++) found.push({ node: alts[i], text: decodeAltText(alts[i]) });
    found = found.slice(0, 9);
    var stale = document.querySelectorAll('[data-yaku-candidate-index]');
    for (var j = 0; j < stale.length; j++) stale[j].removeAttribute('data-yaku-candidate-index');
    found.forEach(function (candidate, index) { candidate.node.setAttribute('data-yaku-candidate-index', String(index + 1)); });
    candidates = found;
    // 学習（用語登録先行）。候補ごとに「覚える」を1つ添える。既に付いていれば
    // 何もしない(冪等)——finishJob/swapAltIntoMainのたびに何度も通る関数なので、
    // 押した直後の disabled/文言をここで巻き戻してはならない。
    found.forEach(function (candidate) { ensureLearnButtonFor(candidate); });
    updateHintTarget();
  }

  /* 「Enterで既定候補をコピー」の“既定候補”が何かを、帯（常に見える場所）へ
     名指しする。小窓では候補1（TM完全一致のことが多い）が画面外に隠れうる
     ——主訳のほうへ視線を寄せるため（revealMainResult）。見えていないものを
     「既定候補」とだけ言うのは不誠実なので、実際に何がコピーされるかを書く。 */
  function updateHintTarget() {
    var span = el('palette-hint-target');
    if (!span) return;
    if (candidates.length === 0) { span.textContent = '既定候補'; return; }
    var node = candidates[0].node;
    if (node.id === 'palette-tm-candidate') { span.textContent = '訳文メモリの候補'; return; }
    if (node.hasAttribute && node.hasAttribute('data-yaku-main-card')) { span.textContent = '標準訳'; return; }
    span.textContent = '既定候補';
  }

  // 上端の余白。0にすると角がぴったり画面端に付き、窮屈に見える。
  var VISIBLE_TOP_LIMIT = 4;

  /* 帯（.palette-footer）に隠れない、実際に見える範囲の下端。position:sticky
     で下に貼り付くぶんだけ、innerHeight より狭い。 */
  function visibleBottomLimit() {
    var footer = document.querySelector('.palette-footer');
    var footerHeight = footer ? footer.getBoundingClientRect().height : 0;
    return window.innerHeight - footerHeight;
  }

  function isFullyVisible(node) {
    if (!node) return false;
    var rect = node.getBoundingClientRect();
    return rect.top >= VISIBLE_TOP_LIMIT && rect.bottom <= visibleBottomLimit();
  }

  /* 対象ノードを画面内へ寄せる。小窓(480x640)では結果がそのまま流し込まれると
     枠の外に出て、二度と見えないままだった（実測: 主訳カード bottom=844、
     TM込みで top=880、いずれも innerHeight=640 の外）。

     block:'center' で寄せると、今度は逆に原文欄が画面の外へ押し出された
     （実測: 結果を挿し込んだ直後、#palette-input の bottom が
     1912x987で-101、480x640で-467——原文併記(仕様item 3)が崩れる）。

     ブラウザ標準の scrollIntoView({block:'nearest'}) にも乗り換えたが、
     これも実測で当てにならなかった：帯(.palette-footer)は position:sticky
     で見た目だけ最下部に貼り付くレンダリングの効果であり、ブラウザの
     scrollIntoView はスクロール領域の実サイズ(=innerHeight)しか知らない。
     scroll-margin を主札へ足しても、実測では主札の下端が帯の下まで
     入り込んだまま(bottom=619, 帯の上端=550)で、しかも原文欄は
     大きく上へ追いやられた(top=-234)。「最小移動」のはずが最小になって
     いなかった。

     ここでは自前で移動量を計算する。帯を差し引いた実際に見える範囲
     （visibleBottomLimit）に対して、対象の下端が出ていれば「出ている分」
     だけ、上端が出ていれば「出ている分」だけ動かす——これが本当の意味の
     最小移動で、対象の高さが見える範囲に収まる限り必ずぴったり収まる。 */
  function revealNode(node) {
    if (!node) return;
    if (isFullyVisible(node)) return;
    var rect = node.getBoundingClientRect();
    var bottomLimit = visibleBottomLimit();
    var deltaY = 0;
    if (rect.bottom > bottomLimit) { deltaY = rect.bottom - bottomLimit; }
    else if (rect.top < VISIBLE_TOP_LIMIT) { deltaY = rect.top - VISIBLE_TOP_LIMIT; }
    if (deltaY === 0) return;
    var reduced = false;
    try { reduced = !!(YakuCommon.reducedMotion && YakuCommon.reducedMotion()); } catch (error) { reduced = false; }
    window.scrollBy({ top: deltaY, left: 0, behavior: reduced ? 'auto' : 'smooth' });
  }

  /* 結果が出ている間は入力欄を縮める（6行→2行）。'nearest' 単独では、
     480x640では主訳カードが帯の裏に隠れたままになる（実測）。全文は
     見えなくなっても、原文の一部・訳・キー案内が同時に画面へ収まる方を
     優先する（原文併記は"一部でも"見せれば足りる、との仕様側の言葉どおり）。 */
  function setCompactInput(compact) {
    if (!input) return;
    input.rows = compact ? 2 : 6;
    input.classList.toggle('is-compact', compact);
  }

  /* Copilotの訳が届いたら、即答(TM/用語)は参照でしかない。全文を見せ続ける
     ぶんの高さが、原文欄を画面外へ押し出す主因だった（MAJOR-B）。中身は
     変えず(1キーでのコピーは全文のまま)、見た目だけ畳む。 */
  function setCompactInstant(compact) {
    var box = el('palette-instant');
    if (!box) return;
    box.classList.toggle('is-compact', compact);
  }

  /* 先頭候補（TMがあればTM、無ければ主訳）を画面内へ寄せる。貼り付け直後、
     まだCopilotの訳が届いていない段階で使う。 */
  function revealFirstCandidate() {
    if (candidates.length === 0) return;
    revealNode(candidates[0].node);
  }

  /* Copilotの主訳を画面内へ寄せる。TMの即答が先に出ていても、ジョブが
     届いたらそちらへ視線を戻す——「先頭候補」で寄せると、TMが残っている間は
     常にTMへ引き戻され、今しがた届いた主訳が視界に入らないままになる。 */
  function revealMainResult() {
    var main = document.querySelector('#palette-result [data-yaku-main-card]');
    if (main) { revealNode(main); return; }
    revealFirstCandidate();
  }

  function candidateForNode(node) {
    for (var i = 0; i < candidates.length; i++) {
      if (candidates[i].node === node || candidates[i].node.contains(node)) return { candidate: candidates[i], index: i + 1 };
    }
    return null;
  }

  function copyCandidate(candidate, displayIndex) {
    if (!candidate || !candidate.text) return;
    YakuCommon.copyText(candidate.text).then(function (ok) {
      var status = el('palette-copy-status');
      status.textContent = ok
        ? ('候補' + displayIndex + 'をコピーしました。')
        : 'コピーできませんでした。もう一度お試しください。';
    });
  }

  /* Html.ps1 は添え札の下に「押すと上と入れ替わります」と案内している
     （data-yaku-swap の由来）。ここは実際に入れ替える：添え札を押すと、
     主札（コピー対象の既定=候補1）とその添え札の中身をそっくり交換する。
     数字キー(1〜9)でのコピーは変えない——マウスの押下だけが「入れ替え」で、
     キーは常に「その場でコピー」のまま（丁寧にチップは、入れ替えとは
     別に、ジョブが作った標準訳(masked_translation)を直し続ける）。 */
  function buildAltFragment(text, kindLabel) {
    var head = document.createElement('span');
    head.className = 'result-alt-head';
    head.appendChild(document.createTextNode(kindLabel));
    var chars = document.createElement('span');
    chars.className = 'result-alt-chars';
    chars.textContent = text.length + ' 字';
    head.appendChild(chars);
    var body = document.createElement('span');
    body.className = 'result-alt-body';
    var preview = text.length > 90 ? text.substring(0, 90) + '…' : text;
    body.textContent = preview;
    return { head: head, body: body };
  }

  function swapAltIntoMain(altButton) {
    var mainCard = document.querySelector('#palette-result [data-yaku-main-card]');
    if (!mainCard || !altButton) return;
    var mainPre = mainCard.querySelector('[data-yaku-main-text]');
    var mainCopyBtn = mainCard.querySelector('[data-yaku-copy-b64]');
    var mainKindEl = mainCard.querySelector('[data-yaku-main-kind]');
    if (!mainPre || !mainCopyBtn || !mainKindEl) return;

    var mainText = mainPre.textContent;
    var mainKindText = mainKindEl.textContent;
    var incomingText = decodeAltText(altButton);
    var incomingKindText = altButton.getAttribute('data-yaku-swap-kind') || mainKindText;

    mainPre.textContent = incomingText;
    mainCopyBtn.setAttribute('data-yaku-copy-b64', utf8ToBase64(incomingText));
    mainKindEl.textContent = incomingKindText;

    altButton.setAttribute('data-yaku-swap', utf8ToBase64(mainText));
    altButton.setAttribute('data-yaku-swap-kind', mainKindText);
    var oldHead = altButton.querySelector('.result-alt-head');
    var oldBody = altButton.querySelector('.result-alt-body');
    var rebuilt = buildAltFragment(mainText, mainKindText);
    if (oldHead && oldHead.parentNode) oldHead.parentNode.replaceChild(rebuilt.head, oldHead); else altButton.appendChild(rebuilt.head);
    if (oldBody && oldBody.parentNode) oldBody.parentNode.replaceChild(rebuilt.body, oldBody); else altButton.appendChild(rebuilt.body);

    refreshCandidates();
    revealMainResult();
  }

  /* --- 学習（用語登録先行）------------------------------------------------
     パレットで得た訳を1クリックで個人用語集へ登録する。構想図の「学習」の
     前半（TMへの登録は素性設計が要るため後続に分離、スコープ外）。

     480x640では主札の下端と帯の間の余白が実測24px前後しかない(CoD審査)。
     新しい行を1つ増やすだけで候補1(主札)が帯の裏へ沈むので、TM・主訳の
     釦は既存の行の中(または絶対配置で高さに寄与しない場所)に収め、
     新しい行を増やさない。添え候補(候補2以降)は画面内に収まる保証の対象
     外なので、そこだけ新しい行を許す。 */

  function looksLikeSentence(text) {
    // 「文」に見えるかの判定。しきい値40字は、既存の個人用語集書き込み
    // (PersonalGlossary.ps1のAdd-YakuPersonalGlossaryEntry、40字超だと弾く)
    // と同じ値を流用した——ここは弾かず確認を挟むだけなので、禁止を発明
    // しない(8/17の利用者判断)。
    //
    // 全角の句点・疑問符・感嘆符（。．！？）と改行は常に「文」とみなす。
    // 半角ピリオド(.)だけは別扱いにする——単純に「.を含む」で判定すると、
    // 'U.S.'・'Ltd.'・'No.1' のような語句までいちいち確認ダイアログを
    // 挟んでしまう(CoD審査 REWORK-1 MINOR-D の実測)。ここでは「直前が
    // 単語境界から始まる2文字以上の小文字の並びで、直後が空白か文字列の
    // 終端」のときだけ終止符として数える——'U.S.'は直前が大文字の頭文字
    // (U/S)、'Ltd.'は単語の先頭が大文字(L)なので単語境界からの小文字の並び
    // にならず、'No.1'は直後が数字なので、どれも外れる。
    // 単純さを優先した割り切りなので、'etc.'のような全部小文字の略語は
    // 依然として引っかかるし、文末が大文字始まりの単語(固有名詞など)で
    // 終わる英文は逆に拾えない——どちらも「確認を1回増やすかどうか」の
    // ガードでしかなく、しきい値40字が保険になる(8/17の利用者判断どおり、
    // 決め打ちの禁止ではない)。
    if (!text) return false;
    if (/[\r\n]/.test(text)) return true;
    if (/[。．！？!?]/.test(text)) return true;
    if (/\b[a-z]{2,}\.(?:\s|$)/.test(text)) return true;
    return text.length > 40;
  }

  /* instantの取り直し(renderInstant)はTM候補の<div>を丸ごと作り直す
     ——ボタンも新品に戻るので、間を置かずに取り直すと登録結果の表示を
     利用者が読む前に消してしまう(実測: 実機Chromiumで0ms後に読むと
     "覚える"のまま)。確認を読めるだけの間を置いてから取り直す。 */
  var TERM_LEARN_REFRESH_DELAY_MS = 900;
  /* 成功/失敗どちらの表示も、この時間だけ見せたら元の「覚える」へ戻す
     (CoD審査 REWORK-1 MINOR-C: 主訳・添え候補は次の翻訳が始まるまで
     DOMが作り直されないため、restoreLabelが無いと「覚えました」が
     押せる状態のまま残り続けていた)。 */
  var TERM_LEARN_RESTORE_DELAY_MS = 4000;

  /* 釦自体の文言は状態を表す2〜4文字だけにする(CoD審査 REWORK-1
     MINOR-A: 480x640ではTM候補の圧縮時カードが高さ43.3pxしかなく、
     「登録しています…」「覚えました」のような長い文言は候補本文へ
     56px/24pxもはみ出して重なった、実測)。詳細な文言(重複の案内・
     サーバのエラー本文)は、候補の近くではなく帯の共有行
     (#palette-copy-status、コピー結果と同じ場所)へ出す(MINOR-B)。 */
  function setTermLearnStatusLine(text) {
    var status = el('palette-copy-status');
    if (status) status.textContent = text;
  }

  function sendTermLearn(button, sourceText, targetText) {
    button.disabled = true;
    var seqAtClick = translateSeq;
    button.textContent = '登録中';
    YakuCommon.post('/api/palette/term-learn', { source: sourceText, target: targetText, direction: lastDirection }).then(function (data) {
      button.disabled = false;
      button.textContent = '済み';
      setTermLearnStatusLine((data && data.message) || '覚えました。次から同じ訳が出ます。');
      window.setTimeout(function () {
        if (button.textContent === '済み') button.textContent = '覚える';
      }, TERM_LEARN_RESTORE_DELAY_MS);
      // 即効性の見える化: 即答欄が開いていれば同じ原文でinstantを取り直し、
      // 登録した用語がその場で反映されることを見せる(学習の魔法の瞬間)。
      var instantBox = el('palette-instant');
      if (instantBox && !instantBox.hidden) {
        window.setTimeout(function () {
          if (seqAtClick !== translateSeq) return;
          fireInstant(sourceText, currentDirectionIntent(), translateSeq);
        }, TERM_LEARN_REFRESH_DELAY_MS);
      }
    }).catch(function (error) {
      button.disabled = false;
      button.textContent = 'エラー';
      setTermLearnStatusLine((error && error.message) || '登録できませんでした。');
      window.setTimeout(function () {
        if (button.textContent === 'エラー') button.textContent = '覚える';
      }, TERM_LEARN_RESTORE_DELAY_MS);
    });
  }

  /* getTarget は候補のテキストをクリックの瞬間に読み直す関数
     （スナップショットを閉じ込めない）。添え札は入れ替え(swapAltIntoMain)で
     中身が変わるため、これが無いと入れ替え後も古い訳文を登録してしまう。 */
  function wireLearnButton(button, getTarget) {
    button.addEventListener('click', function (event) {
      // TM候補・添え候補はカード/釦自体がクリックで別の動作(コピー/入れ替え)を
      // 持つ委譲先(document)の子孫にある。ここで止めないと、覚える釦を押した
      // つもりが同時にコピーや入れ替えも起きてしまう。
      event.stopPropagation();
      if (button.disabled) return;
      var sourceText = input.value.trim();
      var targetText = String(getTarget() || '').trim();
      if (!sourceText || !targetText) return;
      if (looksLikeSentence(sourceText)) {
        if (!window.confirm('文章そのものを用語として覚えます。よろしいですか?')) return;
      }
      sendTermLearn(button, sourceText, targetText);
    });
  }

  function buildLearnButton(extraClass) {
    var button = document.createElement('button');
    button.type = 'button';
    button.className = extraClass ? ('term-learn-button ' + extraClass) : 'term-learn-button';
    button.setAttribute('data-yaku-term-learn', '1');
    button.textContent = '覚える';
    return button;
  }

  /* TM候補: is-compactになると.result-actions(種別ラベル+コピー釦)ごと
     隠れる(既存仕様、480x640で高さを詰めるため)。覚える釦をその中に置くと
     圧縮直後(貼り付けてすぐ)に押せなくなるので、行に依存しない絶対配置に
     する(高さを一切増やさない、palette.cssのterm-learn-corner)。 */
  function ensureTmLearnButton(tmNode) {
    var button = tmNode.querySelector('[data-yaku-term-learn]');
    if (button) return button;
    button = buildLearnButton('term-learn-corner');
    tmNode.appendChild(button);
    wireLearnButton(button, function () { return tmNode.getAttribute('data-yaku-candidate-text') || ''; });
    return button;
  }

  /* 主訳: .result-actionsはis-compactでも隠れない(main.cssの対象外)ので、
     既存の行(種別ラベル+コピー釦)の中へ差し込む。コピー釦の見た目の位置
     (右端)を動かさないよう、コピー釦を覚える釦と同じ小さな器へ包み直す。
     実測: 480px幅でこの行はkind+copy使用後も約76px余っている。 */
  function ensureMainLearnButton(mainCard) {
    var actions = mainCard.querySelector('.result-actions');
    if (!actions) return null;
    var existing = actions.querySelector('[data-yaku-term-learn]');
    if (existing) return existing;
    var button = buildLearnButton('');
    var copyButton = actions.querySelector('[data-yaku-copy-b64]');
    if (copyButton && copyButton.parentNode === actions) {
      var group = document.createElement('span');
      group.className = 'term-learn-group';
      actions.insertBefore(group, copyButton);
      group.appendChild(copyButton);
      group.appendChild(button);
    } else {
      actions.appendChild(button);
    }
    wireLearnButton(button, function () { return mainCardText(mainCard); });
    return button;
  }

  /* 添え候補: 候補1(主札)ではないので、画面内に収まる保証(幾何ゲート)の対象
     外——ここだけ新しい行を増やしてよい。添え札そのものが<button>なので、
     中へ入れ子の<button>を作らない(button-in-buttonはHTML的に不正で、
     クリックの奪い合いにもなる)。代わりに器で包み、覚える釦を兄弟にする。 */
  function ensureAltLearnButton(altNode) {
    var shell = altNode.parentNode;
    if (!shell || !shell.classList || !shell.classList.contains('result-alt-shell')) {
      shell = document.createElement('div');
      shell.className = 'result-alt-shell';
      altNode.parentNode.insertBefore(shell, altNode);
      shell.appendChild(altNode);
    }
    var button = shell.querySelector('[data-yaku-term-learn]');
    if (button) return button;
    button = buildLearnButton('');
    shell.appendChild(button);
    wireLearnButton(button, function () { return decodeAltText(altNode); });
    return button;
  }

  function ensureLearnButtonFor(candidate) {
    var node = candidate.node;
    if (node.id === 'palette-tm-candidate') { ensureTmLearnButton(node); return; }
    if (node.hasAttribute && node.hasAttribute('data-yaku-main-card')) { ensureMainLearnButton(node); return; }
    if (node.classList && node.classList.contains('result-alt')) { ensureAltLearnButton(node); return; }
  }

  /* --- 即答（TM完全一致・個人用語集）------------------------------------ */

  function renderInstant(data) {
    // 「覚える」が/api/palette/term-learnへ送るdirectionは、ジョブ完了時だけ
    // (finishJob)ではなく、即答のみの段階でも要る——TM候補は貼り付け直後の
    // 数秒しかresult-actionsが縮まない(is-compact)前の姿でいないので、その間に
    // 押されても正しい方向で登録できるよう、ここでも同じ変数を更新する。
    if (data && data.direction) { lastDirection = String(data.direction); }
    var box = el('palette-instant');
    box.innerHTML = '';
    var hasTm = !!(data && data.tm && data.tm.target);
    var terms = (data && data.terms) || [];
    if (!hasTm && terms.length === 0) { box.hidden = true; return; }
    box.hidden = false;
    if (hasTm) {
      var card = document.createElement('div');
      card.id = 'palette-tm-candidate';
      card.setAttribute('data-yaku-candidate-text', data.tm.target);
      var pre = document.createElement('pre');
      pre.className = 'translation';
      pre.textContent = data.tm.target;
      card.appendChild(pre);
      var actions = document.createElement('div');
      actions.className = 'result-actions';
      var kind = document.createElement('span');
      kind.className = 'result-kind';
      kind.textContent = '訳文メモリの完全一致（未確認）';
      var copyBtn = document.createElement('button');
      copyBtn.type = 'button';
      copyBtn.className = 'secondary-button copy-button';
      copyBtn.setAttribute('data-yaku-tm-copy', '1');
      copyBtn.textContent = 'コピー';
      actions.appendChild(kind);
      actions.appendChild(copyBtn);
      card.appendChild(actions);
      box.appendChild(card);
    }
    if (terms.length > 0) {
      var head = document.createElement('p');
      head.className = 'palette-instant-title';
      head.textContent = '見つかった用語';
      box.appendChild(head);
      var list = document.createElement('div');
      list.className = 'glossary-preview';
      terms.forEach(function (term) {
        var pill = document.createElement('span');
        pill.className = 'term-pill';
        pill.textContent = String(term.source || '') + ' → ' + String(term.target || '');
        list.appendChild(pill);
      });
      box.appendChild(list);
    }
    refreshCandidates();
    revealFirstCandidate();
  }

  function fireInstant(text, directionIntent, seq) {
    // 「見込みの方向」は出さない(MAJOR-B)。ジョブ完了時に finishJob が
    // 「検出した方向」を出すのでいずれ分かるし、小窓(480x640)では、
    // ここで24px+間隔を使うと原文欄が画面外へ押し出される主因の一つだった。
    YakuCommon.post('/api/palette/instant', { text: text, direction_intent: directionIntent }).then(function (data) {
      if (seq !== translateSeq) return;
      renderInstant(data);
    }).catch(function () {
      // 即答が引けなくても翻訳は続く。コーパス/TMは足しであって前提ではない。
      if (seq !== translateSeq) return;
      el('palette-instant').hidden = true;
    });
  }

  /* --- 翻訳ジョブ --------------------------------------------------------- */

  function setChipsBusy(busy) {
    var buttons = document.querySelectorAll('#palette-chips [data-yaku-chip]');
    for (var i = 0; i < buttons.length; i++) buttons[i].disabled = busy;
  }

  function finishJob(data) {
    jobRunning = false;
    el('palette-result').innerHTML = data.html || '';
    lastSourceText = String(data.source_text || '');
    lastMaskedTranslation = String(data.masked_translation || '');
    lastDirection = String(data.direction || '');
    lastStyle = String(data.style || 'full');
    // レイアウトに効く変更(チップ欄の表示・方向メモの表示)は、必ず
    // revealMainResult() より先に済ませる。チップ欄は結果欄より上にあるので、
    // 後から出すと主札を押し下げ、スクロール量の計算が古い高さのままずれる
    // （実測: 主札を挿し込んだ直後に計算した移動量どおりへ動いたのに、
    // 直後にチップ欄が現れた分(約56px)だけ主札が帯の下へ再びはみ出した）。
    setChipsBusy(false);
    updateHandoffButton(false);
    var chipsBox = el('palette-chips');
    chipsBox.hidden = !(lastSourceText && lastMaskedTranslation);
    if (lastDirection) {
      var label = directionLabel(lastDirection);
      if (label) { el('palette-direction').textContent = '検出した方向: ' + label; el('palette-direction').hidden = false; }
    }
    setCompactInstant(true);
    refreshCandidates();
    revealMainResult();
  }

  function pollJob(jobId, seq, failureCount) {
    window.clearTimeout(jobTimer);
    failureCount = Number(failureCount || 0);
    YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (seq !== translateSeq) return;
      if (['done', 'completed_with_warnings'].indexOf(data.mode) >= 0) { finishJob(data); return; }
      if (data.mode === 'cancelled') {
        jobRunning = false;
        setChipsBusy(false);
        updateHandoffButton(false);
        el('palette-result').innerHTML = '<div class="alert alert-warning">翻訳をやめました。</div>';
        return;
      }
      if (['error', 'failed'].indexOf(data.mode) >= 0) {
        jobRunning = false;
        setChipsBusy(false);
        updateHandoffButton(false);
        /* data.html は Convert-YakuTextResultToHtml が
           ConvertTo-YakuUserFacingError を通した後の安全な文言（例:
           SHORTEN_UNMASKED_CURRENT・EXTERNAL_SEND_*・PROTECTED_PROMPT_* を
           送信中止の定型文へ写す）。data.detail は生のメッセージなので、
           html が無いときだけ最後の手段として使う。 */
        el('palette-result').innerHTML = data.html || ('<div class="alert alert-error">' + YakuCommon.escape(data.detail || '翻訳が途中で止まりました。') + '</div>');
        return;
      }
      el('palette-result').innerHTML = jobLoadingHtml(data.label || data.phase, data.progress, data.detail);
      jobTimer = window.setTimeout(function () { pollJob(jobId, seq, 0); }, 1000);
    }).catch(function () {
      /* 一瞬の通信断でエラーにしない。翻訳はサーバ側で続いている。 */
      if (seq !== translateSeq) return;
      var next = failureCount + 1;
      el('palette-result').innerHTML = jobLoadingHtml(next < 3 ? '進み具合をもう一度確認しています' : '接続の回復を待っています', 0, '翻訳は続いています。画面の更新だけを待っています。');
      jobTimer = window.setTimeout(function () { pollJob(jobId, seq, next); }, Math.min(6000, 800 * Math.pow(2, Math.min(next, 3))));
    });
  }

  function reportJobStartError(error) {
    jobRunning = false;
    updateHandoffButton(false);
    if (error && error.status === 409 && error.data && error.data.code === 'JOB_RUNNING') {
      el('palette-result').innerHTML = '<div class="alert alert-warning">' + YakuCommon.escape('別の翻訳が進行中です。終わってからもう一度お試しください。') + '</div>';
      return;
    }
    el('palette-result').innerHTML = '<div class="alert alert-error">' + YakuCommon.escape((error && error.message) || '翻訳できませんでした。') + '</div>';
  }

  /* 方向がはっきりしないと /api/palette/translate は409で止める
     （Resolve-YakuDirectionDecision 1か所しか判定を持たない決まり。
     即答(/api/palette/instant)は参考情報なので止めないが、Copilotへ実際に
     送るここは止める）。見込みの方向を1つだけ提示し、押す/Enterの1回で
     その方向のまま送り直す。 */
  function showDirectionConfirm(text, suggested, seq) {
    if (seq !== translateSeq) return;
    jobRunning = false;
    updateHandoffButton(false);
    directionConfirmContext = { text: text, suggested: suggested };
    var label = directionLabel(suggested) || suggested;
    el('palette-result').innerHTML =
      '<div class="alert alert-warning">' +
      '<p class="palette-direction-confirm-text">翻訳先をはっきり決められませんでした。</p>' +
      '<button type="button" class="secondary-button compact" data-yaku-direction-confirm="' + YakuCommon.escape(suggested) + '">' + YakuCommon.escape(label) + 'で訳す</button>' +
      '</div>';
    var button = document.querySelector('[data-yaku-direction-confirm]');
    if (button) button.focus();
  }

  function sendTranslate(text, directionIntent, seq) {
    YakuCommon.post('/api/palette/translate', { text: text, direction_intent: directionIntent }).then(function (data) {
      if (seq !== translateSeq) return;
      jobRunning = true;
      /* startTranslationのupdateHandoffButton(true)は、このPOSTの往復中
         ずっと有効なわけではない——待っているあいだに1文字でも打つと
         updateCount()がbusy=jobRunning(まだfalse)で押せる状態へ戻して
         しまう(CoD審査 REWORK-1 MAJOR-A)。jobRunningが実際にtrueへ
         変わるこの瞬間に、あらためて明示で締め直す。 */
      updateHandoffButton(true);
      pollJob(data.job_id, seq, 0);
    }).catch(function (error) {
      if (seq !== translateSeq) return;
      if (error && error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED') {
        showDirectionConfirm(text, String(error.data.suggested_direction || ''), seq);
        return;
      }
      reportJobStartError(error);
    });
  }

  function fireTranslate(text, directionIntent, seq) {
    if (!YakuCommon.isReady()) {
      pendingTranslate = { text: text, directionIntent: directionIntent, seq: seq };
      el('palette-result').innerHTML = '<div class="alert">Copilotの準備ができ次第、この文章を送ります。そのままお待ちください。</div>';
      /* startTranslationのupdateHandoffButton(true)は「送った」ことを
         前提にした締めで、ここは実はまだ送っていない(Copilotの準備待ちで
         足止め)。ジョブは動いていないので押せて当然——待っているあいだ
         こそCATへ逃がしたいはずで、ここを塞ぐとパレットが最も無力な場面で
         昇格も塞ぐことになる(CoD審査 REWORK-1 MINOR-B)。 */
      updateHandoffButton(false);
      return;
    }
    sendTranslate(text, directionIntent, seq);
  }

  function startTranslation(rawText, directionIntent) {
    var text = String(rawText || '');
    if (!text.trim()) return;
    var length = countChars(text);
    var limit = maxBatchChars();
    if (length > limit) {
      var notice = el('palette-long-notice');
      notice.hidden = false;
      notice.textContent = '1回で送れるのは ' + limit.toLocaleString('ja-JP') + '字までです。この文章は ' + length.toLocaleString('ja-JP') + '字あるので、分けて貼り付けてください。';
      return;
    }
    el('palette-long-notice').hidden = true;
    pendingTranslate = null;
    var mySeq = ++translateSeq;
    window.clearTimeout(jobTimer);
    jobRunning = false;
    updateHandoffButton(true);
    candidates = [];
    el('palette-chips').hidden = true;
    el('palette-copy-status').textContent = '';
    el('palette-instant').hidden = true;
    el('palette-instant').innerHTML = '';
    el('palette-direction').hidden = true;
    // 結果欄がこれから伸びる。原文欄を縮めて、原文・訳・キー案内が
    // 480x640でも同時に収まる余地を作る（MAJOR-B）。
    setCompactInput(true);
    /* 体感即時：ネットワークの応答を待たず、最初の描画をここで作る。
       スピナー単独ではなく、字数と状態が読める形にする。 */
    el('palette-result').innerHTML = jobLoadingHtml('取り込んでいます', 0, length.toLocaleString('ja-JP') + '字を確認しています。');
    fireInstant(text, directionIntent, mySeq);
    fireTranslate(text, directionIntent, mySeq);
  }

  /* --- 注文チップ（丁寧に）------------------------------------------------ */

  function onChipClick(button) {
    if (button.disabled || button.hidden) return;
    if (!lastSourceText || !lastMaskedTranslation) return;
    var chip = button.getAttribute('data-yaku-chip');
    var mySeq = ++translateSeq;
    window.clearTimeout(jobTimer);
    // startTranslation と同じく、直前の結果ノードを指したままの候補を捨てる。
    // 捨てないと、ジョブ中に1〜9を押すと消えたノードのテキストをコピーする。
    candidates = [];
    setChipsBusy(true);
    updateHandoffButton(true);
    el('palette-result').innerHTML = jobLoadingHtml('丁寧にしています', 0, '');
    YakuCommon.post('/api/palette/chip', {
      chip: chip, source_text: lastSourceText, current_text: lastMaskedTranslation,
      direction: lastDirection, style: lastStyle
    }).then(function (data) {
      if (mySeq !== translateSeq) return;
      jobRunning = true;
      // 同じ穴(CoD審査 REWORK-1 MAJOR-A)がここにもある。setChipsBusy(true)
      // 直後のupdateHandoffButton(true)は、このPOSTの往復中に1文字でも
      // 打たれると打ち消される。jobRunningが実際にtrueへ変わる瞬間に
      // 締め直す。
      updateHandoffButton(true);
      pollJob(data.job_id, mySeq, 0);
    }).catch(function (error) {
      if (mySeq !== translateSeq) return;
      setChipsBusy(false);
      reportJobStartError(error);
    });
  }

  /* --- クリア(Esc) --------------------------------------------------------- */

  function clearAll() {
    translateSeq++;
    pendingTranslate = null;
    jobRunning = false;
    window.clearTimeout(jobTimer);
    input.value = '';
    setCompactInput(false);
    setCompactInstant(false);
    updateCount();
    el('palette-instant').hidden = true; el('palette-instant').innerHTML = '';
    el('palette-result').innerHTML = '';
    el('palette-chips').hidden = true;
    el('palette-copy-status').textContent = '';
    el('palette-direction').hidden = true;
    el('palette-long-notice').hidden = true;
    candidates = [];
    updateHintTarget();
    lastSourceText = ''; lastMaskedTranslation = ''; lastDirection = ''; lastStyle = 'full';
    explicitDirection = '';
    directionConfirmContext = null;
    if (directionSelect) directionSelect.value = '';
    input.focus();
  }

  /* --- 配線 ----------------------------------------------------------------- */

  function onDocumentClick(event) {
    // コピー釦(data-yaku-tm-copy)は圧縮時(is-compact)に隠すので、カードの
    // どこを押しても拾えるようにする(圧縮していないときは釦を押しても同じ)。
    var tmCopy = event.target.closest('#palette-tm-candidate');
    if (tmCopy) { var hitTm = candidateForNode(tmCopy); if (hitTm) copyCandidate(hitTm.candidate, hitTm.index); return; }
    var mainCopy = event.target.closest('[data-yaku-main-card] [data-yaku-copy-b64]');
    if (mainCopy) { var hitMain = candidateForNode(mainCopy); if (hitMain) copyCandidate(hitMain.candidate, hitMain.index); return; }
    // 添え札は「押すと上と入れ替わる」（Html.ps1の案内文どおり）。コピーは
    // 数字キー/主札の方のボタンに残す。
    var alt = event.target.closest('.result-alt[data-yaku-swap]');
    if (alt) { swapAltIntoMain(alt); return; }
    var directionConfirm = event.target.closest('[data-yaku-direction-confirm]');
    if (directionConfirm) {
      var suggested = directionConfirm.getAttribute('data-yaku-direction-confirm');
      var context = directionConfirmContext;
      directionConfirmContext = null;
      if (suggested === 'to_en' || suggested === 'to_jp') {
        if (context && input.value === context.text) {
          // 待っている間に原文が変わっていない。判定した原文そのものを、
          // 確定した方向で送り直す(NIT-D: input.value を当てにしない)。
          explicitDirection = suggested;
          if (directionSelect) directionSelect.value = suggested;
          startTranslation(context.text, suggested);
        } else {
          // 原文が変わっていた。古い判定を新しい原文へ当てはめない
          // ——通常の自動フローへ戻し、今の原文をあらためて判定させる。
          startTranslation(input.value, currentDirectionIntent());
        }
      }
      return;
    }
    var chip = event.target.closest('[data-yaku-chip]');
    if (chip) { onChipClick(chip); return; }
  }

  function isInteractiveTarget(node) {
    if (!node || !node.tagName) return false;
    var tag = node.tagName;
    return tag === 'BUTTON' || tag === 'A' || tag === 'SELECT' || tag === 'INPUT' || !!node.isContentEditable;
  }

  /* 数字1〜9・Enter・Escはキーボード完結の要。ただし入力欄で打っている
     最中は素通りさせる（でないと貼った直後に数字が打てない、では済まず、
     普通に文章を打つことさえできなくなる）。方向確認ボタンやコピー釦に
     フォーカスがあるときも素通りさせる——そこでのEnterは「そのボタンを押す」
     が正しい動作で、候補1のコピーへ奪ってはならない。Ctrl+Enterは
     入力欄からでも翻訳を起こす（他画面の作法に合わせる）。 */
  function onDocumentKeydown(event) {
    if (event.isComposing) return;
    if (event.key === 'Escape') { event.preventDefault(); clearAll(); return; }
    var typingInInput = (document.activeElement === input);
    if (typingInInput && (event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      startTranslation(input.value, currentDirectionIntent());
      input.blur();
      return;
    }
    if (typingInInput) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    /* isInteractiveTarget はEnterだけに掛ける。数字キーには掛けない——
       添え札(スワップ)やコピー釦をクリックした直後は activeElement がその
       <button> のままになるが、そこで1〜9が無反応になってはならない
       （実測: スワップ後に2/3を押してもクリップボードへ一切書かれなかった）。
       Enterだけは「フォーカス中のボタンを押す」が正しい既定動作なので、
       そちらに限って譲る。 */
    if (event.key === 'Enter') {
      if (isInteractiveTarget(event.target)) return;
      if (candidates.length === 0) return;
      event.preventDefault();
      copyCandidate(candidates[0], 1);
      return;
    }
    if (event.key >= '1' && event.key <= '9') {
      var idx = Number(event.key) - 1;
      if (idx >= candidates.length) return;
      event.preventDefault();
      copyCandidate(candidates[idx], idx + 1);
    }
  }

  /* 翻訳の往復中に閉じられると、その場のCopilot呼び出しが宙に浮く。
     common.jsは触らない（quick.js/cat.jsの離脱確認と混ぜない）ので、
     ここだけの離脱確認を持つ。ジョブが動いている間だけ有効。 */
  function onBeforeUnload(event) {
    if (!jobRunning) return;
    event.preventDefault();
    event.returnValue = '';
  }

  /* 「CATで開く」。本文(と、明示選択されていれば方向)を sessionStorage の
     専用キーへ退避し、/cat?handoff=palette へ移る（別タブは開かない——
     小窓運用ではウィンドウがそのままCATになる。Edge appモードの小窓で
     別タブは体験を壊す）。CAT側(cat.js)は起動時にこのキーを一度だけ読んで
     消し、既存の yaku-instant-handoff 受け口へそのまま渡す（ここでは
     その処理を複製しない）。 */
  function startHandoff() {
    if (handoffButton.disabled) return;
    var text = input.value;
    if (!text.trim()) return;
    try {
      window.sessionStorage.setItem(handoffStorageKey, JSON.stringify({
        text: text,
        direction_intent: currentDirectionIntent()
      }));
    } catch (error) {}
    window.location.assign('/cat?handoff=palette');
  }

  function start() {
    input = el('palette-input');
    directionSelect = el('palette-direction-select');
    handoffButton = el('palette-handoff');
    if (!input || !el('palette-form')) return;
    YakuCommon.start();
    input.addEventListener('input', function (event) {
      updateCount();
      /* 貼り付け(paste)だけが自動翻訳の引き金。inputType で見分ける
         （'paste' イベントは値の反映前に発火するため使わない）。 */
      if (event.inputType === 'insertFromPaste') {
        var text = input.value;
        window.setTimeout(function () { input.blur(); }, 0);
        startTranslation(text, currentDirectionIntent());
      }
    });
    el('palette-form').addEventListener('submit', function (event) {
      event.preventDefault();
      startTranslation(input.value, currentDirectionIntent());
      input.blur();
    });
    if (directionSelect) {
      directionSelect.addEventListener('change', function () {
        var value = directionSelect.value;
        explicitDirection = (value === 'to_en' || value === 'to_jp') ? value : '';
      });
    }
    if (handoffButton) handoffButton.addEventListener('click', startHandoff);
    document.addEventListener('click', onDocumentClick);
    document.addEventListener('keydown', onDocumentKeydown);
    window.addEventListener('beforeunload', onBeforeUnload);
    YakuCommon.onReady(function (ready) {
      if (!ready || !pendingTranslate) return;
      var p = pendingTranslate;
      pendingTranslate = null;
      if (p.seq === translateSeq) sendTranslate(p.text, p.directionIntent, p.seq);
    });
    updateCount();
    input.focus();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
