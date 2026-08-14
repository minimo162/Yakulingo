(function () {
  'use strict';
  var ready = false;
  var busy = false;
  var explicitDirection = '';
  var jobStartedAt = 0;
  /* 取り込み方法を見比べるために ?import=1 へ移ると、同じ開始画面なのに
     WebView が読み直される。そこで打ちかけの文章を失わないよう、移動の直前だけ
     sessionStorage へ退避し、次の画面で一度だけ戻す。作業や翻訳メモリには保存せず、
     この画面を閉じれば消える。 */
  var draftStorageKey = 'yaku.quick.draft.before-navigation';

  function preserveDraft() {
    var input = el('quick-input');
    if (!input || !input.value) return;
    try {
      window.sessionStorage.setItem(draftStorageKey, JSON.stringify({
        text: input.value,
        direction: explicitDirection
      }));
    } catch (_) {}
  }

  function restoreDraft() {
    var raw = '';
    try {
      raw = window.sessionStorage.getItem(draftStorageKey) || '';
      window.sessionStorage.removeItem(draftStorageKey);
    } catch (_) { return false; }
    if (!raw || !el('quick-input') || el('quick-input').value) return false;
    try {
      var draft = JSON.parse(raw);
      if (!draft || !draft.text) return false;
      el('quick-input').value = String(draft.text);
      explicitDirection = draft.direction === 'to_en' || draft.direction === 'to_jp' ? draft.direction : '';
      return true;
    } catch (_) { return false; }
  }

  /* 1回の依頼に入る文字数。サーバの設定（max_chars_per_batch_file）そのもので、
     確認作業が分割の境目に使っているのと同じ値。ここを超える文章は、その場で
     訳す状態では分けて送れない（上限超過での再依頼もしない）ので、1文ずつ
     確認する側を勧める。画面側で別の数字を決めない。 */
  function maxBatchChars() {
    var node = document.querySelector('meta[name="yaku-max-batch-chars"]');
    var value = node ? Number(node.getAttribute('content')) : 0;
    return value > 0 ? value : 3000;
  }

  /* 金額の書き方（oku / billion）。設定そのものを読み、画面側で既定を決めない。
     選び直すと設定を保存する。既に始めた作業には及ばない（作業ごとに固定）。 */
  function notation() {
    var node = document.querySelector('meta[name="yaku-amount-notation"]');
    var value = node ? String(node.getAttribute('content') || '') : '';
    return value === 'billion' ? 'billion' : 'oku';
  }
  /* 訳案のそばに出していた「金額は ¥1,315 billion のように書いています」は、
     訳案カードごと外した（2026-08-13）。書き方は、選ぶところ（上の <select>）が
     両方の例を並べて言っている。訳文は確認画面に出るので、そこでは実際の
     書き方がそのまま読める。説明を2か所に持たない。 */
  function startNotationControl() {
    var select = el('amount-notation');
    if (!select) return;
    var status = el('amount-notation-status');
    select.value = notation();
    select.addEventListener('change', function () {
      var value = select.value;
      select.disabled = true;
      if (status) status.textContent = '保存しています…';
      YakuCommon.post('/api/settings/amount-notation', { amount_notation: value }).then(function (data) {
        var applied = data && data.amount_notation === 'billion' ? 'billion' : 'oku';
        select.value = applied;
        var node = document.querySelector('meta[name="yaku-amount-notation"]');
        if (node) node.setAttribute('content', applied);
        if (status) status.textContent = 'これから訳す分に使います（開いている作業はそのまま）。';
      }).catch(function (error) {
        select.value = notation();
        if (status) status.textContent = error.message || '保存できませんでした。';
      }).then(function () { select.disabled = false; });
    });
  }

  function el(id) { return document.getElementById(id); }

  /* どちらへ訳すのかを、押す前に出す。以前は「文章を見て、英語か日本語かを
     決めます」としか出ておらず、結局どちらになるのかが分からなかった
     （2026-08-13、利用者の指摘）。判定は Resolve-YakuDirectionDecision の
     1か所しか持たない決まりなので、画面側で当てにいかず同じ判定へ聞く。
     打つたびに聞かず、手が止まってから聞く。 */
  var detectedDirection = '';
  var directionTimer = null;
  var directionSeq = 0;
  function refreshDirection() {
    var text = el('quick-input').value.trim();
    window.clearTimeout(directionTimer);
    if (!text) { detectedDirection = ''; update(); return; }
    detectedDirection = '';
    update();
    directionTimer = window.setTimeout(function () {
      var seq = ++directionSeq;
      YakuCommon.post('/api/direction-preview', { text: text }).then(function (data) {
        if (seq !== directionSeq) return;
        detectedDirection = String(data && data.direction || '') || 'unknown';
        update();
      }).catch(function () {
        if (seq !== directionSeq) return;
        detectedDirection = 'unknown';
        update();
      });
    }, 350);
  }
  function update() {
    var text = el('quick-input').value;
    var length = Array.from(text).length;
    el('quick-count').textContent = length.toLocaleString('ja-JP') + '字';
    var notice = el('quick-long-notice');
    if (notice) {
      var limit = maxBatchChars();
      notice.hidden = length <= limit;
      if (length > limit) {
        el('quick-long-text').textContent = '1回で送れるのは ' + limit.toLocaleString('ja-JP') + '字 までです。この文章は ' + length.toLocaleString('ja-JP') + '字 あるので、分けて送りながら1文ずつ確認するほうが確実です。';
      }
    }
    /* 翻訳先と実行を二つの操作にまとめる。以前は「日本語に訳します」
       「訳す言語を変える」「すぐ訳す」が横並びで、どれを押すのか迷わせていた。
       自動判定した翻訳先を select に反映し、実行ボタンにも同じ言語を書く。 */
    el('quick-direction-summary').hidden = !text.trim();
    var direction = explicitDirection || detectedDirection;
    var directionSelect = el('quick-direction-select');
    var pendingOption = el('quick-direction-pending');
    if (pendingOption) pendingOption.textContent = detectedDirection === 'unknown' ? '選んでください' : '確認中…';
    if (directionSelect) {
      directionSelect.value = direction === 'to_en' || direction === 'to_jp' ? direction : '';
      directionSelect.disabled = !text.trim() || busy;
    }
    /* 金額表記は英訳にしか使わない。英文メールを和訳したい利用者に、専門的な
       設定を常時見せて最初の判断を増やさない。 */
    var amountSetting = el('quick-amount-setting');
    if (amountSetting) amountSetting.hidden = direction !== 'to_en';
    var submit = el('quick-submit');
    /* 押せないときは、押せない理由をボタン自身に書く。ラベルが「訳案を作る」のまま
       灰色になると、利用者は理由が分からず押し続けて諦める。 */
    /* 押した先が確認画面になったので、ラベルもそう書く（2026-08-13）。
       「訳案を作る」のままだと、その場に訳文が出ると読めてしまう。 */
    submit.textContent = !text.trim() ? '文章を入力してください'
      : busy ? '確認作業を準備しています…'
      : direction !== 'to_en' && direction !== 'to_jp' ? (detectedDirection === 'unknown' ? '翻訳先を選んでください' : '翻訳先を確認中…')
      : !ready ? (direction === 'to_en' ? '英語に訳す（準備中・予約できます）' : '日本語に訳す（準備中・予約できます）')
      : direction === 'to_en' ? '英語に訳す'
      : '日本語に訳す';
    var submitNote = el('quick-submit-note');
    if (submitNote) submitNote.textContent = '一時作業を作って確認画面へ移ります。確認するまで翻訳メモリには登録しません。';
    submit.disabled = !text.trim() || busy || (direction !== 'to_en' && direction !== 'to_jp');
    el('quick-input').readOnly = busy;
  }

  function requireDirection(message) {
    detectedDirection = 'unknown';
    update();
    if (message) el('quick-job').innerHTML = '<div class="alert">' + YakuCommon.escape(message) + '</div>';
    YakuCommon.focus(el('quick-direction-select'));
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
    document.title = percent > 0 ? percent + '% 翻訳中 - 翻訳 - YakuLingo' : '翻訳 - YakuLingo';
  }

  /* 訳案を1枚返す状態（その場で訳す）は 2026-08-13 に廃止した。ここにあった
     finish / poll と、訳案カード・直す・昇格の配線をまとめて外す。到達できる道が
     無くなっていた（finish は poll からしか呼ばれず、poll は artifact が要る
     「直す」からしか呼ばれず、その artifact を作るのは finish だけだった）。
     いまは submit が /api/cat/open で作業を作り、確認画面へ移る。 */

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
    /* 貼り付けは入力形式であって別翻訳モードではない。必ず一時CAT作業を
       作り、同じ翻訳・QC・確認経路へ進める。 */
    busy = true; jobStartedAt = Date.now(); update(); renderJob('取り込んでいます', 0, '', '');
    YakuCommon.post('/api/cat/open', { text: text, direction_intent: explicitDirection || 'auto' }).then(function (data) {
      if (!data.id) throw new Error('確認する作業を作れませんでした。1分ほど待ってから、もう一度お試しください。');
      /* translate=1 を付けて渡す。付けないと、押したのに原文が並ぶだけで訳が
         始まらない（2026-08-13、利用者の指摘）。ボタンは「訳して確認する」で、
         案内も「押すとCopilotへ送ります」と言っているので、送るところまでが
         この操作である。資料の取り込みボタンは「取り込んで確認を始める」と
         名乗っているので、そちらは今までどおり取り込むだけにする。 */
      window.location.assign('/cat?project=' + encodeURIComponent(data.id) + '&translate=1');
    }).catch(function (error) {
      busy = false; update();
      if (error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED') { requireDirection(error.data.error); return; }
      showError(error.message);
    });
  }

  function submitPendingWhenReady() {
    if (window.__yakuPendingQuickSubmit !== true || !ready || busy || !el('quick-input').value.trim()) return;
    window.__yakuPendingQuickSubmit = false;
    el('quick-form').requestSubmit();
  }

  /* 状態は二つになった（選んで訳す／1文ずつ確認する）。貼り付け欄は最初の画面に
     常にあるので、show() は「その画面へ戻して入力欄へ焦点を置く」だけでよい。
     以前は貼り付け欄が別の状態で、押すと画面ごと入れ替わっていた。画面を一つに
     したと言いながら入れ替えていただけだった（2026-08-12、利用者の指摘）。 */
  function show() {
    if (!el('quick-input')) return;
    window.dispatchEvent(new CustomEvent('yaku-instant-open'));
    /* scrollIntoView は使わない。入力欄を画面の中央へ寄せるため、上の見出しと
       状態表示が窓の外へ出てしまう（実機で確認）。ここは最初から見えている。 */
    el('quick-input').focus();
    window.scrollTo(0, 0);
  }

  function hide() { }

  function isBusy() { return busy; }

  function start() {
    if (!el('quick-form')) return;
    YakuCommon.start();
    /* 起動して最初に出るのがこの画面になったので、開いた時点で貼り付け欄に
       入れておく（2026-08-12）。押す場所を探さずに、貼って Ctrl+Enter で訳せる。
       保存した作業を開いている最中は横取りしない。 */
    window.setTimeout(function () {
      var input = el('quick-input');
      var picker = document.getElementById('cat-picker');
      if (!input || !picker || picker.hidden) return;
      if (document.activeElement && document.activeElement !== document.body) return;
      input.focus();
    }, 0);
    YakuCommon.onReady(function (value) { ready = value; update(); submitPendingWhenReady(); });
    window.addEventListener('yaku-pending-quick-submit', submitPendingWhenReady);
    el('quick-input').addEventListener('input', function () {
      explicitDirection = '';
      refreshDirection();
      if (!busy) el('quick-job').innerHTML = '';
      update();
    });
    el('quick-form').addEventListener('submit', submit);
    /* 翻訳先の変更だけでは送信しない。実行は隣の主ボタンに限定する。 */
    el('quick-direction-select').addEventListener('change', function () {
      explicitDirection = this.value === 'to_en' || this.value === 'to_jp' ? this.value : '';
      update();
      YakuCommon.focus(el('quick-submit'));
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
    el('quick-long-handoff').addEventListener('click', function () {
      if (busy) return;
      window.dispatchEvent(new CustomEvent('yaku-instant-handoff', { detail: { text: el('quick-input').value } }));
    });
    startNotationControl();
    if (restoreDraft()) refreshDirection(); else update();
  }
  window.YakuInstant = { show: show, hide: hide, isBusy: isBusy, preserveDraft: preserveDraft };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
