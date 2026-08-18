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

  var input = null;
  var directionSelect = null;
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

  /* --- 即答（TM完全一致・個人用語集）------------------------------------ */

  function renderInstant(data) {
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
        el('palette-result').innerHTML = '<div class="alert alert-warning">翻訳をやめました。</div>';
        return;
      }
      if (['error', 'failed'].indexOf(data.mode) >= 0) {
        jobRunning = false;
        setChipsBusy(false);
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
    el('palette-result').innerHTML = jobLoadingHtml('丁寧にしています', 0, '');
    YakuCommon.post('/api/palette/chip', {
      chip: chip, source_text: lastSourceText, current_text: lastMaskedTranslation,
      direction: lastDirection, style: lastStyle
    }).then(function (data) {
      if (mySeq !== translateSeq) return;
      jobRunning = true;
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

  function start() {
    input = el('palette-input');
    directionSelect = el('palette-direction-select');
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
