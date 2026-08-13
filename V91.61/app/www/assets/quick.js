(function () {
  'use strict';
  if (new URLSearchParams(window.location.search).get('compact') === '1') document.documentElement.classList.add('yaku-compact');
  var ready = false;
  var busy = false;
  var explicitDirection = '';
  var jobStartedAt = 0;
  /* Ctrl+Alt+J で読んだ選択の出どころ（保存済みのファイルのときだけ入る）。 */
  var sourceFilePath = '';

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
  /* Office 以外は外枠が疑似 Ctrl+C で読むため、サーバを通らない。読み込んだ事実
     （文字数だけ、本文は送らない）を報告して記録に残す。Office 側はサーバが自分で
     記録するので、ここでは扱わない。 */
  function reportClipboardCapture(chars) {
    if (!(chars > 0)) return;
    YakuCommon.post('/api/quick/selection-capture', { chars: chars }).catch(function () {
      /* 記録できなくても翻訳は続けられる。ここで止める理由が無い。 */
    });
  }

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
    /* 押す前に、どちらへ訳すのかを出す。以前は利用者が自分で選んだときにしか出ず、
       既定（自動判定）では何も出ていなかった。実測 2026-08-13: 日本語だけを貼っても
       日英を混ぜても、方向を示すものは画面に現れなかった。
       そこで「文章を見て、英語か日本語かを決めます」と決め方を書いたが、結局
       どちらになるのかが分からない一文だった（同日、利用者の指摘）。いまは
       サーバの判定へ聞いて、決まった向きそのものを出す。画面側では当てない。 */
    el('quick-direction-summary').hidden = !text.trim();
    el('quick-direction-choice').hidden = true;
    el('quick-direction-label').textContent = explicitDirection
      ? (explicitDirection === 'to_en' ? '英語に訳します' : '日本語に訳します')
      : detectedDirection === 'to_en' ? '英語に訳します'
      : detectedDirection === 'to_jp' ? '日本語に訳します'
      : detectedDirection === 'unknown' ? 'どちらに訳すかを選んでください'
      : '訳す言語を調べています…';
    var submit = el('quick-submit');
    /* 押せないときは、押せない理由をボタン自身に書く。ラベルが「訳案を作る」のまま
       灰色になると、利用者は理由が分からず押し続けて諦める。 */
    /* 押した先が確認画面になったので、ラベルもそう書く（2026-08-13）。
       「訳案を作る」のままだと、その場に訳文が出ると読めてしまう。 */
    submit.textContent = !text.trim() ? '文章を入力してください'
      : busy ? '取り込んでいます…'
      : !ready ? 'いま準備中です（このまま押せば予約します）'
      : explicitDirection === 'to_en' ? '英語に訳す（確認画面へ）' : explicitDirection === 'to_jp' ? '日本語に訳す（確認画面へ）' : '訳して確認する';
    submit.disabled = !text.trim() || busy;
    el('quick-input').readOnly = busy;
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
    /* 貼り付けた文章も、資料と同じ扱いにする（2026-08-13、利用者判断
       「保存しない約束は要らない」）。以前はここから /api/quick/jobs を叩き、
       保存しない・用語集を使わない・過去訳を引かない一時的な訳案を作っていた。
       そのため同じ「訳す」が2つあり、片方が劣化版に見えていた。
       いまは資料と同じ経路（/api/cat/open）で作業を作り、確認画面へ入る。
       これで登録した訳語も過去訳も数値の点検も、貼り付けた文章に効く。 */
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
    /* Ctrl+Alt+J は貼り付け欄へ着地させる。押した文章はここに入るだけで、
       送信はしない。送るのは利用者がボタンを押したときだけ。 */
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
        : reason === 'too_large' ? '選んだ範囲が大きすぎます。下の「Word・Excelを取り込む」からファイルごと取り込んでください。'
        : reason === 'multi_area' ? '複数の範囲が選ばれています。1つの範囲を選んでください。'
        /* 実測で分かった2つ（2026-08-12）。どちらも以前は事実と違う理由が出ていた。
           数式のセルだけ → 「文字がありませんでした」（文字は見えているので通じない）
           図形・グラフ   → 「複数の範囲が選ばれています」（範囲を選んでいない） */
        : reason === 'formula_only' ? '数式のセルは訳しません（訳を書き戻すと数式が消えるため）。文字が入ったセルを選んでください。'
        : reason === 'not_a_range' ? '図形やグラフは読み込めません。セルを選ぶか、文字をコピーして貼り付けてください。'
        : reason === 'no_selection' ? '文章が選ばれていません。訳したい範囲を選んでから、もう一度押してください。'
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
    if (YakuCommon.onOfficeSelection) YakuCommon.onOfficeSelection(applyOfficeSelection);
    YakuCommon.onReady(function (value) { ready = value; update(); submitPendingWhenReady(); });
    window.addEventListener('yaku-pending-quick-submit', submitPendingWhenReady);
    /* 文章を書き換えたら、読み込んだ出どころの案内は外す。手で直した文と
       「このブック全体」は、もう同じものを指していない。 */
    el('quick-input').addEventListener('input', function () {
      explicitDirection = '';
      refreshDirection();
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
    /* 外枠が流し込んだときだけ拾う。人が手で打った文字では鳴らない。 */
    window.addEventListener('yaku-clipboard-selection', function (event) {
      var chars = Number((event.detail && event.detail.chars) || 0);
      reportClipboardCapture(chars);
    });
    startNotationControl();
    update();
  }
  window.YakuInstant = { show: show, hide: hide, isBusy: isBusy };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
