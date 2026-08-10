(function () {
  'use strict';
  if (new URLSearchParams(window.location.search).get('compact') === '1') document.documentElement.classList.add('yaku-compact');
  var ready = false;
  var busy = false;
  var explicitDirection = '';
  var artifact = null;
  var pollTimer = null;
  var revisionInFlight = false;
  var activeSourceSnapshot = '';
  var jobStartedAt = 0;
  var activeJobId = '';

  function el(id) { return document.getElementById(id); }
  function update() {
    var text = el('quick-input').value;
    el('quick-count').textContent = Array.from(text).length.toLocaleString('ja-JP') + '字';
    el('quick-direction-summary').hidden = !text.trim() || !explicitDirection;
    el('quick-direction-choice').hidden = true;
    if (explicitDirection) el('quick-direction-label').textContent = explicitDirection === 'to_en' ? '英語に訳します' : '日本語に訳します';
    var submit = el('quick-submit');
    /* 押せないときは、押せない理由をボタン自身に書く。ラベルが「訳案を作る」のまま
       灰色になると、利用者は理由が分からず押し続けて諦める。 */
    submit.textContent = !text.trim() ? '文章を入力してください'
      : busy ? '翻訳しています…'
      : !ready ? 'いま準備中です（このまま押せば予約します）'
      : explicitDirection === 'to_en' ? '英語の訳案を作る' : explicitDirection === 'to_jp' ? '日本語の訳案を作る' : '訳案を作る';
    submit.disabled = !text.trim() || busy;
    el('quick-input').readOnly = busy;
    ['quick-copy', 'quick-revise-open', 'quick-promote'].forEach(function (id) {
      var button = el(id); if (button) button.disabled = busy;
    });
    var reviseForm = el('quick-revise-form');
    var reviseInput = el('quick-revise-instruction');
    var reviseSubmit = el('quick-revise-submit');
    var reviseCancel = el('quick-revise-cancel');
    if (reviseForm) reviseForm.setAttribute('aria-busy', busy && revisionInFlight ? 'true' : 'false');
    if (reviseInput) reviseInput.readOnly = busy;
    if (reviseSubmit) reviseSubmit.disabled = busy;
    if (reviseCancel) reviseCancel.disabled = busy;
  }

  function showChoice(message) {
    var choice = el('quick-direction-choice');
    choice.hidden = false;
    el('quick-direction-help').textContent = message || '日本語と外国語が混ざっているため、自動で決められません。';
    YakuCommon.focus(choice.querySelector('[data-quick-direction]'));
  }

  /* 待っているあいだ、残り時間（サーバが detail に入れている）と経過時間、
     そして「やめる」を必ず出す。止められない処理は使うのが怖くなる。 */
  function elapsedLabel() {
    if (!jobStartedAt) return '';
    var seconds = Math.max(0, Math.round((Date.now() - jobStartedAt) / 1000));
    if (seconds < 60) return seconds + '秒経過';
    return Math.floor(seconds / 60) + '分' + (seconds % 60) + '秒経過';
  }
  function renderJob(label, progress, detail, jobId) {
    var percent = Math.max(0, Math.min(100, Math.round(progress || 0)));
    var esc = YakuCommon.escape;
    var elapsed = elapsedLabel();
    el('quick-job').innerHTML = '<div class="job-loading"><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase">' + esc(label || '訳案を作っています') + '</div><div class="job-percent">' + percent + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳の進み具合" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + percent + '"><span class="job-progress-bar" style="width:' + percent + '%"></span></div>' +
      '<div class="job-bottomline"><div class="job-meta">' + esc(detail || 'Copilotの返事を待っています。') +
      (elapsed ? '<br><span class="job-elapsed">' + esc(elapsed) + '</span>' : '') + '</div>' +
      (jobId ? '<button type="button" class="secondary-button job-cancel" data-yaku-cancel-job="' + esc(jobId) + '">翻訳をやめる</button>' : '') +
      '</div></div></div>';
    document.title = percent > 0 ? percent + '% 翻訳中 - ちょっと翻訳 - YakuLingo' : 'ちょっと翻訳 - YakuLingo';
  }

  function finish(data) {
    var wasRevision = revisionInFlight;
    revisionInFlight = false;
    var sourceStillMatches = el('quick-input').value.trim() === activeSourceSnapshot;
    activeSourceSnapshot = '';
    busy = false;
    activeJobId = '';
    el('quick-job').innerHTML = '';
    document.title = '✔ 訳案ができました - ちょっと翻訳 - YakuLingo';
    window.setTimeout(function () { document.title = 'ちょっと翻訳 - YakuLingo'; }, 8000);
    if (!sourceStillMatches) {
      artifact = null;
      el('quick-result').hidden = true;
      update();
      showError('文章が変わったため、受け取った訳案は表示していません。現在の文章でもう一度お試しください。');
      return;
    }
    artifact = data.artifact || null;
    if (!artifact || !artifact.translation) { showError('訳案を取得できませんでした。'); return; }
    var toEnglish = artifact.direction === 'to_en';
    el('quick-result-title').textContent = toEnglish ? '英語の訳案（未確認）' : '日本語の訳案（内容確認用）';
    el('quick-result-text').textContent = artifact.translation;
    el('quick-result-note').textContent = toEnglish ? '外部へ配布する資料に使う場合は、資料翻訳で1文ずつ確認してください。' : '内容確認用の訳案です。';
    /* 件数だけでは「自分のあの数字が伏せられたか」が確かめられない。
       伏せた値そのものを並べる。値はこのパソコンの中で作り直したもので、
       Copilotへは記号として送っている。 */
    var maskCount = Number(artifact.masked_count || 0);
    var maskValues = Array.isArray(artifact.masked_values) ? artifact.masked_values : [];
    el('quick-mask-summary').hidden = maskCount < 1;
    if (maskCount > 0) {
      el('quick-mask-count').textContent = maskCount.toLocaleString('ja-JP') + '件の数値';
      var maskDetail = el('quick-mask-detail');
      var maskList = el('quick-mask-list');
      maskList.innerHTML = '';
      maskDetail.hidden = maskValues.length < 1;
      maskValues.forEach(function (value, index) {
        var item = document.createElement('li');
        item.className = 'mask-item';
        var token = document.createElement('span');
        token.className = 'mask-token';
        token.textContent = '[[N' + (index + 1) + ']]';
        var shown = document.createElement('span');
        shown.className = 'mask-value';
        shown.textContent = value;
        item.appendChild(token);
        item.appendChild(shown);
        maskList.appendChild(item);
      });
      /* 少なければ開いたまま見せ、多いときは畳んで画面を埋めない。 */
      maskDetail.open = maskValues.length > 0 && maskValues.length <= 6;
    }
    el('quick-promote').hidden = !toEnglish;
    el('quick-result').hidden = false;
    if (wasRevision) {
      if (artifact.revision_error) {
        el('quick-revise-status').textContent = '直せませんでした。現在の訳案は変わっていません。' + artifact.revision_error;
      } else {
        el('quick-revise-status').textContent = '指示に合わせて訳案を更新しました。Copilotが作った、まだ確認していない訳案です。';
        el('quick-revise-instruction').value = '';
        el('quick-revise-form').hidden = true;
        el('quick-revise-open').setAttribute('aria-expanded', 'false');
      }
    } else {
      el('quick-revise-status').textContent = '';
    }
    update();
    YakuCommon.focus(el('quick-result-title'));
  }

  function poll(jobId, failureCount) {
    window.clearTimeout(pollTimer);
    failureCount = Number(failureCount || 0);
    YakuCommon.json('/api/quick/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (data.artifact && (data.mode === 'done' || data.mode === 'completed_with_warnings')) { finish(data); return; }
      if (data.mode === 'cancelled') {
        revisionInFlight = false; activeSourceSnapshot = ''; busy = false; activeJobId = ''; update();
        el('quick-job').innerHTML = '';
        document.title = 'ちょっと翻訳 - YakuLingo';
        el('quick-revise-status').textContent = '';
        el('quick-copy-status').textContent = '翻訳をやめました。もう一度「訳案を作る」を押せば、やり直せます。';
        return;
      }
      if (['error', 'failed'].indexOf(data.mode) >= 0) {
        var failedRevision = revisionInFlight; revisionInFlight = false; activeSourceSnapshot = ''; busy = false; activeJobId = ''; update();
        if (failedRevision) el('quick-revise-status').textContent = '直せませんでした。いまの訳案は変わっていません。';
        showError(data.error || data.detail || '翻訳が終わりませんでした。文章を少し短くして、もう一度お試しください。'); return;
      }
      renderJob(data.label || data.phase || '訳案を作っています', data.progress || 0, data.detail, jobId);
      pollTimer = window.setTimeout(function () { poll(jobId, 0); }, 900);
    }).catch(function () {
      var nextFailure = failureCount + 1;
      renderJob(nextFailure < 3 ? '進み具合をもう一度確認しています' : '接続の回復を待っています', 0, '翻訳は続いています。文章を送り直してはいません。', jobId);
      pollTimer = window.setTimeout(function () { poll(jobId, nextFailure); }, Math.min(5000, 700 * Math.pow(2, Math.min(nextFailure, 3))));
    });
  }

  function showError(message) {
    el('quick-job').innerHTML = '<div class="alert alert-error">' + YakuCommon.escape(message || '処理を完了できませんでした。') + '</div>';
    YakuCommon.focus(el('quick-job'));
  }

  function submit(event) {
    event.preventDefault();
    var text = el('quick-input').value.trim();
    if (!text || busy) return;
    /* 準備が終わる前の Ctrl+Enter を黙って捨てると「壊れている」と受け取られる。
       予約しておき、準備でき次第そのまま送る。 */
    if (!ready) {
      window.__yakuPendingQuickSubmit = true;
      el('quick-job').innerHTML = '<div class="alert">Copilotの準備ができ次第、この文章を送ります。そのままお待ちください。</div>';
      return;
    }
    activeSourceSnapshot = text;
    busy = true; artifact = null; jobStartedAt = Date.now(); el('quick-result').hidden = true; update(); renderJob('翻訳を始めています', 0, '', '');
    YakuCommon.post('/api/quick/jobs', { input_text: text, direction_intent: explicitDirection || 'auto' }).then(function (data) {
      if (!data.job_id) throw new Error('翻訳を始められませんでした。1分ほど待ってから、もう一度お試しください。');
      activeJobId = data.job_id;
      poll(data.job_id);
    }).catch(function (error) {
      activeSourceSnapshot = ''; busy = false; activeJobId = ''; update();
      if (error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED') { showChoice(error.data.error); return; }
      showError(error.message);
    });
  }

  function submitPendingWhenReady() {
    if (window.__yakuPendingQuickSubmit !== true || !ready || busy || !el('quick-input').value.trim()) return;
    window.__yakuPendingQuickSubmit = false;
    el('quick-form').requestSubmit();
  }

  function start() {
    YakuCommon.start();
    YakuCommon.onReady(function (value) { ready = value; update(); submitPendingWhenReady(); });
    window.addEventListener('yaku-pending-quick-submit', submitPendingWhenReady);
    el('quick-input').addEventListener('input', function () { explicitDirection = ''; artifact = null; el('quick-result').hidden = true; update(); });
    el('quick-form').addEventListener('submit', submit);
    el('quick-direction-change').addEventListener('click', function () { showChoice('翻訳先を変更できます。'); });
    /* 訳す向きを選んだら、そのまま翻訳へ進む。資料翻訳（cat.js）は選んだ時点で
       再実行しており、同じアプリで挙動が違うと「選んだのに何も起きない」と受け取られる。 */
    document.querySelectorAll('[data-quick-direction]').forEach(function (button) { button.addEventListener('click', function () { explicitDirection = button.getAttribute('data-quick-direction'); el('quick-direction-choice').hidden = true; update(); if (el('quick-input').value.trim() && ready && !busy) el('quick-form').requestSubmit(); else YakuCommon.focus(el('quick-submit')); }); });
    el('quick-copy').addEventListener('click', function () { if (!artifact) return; var fallback = el('quick-copy-fallback'); fallback.hidden = true; YakuCommon.copyText(artifact.translation, fallback, el('quick-copy-status')); });
    el('quick-revise-open').addEventListener('click', function () {
      if (!artifact || busy) return;
      var form = el('quick-revise-form'); form.hidden = false;
      el('quick-revise-open').setAttribute('aria-expanded', 'true');
      el('quick-revise-status').textContent = '';
      YakuCommon.focus(el('quick-revise-instruction'));
    });
    el('quick-revise-cancel').addEventListener('click', function () {
      if (busy) return;
      el('quick-revise-instruction').value = '';
      el('quick-revise-form').hidden = true;
      el('quick-revise-open').setAttribute('aria-expanded', 'false');
      YakuCommon.focus(el('quick-revise-open'));
    });
    el('quick-revise-form').addEventListener('submit', function (event) {
      event.preventDefault();
      var instruction = el('quick-revise-instruction').value.trim();
      if (!artifact || busy || !instruction) { if (!instruction) YakuCommon.focus(el('quick-revise-instruction')); return; }
      activeSourceSnapshot = el('quick-input').value.trim();
      busy = true; revisionInFlight = true; jobStartedAt = Date.now(); update();
      el('quick-revise-status').textContent = '指示に合わせて訳案を直しています。いまの訳案は、終わるまで変わりません。このまま待つだけで大丈夫です。';
      renderJob('表現を直しています', 0, '', '');
      var requestId = window.crypto.randomUUID().replace(/-/g, '');
      YakuCommon.post('/api/quick/artifacts/' + encodeURIComponent(artifact.artifact_id) + '/revisions', {
        expected_version: artifact.version,
        instruction: instruction,
        request_id: requestId
      }).then(function (data) {
        if (!data.job_id) throw new Error('直す作業を始められませんでした。もう一度「この指示で訳案を直す」を押してください。');
        activeJobId = data.job_id;
        poll(data.job_id);
      }).catch(function (error) {
        activeSourceSnapshot = ''; revisionInFlight = false; busy = false; activeJobId = ''; update();
        el('quick-revise-status').textContent = '直せませんでした。いまの訳案は変わっていません。';
        showError(error.message);
      });
    });
    el('quick-promote').addEventListener('click', function () {
      if (!artifact || !artifact.artifact_id) return;
      var button = el('quick-promote'); button.disabled = true; button.textContent = '資料翻訳へ移しています…';
      YakuCommon.post('/api/cat/promote', { artifact_id: artifact.artifact_id }).then(function (data) {
        if (!data.project_id) throw new Error('資料翻訳へ移せませんでした。');
        window.location.assign('/cat?project=' + encodeURIComponent(data.project_id));
      }).catch(function (error) { button.disabled = false; button.textContent = '資料翻訳で1文ずつ確認する'; showError(error.message); });
    });
    /* 「翻訳をやめる」は、進捗表示のたびに作り直されるので document で受ける。 */
    document.addEventListener('click', function (event) {
      var button = event.target.closest('[data-yaku-cancel-job]');
      if (!button) return;
      if (!window.confirm('翻訳をやめますか？\n\n入力した文章はこの画面に残ります。')) return;
      button.disabled = true; button.textContent = 'やめています…';
      YakuCommon.post('/api/cancel-translation', { job_id: button.getAttribute('data-yaku-cancel-job') })
        .catch(function (error) { showError(error.message); });
    });
    /* Ctrl+Enter は入力欄以外（修正の指示欄）でも効かせる。効かない欄があると
       「押しても何も起きない」体験になる。 */
    document.addEventListener('keydown', function (event) {
      if (event.isComposing || !(event.ctrlKey || event.metaKey) || event.key !== 'Enter') return;
      var field = event.target.closest('textarea');
      if (!field) return;
      var form = field.form || el('quick-form');
      if (!form) return;
      event.preventDefault();
      form.requestSubmit();
    });
    update(); el('quick-input').focus();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
