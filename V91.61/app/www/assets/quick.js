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
  /* Ctrl+Alt+J で読んだ選択の出どころ（保存済みのファイルのときだけ入る）。 */
  var sourceFilePath = '';

  /* 昇格ボタンの文言は1つだけ。失敗して戻したときに別の名前へ化けると、
     同じボタンが2つの操作に見える。 */
  var PROMOTE_LABEL = '1文ずつ確認して保存する（あとから開けます）';

  /* 1回の依頼に入る文字数。サーバの設定（max_chars_per_batch_file）そのもので、
     確認作業が分割の境目に使っているのと同じ値。ここを超える文章は、その場で
     訳す状態では分けて送れない（上限超過での再依頼もしない）ので、1文ずつ
     確認する側を勧める。画面側で別の数字を決めない。 */
  function maxBatchChars() {
    var node = document.querySelector('meta[name="yaku-max-batch-chars"]');
    var value = node ? Number(node.getAttribute('content')) : 0;
    return value > 0 ? value : 3000;
  }

  function el(id) { return document.getElementById(id); }
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
    document.title = percent > 0 ? percent + '% 翻訳中 - 翻訳 - YakuLingo' : '翻訳 - YakuLingo';
  }

  function finish(data) {
    var wasRevision = revisionInFlight;
    revisionInFlight = false;
    var sourceStillMatches = el('quick-input').value.trim() === activeSourceSnapshot;
    activeSourceSnapshot = '';
    busy = false;
    activeJobId = '';
    el('quick-job').innerHTML = '';
    document.title = '✔ 訳案ができました - 翻訳 - YakuLingo';
    window.setTimeout(function () { document.title = '翻訳 - YakuLingo'; }, 8000);
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
    el('quick-result-note').textContent = toEnglish ? '外部へ配布する資料に使う場合は、1文ずつ確認して保存してからお使いください。' : '内容確認用の訳案です。';
    /* 金額を社内表記（oku）へ換算しているのに、画面がそれを言っていなかった。
       「メール、Web、数文を訳す」という看板から billion を期待した人が混乱する。
       和訳では換算が起きないので出さない。 */
    el('quick-notation-hint').hidden = !toEnglish;
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
    el('quick-promote').hidden = false;
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
        document.title = '翻訳 - YakuLingo';
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

  /* Ctrl+Alt+J で前面にあったのが Word / Excel のとき、外枠が窓のクラスとハンドルを
     寄こす。本文はバックエンドが COM で読む。ブラウザーから本文を送る経路は作らない。
     読んだブック・シート・番地は必ず画面に出す。出さないと、別のブックを読んで
     いても利用者が気づけない。 */
  function applyOfficeSelection(windowClass, hwnd) {
    if (!windowClass) return;
    /* Ctrl+Alt+J は「その場で訳す」へ着地させる。取り込んで1文ずつ確認したく
       なったら、訳したあとに移れる。 */
    show();
    var note = el('quick-selection-note');
    YakuCommon.post('/api/quick/selection', { window_class: windowClass, foreground_hwnd: hwnd }).then(function (data) {
      var kind = String(data && data.kind || 'none');
      if (kind === 'word_text' || kind === 'excel_cells' || kind === 'powerpoint_text') {
        var input = el('quick-input');
        input.value = String(data.text || '');
        input.dispatchEvent(new Event('input', { bubbles: true }));
        if (note) {
          note.textContent = kind === 'excel_cells'
            ? ('Excel「' + (data.workbook_name || '') + '」の ' + (data.sheet_name || '') + ' シート ' + (data.address || '') + '（' + (data.cell_count || 0) + 'セル）を読み込みました。'
               + ((data.formula_skipped || 0) > 0 ? ' 数式のセル ' + data.formula_skipped + ' 件は訳しません。' : ''))
            : kind === 'powerpoint_text'
            ? ('PowerPoint「' + (data.presentation_name || '') + '」の ' + (data.slide_index || 0) + ' 枚目'
               + ((data.shape_count || 0) > 0 ? '（' + data.shape_count + ' 個の枠）' : '') + 'から ' + (data.char_count || 0) + ' 文字を読み込みました。')
            : ('Word「' + (data.document_name || '') + '」で選んでいた ' + (data.char_count || 0) + ' 文字を読み込みました。');
          note.hidden = false;
        }
        showSourceFileOffer(kind, data);
        /* 送信はしない。押す前に何を送るかが見えている必要がある。ボタンへ
           scrollIntoView すると、小さい窓では「どこから読んだか」の1行と本文が
           上へ流れて見えなくなった（実機で確認）。焦点だけ移し、画面は先頭に置く。 */
        el('quick-submit').focus({ preventScroll: true });
        window.scrollTo(0, 0);
        return;
      }
      if (!note) return;
      var reason = String(data && data.reason || '');
      note.textContent = reason === 'instance_mismatch' ? '前面のOfficeを読めませんでした。ファイルを取り込んでお使いください。'
        : reason === 'too_large' ? '選んだ範囲が大きすぎます。資料翻訳でファイルを取り込んでください。'
        : reason === 'multi_area' ? '複数の範囲が選ばれています。1つの範囲を選んでください。'
        : reason === 'no_text' ? '選んだ範囲に文字がありませんでした。'
        : '選んでいた文章を読み取れませんでした。貼り付けてください。';
      note.hidden = false;
    }).catch(function () {
      if (note) { note.textContent = '選んでいた文章を読み取れませんでした。貼り付けてください。'; note.hidden = false; }
    });
  }

  /* 選んだ範囲だけを訳しても、Word・Excelの体裁を保った社内確認用ファイルには
     ならない。元のファイルが分かっているので、丸ごと取り込む道を出す。

     未保存のときは出さない。取り込むのはディスクにある版なので、画面で編集中の
     内容とは違うものから DRAFT を作ってしまう。黙って古い内容を訳すより、
     保存してくださいと言うほうがよい。 */
  function showSourceFileOffer(kind, data) {
    var host = el('quick-source-file');
    if (!host) return;
    var path = String(data && data.source_path || '');
    var name = String((kind === 'excel_cells' ? data.workbook_name : data.document_name) || '');
    var label = kind === 'excel_cells' ? 'このブック' : 'この文書';
    sourceFilePath = '';
    if (!path || !name) { host.hidden = true; return; }
    if (data.saved === false) {
      el('quick-source-file-text').textContent = name + ' は編集中で、まだ保存されていません。' + label + '全体を取り込むときは、先に保存してください。';
      el('quick-source-file-open').hidden = true;
      host.hidden = false;
      return;
    }
    sourceFilePath = path;
    el('quick-source-file-text').textContent = name + ' 全体を取り込むと、1文ずつ確認して社内確認用のファイル（DRAFT_ 付きのコピー）を作れます。原本には書き込みません。';
    var button = el('quick-source-file-open');
    button.textContent = label + '全体を取り込む';
    button.title = path;
    button.hidden = false;
    host.hidden = false;
  }

  /* 画面は一つで、状態が三つある（選ぶ／その場で訳す／1文ずつ確認）。
     状態の出し入れは cat.js が持ち、ここは自分の状態の中身だけを持つ。
     器の高さ固定（cat-workspace.css）は確認作業のときだけ効かせたいので、
     いま何の状態かを body に書く。 */
  function show() {
    var host = el('cat-instant');
    if (!host || !host.hidden) { if (host) YakuCommon.focus(el('quick-input')); return; }
    window.dispatchEvent(new CustomEvent('yaku-instant-open'));
    host.hidden = false;
    document.body.setAttribute('data-cat-view', 'instant');
    update();
    /* scrollIntoView は使わない。入力欄を画面の中央へ寄せるため、上の見出しと
       状態表示が窓の外へ出てしまう（実機で確認）。ここは最初から見えている。 */
    el('quick-input').focus();
    window.scrollTo(0, 0);
  }

  function hide() {
    var host = el('cat-instant');
    if (host) host.hidden = true;
  }

  function isBusy() { return busy; }

  function start() {
    if (!el('quick-form')) return;
    YakuCommon.start();
    if (YakuCommon.onOfficeSelection) YakuCommon.onOfficeSelection(applyOfficeSelection);
    YakuCommon.onReady(function (value) { ready = value; update(); submitPendingWhenReady(); });
    window.addEventListener('yaku-pending-quick-submit', submitPendingWhenReady);
    /* 文章を書き換えたら、読み込んだ出どころの案内は外す。手で直した文と
       「このブック全体」は、もう同じものを指していない。 */
    el('quick-input').addEventListener('input', function () {
      explicitDirection = ''; artifact = null; el('quick-result').hidden = true;
      sourceFilePath = '';
      var host = el('quick-source-file'); if (host) host.hidden = true;
      var note = el('quick-selection-note'); if (note) note.hidden = true;
      update();
    });
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
      }).catch(function (error) { button.disabled = false; button.textContent = PROMOTE_LABEL; showError(error.message); });
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
    el('quick-source-file-open').addEventListener('click', function () {
      if (busy || !sourceFilePath) return;
      window.dispatchEvent(new CustomEvent('yaku-instant-handoff', { detail: { filePath: sourceFilePath } }));
    });
    el('quick-long-handoff').addEventListener('click', function () {
      if (busy) return;
      window.dispatchEvent(new CustomEvent('yaku-instant-handoff', { detail: { text: el('quick-input').value } }));
    });
    el('quick-back').addEventListener('click', function () {
      if (busy) { showError('翻訳しているあいだは移動できません。「翻訳をやめる」を押すか、終わるまでお待ちください。'); return; }
      window.dispatchEvent(new CustomEvent('yaku-instant-close'));
    });
    update();
  }
  window.YakuInstant = { show: show, hide: hide, isBusy: isBusy };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
