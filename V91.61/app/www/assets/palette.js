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
  var candidates = [];
  var translateSeq = 0;
  var jobTimer = null;
  var pendingTranslate = null;
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

  function directionLabel(direction) {
    if (direction === 'to_en') return '日本語 → 英語';
    if (direction === 'to_jp') return '英語 → 日本語';
    return '';
  }

  function updateCount() {
    var text = input.value;
    var length = Array.from(text).length;
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
  function altText(node) {
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
    for (var i = 0; i < alts.length; i++) found.push({ node: alts[i], text: altText(alts[i]) });
    found = found.slice(0, 9);
    var stale = document.querySelectorAll('[data-yaku-candidate-index]');
    for (var j = 0; j < stale.length; j++) stale[j].removeAttribute('data-yaku-candidate-index');
    found.forEach(function (candidate, index) { candidate.node.setAttribute('data-yaku-candidate-index', String(index + 1)); });
    candidates = found;
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
  }

  function fireInstant(text, directionIntent, seq) {
    YakuCommon.post('/api/palette/instant', { text: text, direction_intent: directionIntent }).then(function (data) {
      if (seq !== translateSeq) return;
      renderInstant(data);
      if (data && data.direction) {
        var label = directionLabel(data.direction);
        if (label) { el('palette-direction').textContent = '見込みの方向: ' + label; el('palette-direction').hidden = false; }
      }
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
    el('palette-result').innerHTML = data.html || '';
    lastSourceText = String(data.source_text || '');
    lastMaskedTranslation = String(data.masked_translation || '');
    lastDirection = String(data.direction || '');
    lastStyle = String(data.style || 'full');
    refreshCandidates();
    setChipsBusy(false);
    var chipsBox = el('palette-chips');
    if (lastSourceText && lastMaskedTranslation) {
      chipsBox.hidden = false;
      // 短くするのは英訳専用（Invoke-YakuTextShorten が to_en 決め打ち）。
      var shortenBtn = chipsBox.querySelector('[data-yaku-chip="shorten"]');
      if (shortenBtn) shortenBtn.hidden = (lastDirection !== 'to_en');
    } else {
      chipsBox.hidden = true;
    }
    if (lastDirection) {
      var label = directionLabel(lastDirection);
      if (label) { el('palette-direction').textContent = '検出した方向: ' + label; el('palette-direction').hidden = false; }
    }
  }

  function pollJob(jobId, seq, failureCount) {
    window.clearTimeout(jobTimer);
    failureCount = Number(failureCount || 0);
    YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (seq !== translateSeq) return;
      if (['done', 'completed_with_warnings'].indexOf(data.mode) >= 0) { finishJob(data); return; }
      if (data.mode === 'cancelled') {
        setChipsBusy(false);
        el('palette-result').innerHTML = '<div class="alert alert-warning">翻訳をやめました。</div>';
        return;
      }
      if (['error', 'failed'].indexOf(data.mode) >= 0) {
        setChipsBusy(false);
        el('palette-result').innerHTML = '<div class="alert alert-error">' + YakuCommon.escape(data.detail || '翻訳が途中で止まりました。') + '</div>';
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
    if (error && error.status === 409 && error.data && error.data.code === 'JOB_RUNNING') {
      el('palette-result').innerHTML = '<div class="alert alert-warning">' + YakuCommon.escape('別の翻訳が進行中です。終わってからもう一度お試しください。') + '</div>';
      return;
    }
    el('palette-result').innerHTML = '<div class="alert alert-error">' + YakuCommon.escape((error && error.message) || '翻訳できませんでした。') + '</div>';
  }

  function sendTranslate(text, directionIntent, seq) {
    YakuCommon.post('/api/palette/translate', { text: text, direction_intent: directionIntent }).then(function (data) {
      if (seq !== translateSeq) return;
      pollJob(data.job_id, seq, 0);
    }).catch(function (error) {
      if (seq !== translateSeq) return;
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
    var length = Array.from(text).length;
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
    candidates = [];
    el('palette-chips').hidden = true;
    el('palette-copy-status').textContent = '';
    el('palette-instant').hidden = true;
    el('palette-instant').innerHTML = '';
    el('palette-direction').hidden = true;
    /* 体感即時：ネットワークの応答を待たず、最初の描画をここで作る。
       スピナー単独ではなく、字数と状態が読める形にする。 */
    el('palette-result').innerHTML = jobLoadingHtml('取り込んでいます', 0, length.toLocaleString('ja-JP') + '字を確認しています。');
    fireInstant(text, directionIntent, mySeq);
    fireTranslate(text, directionIntent, mySeq);
  }

  /* --- 注文チップ（短く／丁寧に）------------------------------------------ */

  function onChipClick(button) {
    if (button.disabled || button.hidden) return;
    if (!lastSourceText || !lastMaskedTranslation) return;
    var chip = button.getAttribute('data-yaku-chip');
    var mySeq = ++translateSeq;
    window.clearTimeout(jobTimer);
    setChipsBusy(true);
    el('palette-result').innerHTML = jobLoadingHtml(chip === 'shorten' ? '短くしています' : '丁寧にしています', 0, '');
    YakuCommon.post('/api/palette/chip', {
      chip: chip, source_text: lastSourceText, current_text: lastMaskedTranslation,
      direction: lastDirection, style: lastStyle
    }).then(function (data) {
      if (mySeq !== translateSeq) return;
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
    window.clearTimeout(jobTimer);
    input.value = '';
    updateCount();
    el('palette-instant').hidden = true; el('palette-instant').innerHTML = '';
    el('palette-result').innerHTML = '';
    el('palette-chips').hidden = true;
    el('palette-copy-status').textContent = '';
    el('palette-direction').hidden = true;
    el('palette-long-notice').hidden = true;
    candidates = [];
    lastSourceText = ''; lastMaskedTranslation = ''; lastDirection = ''; lastStyle = 'full';
    input.focus();
  }

  /* --- 配線 ----------------------------------------------------------------- */

  function onDocumentClick(event) {
    var tmCopy = event.target.closest('#palette-tm-candidate [data-yaku-tm-copy]');
    if (tmCopy) { var hitTm = candidateForNode(tmCopy); if (hitTm) copyCandidate(hitTm.candidate, hitTm.index); return; }
    var mainCopy = event.target.closest('[data-yaku-main-card] [data-yaku-copy-b64]');
    if (mainCopy) { var hitMain = candidateForNode(mainCopy); if (hitMain) copyCandidate(hitMain.candidate, hitMain.index); return; }
    var alt = event.target.closest('.result-alt[data-yaku-swap]');
    if (alt) { var hitAlt = candidateForNode(alt); if (hitAlt) copyCandidate(hitAlt.candidate, hitAlt.index); return; }
    var chip = event.target.closest('[data-yaku-chip]');
    if (chip) { onChipClick(chip); return; }
  }

  /* 数字1〜9・Enter・Escはキーボード完結の要。ただし入力欄で打っている
     最中は素通りさせる（でないと貼った直後に数字が打てない、では済まず、
     普通に文章を打つことさえできなくなる）。Ctrl+Enterは入力欄からでも
     翻訳を起こす（他画面の作法に合わせる）。 */
  function onDocumentKeydown(event) {
    if (event.isComposing) return;
    if (event.key === 'Escape') { event.preventDefault(); clearAll(); return; }
    var typingInInput = (document.activeElement === input);
    if (typingInInput && (event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      startTranslation(input.value, 'auto');
      input.blur();
      return;
    }
    if (typingInInput) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    if (event.key === 'Enter') {
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

  function start() {
    input = el('palette-input');
    if (!input || !el('palette-form')) return;
    YakuCommon.start();
    input.addEventListener('input', function (event) {
      updateCount();
      /* 貼り付け(paste)だけが自動翻訳の引き金。inputType で見分ける
         （'paste' イベントは値の反映前に発火するため使わない）。 */
      if (event.inputType === 'insertFromPaste') {
        var text = input.value;
        window.setTimeout(function () { input.blur(); }, 0);
        startTranslation(text, 'auto');
      }
    });
    el('palette-form').addEventListener('submit', function (event) {
      event.preventDefault();
      startTranslation(input.value, 'auto');
      input.blur();
    });
    document.addEventListener('click', onDocumentClick);
    document.addEventListener('keydown', onDocumentKeydown);
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
