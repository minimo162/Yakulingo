(function () {
  'use strict';
  var ready = false, busy = false, project = null, pendingDirection = null, uploaded = null, directFilePath = '';
  var alignExcelHandles = { source: '', target: '' };
  var recentSnapshot = null, recentRequest = null, recentRequestOwner = false;
  var dirty = new Map(), saveChain = Promise.resolve(), jobTimer = null, jobContext = null, candidateSeq = 0, cancelRequestedJobId = '';
  var alignReadEpoch = { source: 0, target: 0, pair: 0 };
  var deleteTarget = null, preflightScope = null, jobSerial = 0, viewEpoch = 0, outputScope = null;
  var fileLoadingOwner = 0;
  var activeSegmentId = '', activeIndex = -1, currentFilter = 'actionable', currentLocation = 'all', currentChange = 'all';
  /* 作業メモの入力途中はサーバへ送らない。行や資料を切り替えても、別の行へ
     誤登録しないよう、保存先の資料IDとsegment_idをキーにして画面内だけで保持する。 */
  var reviewNoteDrafts = {};
  /* 検索の掛け方。市販CAT（memoQ / Phrase / Trados / XTM）はどれも「どこを探すか」
     「大文字小文字を区別するか」「正規表現か」を持っている。ここまでは原文・訳文・
     場所を連結した小文字化部分一致1本だけで、絞りようが無かった。 */
  var searchScope = 'both', searchCase = false, searchRegex = false;
  var revisionComparison = null;
  var pendingMutationKeys = {};
  var projectLeaseSequence = 0, projectLeaseId = '', projectLeaseTimer = null;
  var termSelection = { index: -1, source: '', target: '' };
  var candidateDetailRequestIndex = -1, candidateDetailRequestProjectId = '', candidateDetailRequestRevision = -1;
  /* 原文の数字を訳文へ入れる一覧（Ctrl+D）。市販CATが placeable と呼ぶもので、
     memoQ・Trados はどちらも「原文の数字を打ち直させない」ためのキーを持つ。
     このアプリは数字の抜けを点検（numeric-value-mismatch）で捕まえるが、
     入力側の手当てが無く、打ち間違いを起こしてから止めていた。
     seq は往復の追い越し対策。押しっぱなしで2回飛ばしたとき、古い応答で
     一覧を書き換えない。 */
  var placeablePicker = { open: false, index: -1, items: [], input: null, seq: 0 };
  /* 原文のどこで分けるか。ボタンを押すと選択は消える（mousedown で解除される）
     ので、押す前の位置を覚えておく。覚えないと「クリックしたのに何も起きない」
     になる。 */
  var sourceCaret = { index: -1, position: -1 };
  function el(id) { return document.getElementById(id); }
  function esc(value) { return YakuCommon.escape(value); }

  /* 過去訳の原文が、いまの原文とどこが違うかを示す。市販CAT（memoQ・Trados・
     Phrase）はどれも一致率だけでなく差分を出す。率だけでは「93%」がどこの93%か
     分からず、結局は目で2文を読み比べることになる。

     日本語は語の区切りが無いので1文字ずつ、英数字は語単位で比べる。長い文は
     比較そのものが重くなるので、上限を超えたら差分をあきらめて原文を出す
     （出さないより、印の無い原文を出すほうがまし）。 */
  function humanMessage(text) {
    var raw = String(text || '');
    if (/^(?:Type|Reference|Syntax|Range)Error\b|Cannot read propert|is not a function|is not defined|undefined is not/i.test(raw)) {
      try { console.error('YakuLingo internal error: ' + raw); } catch (_) {}
      return '画面を表示できませんでした。画面を読み込み直してください（Ctrl+R）。作業内容は保存されています。';
    }
    return raw;
  }
  function status(text, error) {
    var node = el('cat-status');
    node.textContent = error ? humanMessage(text) : (text || '');
    node.classList.toggle('alert-inline', !!error);
    /* aria-live announces asynchronous failures without stealing the editor caret. */
  }
  /* 保存できているのは既定の状態なので、毎回言わない。言うのは、まだ保存できて
     いないときだけにする（2026-08-12）。読み上げ用の要約には従来どおり入れる。 */
  function saveStatus(text, error) { el('cat-save-status').textContent = (text === '保存済み' ? '' : (text || '')); el('cat-current-save').textContent = text || '保存済み'; el('cat-save-status').classList.toggle('is-error', !!error); el('cat-current-save').classList.toggle('is-error', !!error); }
  function revision() { return project ? Number(project.revision) || 0 : -1; }
  function currentScope() { return project ? { id: String(project.id || ''), revision: revision() } : null; }
  function scopeIsCurrent(scope, checkRevision) {
    return !!(scope && project && String(project.id || '') === scope.id && (!checkRevision || revision() === scope.revision));
  }
  function dirtyKey(projectId, index) { return String(projectId || '') + ':' + String(index); }
  /* 開いている資料をアドレスに残す。スリープ復帰やネットワーク切替でシェルが
     読み込み直したとき、ここが空だと作業一覧へ戻ってしまう。 */
  /* 資料を開いたときだけ履歴に1つ積む。ずっと replaceState だった頃は、URL が
     /cat -> /cat?project=… と変わるのに historyLength が増えず、ブラウザの戻るで
     アプリの外へ出ていた（実測 2026-08-13）。戻る＝始める画面へ、が期待に合う。
     始める画面へ戻すときは積まない。積むと、戻るを2回押さないと外へ出られない。 */
  /* 読み込んだ時点で既に ?project= が付いていたときは、履歴を積まずに書き換える。
     積んでいたころは、貼り付けから来ると履歴が
       /cat → /cat?project=X&translate=1 → /cat?project=X
     の3段になり、戻るを1回押しても同じ資料に戻るだけだった（2026-08-13）。
     しかも戻った先の住所は translate=1 付きなので、読み直すとまた訳しにいく。 */
  var locationSynced = false, historySequence = 0, appliedHistoryEntry = null, historyRestoreGuard = false, pendingHistoryResume = null;
  function historyStateFor(route, sequence) {
    var state = window.history.state && typeof window.history.state === 'object' ? Object.assign({}, window.history.state) : {};
    state.yakuCatNavigation = true;
    state.sequence = sequence;
    state.route = route;
    return state;
  }
  function readCatHistoryState() {
    var state = window.history.state;
    if (!state || state.yakuCatNavigation !== true || typeof state.sequence !== 'number' || typeof state.route !== 'string') return null;
    return state;
  }
  function rememberAppliedHistoryEntry() {
    var state = readCatHistoryState();
    if (!state) return;
    historySequence = Math.max(historySequence, state.sequence);
    appliedHistoryEntry = { route: state.route, sequence: state.sequence };
  }
  function appliedRouteFallback() {
    if (project && project.id) return '/cat?project=' + encodeURIComponent(String(project.id));
    var params = new URLSearchParams(location.search);
    if (params.get('import') === '1' || (document.querySelector('meta[name="yaku-import"]') && document.querySelector('meta[name="yaku-import"]').getAttribute('content') === '1')) return '/cat?import=1';
    if (params.get('view') === 'work' || document.body.getAttribute('data-cat-view') === 'work') return '/cat?view=work';
    return '/';
  }
  function keepBusyAtAppliedEntry() {
    var applied = appliedHistoryEntry;
    var route = applied && applied.route ? applied.route : appliedRouteFallback();
    var sequence = applied && typeof applied.sequence === 'number' ? applied.sequence : historySequence;
    try {
      window.history.replaceState(historyStateFor(route, sequence), '', route);
      rememberAppliedHistoryEntry();
    } catch (_) {}
    return true;
  }
  function restoreBusyHistory() {
    var target = readCatHistoryState();
    var applied = appliedHistoryEntry;
    if (target && applied && target.route === applied.route) {
      appliedHistoryEntry = { route: target.route, sequence: target.sequence };
      historySequence = Math.max(historySequence, target.sequence);
      return true;
    }
    if (target && applied && target.sequence !== applied.sequence) {
      var delta = applied.sequence - target.sequence;
      historyRestoreGuard = true;
      try { window.history.go(delta); return true; }
      catch (_) { historyRestoreGuard = false; }
    }
    /* A null/non-app entry cannot tell us its history offset. Keep the
       already-applied screen and URL together in this entry instead of
       reloading: common.js may correctly keep a beforeunload confirmation
       open, and a dismissed confirmation must not leave the old screen at a
       new address. The next explicit navigation can still leave normally. */
    return keepBusyAtAppliedEntry();
  }
  function copyHistoryEntry(entry) {
    return entry && typeof entry.route === 'string' && typeof entry.sequence === 'number'
      ? { route: entry.route, sequence: entry.sequence } : null;
  }
  function sameHistoryEntry(left, right) {
    return !!(left && right && left.route === right.route && left.sequence === right.sequence);
  }
  function cancelPendingHistoryResume() {
    if (!pendingHistoryResume) return false;
    pendingHistoryResume = null;
    ++viewEpoch;
    setBusy(false);
    status('');
    return true;
  }
  function rollbackPendingHistoryResume(token) {
    var target = readCatHistoryState();
    var applied = token && token.appliedEntry;
    if (target && applied && target.sequence !== applied.sequence) {
      var delta = applied.sequence - target.sequence;
      historyRestoreGuard = true;
      try { window.history.go(delta); return; }
      catch (_) { historyRestoreGuard = false; }
    }
    keepBusyAtAppliedEntry();
  }
  function resumeFromHistory(id) {
    var token = {
      id: String(id || ''),
      epoch: ++viewEpoch,
      targetEntry: copyHistoryEntry(readCatHistoryState()),
      appliedEntry: copyHistoryEntry(appliedHistoryEntry)
    };
    pendingHistoryResume = token;
    setBusy(true);
    status('続きの作業を開いています…');
    return Promise.resolve().then(function () { return post('resume', { project_id: token.id }, false, null); }).then(function (data) {
      if (pendingHistoryResume !== token || token.epoch !== viewEpoch) return;
      render(data, true);
      pendingHistoryResume = null;
    }).catch(function (error) {
      if (pendingHistoryResume !== token || token.epoch !== viewEpoch) return;
      pendingHistoryResume = null;
      setBusy(false);
      status(error.message, true);
      rollbackPendingHistoryResume(token);
    });
  }
  function syncLocation(projectId, preserveImport, preserveWork) {
    try {
      var first = !locationSynced;
      /* 翻訳の標準面は / の左右画面だけ。旧 /quick・/cat・/palette から来ても、
         資料・過去訳・作業一覧を指定していなければ履歴を増やさず / へ寄せる。 */
      var next = projectId ? ('/cat?project=' + encodeURIComponent(projectId)) : (preserveImport ? '/cat?import=1' : preserveWork ? '/cat?view=work' : '/');
      var current = location.pathname + location.search;
      var existing = readCatHistoryState();
      var sequence = existing ? existing.sequence : (appliedHistoryEntry ? appliedHistoryEntry.sequence : historySequence);
      locationSynced = true;
      if (current === next) {
        if (!existing) window.history.replaceState(historyStateFor(next, sequence), '', next);
        rememberAppliedHistoryEntry();
        return;
      }
      if (projectId && !first) {
        sequence = (appliedHistoryEntry ? appliedHistoryEntry.sequence : historySequence) + 1;
        historySequence = sequence;
        window.history.pushState(historyStateFor(next, sequence), '', next);
      } else {
        window.history.replaceState(historyStateFor(next, sequence), '', next);
      }
      rememberAppliedHistoryEntry();
    } catch (_) {}
  }
  /* 帯は外した（2026-08-13）。貼り付けも取り込みも同じ経路で作業を作るように
     なったので、行き来する2つの仕事が無くなり、選ぶ相手が消えたため。
     資料を開いているあいだの入口は、資料名（F7）から開く一覧が持つ。 */
  function clearOutputDisplay() {
    outputScope = null;
    el('cat-output-row').hidden = true; el('cat-output-row').removeAttribute('data-cat-output-project');
    closeTextOutput(); el('cat-text-output').removeAttribute('data-cat-output-project');
    el('cat-output-name').textContent = ''; el('cat-text-output-value').value = ''; el('cat-text-output-note').textContent = '';
  }
  function post(action, body, mutate, scope, keepalive) {
    body = Object.assign({}, body || {});
    var requestScope = scope || currentScope();
    if (requestScope && !body.id && ['resume','recent','open','from-prior-version'].indexOf(action) < 0) body.id = requestScope.id;
    if (mutate && requestScope) body.expected_revision = requestScope.revision;
    var requestKey = '';
    if (mutate) {
      /* 応答が失われて同じ操作を押し直した場合も、server側receiptで二重更新を
         防げるよう、成功するまでは同じpayloadへ同じkeyを使う。 */
      var keyBody = Object.assign({}, body); delete keyBody.expected_revision; delete keyBody.idempotency_key;
      requestKey = action + '|' + JSON.stringify(keyBody);
      if (!pendingMutationKeys[requestKey]) {
        pendingMutationKeys[requestKey] = (window.crypto && window.crypto.randomUUID)
          ? window.crypto.randomUUID().replace(/-/g, '')
          : (Date.now().toString(36) + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2));
      }
      body.idempotency_key = pendingMutationKeys[requestKey];
    }
    return YakuCommon.json('/api/cat/' + action, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body), keepalive: !!keepalive }).then(function (result) {
      if (requestKey) delete pendingMutationKeys[requestKey];
      return result;
    });
  }
  function reportProjectLease(state) {
    if (!project || !YakuCommon.clientId || !YakuCommon.clientId()) return Promise.resolve();
    var id = String(project.id || ''); if (!id) return Promise.resolve();
    if (projectLeaseId !== id) { projectLeaseId = id; projectLeaseSequence = 0; }
    projectLeaseSequence++;
    return post('project-presence', { id: id, client_id: YakuCommon.clientId(), lease_sequence: projectLeaseSequence, observed_revision: Number(project.revision || 0), state: state || 'open' }, false).catch(function () {});
  }
  function startProjectLease() {
    reportProjectLease('open'); window.clearInterval(projectLeaseTimer);
    projectLeaseTimer = window.setInterval(function () { if (project) reportProjectLease('open'); }, 20000);
  }
  function directionName(value) { return value === 'to_jp' ? '日本語に訳す作業' : '英語に訳す作業'; }
  function workName(source, direction) { return source === 'align' ? '過去訳の対応確認' : directionName(direction); }
  /* ツールバーは横に長い。向きは記号で足りる（2026-08-12、利用者の指摘）。 */
  function directionMark(value) { return value === 'to_jp' ? '英→日' : '日→英'; }
  /* 画面は一つで、状態は二つ（始める／1文ずつ確認する）。どれが出ているかは
     body の data-cat-view に書く。
     器の高さを窓に固定する規則（cat-workspace.css）は、一覧が主役の確認作業に
     しか合わない。選ぶ画面とその場で訳す状態は、内容の丈だけ縦に伸びてよい。 */
  function setView(name) { document.body.setAttribute('data-cat-view', name); }
  function showPicker(preserveImport, preserveWork, refreshRecent) { if(project) reportProjectLease('closed'); syncLocation('', !!preserveImport, !!preserveWork); viewEpoch++; candidateSeq++; project = null; activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; resetSearchTools(); termSelection = { index: -1, source: '', target: '' }; dirty.clear(); directFilePath = ''; clearOutputDisplay(); document.body.removeAttribute('data-cat-source'); document.title = '翻訳 - YakuLingo'; el('cat-page-title').textContent = '翻訳'; setView('start'); el('cat-picker').hidden = false; el('cat-workspace').hidden = true; el('cat-current-summary').hidden = true; closeStartPanels(); if (refreshRecent !== false) loadRecent(true); }
  function navigateStart(view) {
    if (busy) return false;
    if (document.body.getAttribute('data-cat-view') !== 'start') return false;
    var importMeta = document.querySelector('meta[name="yaku-import"]');
    var params = new URLSearchParams(location.search);
    if ((importMeta && importMeta.getAttribute('content') === '1') || params.get('import') === '1') return false;
    var next = view === 'work' ? '/cat?view=work' : '/';
    if (location.pathname + location.search === next) return true;
    try {
      var sequence = (appliedHistoryEntry ? appliedHistoryEntry.sequence : historySequence) + 1;
      historySequence = sequence;
      window.history.pushState(historyStateFor(next, sequence), '', next);
      var event = typeof PopStateEvent === 'function' ? new PopStateEvent('popstate') : new Event('popstate');
      window.dispatchEvent(event);
      return true;
    } catch (_) { return false; }
  }
  function closeStartPanels() { document.querySelectorAll('.cat-start-panel').forEach(function (panel) { panel.hidden = true; }); el('cat-direction-choice').hidden = true; }
  /* 開いた欄は、いちばん少ない移動で見える所へ入れる（block:'nearest'）。
     画面の中央へ寄せていたころは、押しただけで 560px 飛び、押したボタン自身が
     画面の外へ出ていた。初回の案内が次に指すボタンも一緒に外れ、吹き出しだけが
     上端で切れて残っていた（2026-08-13 実測、1240x860）。 */
  function showStart(mode) {
    closeStartPanels();
    if (mode !== 'align') return;
    var panel = el('cat-source-' + mode);
    if (!panel) return;
    panel.hidden = false;
    if (mode === 'align') updateAlignEstimate();
    var first = panel.querySelector('input,textarea,[role="button"],button');
    if (first) { try { first.focus({ preventScroll: true }); } catch (_) { first.focus(); } }
    /* パネルは entry-body の下に続けて出るので、開いた時点で見出しが画面の
       外にあることが多い。旧実装は最初の入力欄の bounding box で出し入れを
       決めていたが、その条件が偽になり、見出しが画面外のまま開いた
       （2026-08-18 実機で再現）。見出しは無条件で scrollIntoView する。
       パネルの中身は見出しのすぐ下に続くだけの短い量なので、これで
       中の入力欄・ボタンも一緒に画面内へ入る（1912x987・入れ子の scroll 実測で
       確認済み。ページの残り丈が足りず block:'start' の0pxまでは着かないが、
       見出しも以降の内容も画面内に収まる）。 */
    var heading = panel.querySelector('h3');
    if (heading) {
      try { heading.scrollIntoView({ behavior: 'auto', block: 'start' }); } catch (_) { heading.scrollIntoView(); }
    }
  }
  /* 翻訳中に画面ごと凍らせない。数十分かかるあいだ、できた訳を読む・探す・コピーする、
     そして「やめる」ことは常にできる必要がある。止めるのは作業を壊す操作だけ。 */
  function isAlwaysEnabled(button) {
    if (button.closest('dialog')) return true;
    if (button.classList.contains('job-cancel')) return true;
    /* 貼り付け側の主ボタンは quick-page.js が持ち場を持っている（文章の有無・翻訳先・
       準備状況で押せるかどうかを決める）。ここで一律に触ると、文章が空でも
       押せる状態に戻ってしまう。実測 2026-08-16: 起動直後の #quick-submit は
       ラベルが空欄の操作指示なのに disabled=false だった。 */
    if (button.id === 'quick-submit') return true;
    if (button.hasAttribute('data-cat-filter') || button.hasAttribute('data-cat-location') ||
        button.hasAttribute('data-cat-change')) return true;
    return false;
  }
  function exportActionLabel(value) {
    var item = value || project;
    if (!item || item.source !== 'file') return '訳文をコピー';
    var format = String(item.document_format || '').toLowerCase();
    var missing = (item.eligibility_reasons || []).indexOf('source-file-missing') >= 0;
    if (format === 'docx') return item.word_file_output_supported && !missing ? '訳文入りWordを作る' : '訳文をコピー';
    if (['xlsx', 'xlsm', 'csv'].indexOf(format) >= 0) return '訳文入りファイルを作る';
    return '訳文をコピー';
  }
  /* 押せないボタンには、押せない理由をそのまま書く。灰色になった理由が分からないと、
     利用者は「壊れた」と判断してそこで止まる。 */
  function updateActionLabels() {
    var translate = el('cat-translate');
    if (translate) {
      translate.textContent = busy ? '翻訳しています…'
        : !ready ? 'Copilotを準備しています（数秒〜十数秒）'
        : (project && Number(project.untranslated) <= 0) ? '未訳はありません'
        : 'Copilotで未訳を翻訳';
    }
    /* 塗ったボタンは、いつでも「次にやること」1つだけにする。訳案が全部できると
       訳すボタンは灰色の飾りになり、実際の次（取り出す）は輪郭線だけの
       ボタンとして「ほかの資料に切り替える」と同じ見た目で並んでいた。
       訳す仕事が残っていないときは、主役を取り出す側へ渡す（2026-08-12）。 */
    var exportButton = el('cat-export');
    if (exportButton && translate) {
      var drafting = !(project && Number(project.untranslated) <= 0);
      exportButton.classList.toggle('secondary-button', drafting);
      translate.classList.toggle('secondary-button', !drafting);
    }
  }
  /* 「この操作でCopilotを約N回使います（直近3時間でM回）」は外した（2026-08-12）。
     押す前に読んでも判断が変わらない数字で、ツールバーの2段目を1行ぶん占めていた。
     上限に当たったときは、そのときに出る文言で足りる。 */

  function setFileLoading(value, detail) {
    var node = el('cat-file-loading');
    if (!node) return;
    node.hidden = !value;
    node.setAttribute('aria-busy', value ? 'true' : 'false');
    var label = el('cat-file-loading-label');
    if (label && detail) label.textContent = detail;
  }

  function beginFileLoading(owner) {
    fileLoadingOwner = owner;
    setFileLoading(true, 'ファイルを読み込んでいます…');
  }

  function finishFileLoading(owner) {
    if (fileLoadingOwner !== owner) return;
    fileLoadingOwner = 0;
    setFileLoading(false);
  }

  function cancelFileLoading() {
    if (!fileLoadingOwner) return;
    fileLoadingOwner = 0;
    setFileLoading(false);
  }

  function updateAlignmentRegistrationUi() {
    var button = el('cat-align-register-bulk');
    if (!button) return;
    if (!project || project.source !== 'align') {
      button.removeAttribute('aria-disabled');
      return;
    }
    var eligible = Number(project.tm_bulk_eligible_count);
    if (!isFinite(eligible)) {
      button.disabled = busy;
      button.removeAttribute('aria-disabled');
      button.textContent = '確認済みを過去訳として登録';
      button.title = '';
      return;
    }
    eligible = Math.max(0, eligible);
    var pending = Math.max(0, Number(project.tm_pending || 0));
    var retryPending = eligible === 0 && pending > 0;
    var unavailable = eligible === 0 && !retryPending;
    button.disabled = busy || unavailable;
    button.setAttribute('aria-disabled', unavailable ? 'true' : 'false');
    button.textContent = retryPending ? '翻訳メモリへの反映を再試行'
      : unavailable ? '登録できる過去訳はありません' : '確認済みを過去訳として登録';
    button.title = retryPending
      ? '反映待ちの' + pending + '件を、翻訳メモリへもう一度反映します。'
      : unavailable
        ? '現在、確認済み・最新の点検済み・非空・未登録の行はありません。'
        : eligible + '行を翻訳メモリへ登録できます。';
  }

  function setBusy(value) {
    busy = value;
    updateActionLabels();
    document.querySelectorAll('button').forEach(function (button) { if (!isAlwaysEnabled(button)) button.disabled = value || (button.id === 'cat-translate' && !ready); });
    /* readOnly なら、待っているあいだも訳文を読んで選択・コピーできる。 */
    document.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.readOnly = value; input.disabled = false; });
    syncReviewNoteFormState(!!activeSegment());
    if (!value) {
      el('cat-translate').disabled = !ready || !project || Number(project && project.untranslated) <= 0;
      updateActionLabels();
      el('cat-export').disabled = !project || !!(project && project.export_blocked) || dirty.size > 0;
      /* 出せないときは、どこを直すかへ行ける場所を出しておく。件数もボタンに出す
         （市販CATの検証パネルと同じ役目）。取り出しボタンは方針どおり止めたまま。 */
      updateQaButton();
      /* 1行でも確認済みなら取り出せる。全行そろうのを待たせない。 */
      el('cat-export-reviewed').disabled = !project || Number(project && project.confirmed) <= 0 || dirty.size > 0;
      document.querySelectorAll('[data-cat-filter],[data-cat-location],[data-cat-change]').forEach(function (button) { button.disabled = false; });
      /* 待機解除は全ボタンを押せる状態へ戻すので、置換のボタンだけは条件から
         決め直す。戻したままにすると、探す文字列が空でも押せてしまい、押した
         あとに「探す文字列を入れてください」と言うことになる（実機で確認、
         2026-08-15）。 */
      if (project) renderSearchTools();
      /* 全体の待機解除は全ボタンを戻すため、日英が揃っていない対訳開始ボタンまで
         押せる状態にしない。開始条件だけは本文の有無からもう一度決める。 */
      if (el('cat-align-open')) updateAlignEstimate();
    }
    updateAlignmentRegistrationUi();
  }

  /* 保存した作業は既定で直近3件だけ出す。実機で10件あり、この一覧だけで
     画面の44%（685px / 全体1555px）を占めていた（2026-08-12）。
     多いほうが困る一覧なので、隠すのではなく「あと何件あるか」を出して畳む。 */
  var RESUME_VISIBLE = 3;
  var resumeItems = [];
  var resumeExpanded = false;
  var resumePreviewSeq = 0;

  /* いつ保存したか。同じ資料を2回取り込むと、名前も残り行数も同じ行が並び、
     どちらが新しいか画面から判断できなかった（実測 2026-08-13: 「spec.docx・
     英語に訳す作業・あと258行」が2件、区別できる情報なし）。時刻はサーバから
     saved で既に届いていたので、出すだけでよい。 */
  function savedLabel(iso) {
    if (!iso) return '';
    var when = new Date(iso);
    if (isNaN(when.getTime())) return '';
    var hm = String(when.getHours()).padStart(2, '0') + ':' + String(when.getMinutes()).padStart(2, '0');
    var today = new Date();
    var sameDay = function (a, b) {
      return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
    };
    if (sameDay(when, today)) return '今日 ' + hm;
    var yesterday = new Date(today.getTime() - 86400000);
    if (sameDay(when, yesterday)) return '昨日 ' + hm;
    return (when.getMonth() + 1) + '月' + when.getDate() + '日 ' + hm;
  }

  /* 貼り付け資料には同じ仮名が付くため、一覧では最初の原文を短い見出しに
     使う。名前そのものは後段で必ず esc() し、タグを含む原文も画面へ出さない。 */
  function isGenericPastedName(name) { return String(name || '').trim() === '貼り付けたテキスト'; }
  function shortDocumentPreview(value) {
    var text = String(value || '').replace(/\s+/g, ' ').trim();
    if (text.length > 32) text = text.slice(0, 31) + '…';
    return text;
  }
  function firstDocumentSource(item) {
    var segments = item && Array.isArray(item.segments) ? item.segments : [];
    for (var i = 0; i < segments.length; i++) {
      var source = shortDocumentPreview(segments[i] && (segments[i].source || segments[i].source_text));
      if (source) return source;
    }
    return '';
  }
  function documentDisplayName(item) {
    var fileName = String(item && item.file_name || '').trim();
    if (!isGenericPastedName(fileName)) return fileName || '名称未設定';
    return shortDocumentPreview(item.display_name || item.source_preview) || fileName;
  }
  function documentKindLabel(item) {
    if (isGenericPastedName(item && item.file_name)) return '貼り付け';
    return item && item.source === 'align' ? '過去訳の対応確認' : directionMark(item && item.direction);
  }
  function documentMeta(item, isCurrent) {
    var remaining = Math.max(0, Number(item && item.total) - Number(item && item.confirmed));
    var parts = [documentKindLabel(item), remaining ? 'あと' + remaining + '行' : '確認完了'];
    var saved = savedLabel(item && item.saved);
    if (saved) parts.push(saved);
    if (isCurrent) parts.push('開いています');
    return parts;
  }

  function recentFailureSnapshot(error) {
    var message = error && error.message ? String(error.message) : '最近の作業を読み込めませんでした。';
    return { projects: [], error: { code: 'recent-unavailable', message: message } };
  }
  function publishRecentSnapshot(data) {
    recentSnapshot = data && typeof data === 'object' ? data : { projects: [] };
    try { window.dispatchEvent(new CustomEvent('yaku-cat-recent', { detail: recentSnapshot })); } catch (_) {}
    return recentSnapshot;
  }
  function applyRecentSnapshot(data) {
    /* PR #126 removed the legacy resume DOM. CAT owns and publishes the snapshot;
       premium-ui is the only renderer. */
    var items=data&&Array.isArray(data.projects)?data.projects:[];resumeItems=items;
    if(items.length<=RESUME_VISIBLE)resumeExpanded=false;return recentSnapshot;
  }
  /* Excel views and asks for the same list to populate its
     context selector. Keep that second consumer on the CAT-owned snapshot,
     while allowing CAT's own forced refresh to reach the server. */
  function installRecentSnapshotAdapter() {
    if (!(window.YakuCommon && YakuCommon.post)) return;
    var original = YakuCommon.post;
    if (original.__yakuCatRecentAdapter) return;
    var inAdapter = false;
    var adapted = function (path, body) {
      if (path !== '/api/cat/recent' || recentRequestOwner || inAdapter) return original.apply(YakuCommon, arguments);
      inAdapter = true;
      return Promise.resolve(loadRecent()).then(function (value) {
        inAdapter = false;
        return value;
      }, function (error) {
        inAdapter = false;
        throw error;
      });
    };
    adapted.__yakuCatRecentAdapter = true;
    YakuCommon.post = adapted;
  }
  function loadRecent(force) {
    if (!force && recentSnapshot) {
      applyRecentSnapshot(recentSnapshot);
      return Promise.resolve(recentSnapshot);
    }
    if (recentRequest) return recentRequest;
    var request;
    recentRequestOwner = true;
    try { request = post('recent', {}); } finally { recentRequestOwner = false; }
    request = request.then(function (data) {
      return applyRecentSnapshot(publishRecentSnapshot(data));
    }).catch(function (error) {
      return applyRecentSnapshot(publishRecentSnapshot(recentFailureSnapshot(error)));
    });
    recentRequest = request.then(function (result) { recentRequest = null; return result; }, function (error) { recentRequest = null; throw error; });
    return recentRequest;
  }

  function qcMessages(segment) {
    var labels = {
      empty: '訳文が空です。', 'invalid-or-source-fallback': '訳文として成立していないか、原文のままです。',
      'placeholder-residue': '訳文に「[[N1]]」のような記号が残っています。左の原文の同じ位置にある数字に、手で置き換えてください。',
      'numeric-value-mismatch': '原文と訳文の数字の意味が一致しません。原文と見比べてください。書き出しは止まりません。', 'numeric-value-extra': '原文に無い数字が訳文に入っています。余分な数字を確認してください。書き出しは止まりません。',
      'numeric-value-order-mismatch': '原文と訳文で、数字の並ぶ順番が違います。どの数字がどこに掛かるか確認してください。書き出しは止まりません。',
      'numeric-scale-mismatch': '数字の桁（億・百万など）が原文と合っていません。原文の単位をご確認ください。書き出しは止まりません。', 'numeric-sign-missing': '損失や減少を示すマイナスが訳文に入っていません。原文をご確認ください。書き出しは止まりません。',
      'accounting-polarity-mismatch': '利益と損失、または増加と減少が、原文と逆になっているようです。原文と見比べてください。書き出しは止まりません。', 'currency-mismatch': '通貨（円・ドルなど）が原文と合っていません。原文をご確認ください。書き出しは止まりません。',
      'numeric-validation-error': '数字の点検を最後まで完了できませんでした。確認と書き出しは続けられます。必要なら原文と訳文をご確認ください。',
      'structure-integrity': '見出しや箇条書きの形が原文と違っています。原文と見比べてください。', 'structure-validation-error': '見出しや箇条書きの形の点検が最後まで終わりませんでした。この行は出力できません。もう一度「確認済みにする」を押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      , 'terminology-missing': '登録した訳語が使われていません。右の「用語・参考訳」に出ている訳語をお使いください。この行だけ別の言い方にしたい場合は、その行の設定から外せます。'
      , 'terminology-forbidden': '「使わない」と登録した表現が訳文に入っています。右の「用語・参考訳」に出ている訳語に置き換えてください。'
      , 'terminology-check-unavailable': '登録した用語を読み込めませんでした。いったんアプリを閉じて開き直してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      , 'terminology-conflict': '同じ語に、必ず使う訳が2つ以上登録されています。どちらか一方を「作業の管理」から取り消してください。'
      /* この1件だけは、点検が出した種別ではなくサーバが合成したものである
         （src/CatProject.ps1 の Get-YakuCatOutputEligibility が、点検そのものが
         例外で落ちた行に積む）。合成なので qc_findings には現れず、
         qc_preview 経由でだけここへ届く。文言が無いと汎用文へ落ち、しかも
         qcGroup が 'error'（赤）で塗るので、**直しようのない道具の不調が
         利用者の訳の欠陥の顔で出る**。書き出しを止めた理由の側
         （Get-YakuCatQcBlockerMessages）は既にこの種別へ専用の文を持っている
         ので、行の表示だけ黙ると画面と窓が食い違う（2026-08-15）。 */
      , 'validation-unavailable': '自動点検が最後まで終わりませんでした。この行は出力できません。もう一度「確認済みにする」を押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      /* これだけは、出力を止めない警告である（サーバの Severity が 'warning'）。
         用語集の完全一致は「はみ出さないこと」の保証として使われており、
         保証が切れるのは新しいラベルのときだけである。止めはしないが、
         見えないままだと列からはみ出したことに出してから気づく。
         文中で「このセルの訳を今後も自動で使う」を名指しするのは、それが
         この行に実際に描かれるボタンだからである（下の renderRows を参照）。 */
      , 'label-not-in-glossary': '用語集に無い短いラベルです。訳が長いと列からはみ出すことがあります。この訳でよければ「そのほかの操作」の「このセルの訳を今後も自動で使う」で登録しておくと、次からも同じ訳になります。書き出しは止まりません。'
      , 'paired-delimiter-mismatch': '対応する開き括弧・閉じ括弧の組み合わせが合っていません。訳文の記号を見比べてください。書き出しは止まりません。'
      , 'fit-overflow': '意味を保ったまま指定幅へ収められませんでした。書き出しは止まりません。あふれを許容するか、意訳してよいか判断してください。'
      , 'acronym-inconsistency': '同じ原語に別の略し方が使われています。資料内で表記をそろえてください。書き出しは止まりません。'
    };
    return qcFindingViews(segment).map(function (view) { if (view.code === 'fit-overflow' && segment.fit_overflow) { return '意味を保ったまま指定幅へ収められませんでした。目標 ' + Number(segment.fit_overflow.max_chars || 0) + ' 字、必要 ' + Number(segment.fit_overflow.need_chars || 0) + ' 字です。あふれを許容するか、意訳してよいか判断してください。書き出しは止まりません。'; } return labels[view.code] || '自動点検で気になる点が見つかりました。左の原文と見比べてください。'; });
  }
  function qcCodeOf(finding) { return String((finding && (finding.code || finding.Code)) || '').toLowerCase().replace(/_/g, '-'); }
  /* この行の指摘は2つの出どころから来る。

     qc_findings … その行を「確認済みにする」ときに実際に走った点検の結果。
                   いつ・どの用語一覧で行われたかまで行に残っている。
     qc_preview  … 未確定行をサーバが写しに掛けた結果、または保存済みの確認行へ
                   advisory として足した種別。新しい payload は severity も持つ。

     2つ目が要る理由（2026-08-15）: 書き出しが止まった理由の案内は
     「左の『点検の指摘』を押すと、その行だけ表示できます」と言う。ところが
     qc_findings は確定処理でしか書かれないので、「訳を入れただけ・未確定」で
     止まった行では1件も無く、その絞り込みボタンは counts.qc < 1 で隠れていた。
     同じ書き出しの窓の「点検一覧を開く」も同じ出どころで、「用語で N 行
     止まっています」と言った直後に「直すところは見つかりませんでした」と出た。
     案内先が無いまま名指しだけしている状態だったので、写しの結果も合流させる。

     合流の規則は3つ。
      1. qc_findings は1件も落とさない（同じ種別が2件あっても両方出す。用語は
         語ごとに免除できるので、まとめると免除の口が減る）
      2. qc_preview は、qc_findings に無い種別だけを、種別ごとに1件だけ足す
         （文言は種別から作るので、同じ種別を2度出しても同じ字が並ぶだけ）
      3. qc_preview 由来には preview 印を付ける。用語の免除ボタン（訳文を
         書き換える操作）はこの印が付いた指摘には出さない。**見ることと
         決めることを混ぜない。**

     数える式（counts.qc）も、絞り込みも、行の指摘も、点検一覧も、みなここを
     通るので、1か所直せば同時に埋まる。分けて書くと片方だけ腐る。 */
  function qcFindingViews(segment) {
    var views = [], seen = {};
    (segment.qc_findings || []).forEach(function (finding) {
      var code = qcCodeOf(finding);
      seen[code] = true;
      views.push({ code: code, finding: finding, preview: false });
    });
    (segment.qc_preview || []).forEach(function (finding) {
      var code = qcCodeOf(finding);
      if (seen[code]) return;
      seen[code] = true;
      views.push({ code: code, finding: finding, preview: true });
    });
    return views;
  }
  /* 点検の指摘は「何が起きたか」で分かれる。19種を全部おなじ赤で出すと、
     数字の食い違い（出力を止める欠陥）と、用語集を読めなかった道具の不調とが
     同じ重さに見える。後者は利用者の訳の欠陥ではなく、直しようがない。
     赤は1種類のままにする。--error を複数作ると、どれが出力を止めるのか
     分からなくなる。 */
  /* 道具の不調と分類された種別。**正本は src/CatProject.ps1 の
     Get-YakuCatQcToolTroubleCodes** で、ここはその写しである。両者が集合として
     一致することを tools/Test-YakuV9171CatQcLabelCoverage.ps1 の CASE 4 が見る
     ので、片方へ足してもう片方へ足し忘れたら赤になる。

     どれも「原文と見比べて直す」ことができない。訳を直しても消えないものを
     赤（訳の欠陥）で出すと、利用者は際限なく探す。2026-08-15 に
     validation-unavailable だけを直したが、同じ形の
     numeric-validation-error / structure-validation-error が
     赤のまま残っていた（2026-08-16 に src の分類へ揃えた）。

     **色は表示だけの話である。** 書き出しを止める条件（サーバの
     Get-YakuCatOutputEligibility）はここを読まない。塗り分けても、その行は
     止まったままである。 */
  var QC_TOOL_TROUBLE_CODES = ['numeric-validation-error', 'structure-validation-error', 'terminology-check-unavailable', 'validation-unavailable'];
  /* 出力を止めない警告。**正本は src/CatProject.ps1 の Get-YakuCatQcWarningCodes**
     で、ここはその写しである。両者が集合として一致することを
     tools/Test-YakuV9171CatQcLabelCoverage.ps1 の CASE 5 が見る。

     numeric-validation-error は点検不能でも確認と書き出しを止めないが、
     道具の不調群として表示する。それ以外はこちらは
     **直せるが、直さなくても書き出せる**ものである。
     error と同じ赤で出すと
     「押せるのに押せない」と読め、tool と同じにすると自分で対処できることが
     伝わらない。色は表示だけの話で、止める条件はサーバの Severity が決める。 */
  var QC_WARNING_CODES = ['numeric-value-mismatch', 'numeric-value-extra', 'numeric-value-order-mismatch', 'numeric-sign-missing', 'numeric-scale-mismatch', 'currency-mismatch', 'accounting-polarity-mismatch', 'label-not-in-glossary', 'paired-delimiter-mismatch', 'fit-overflow', 'acronym-inconsistency'];
  var QC_PREVIEW_BLOCKING_CODES = ['structure-validation-error', 'terminology-check-unavailable', 'validation-unavailable'];
  function qcGroup(code) {
    if (QC_TOOL_TROUBLE_CODES.indexOf(code) >= 0) return 'tool';
    if (QC_WARNING_CODES.indexOf(code) >= 0) return 'warn';
    return 'error';
  }
  /* The server's finding severity is authoritative for the editor boundary.
     Numeric findings are warnings by contract, even when an older fixture did
     not carry an explicit severity field. Legacy code-only preview payloads
     still identify the three non-numeric tool failures as blockers. Displaying
     a warning in the QC list must not make the editable cell look invalid or
     block correction. */
  function qcFindingSeverity(view) {
    var finding = view && view.finding || {};
    var severity = String(finding.severity || finding.Severity || '').toLowerCase();
    if (severity === 'error') return 'error';
    if (severity === 'warning' || severity === 'warn') return 'warning';
    if (view && view.code === 'numeric-validation-error') return 'warning';
    if (view && QC_PREVIEW_BLOCKING_CODES.indexOf(view.code) >= 0) return 'error';
    return qcGroup(view && view.code || '') === 'error' ? 'error' : 'warning';
  }
  /* A tool-trouble code keeps its separate display group, while ordinary
     cards follow the authoritative finding severity. This prevents a new
     explicit warning/error code from inheriting the old code table blindly. */
  function qcCardGroup(view) {
    return qcGroup(view && view.code || '') === 'tool' ? 'tool' : (qcFindingSeverity(view) === 'error' ? 'error' : 'warn');
  }
  function segmentHasBlockingError(segment) {
    return qcFindingViews(segment).some(function (view) { return qcFindingSeverity(view) === 'error'; });
  }
  function qcWarningGroupKey(code) {
    if (['numeric-value-mismatch', 'numeric-value-extra', 'numeric-value-order-mismatch', 'numeric-sign-missing', 'numeric-scale-mismatch', 'currency-mismatch', 'accounting-polarity-mismatch', 'numeric-validation-error'].indexOf(code) >= 0) return 'numeric-warning';
    if (code === 'label-not-in-glossary') return 'label-warning';
    if (code === 'paired-delimiter-mismatch') return 'delimiter-warning';
    return 'warning';
  }
  function qaGroupByKey(groups, key) { return groups.find(function (group) { return group.key === key; }) || null; }
  /* 一覧の印は短く。長い名前は狭い列から溢れて隣の列に重なる。
   意味は title と、左の絞り込み（要対応・未翻訳・未確認…）が持つ。 */
  function stateLabel(state) { return state === 'reviewed' ? '確認済' : state === 'human_edited' ? '手直し' : state === 'machine_draft' ? '未確認' : state === 'stale' ? '再確認' : '未翻訳'; }
  /* 記号は札を置き換えるものではなく、札の読み方を教える相棒として隣に並べる。
     単独で意味が通じる記号は市販CATでも ✓（確定）だけで、「機械の訳案」や
     「要再確認」に共通の図形は無い。記号だけにすると title に頼ることになり、
     ホバーできない環境では今より情報が減る。札はその場の凡例として残す。 */
  function icon(id) { return '<svg class="yaku-icon" aria-hidden="true" focusable="false"><use href="#' + id + '"></use></svg>'; }
  function stateIcon(state) {
    return icon(state === 'reviewed' ? 'i-reviewed' : state === 'human_edited' ? 'i-edited' : state === 'machine_draft' ? 'i-draft' : state === 'stale' ? 'i-stale' : 'i-untranslated');
  }
  /* machine_draft を「Copilotの訳案」と決め打ちしない。用語集・翻訳メモリ・
     同じ原文からの配りも machine_draft で、Copilot は経路のひとつでしかない
     （2026-08-15、事前翻訳で埋めた行の吹き出しが「Copilotの訳案」と出ていた）。
     どこから来たかは出どころの札が別に言うので、ここは「機械が入れた」に留める。 */
  function stateTitle(state) { return state === 'reviewed' ? '確認済み' : state === 'human_edited' ? '手直し済み・未確認' : state === 'machine_draft' ? '機械が入れた訳案・未確認' : state === 'stale' ? '原文が変わったので再確認が必要' : 'まだ訳がありません'; }
  /* 候補から挿入した訳は「手直し」ではない。訳文を書き込む口が1つしかないため、
     挿入も手打ちも Origin='manual' になり、行の札は「手直し」と出ていた
     （2026-08-13、実機で確認: 完全一致の候補を挿入した直後の札が「手直し」だった）。
     出どころは segment.reference_usage に
     残っているので、そちらを先に見る。挿入したあと自分で書き換えたら、
     そのことも分かるようにする（決定文書 §5「翻訳例から挿入後に編集」）。 */
  function referenceOriginLabel(segment) {
    var usage = segment && segment.reference_usage;
    if (!usage || String(usage.action || '') !== 'inserted') return '';
    var base = String(usage.kind || '') === 'memory' ? '自分が確認した訳' : '過去の翻訳例';
    return usage.edited_after_insert ? (base + 'を直した') : (base + 'から');
  }
  function originLabel(origin) {
    if (origin === 'glossary') return '用語集';
    if (origin === 'copilot') return 'Copilot訳';
    if (origin === 'manual') return '手直し';
    if (origin === 'carried_forward' || origin === 'numeric_update') return '自分が確認した訳';
    /* 同じ原文の行へ配った訳。出どころが分からないと、直したはずの訳が
       別の行に残っていると誤解される。 */
    if (origin === 'propagated') return '同じ原文から';
    /* 事前翻訳で翻訳メモリから流し込んだ行。確認済みではないので、
       「自分が確認した訳」とは言い切らない。どこから来たかだけを言う。
       ただし通常はここへ来ない。出どころの札は referenceOriginLabel を先に
       見る（cat.js の描画側）ので、出典を書けた行の札は「自分が確認した訳から」
       になる。この枝が出るのは、出典を書けなかったときだけである。 */
    if (origin === 'translation-memory') return '翻訳メモリから';
    return '';
  }
  function segmentEffectiveTranslation(segment) { return segment ? String(segment.translation || '') : ''; }
  function segmentState(segment) { return segment.status || segment.state || (segmentEffectiveTranslation(segment) ? 'machine_draft' : 'untranslated'); }
  function reviewNotesOf(segment) { return segment && Array.isArray(segment.review_notes) ? segment.review_notes : []; }
  function unresolvedReviewNotes(segment) { return reviewNotesOf(segment).filter(function (note) { return String(note.state || '') === 'open'; }); }
  function segmentHasReviewNotes(segment) { return unresolvedReviewNotes(segment).length > 0; }
  function reviewNoteDraftKey(projectValue, segment) {
    if (!projectValue || !segment) return '';
    var projectId = String(projectValue.id || ''), segmentId = String(segment.segment_id || '');
    return projectId && segmentId ? projectId + '|' + segmentId : '';
  }
  function reviewNoteDraftFor(segment) {
    var key = reviewNoteDraftKey(project, segment);
    return key && Object.prototype.hasOwnProperty.call(reviewNoteDrafts, key) ? reviewNoteDrafts[key] : '';
  }
  function syncReviewNoteFormState() {}
  function reviewNoteStateLabel(note) { return String(note && note.state || '') === 'resolved' ? '解決済み' : '未解決'; }
  function reviewNoteCreatedLabel(note) { return savedLabel(note && note.created_at) || '日時不明'; }
  function segmentHasQc(segment) { return qcMessages(segment).length > 0; }
  function editorLanguages() {
    return project && project.direction === 'to_jp' ? { source: 'en', target: 'ja' } : { source: 'ja', target: 'en' };
  }
  /* 「要対応」に数えるのは、出力を止める指摘だけである。止めない警告
     （用語集に無いラベル）でここを立てると、確認し終えた資料が永久に
     「まだ残っている」と言い続ける。用語集へ足すかどうかは利用者が決めることで、
     足していないこと自体は欠陥ではない（決定 §1「用語集を網羅する必要はない」）。
     警告が1件も無い資料では、この関数は segmentHasQc と同じ値を返す。 */
  function segmentBlockingQc(segment) {
    return qcFindingViews(segment).some(function (view) { return qcFindingSeverity(view) === 'error'; });
  }
  function segmentActionable(segment) { return !segment.confirmed || segmentBlockingQc(segment); }
  function changeGroup(segment) {
    var kind = String(segment.change_kind || '');
    if (['unchanged', 'moved_unchanged', 'unchanged_reference_only'].indexOf(kind) >= 0) return 'unchanged';
    if (['changed', 'numeric_updated'].indexOf(kind) >= 0) return 'changed';
    if (kind === 'new') return 'new';
    return '';
  }
  /* 92px の列に「前回と同じ」を入れると2行に折り返し、原文が73pxしかないのに
     行が140pxになる。印は短くして1行に収め、意味は title で補う。 */
  function changeLabel(segment) {
    var group = changeGroup(segment);
    return group === 'unchanged' ? '同じ' : group === 'changed' ? '変更' : group === 'new' ? '追加' : '';
  }
  function changeTitle(segment) {
    var group = changeGroup(segment);
    return group === 'unchanged' ? '前回と同じ原文です' : group === 'changed' ? '前回から原文が変わりました' : group === 'new' ? '今回追加された原文です' : '';
  }
  function locationGroup(segment) {
    var location = String(segment.location || '').trim();
    /* セルはシートでまとめる。番地（A1）まで見ると1セルが1グループになり、
       500セルの資料で500個の「場所」が並ぶ。区切りが Sheet1!A1 から
       「Sheet1, A1」へ変わったあとも ! だけを見ていたため、実際にそうなっていた
       （2026-08-12、利用者の指摘で気づいた）。 */
    if (segment.kind === 'cell') {
      var sheet = location.match(/^(.*?)\s*[!,]\s*\$?[A-Z]{1,3}\$?\d+$/i);
      return sheet ? sheet[1] : (location || 'Excel');
    }
    if (/^見出し/.test(location)) return '見出し';
    if (/^本文/.test(location)) return '本文';
    if (/^表/.test(location)) return '表';
    if (/^文書付属領域/.test(location)) return '文書付属領域';
    return location || '本文';
  }
  /* 表示する行の絞り込み。**ここの鍵と cat.html のボタンは1対1にする。**
     以前は untranslated / unconfirmed という枝がここにあったのに、それを押す
     ボタンが cat.html に無く、どうやっても通らない道になっていた（6つあった
     絞り込みを2026-08-12に3つへ減らしたとき、枝だけが残った）。押せない枝は
     読む人に「まだ何かある」と思わせるだけで、動きはしない。
     対応は Test-YakuV9174SearchReplace.ps1 が両側から鍵を取り出して突き合わせる。 */
  var stateFilters = {
    actionable: function (segment) { return segmentActionable(segment); },
    qc: function (segment) { return segmentHasQc(segment); },
    review_notes: function (segment) { return segmentHasReviewNotes(segment); },
    repetition: function (segment) { return Number(segment.repetition_count || 1) > 1; },
    reviewed: function (segment) { return !!segment.confirmed; },
    all: function () { return true; }
  };
  function escapeRegExp(text) { return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }
  /* 検索語の照合器。探すのと置き換えるのを1つの式で行う。分けて書くと、
     「N行に掛かります」と告げた数と、実際に変わる行の数がずれる。

     不正な正規表現は invalid を立てて返す（例外で画面を白くしない）。
     サーバ側（CatProject.ps1 の New-YakuCatSearchMatcher）も同じ規則で照合し、
     押したときの対象行数はサーバが数えたものを使う。両方が同じ答を出すことは、
     Test-YakuV9174SearchReplace.ps1 が同じ表を両方へ通して確かめる。

     検索語は前後の空白を落とさない。「会社 」と「会社」は置換では別物である。 */
  function searchMatcher(text, replacement) {
    var needle = String(text === undefined ? (el('cat-search') ? el('cat-search').value : '') : text);
    var identity = function (value) { return String(value || ''); };
    if (!needle) return { empty: true, test: function () { return true; }, replace: identity };
    var pattern = searchRegex ? needle : escapeRegExp(needle);
    var expression = null;
    try { expression = new RegExp(pattern, searchCase ? 'g' : 'gi'); }
    catch (error) { return { empty: false, invalid: true, message: '正規表現として読めません。' + error.message, test: function () { return false; }, replace: identity }; }
    /* 空に一致する式（a* や ^）は、置換すると1文字ごとに差し込まれる。
       サーバも同じ理由で断る（CAT_SEARCH_PATTERN_MATCHES_EMPTY）。 */
    if (new RegExp(pattern, searchCase ? '' : 'i').test('')) {
      return { empty: false, invalid: true, message: '何も無いところにも一致する式です。', test: function () { return false; }, replace: identity };
    }
    var into = String(replacement === undefined ? (el('cat-replace-input') ? el('cat-replace-input').value : '') : replacement);
    if (!searchRegex) into = into.replace(/\$/g, '$$$$');
    return {
      empty: false,
      test: function (value) { expression.lastIndex = 0; return expression.test(String(value || '')); },
      replace: function (value) { expression.lastIndex = 0; return String(value || '').replace(expression, into); }
    };
  }
  /* 検索語を、どの欄に当てるか。原文だけ・訳文だけを選べないと、訳文の言い回しを
     直したいのに原文が引っかかった行まで並ぶ。 */
  function searchFields(segment) {
    if (searchScope === 'source') return [String(segment.source || '')];
    if (searchScope === 'target') return [String(segment.translation || '')];
    return [String(segment.source || ''), String(segment.translation || ''), String(segment.location || '')];
  }
  function segmentMatchesFilter(segment, matcher) {
    var test = stateFilters[currentFilter] || stateFilters.all;
    if (!test(segment)) return false;
    if (currentLocation !== 'all' && locationGroup(segment) !== currentLocation) return false;
    if (currentChange !== 'all' && changeGroup(segment) !== currentChange) return false;
    var needle = matcher || searchMatcher();
    if (needle.empty) return true;
    return searchFields(segment).some(needle.test);
  }
  /* 照合器は1回だけ作って全行へ回す。filter へ関数をそのまま渡すと第2引数に
     添字が入り、照合器のつもりで数字を受け取る。 */
  function visibleSegments() {
    if (!project) return [];
    var matcher = searchMatcher();
    return (project.segments || []).filter(function (segment) { return segmentMatchesFilter(segment, matcher); });
  }
  /* 置換が掛かる行。**絞り込み結果の中で、訳文が実際に変わる行だけ**である。
     原文だけを探しているときは訳文を書き換えられないので、対象は0行になる。
     ここで数えた行数を押す前に告げ、同じ条件でサーバがもう一度数える。 */
  function replaceTargets() {
    if (!project) return [];
    var matcher = searchMatcher();
    if (matcher.empty || matcher.invalid || searchScope === 'source') return [];
    return visibleSegments().filter(function (segment) {
      var before = String(segment.translation || '');
      if (!before || !matcher.test(before)) return false;
      /* 置換しても同じ文字列になる行は対象にしない。何も変わらないのに
         確認済みだけが落ちる。サーバ側の計画も同じ条件で落としている。 */
      return matcher.replace(before) !== before;
    });
  }
  function activeSegment() {
    if (!project) return null;
    return (project.segments || []).find(function (segment) { return String(segment.segment_id || '') === activeSegmentId; }) ||
      (project.segments || []).find(function (segment) { return Number(segment.index) === Number(activeIndex); }) || null;
  }
  function chooseInitialActive() {
    var all = project.segments || [], current = activeSegment();
    if (current && segmentMatchesFilter(current)) return current;
    var shown = visibleSegments(), next = shown.find(segmentActionable) || shown[0] || null;
    if (!next && currentFilter === 'actionable' && all.length && !all.some(segmentActionable)) {
      currentFilter = 'all'; shown = visibleSegments(); next = shown[0] || null;
    }
    if (next) { activeIndex = Number(next.index); activeSegmentId = String(next.segment_id || ''); }
    else { activeIndex = -1; activeSegmentId = ''; }
    return next;
  }
  function renderNavigation() {
    /* 件数も stateFilters から数える。数える式とボタンの式が別々だと、
       片方だけ直したときに数字と中身が食い違う。 */
    var all = project.segments || [], counts = {};
    Object.keys(stateFilters).forEach(function (name) {
      counts[name] = all.filter(stateFilters[name]).length;
      var target = document.querySelector('[data-cat-count="' + name + '"]');
      if (target) target.textContent = counts[name];
    });
    syncOptionalStateFilters(counts);
    document.querySelectorAll('[data-cat-filter]').forEach(function (button) { button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-filter') === currentFilter)); });
    var changeCounts = { unchanged: 0, changed: 0, new: 0 }, hasChanges = false;
    all.forEach(function (segment) { var group = changeGroup(segment); if (group) { changeCounts[group]++; hasChanges = true; } });
    el('cat-change-filter').hidden = !hasChanges;
    Object.keys(changeCounts).forEach(function (name) { var target = document.querySelector('[data-cat-change-count="' + name + '"]'); if (target) target.textContent = changeCounts[name]; });
    document.querySelectorAll('[data-cat-change]').forEach(function (button) { button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-change') === currentChange)); });
    var groups = {};
    all.forEach(function (segment) { var name = locationGroup(segment); groups[name] = (groups[name] || 0) + 1; });
    /* 場所が1種類しかない資料（貼り付けた文章や、本文だけの Word）では、
       「すべての場所」と「本文」が同じものを指す。選べない選択肢は出さない
       （2026-08-12、利用者の指摘）。 */
    var locationNames = Object.keys(groups);
    /* 場所は表の上の帯に畳んで置く（2026-08-12）。閉じている summary に、いま
       どこを見ているかを書く。書かないと、絞り込んだことが画面から消える。 */
    var locationMenu = el('cat-location-menu');
    if (locationMenu) {
      locationMenu.hidden = locationNames.length < 2;
      var summary = el('cat-location-summary');
      if (summary) summary.textContent = currentLocation === 'all' ? '資料内の場所' : ('場所: ' + currentLocation);
    }
    el('cat-location-list').innerHTML = '<button type="button" data-cat-location="all" aria-pressed="' + String(currentLocation === 'all') + '">すべての場所 <span>' + all.length + '</span></button>' + locationNames.map(function (name) {
      return '<button type="button" data-cat-location="' + esc(name) + '" aria-pressed="' + String(currentLocation === name) + '">' + esc(name) + ' <span>' + groups[name] + '</span></button>';
    }).join('');
  }
  function syncOptionalStateFilters(counts) {
    ['qc','repetition','review_notes'].forEach(function (name) {
      var button = document.querySelector('[data-cat-filter="' + name + '"]');
      if (!button) return;
      button.hidden = Number(counts[name] || 0) < 1;
      if (button.hidden && currentFilter === name) currentFilter = 'actionable';
    });
  }
  function autoGrow(input) {
    if (!input) return;
    var grown = input.style.height;
    input.style.height = 'auto';
    var needed = input.scrollHeight;
    input.style.height = grown;
    var floor = parseFloat(window.getComputedStyle(input).minHeight) || 0;
    if (needed > floor) input.style.height = needed + 'px';
    else input.style.height = '';
  }

  function segmentActionIcon(id, label) {
    return icon(id) + '<span class="cat-segment-button-label">' + esc(label) + '</span>';
  }
  function appendStaticSegmentActions(host) {
    if (!host) return;
    /* Row B owns the low-frequency tools. Moving the existing nodes keeps their
       IDs and delegated listeners intact while keeping Row C to translation,
       output, and QA. */
    /* まとめて収めるボタンも同じ理由でここへ動かす（CoD審査 REWORK-1 BLOCKER-B1）。
       .cat-toolbar-filters の帯は幅1320px以上で高さ32px・overflow:hiddenに
       固定されており(cat-workspace.css:2594-2606)、30pxの丈上限(:2608-2616)の
       セレクタにも乗っていない。cat-confirm-bulk と同じホストへ移すことで、
       同じ丈の規約（.cat-segment-button）へ素直に乗る。 */
    ['cat-tm-pretranslate', 'cat-key-help', 'cat-confirm-bulk'].forEach(function (id) {
      var node = el(id);
      if (node && node.parentNode !== host) host.appendChild(node);
    });
  }
  /* 行の細かな操作は表の高さへ足さず、選択行リボンへ集める。data-cat-* は
     既存の委譲リスナーをそのまま通し、操作の契約を変えない。 */
  function renderSegmentActions(segment) {
    var host = el('cat-segment-actions');
    if (!host) {
      var actions = el('cat-actions');
      if (!actions) return;
      host = document.createElement('div'); host.id = 'cat-segment-actions'; host.className = 'cat-segment-actions';
      host.setAttribute('role', 'toolbar'); host.setAttribute('aria-label', '選択中の行の操作');
      actions.appendChild(host);
    }
    /* 行を移るたびに同じ操作リボンを更新する。古い版の画面や、保存完了と
       行移動が同時に走った場合に一時的な重複ホストが残っても、先頭だけを
       正本として使い、残りを捨てる。残すと前の行の分割ボタンが見え続ける。 */
    var dynamicNodes = host.querySelectorAll('.cat-segment-actions-dynamic'), dynamic = dynamicNodes.length ? dynamicNodes[0] : null, dynamicIndex;
    for (dynamicIndex = 1; dynamicIndex < dynamicNodes.length; dynamicIndex++) {
      if (dynamicNodes[dynamicIndex].parentNode) dynamicNodes[dynamicIndex].parentNode.removeChild(dynamicNodes[dynamicIndex]);
    }
    if (!dynamic) {
      dynamic = document.createElement('span');
      dynamic.className = 'cat-segment-actions-dynamic';
      host.insertBefore(dynamic, host.firstChild);
    }
    if (!segment) { dynamic.innerHTML = ''; appendStaticSegmentActions(host); host.hidden = true; return; }
    host.hidden = false;
    var index = Number(segment.index), effectiveTranslation = segmentEffectiveTranslation(segment), hasTranslation = effectiveTranslation.trim().length > 0;
    var all = (project && project.segments) || [], next = all.find(function (item) { return Number(item.index) === index + 1; });
    var mergeLosesTranslation = !!(hasTranslation || (next && String(next.translation || '').trim()));
    var splitLosesTranslation = hasTranslation;
    var html = '<span class="cat-segment-actions-label sr-only">選択行</span>';
    html += hasTranslation
      ? '<button type="button" class="cat-segment-button secondary-button" data-cat-copy-target="' + index + '" title="この行の訳文をコピー" aria-label="この行の訳文をコピー">' + segmentActionIcon('i-copy', '訳文をコピー') + '</button>'
      : '<button type="button" class="cat-segment-button secondary-button" data-cat-translate-row="' + index + '" title="この行だけCopilotで翻訳" aria-label="選択行をCopilotで翻訳">' + segmentActionIcon('i-translate', '選択行をCopilotで翻訳') + '</button>';
    html += '<button type="button" class="cat-segment-button secondary-button" data-cat-copy-source="' + index + '" title="原文を訳文へコピー（Ctrl+Shift+S）" aria-label="原文を訳文へコピー（Ctrl+Shift+S）" aria-keyshortcuts="Control+Shift+S">' + segmentActionIcon('i-copy', '原文を訳文へコピー') + '</button>';
    html += segment.confirmed
      ? '<button type="button" class="cat-segment-button secondary-button" data-cat-unconfirm="' + index + '" title="確認済み。押すと確認を取り消す（Ctrl+Shift+U）" aria-label="確認を取り消す（Ctrl+Shift+U）" aria-keyshortcuts="Control+Shift+U">' + segmentActionIcon('i-check', '確認を取り消す') + '</button>'
      : '<button type="button" class="cat-segment-button secondary-button" data-cat-confirm="' + index + '" title="この行を確認済みにする（Ctrl+Enter）" aria-label="確認済みにする（Ctrl+Enter）" aria-keyshortcuts="Control+Enter">' + segmentActionIcon('i-check', '確認済みにする') + '</button>';
    if (segment.can_merge) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-merge="' + index + '" data-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '" title="次の行と結合" aria-label="次の行と結合">' + segmentActionIcon('i-merge', '次の行と結合') + '</button>';
    if (segment.can_split) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-split="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '" title="結合した行を戻す" aria-label="結合を戻す">' + segmentActionIcon('i-split', '結合を戻す') + '</button>';
    if (segment.can_split_at) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-split-at="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '" title="原文の位置で分割（先に原文をクリック）" aria-label="位置で分割（原文の位置を選択）" aria-keyshortcuts="Alt+S">' + segmentActionIcon('i-split', '位置で分割') + '</button>';
    if (segment.translation) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-term-open="' + index + '" title="この行の用語を登録" aria-label="この行の用語を登録">' + segmentActionIcon('i-book', '用語を登録') + '</button>';
    if (segment.kind === 'cell' && segment.translation && String(segment.source).length <= 40) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-glossary="' + index + '" title="このセルの訳を今後も使う" aria-label="このセルの訳を今後も使う">' + segmentActionIcon('i-book', 'この訳を登録') + '</button>';
    if (segment.tm_registered) html += '<span class="cat-segment-status">翻訳メモリ登録済み</span>';
    else if (segment.confirmed) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-tm-register="' + index + '" title="この訳を翻訳メモリへ登録" aria-label="翻訳メモリへ登録">' + segmentActionIcon('i-book', '翻訳メモリへ登録') + '</button>';
    if (segment.can_revise) html += '<details class="cat-segment-revise"><summary>基準訳を直す</summary><form class="revise-form" data-cat-revise="' + index + '"><label class="revise-label">直す指示</label><div class="revise-row"><input class="revise-input" type="text" placeholder="例：「increase」を「rise」に変える"><button class="secondary-button" type="submit">修正案を作る</button></div></form></details>';
    dynamic.innerHTML = html;
    appendStaticSegmentActions(host);
  }

  function renderRows() {
    var all = project.segments || [], body = el('cat-grid-body');
    var languages = editorLanguages();
    /* 任意状態filterが最後の1件を失うときは、行の選択・表示を計算する前に
       fallbackへ戻す。後から切り替えると、ボタンだけ「残り」なのに一覧が
       0件のまま次の操作まで残る。 */
    var optionalFilterCounts = {};
    ['qc','repetition','review_notes'].forEach(function (name) { optionalFilterCounts[name] = all.filter(stateFilters[name]).length; });
    syncOptionalStateFilters(optionalFilterCounts);
    /* 行を作り直すと、一覧が指していた訳文欄は消える。浮いたままにしない。 */
    closePlaceablePicker();
    candidateSeq++;
    chooseInitialActive();
    var shown = visibleSegments(), current = activeSegment();
    renderNavigation(); renderSearchTools();
    el('cat-filter-count').textContent = shown.length + ' / ' + all.length + '件';
    /* 表示中の未確認行をまとめて確認済みにする。市販CATは12本すべて一括確定を持つ。
       いまも Ctrl+Enter を押し続ければ同じ結果になるので、押下回数だけを負わせない。
       QC は1行ずつと同じ検査が全行で走り、通らない行は確定しない。 */
    var bulkTargets = shown.filter(function (segment) { return !segment.confirmed && String(segment.translation || '').trim(); });
    var bulkButton = el('cat-confirm-bulk');
    bulkButton.hidden = bulkTargets.length < 2;
    var bulkLabel = '表示中の' + bulkTargets.length + '行をまとめて確認済みにする';
    bulkButton.setAttribute('aria-label', bulkLabel);
    bulkButton.title = bulkLabel;
    bulkButton.innerHTML = icon('i-check') + '<span class="cat-segment-button-label">' + esc(bulkLabel) + '</span>';
    bulkButton.classList.add('cat-segment-button');
    bulkButton.setAttribute('data-cat-bulk-indexes', bulkTargets.map(function (segment) { return Number(segment.index); }).join(','));
    el('cat-complete-state').hidden = !(all.length && !all.some(segmentActionable));
    el('cat-empty-state').hidden = shown.length > 0;
    /* 既定の絞り込み（actionable）は確認済みの行を隠す。初めて開いた資料で
       確認済みが先頭に並んでいると、表が3行目から始まって見え、何行目から
       見ているのか分からない（2026-08-18、初見レビューの指摘）。表の直上に
       件数だけ添える。全行確認済み（cat-complete-state の枝）とは別に出す。 */
    var hiddenConfirmedNotice = el('cat-hidden-confirmed-notice');
    if (hiddenConfirmedNotice) {
      var hiddenConfirmedCount = currentFilter === 'actionable'
        ? all.filter(function (segment) { return !!segment.confirmed && !segmentActionable(segment); }).length
        : 0;
      var showHiddenConfirmedNotice = hiddenConfirmedCount > 0 && shown.length > 0;
      hiddenConfirmedNotice.hidden = !showHiddenConfirmedNotice;
      if (showHiddenConfirmedNotice) hiddenConfirmedNotice.textContent = '確認済みの' + hiddenConfirmedCount + '行を隠しています。左の「すべて」を押すと表示されます。';
    }
    /* ちょっと翻訳から移したとき、原文と訳案の文の数が合わないと、行には割り当てず
       サーバが全文を保持する（CatProject.ps1 の PromotionReferenceTranslation）。
       画面がそれを読んでいなかったので、利用者からは「移したら訳が消えた」に
       見えていた。挿入ボタンは置かない。手で写す。 */
    var carried = String(project.promotion_reference_translation || '');
    el('cat-promotion-reference').hidden = !carried;
    if (carried) el('cat-promotion-reference-text').textContent = carried;
    el('cat-grid-wrap').hidden = shown.length === 0;
    body.innerHTML = shown.map(function (segment) {
      var index = Number(segment.index), row = index + 1, state = segmentState(segment), isActive = current && Number(current.index) === index;
      var findings = qcMessages(segment), findingViews = qcFindingViews(segment), findingId = 'cat-qc-' + index, origin = referenceOriginLabel(segment) || originLabel(segment.origin), ops = '';
      var nextSegment = all.find(function (candidate) { return Number(candidate.index) === index + 1; });
      var mergeLosesTranslation = !!(String(segment.translation || '').trim() || (nextSegment && String(nextSegment.translation || '').trim()));
      var splitLosesTranslation = !!String(segment.translation || '').trim();
      if (segment.can_merge) ops += '<button type="button" class="cat-op secondary-button" data-cat-merge="' + index + '" data-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '">' + icon('i-merge') + '次の行とつなげて1文にする</button>';
      if (segment.can_split) ops += '<button type="button" class="cat-op secondary-button" data-cat-split="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '">' + icon('i-split') + 'つなげた行を元に戻す</button>';
      /* 自動の切り分けが1つのセルの中で外れると、境目へ戻すだけでは直せない。
         市販CATは全社が任意位置の分割を持つ（memoQ Ctrl+T / Phrase Ctrl+E）。
         位置は原文の中でクリックした場所で受ける。 */
      if (segment.can_split_at) ops += '<button type="button" class="cat-op secondary-button" data-cat-split-at="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '" title="原文の分けたい位置をクリックしてから押します（Alt+S）" aria-keyshortcuts="Alt+S">' + icon('i-split') + '原文の選んだ位置で2つに分ける<span class="cat-op-key" aria-hidden="true">Alt+S</span></button>';
      /* 原文をそのまま訳文へ。市販CATの定番（memoQ Ctrl+Shift+S / Trados Ctrl+Ins）。
         数字だけ・製品コードだけのセルは訳す必要が無く、打ち直す手間だけが残る。 */
      ops += '<button type="button" class="cat-op secondary-button" data-cat-copy-source="' + index + '">原文をそのまま訳文へ入れる</button>';
      /* この行だけ Copilot へ送る／この行の訳文だけ写す。どちらも道が無く、
         「1文ずつ依頼するにはどうすればよいか」「1文だけコピーするにはどうしたら
         よいか」が分からなかった（2026-08-13、利用者の指摘）。まとめて行う道は
         道具の帯にあり、どちらも名前で範囲を言っている。 */
      var rowPrimary = String(segment.translation || '').trim()
        ? '<button type="button" class="cat-op secondary-button" data-cat-copy-target="' + index + '">この行の訳文をコピー</button>'
        : '<button type="button" class="cat-op secondary-button" data-cat-translate-row="' + index + '">この行だけ訳す</button>';
      var prior = (segment.prior_translation || segment.prior_source) ? '<details><summary>前回版を見る</summary>' + (segment.prior_source ? '<div><strong>前回の原文</strong><br>' + esc(segment.prior_source) + '</div>' : '') + (segment.prior_translation ? '<div><strong>前回の訳文</strong><br>' + esc(segment.prior_translation) + '</div>' : '') + '</details>' : '';
      var qc = findings.length ? '<div id="' + findingId + '" class="cat-qc-findings" role="alert">' + findings.map(function (m) { return '<div>' + esc(m) + '</div>'; }).join('') + '</div>' : '';
      var usage = segment.reference_usage || null;
      var referenceTrace = usage ? '<div class="cat-example-trace"><p>この参考訳から挿入（その後編集' + (usage.edited_after_insert ? 'あり' : 'なし') + '）・' + esc(usage.source_name || '資料名なし') + (usage.location ? '・' + esc(usage.location) : '') + (Number(usage.page) > 0 ? '・ページ ' + Number(usage.page) : '') + '</p>' +
        ((usage.source || usage.translation) ? '<details><summary>使った参考訳を確認</summary>' + (usage.source ? '<div><strong>原文</strong><br>' + esc(usage.source) + '</div>' : '') + (usage.translation ? '<div><strong>訳文</strong><br>' + esc(usage.translation) + '</div>' : '') + '</details>' : '') + '</div>' : '';
      var generatedTerms = (segment.terminology_generation || []).filter(Boolean).length ? '<details class="cat-term-trace"><summary>訳案作成時に指定した用語 ' + segment.terminology_generation.filter(Boolean).length + '件</summary>' + segment.terminology_generation.filter(Boolean).map(function (term) { return '<div><strong>' + esc(term.source || '') + '</strong> → ' + esc(term.preferred || '') + '</div>'; }).join('') + '</details>' : '';
      var kind = segment.kind === 'cell' ? 'セル' : /^word_/.test(segment.kind || '') ? 'Word' : '文';
      /* 訳文欄は全行に置く。押して「開く」段を挟むと、1行直すのに2動作かかる。
         memoQ の表は訳文セルをその場で直す作り（"type or edit the translation in
         the cell on the right"／未確認でも自動保存）で、押して開く段は無い。
         開いている行だけは、下に操作と点検結果を出す。 */
      var effectiveTranslation = segmentEffectiveTranslation(segment), blockingError = segmentHasBlockingError(segment), blockingReason = blockingError || !effectiveTranslation.trim() || String(state) === 'stale';
      var warningFinding = findingViews.some(function (view) { return qcFindingSeverity(view) === 'warning'; });
      var recommendedReason = !blockingReason && (!segment.confirmed || warningFinding || segmentHasReviewNotes(segment));
      var unsavedChange = !!segment.save_failed || dirty.has(dirtyKey(project && project.id, Number(segment.index)));
      var editor = '<textarea rows="1" data-cat-input="' + index + '" data-cat-project-id="' + esc(project.id) + '" data-original="' + esc(effectiveTranslation) + '" lang="' + languages.target + '" spellcheck="true" aria-label="' + row + '行目のExcelに保存される訳文" aria-invalid="' + (blockingError ? 'true' : 'false') + '">' + esc(effectiveTranslation) + '</textarea>';
      var confirmation = segment.confirmed
        ? '<button type="button" class="cat-confirm-control is-confirmed" data-cat-unconfirm="' + index + '" title="確認済み。押すと確認を取り消す（Ctrl+Shift+U）" aria-label="' + row + '行目は確認済み。押すと確認を取り消す（Ctrl+Shift+U）" aria-keyshortcuts="Control+Shift+U"><span class="cat-confirm-mark" aria-hidden="true">✓</span><span>確認済み</span></button>'
        : effectiveTranslation.trim()
          ? '<button type="button" class="cat-confirm-control" data-cat-confirm="' + index + '" title="この行を確認済みにする（Ctrl+Enter）" aria-label="' + row + '行目を確認済みにする（Ctrl+Enter）" aria-keyshortcuts="Control+Enter"><span class="cat-confirm-mark" aria-hidden="true">–</span><span>未確認</span></button>'
          : '<button type="button" class="cat-confirm-control" data-cat-confirm="' + index + '" disabled title="訳文を入力してから確認できます。先に「この行だけ訳す」か「未訳を翻訳」を実行してください。" aria-label="' + row + '行目は訳文を入力してから確認できます"><span class="cat-confirm-mark" aria-hidden="true">–</span><span>未確認</span></button>';
      /* 行の高さを操作の置き場にしない。行固有の操作は上部の選択行リボンへ
         移し、点検結果・修正比較は下部ドックで表示する。 */
      var extras = findings.length ? '<div class="premium-inline-findings" role="status" aria-label="このセルの指摘">' + findings.map(function (message) { return '<span>' + esc(message) + '</span>'; }).join('') + '</div>' : '';
      var fitPipeline = segment.fit_pipeline || null;
      if (fitPipeline) {
        var fitParts = [];
        if (Number(fitPipeline.candidate_count || 0) > 0) fitParts.push('圧縮案' + Number(fitPipeline.candidate_count) + 'つ' + (Number(fitPipeline.candidate_count) > 1 ? 'から選抜' : 'を採用'));
        if (fitPipeline.retried) fitParts.push('意味差を修正して再照合');
        if (fitPipeline.abbreviation_used) fitParts.push('略語で再調整');
        if (String(fitPipeline.backcheck || '') === 'passed' || /-passed$/.test(String(fitPipeline.backcheck || ''))) fitParts.push('逆照合を通過');
        else if (String(fitPipeline.backcheck || '') === 'failed') fitParts.push('逆照合で意味差あり');
        if (fitParts.length) extras += '<div class="cat-fit-summary" role="status">' + esc(fitParts.join('・')) + '</div>';
      }
      var change = changeLabel(segment), reviewNoteCount = unresolvedReviewNotes(segment).length;
      return '<tr class="' + (isActive ? 'is-active' : '') + '" data-cat-row="' + index + '" data-cat-segment-id="' + esc(segment.segment_id || '') + '" data-cat-confirmed="' + (segment.confirmed ? '1' : '0') + '" data-yaku-cat-state="' + esc(state) + '" data-cat-effective-value="' + esc(effectiveTranslation) + '" data-cat-canonical-translation="' + esc(segment.translation || '') + '" data-cat-blocking="' + (blockingReason ? '1' : '0') + '" data-cat-recommended="' + (recommendedReason ? '1' : '0') + '" data-cat-qc-warning="' + (warningFinding ? '1' : '0') + '" data-cat-save-failed="' + (unsavedChange ? '1' : '0') + '">' +
        '<td class="cat-col-no"><span class="cat-card-label">行番号・状態</span>' + row + '<span class="cat-state cat-state-' + esc(state) + '" title="' + esc(stateTitle(state)) + '">' + stateIcon(state) + '<span>' + esc(stateLabel(state)) + '</span></span>' + ((change && isActive) ? '<span class="cat-change-badge cat-change-' + esc(changeGroup(segment)) + '" title="' + esc(changeTitle(segment)) + '">' + esc(change) + '</span>' : '') + (reviewNoteCount ? '<span class="cat-review-note-badge" title="未解決の作業メモ ' + reviewNoteCount + '件">メモ ' + reviewNoteCount + '</span>' : '') + '</td>' +
        /* 場所は幅が狭く、長いシート名だと番地まで届かない（実測 2026-08-13、
           窓 1760px: 「2026年3月期 連結決算サマリー, AB123」は 366px 必要なのに
           89px しか無く、番地が1文字も出ない）。どのセルかは Excel の作業では
           いちばん要る情報なので、全文を title に持たせて指せば読めるようにする。 */
        '<td class="cat-col-loc"><span class="cat-card-label">場所</span><span class="cat-location-main" title="' + esc(segment.location || '本文') + '">' + esc(segment.location || '本文') + '</span><span class="cat-location-kind">' + esc(kind) + '</span>' + (Number(segment.split_parts || 0) > 1 ? '<span class="cat-repetition" title="この行は1つのセル（段落）を手で分けたものです。書き出すときは、同じ組の行を繋いで元の1つへ戻します。Alt+M でも元へ戻せます。">分けた行 ' + Number(segment.split_part) + '/' + Number(segment.split_parts) + '</span>' : '') + (Number(segment.repetition_count || 1) > 1 ? '<span class="cat-repetition" title="この原文は資料の中に ' + segment.repetition_count + ' 行あります。確認済みにすると、まだ訳が入っていない同じ原文の行へ同じ訳を入れます。">同じ原文×' + segment.repetition_count + '</span>' : '') +
        (origin ? '<span class="cat-origin">' + esc(origin) + '</span>' : '') + '</td>' +
        /* 行の作りは、開いていても閉じていても同じ（原文｜訳文）。以前は開いた行だけ
           上下2段のカードに化けていたが、行を移るたびに表がずれて、いま何行目かを
           見失う。市販の CAT（memoQ・Trados・Phrase）はどれも表の形を保ったまま
           その場で直す。上下2段は memoQ でも「横表示」という別の表示であって既定では
           ない（Läubli et al. arXiv:2011.05978 が速いとしたのもこの表示のこと）。 */
        '<td class="cat-source"><span class="cat-card-label">原文（変更されません）</span><span class="cat-source-lock">変更不可</span><span class="cat-source-text" lang="' + languages.source + '">' + esc(segment.source) + '</span></td>' +
         '<td class="cat-target"><span class="cat-card-label">Excelに保存される訳文</span><span class="cat-save-meta">' + (segment.confirmed ? '<span class="cat-save-state is-confirmed">確認済み</span>' : (effectiveTranslation.trim() ? '<span class="cat-save-state">未確認（出力を止めません）</span>' : '<span class="cat-save-state is-blocked">未翻訳（出力を止めます）</span>')) + (unsavedChange ? '<span class="cat-save-state is-failed">保存できていません</span>' : '<span class="cat-save-state is-autosaved">自動保存済み</span>') + '</span>' + editor + extras + '</td>' +
         '<td class="cat-col-confirm"><span class="cat-card-label">状態</span>' + confirmation + '</td></tr>';
    }).join('');
    renderSegmentActions(current);
    /* 翻訳中に絞り込みを変えると行が作り直される。編集不可の状態を引き継ぐ。 */
    if (busy) body.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.readOnly = true; });
    body.querySelectorAll('textarea[data-cat-input]').forEach(autoGrow);
    /* 絞り込み・行を開く操作は busy 中も生きており、renderRows() を再度
       走らせる（訳文欄クリック→focusin→activateIndex、絞り込みボタンは
       setBusyでもdisabled=false のまま）。そのたびに先出しの書き込みが
       消えてしまう（renderRows由来の再構築はcheckpointへ届いていない
       DOMを作り直すだけで、jobContext.partialRowsの累積自体は失われて
       いない）。同じガード（source一致・訳文欄が空）で再適用し、
       カーソルが進んでいるぶんも取りこぼさず埋め直す（冪等）
       （CoD審査 REWORK-1 MINOR-2）。
       renderRows()自体は毎tickでは呼ばれない（設計判断4は不変）ので、
       これは全面再描画からの回復であって、tickからの呼び出しではない。 */
    if (jobContext && Array.isArray(jobContext.partialRows)) {
      /* deferGrow=true で書き込みだけ先に済ませ、autoGrow(強制同期レイアウト)は
         最後に一括で回す(CoD審査REWORK-3 MINOR-D)。forEach(applyPartialPreviewRow)
         と直接渡すと第2引数の配列位置が deferGrow に化けるため、明示的に包む。 */
      jobContext.partialRows.forEach(function (partialRow) { applyPartialPreviewRow(partialRow, true); });
      body.querySelectorAll('textarea[data-cat-input]').forEach(autoGrow);
    }
    /* #136 option 2: TM candidates are applied deterministically through the
       dedicated pretranslation action. The removed inspector no longer owns
       a candidate-rendering side effect. */
    window.dispatchEvent(new CustomEvent('yaku-cat-rows-rendered'));
  }

  /* 押せないボタンには「してください」、押せるボタンには「こうなります」を書く。
     未確認が残っていても取り出せる決まりにした（2026-08-12）のに、押せる状態の
     ボタンに「あと2行を確認済みにしてください。」と出していた。命令に読めるので、
     押してはいけないのだと受け取られる（2026-08-13、初回利用者として実機で確認。
     同じ場面の取り出しダイアログは「まだ確認していない行が 2 行あります。そのまま
     コピーに入れます。」と、起きることのほうを書いていた）。 */
  function outputGuidance() {
    var left = Math.max(0, Number(project.total) - Number(project.confirmed));
    if (dirty.size > 0) return '保存できていない編集があります。もう一度保存してからお使いください。';
    if (Number(project.untranslated) > 0) return '「Copilotで未訳を翻訳」で、未訳' + project.untranslated + '行を訳してください。';
    if (project.export_blocked) return '検査結果を確認し、必要な行を直してください。';
    if (left > 0) return 'まだ確認していない' + left + '行も、そのまま入ります。';
    return '';
  }
  /* 「確認済みの行だけコピー」は、押せない理由をどこにも持っていなかった
     （実測 2026-08-13: title が空）。1行でも確認済みなら押せる決まりなので、
     言うべきことは「まだ1行も無い」か「保存していない編集がある」かの2つ。 */
  function reviewedGuidance() {
    if (!project) return '';
    if (dirty.size > 0) return '編集中の行があります。保存してからお使いください。';
    if (Number(project.confirmed) <= 0) return 'まだ確認済みの行がありません。1行でも確認済みにすると押せます。';
    return '';
  }
  function render(data, focusFirst) {
    var previousProjectId = project ? String(project.id || '') : '';
    if (data) project = data;
    if (!project) return;
    syncLocation(String(project.id || ''));
    if (el('cat-editor-layout').classList.contains('is-docs-open')) renderDocsPane();
    if (previousProjectId && previousProjectId !== String(project.id || '')) { activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; resetSearchTools(); el('cat-mask-notice').textContent = ''; }
    if (outputScope && (outputScope.id !== String(project.id || '') || outputScope.revision !== revision())) clearOutputDisplay();
    dirty.clear(); candidateSeq++;
    /* 画面遷移なしで確認作業へ入る道（その場で訳す → 長すぎるので渡す）ができた。
       外枠の広げ直しは読み込み完了に紐づいているので、その道では効かない。
       状態が変わったことを外枠へ知らせる。 */
    setView('workspace');
    el('cat-picker').hidden = true; el('cat-workspace').hidden = false; el('cat-current-summary').hidden = true;
    el('cat-current-title').textContent = project.file_name || '貼り付けた文章';
    var isAlignment = project.source === 'align';
    document.body.setAttribute('data-cat-source', String(project.source || ''));
    document.title = (isAlignment ? '過去訳の対応確認' : '翻訳') + ' - YakuLingo';
    el('cat-page-title').textContent = isAlignment ? '過去訳の対応確認' : '翻訳';
    el('cat-current-progress').textContent = workName(project.source, project.direction) + '・全' + project.total + '行のうち' + project.confirmed + '行を確認済み・残り' + Math.max(0, project.total - project.confirmed) + '行';
    el('cat-toolbar-title').textContent = project.file_name || '貼り付けた文章';
    el('cat-toolbar-direction').textContent = directionMark(project.direction);
    var notationControl = el('cat-notation'); if (notationControl) notationControl.hidden = false;
    document.querySelectorAll('[name="cat-notation"]').forEach(function (radio) { radio.checked = radio.value === String(project.amount_notation || 'oku'); });
    el('cat-translate').textContent = '残りを訳す';
    el('cat-tm-pretranslate').textContent = '確定済み対訳から入力';
    el('cat-tm-pretranslate').title = '確定済み対訳の完全一致を未訳の行へ先に入れます';
    el('cat-current-kicker').textContent = isAlignment ? '過去訳の対応確認' : '現在の確認作業';
    el('cat-align-review-guide').hidden = !isAlignment;
    /* 見出しは役割と実際の言語を一緒に持つ。thead は密度を守るため視覚的に
       畳むが、既存 ID と列見出しは支援技術へ残す。 */
    var headingLabels = isAlignment
      ? { source: '日本語', target: '英語' }
      : (project.direction === 'to_jp'
        ? { source: '原文・英語', target: '訳文・日本語' }
        : { source: '原文・日本語', target: '訳文・英語' });
    el('cat-source-heading').textContent = headingLabels.source;
    el('cat-target-heading').textContent = headingLabels.target;
    el('cat-translate').hidden = isAlignment;
    /* 対応確認では訳さないので、下訳の入口も出さない（訳す入口と同じ扱い）。 */
    el('cat-tm-pretranslate').hidden = isAlignment;
    startProjectLease();
    el('cat-source-update-open').hidden = project.source !== 'file';
    var pct = project.total ? Math.round(100 * Number(project.confirmed) / Number(project.total)) : 0;
    el('cat-progress-bar').style.width = pct + '%'; el('cat-progress-row').querySelector('[role="progressbar"]').setAttribute('aria-valuenow', String(pct)); el('cat-progress-text').textContent = project.confirmed + '/' + project.total + '行';
    renderRows();
    var isFile = project.source === 'file', sourceMissing = (project.eligibility_reasons || []).indexOf('source-file-missing') >= 0;
    var wordReady = project.document_format === 'docx' && project.word_file_output_supported && !sourceMissing;
    var draft = isFile && !sourceMissing && (project.document_format !== 'docx' || wordReady);
    /* 読み上げにも同じ言い方を出す。ここだけ硬い言い方にしない。 */
    el('cat-output-help').textContent = draft ? '原本はそのままで、訳文を入れたコピーを作ります。名前の先頭に「DRAFT_」が付きます。' : '';
    /* 行の操作に「この行の訳文をコピー」を足したので、帯の側は範囲を名乗る。
       並べたときに、どちらが1行でどちらが全部なのかが名前だけで分かる
       （2026-08-13、利用者の指摘「パッと見て分かりにくいかも」）。 */
    el('cat-export').textContent = exportActionLabel(project);
    /* 出せない理由は、押す前の常時表示ではなく取り出しダイアログの点検で出す。
       常時 35px を占めながら、ほぼ always「あと N 行」としか言っていなかった。 */
    el('cat-export-blocked').textContent = '';
    /* 帯は畳んだが、理由は失わない。押せない理由はボタン自身が持つ（title）。
       押したあとの詳細は取り出しダイアログの点検一覧が出す。

       ただし title だけでは、押せないボタンに触れられない人へ届かない。
       disabled のボタンはフォーカスを受けないので、キーボードだけで操作すると
       理由に到達できない（実測 2026-08-13: 画面上の理由テキスト0件、
       無効ボタンへのフォーカス不可）。読み上げ用の行へ同じ理由を書き、
       ボタンから aria-describedby で指す。帯は畳んだままで、場所は取らない。 */
    el('cat-export').title = outputGuidance() || '';
    el('cat-export-reviewed').title = reviewedGuidance() || '';
    saveStatus('保存済み', false); setBusy(false);
    /* 押せる／押せないを決めるのは setBusy(false) なので、理由はそのあとで作る。
       先に作っていたころは、待っているあいだの「全部押せない」状態を読んでいて、
       押せるボタンにも「押せません」と書いていた（実測 2026-08-13:
       「訳文をコピー」は disabled=false なのに読み上げ行は「押せません」）。 */
    var outputReasons = [];
    if (el('cat-export').disabled && outputGuidance()) outputReasons.push('「' + el('cat-export').textContent.trim() + '」が押せません。' + outputGuidance());
    if (el('cat-export-reviewed').disabled && reviewedGuidance()) outputReasons.push('「確認済みだけコピー」が押せません。' + reviewedGuidance());
    el('cat-output-reason').textContent = outputReasons.join(' ');
    /* 資料名も残り行数も、ツールバーと左ナビが持っている。同じ数字を4か所へ書いて
       いた。この帯は「異常を知らせる」ときだけ使う。読み上げは sr-only の
       #cat-current-summary が担う。 */
    status('');
    if (focusFirst) window.setTimeout(function () { var first = document.querySelector('.is-active [data-cat-input]') || document.querySelector('[data-cat-input]'); YakuCommon.focus(first); }, 0);
  }

  function handleDirection(error, retry) {
    if (!(error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED')) return false;
    pendingDirection = retry; el('cat-direction-choice').hidden = false; status(error.data.error || '翻訳先を選んでください。'); YakuCommon.focus(el('cat-direction-choice').querySelector('[data-cat-direction]')); return true;
  }
  function source(mode, fileOverride) {
    /* Excel のファイル入力は Premium 側が所有し、File を直接渡す。 */
    var file = fileOverride;
    if (file) {
      if (!file.size) return Promise.reject(new Error('空のファイルは取り込めません。'));
      if (file.size > YakuCommon.maxUploadBytes) return Promise.reject(new Error('ファイルが大きすぎます。取り込めるのは ' + Math.round(YakuCommon.maxUploadBytes / 1048576) + 'MB までですが、このファイルは ' + (file.size / 1048576).toFixed(1) + 'MB あります。資料を分けてからお試しください。'));
      var key = [file.name, file.size, file.lastModified].join(':');
      if (uploaded && uploaded.key === key) return Promise.resolve({ file_handle: uploaded.handle });
      return YakuCommon.upload('/api/upload', file).then(function (data) { if (!data.file_handle) throw new Error('ファイルを読み込めませんでした。そのファイルがWordやExcelで開いたままになっていないかご確認のうえ、もう一度お選びください。'); uploaded = { key: key, handle: data.file_handle }; return { file_handle: data.file_handle }; });
    }
    var path = String(directFilePath || '').trim(); return path ? Promise.resolve({ file_path: path }) : Promise.reject(new Error('Word・Excelを選択してください。'));
  }
  function openSource(mode, intent, fileOverride) {
    var epoch = ++viewEpoch;
    /* A newer source operation owns the screen. Clear an older file spinner
       before its promise can settle, otherwise a stale file response may leave
       the indicator visible forever when the user switches to pasted text. */
    cancelFileLoading();
    if (mode === 'file') beginFileLoading(epoch);
    setBusy(true); status('取り込んでいます…');
    return Promise.resolve().then(function () { return source(mode, fileOverride); }).then(function (payload) { payload.direction_intent = intent || 'auto'; return post('open', payload, false, null); }).then(function (data) { if (epoch !== viewEpoch) return; finishFileLoading(epoch); pendingDirection = null; render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; finishFileLoading(epoch); setBusy(false); if (!handleDirection(error, function (dir) { return openSource(mode, dir, fileOverride); })) status(error.message, true); });
  }
  function resume(id) { var epoch = ++viewEpoch; setBusy(true); status('続きの作業を開いています…'); return post('resume', { project_id: id }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); }

  function commit(input, keepalive) {
    if (!input) return Promise.resolve();
    var index = Number(input.getAttribute('data-cat-input')), value = input.value;
    var projectId = input.getAttribute('data-cat-project-id') || '';
    var key = dirtyKey(projectId, index);
    if (value === input.getAttribute('data-original')) { dirty.delete(key); return Promise.resolve(); }
    saveStatus('保存しています…', false);
    saveChain = saveChain.catch(function () {}).then(function () {
      if (!project || String(project.id || '') !== projectId) return { stale: true };
      var requestScope = currentScope();
      return post('segment', { index: index, text: value }, true, requestScope, keepalive).then(function (data) { return { data: data, scope: requestScope }; });
    }).then(function (packet) {
      if (!packet || packet.stale || !scopeIsCurrent(packet.scope, true) || !packet.data || String(packet.data.id || '') !== projectId) return packet && packet.data;
      project = packet.data;
      var currentInput = Array.from(document.querySelectorAll('[data-cat-input]')).find(function (candidate) {
        return String(candidate.getAttribute('data-cat-project-id') || '') === projectId && Number(candidate.getAttribute('data-cat-input')) === index;
      });
      if (!currentInput || currentInput.value === value) {
        dirty.delete(key);
        if (currentInput) currentInput.setAttribute('data-original', value);
        var savedRow = currentInput ? currentInput.closest('[data-cat-row]') : null; if (savedRow) { savedRow.classList.remove('cat-dirty'); savedRow.classList.remove('cat-unsaved'); }
      } else {
        dirty.set(key, true);
      }
      saveStatus(dirty.size ? '変更を保存していません' : '保存済み', false);
      return packet.data;
    }).catch(function (error) {
      if (project && String(project.id || '') === projectId) {
        saveStatus('保存できませんでした。「⚠ 保存できませんでした」と出ている行をご確認ください。', true);
        var row = input.closest('[data-cat-row]'); if (row) row.classList.add('cat-unsaved');
      }
      throw error;
    });
    return saveChain;
  }
  function flush(keepalive) { var inputs = Array.from(document.querySelectorAll('[data-cat-input]')).filter(function (input) { return dirty.has(dirtyKey(input.getAttribute('data-cat-project-id'), Number(input.getAttribute('data-cat-input')))); }); var chain = Promise.resolve(); inputs.forEach(function (input) { chain = chain.then(function () { return commit(input, keepalive); }); }); return chain; }
  function mutate(action, body, message) {
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); if (message) status(message); return post(action, body || {}, true, requestScope);
    }).then(function (data) {
      if (!scopeIsCurrent(requestScope, true) || !data || (data.id && String(data.id) !== requestScope.id)) { setBusy(false); return null; }
      render(data); return data;
    }).catch(function (error) { setBusy(false); status(error.message, true); return null; });
  }

  function startJobHtml(html, context) {
    el('cat-job').innerHTML = html; var node = el('cat-job').querySelector('[data-yaku-job-id]'); if (!node) throw new Error('翻訳を始められませんでした。1分ほど待ってから、もう一度お試しください。');
    context = context || {}; context.token = ++jobSerial; context.startedAt = Date.now(); cancelRequestedJobId = '';
    /* 部分結果先出し。受け取った checkpoint 行を、差分カーソルの分母として
       ここへ積む(サーバの partial_rows は毎回「N件目以降」だけを返す)。
       プロジェクト状態は変えない・表示のみ(設計判断1・2)。 */
    context.partialRows = [];
    jobContext = context;
    pollJob(node.getAttribute('data-yaku-job-id'), context.token);
  }
  /* 先出しで届いた1行を、いま画面に見えている該当行だけへ書き込む。
     renderRows() は毎秒の全面再描画になり選択・コピー・スクロールを壊すため
     呼ばない(設計判断4)。 値のセットだけで input/change は発火させない。 */
  function applyPartialPreviewRow(row, deferGrow) {
    var index = Number(row && row.index);
    /* cancelled/error後にjobContextをnullにしない設計（MINOR-2でrenderRows末尾
       からの再適用を足したため、同じ資料に留まっている限りは効かせたい）の
       裏返しとして、資料を切り替えても前の資料のjobContextが生き続ける。
       finishJob()はcontext.scopeで守っているのに、ここは守っていなかった
       （CoD審査REWORK-2 MAJOR-A、実機4クリックで再現）。scopeが無いジョブ
       （align）は先出し行を生まないため無害。 */
    if (!jobContext || !jobContext.scope || !project || String(project.id || '') !== String(jobContext.scope.id)) return;
    if (!project || !Array.isArray(project.segments) || !isFinite(index)) return;
    var rowEl = document.querySelector('[data-cat-row="' + index + '"]');
    if (!rowEl) return;
    /* segments[i].index === i（CatProject.ps1:3786、ConvertTo-YakuCatProjectJson の
       index = $i）が正本の並びなので、毎回 find() で線形探索しない（CoD審査
       REWORK-2 NIT-B。なお600行の実測では find は3.6msで、遅さの主因は
       autoGrow の強制同期レイアウトだった — REWORK-3 MINOR-D を参照）。
       並びがずれていた場合に備え、直取りした要素の.indexが一致するかだけは確認する。 */
    var segment = project.segments[index];
    if (!segment || Number(segment.index) !== index || String(segment.source || '') !== String(row.source || '')) return;
    var input = rowEl.querySelector('textarea[data-cat-input="' + index + '"]');
    // NIT-C: text=''の先出し行(正本では到達しないはずだが、renderRows由来の
    // リプレイ対象になった以上は防御する）は、空の訳文欄へバッジだけ付けて
    // しまわないよう、ここで弾く。
    if (!input || String(input.value || '').trim() !== '' || !String(row.text || '').trim()) return;
    input.value = String(row.text || '');
    /* autoGrow は scrollHeight と getComputedStyle を読む＝強制同期レイアウト。
       renderRows() 末尾のリプレイで1行ごとに読み書きを交互にやると、600行資料の
       再描画1回が 556ms→2344ms に膨らんだ(CoD審査REWORK-3 MINOR-D の実測)。
       リプレイ側は deferGrow=true で書き込みだけ先に済ませ、autoGrow は呼び出し元が
       最後に一括で回す(703msまで戻る)。pollJob からの1行ずつの経路は従来どおり。 */
    if (!deferGrow) autoGrow(input);
    rowEl.classList.add('cat-partial-preview');
    if (!rowEl.querySelector('.cat-partial-badge')) {
      /* 場所は cat-col-loc/cat-col-no ではなく訳文欄側に置く。行番号・場所の列は
         実測で既に幅が詰まっており（CLAUDE.md「点検で気になる点」119px事例）、
         テキストの印を足すと折り返す危険がある。訳文欄は textarea の下に
         流れるだけの余白がある。 */
      var targetCell = rowEl.querySelector('.cat-target');
      if (targetCell) targetCell.insertAdjacentHTML('beforeend', '<span class="cat-partial-badge" title="Copilotから先に届いた訳文です。翻訳が全部終わると確定します。">先出し</span>');
    }
  }
  function applyPartialPreview(data) {
    var incoming = Array.isArray(data && data.partial_rows) ? data.partial_rows : [];
    if (!incoming.length || !jobContext || !Array.isArray(jobContext.partialRows)) return;
    for (var i = 0; i < incoming.length; i++) {
      jobContext.partialRows.push(incoming[i]);
      applyPartialPreviewRow(incoming[i]);
    }
  }
  function elapsedLabel(startedAt) {
    var seconds = Math.max(0, Math.round((Date.now() - Number(startedAt || Date.now())) / 1000));
    if (seconds < 60) return seconds + '秒経過';
    return Math.floor(seconds / 60) + '分' + (seconds % 60) + '秒経過';
  }
  /* サーバは「12回のうち3回目を翻訳中（1,840字）。残り20〜30分ほどです」まで作って
     detail に載せている。ここで捨てていたので、利用者は数十分を「翻訳中」の4文字だけで
     待たされていた。％・残り時間・経過・中止を、待っているあいだ必ず画面に置く。 */
  function jobHtml(id, data, startedAt) {
    var percent = Math.max(0, Math.min(100, Math.round(Number(data.progress) || 0)));
    var detail = String(data.detail || '');
    /* 先出しの分母(partial_expected_total)が有るCAT翻訳ジョブでだけ、
       「訳了 n/N 行(先出し)」を1行足す。n はサーバの累積値(partial_total)を
       そのまま使う(自前集計と食い違わせない)。 */
    var partialExpectedTotal = Number(data.partial_expected_total) || 0;
    var partialLine = partialExpectedTotal > 0
      ? ('<br><span class="job-partial-progress">訳了 ' + (Number(data.partial_total) || 0) + '/' + partialExpectedTotal + ' 行(先出し)</span>')
      : '';
    var stageLabels = { draft: '下訳', compress: '幅へ圧縮', select: '候補を選抜', back_reconstruct: '意味を逆照合', back_judge: '意味差を判定', retry: '意味差を修正', abbreviate: '略語で再調整' };
    var workerStateLabels = { waiting: '待機', done: '完了', requeued: '再試行待ち', error: '停止' };
    var stage = String(data.stage || '');
    var workers = Array.isArray(data.worker_progress) ? data.worker_progress.filter(function (worker) { return worker && typeof worker === 'object'; }) : [];
    var workerLine = workers.length ? ('<div class="job-workers" aria-label="Copilot workerの進行">' + workers.map(function (worker) {
      var state = String(worker.state || 'waiting'), ids = Array.isArray(worker.items) ? worker.items : [];
      return '<span class="job-worker job-worker-' + esc(state) + '"><strong>W' + (Number(worker.worker) + 1) + '</strong> ' + esc(state === 'running' ? (ids.length ? ('行 ' + ids.join(', ')) : '処理中') : (workerStateLabels[state] || state)) + '</span>';
    }).join('') + '</div>') : '';
    return '<div class="job-loading"><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase">' + esc(stage ? (stageLabels[stage] || stage) : (data.label || data.phase || '翻訳しています')) + '</div><div class="job-percent">' + percent + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳の進み具合" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + percent + '"><span class="job-progress-bar" style="width:' + percent + '%"></span></div>' +
      workerLine +
      '<div class="job-bottomline"><div class="job-meta">' + (detail ? esc(detail) : 'Copilotの返事を待っています。') +
      '<br><span class="job-elapsed">' + esc(elapsedLabel(startedAt)) + '</span>' + partialLine + '</div>' +
      '<button type="button" class="secondary-button job-cancel" data-yaku-cancel-job="' + esc(id) + '"' + (cancelRequestedJobId === String(id) ? ' disabled' : '') + '>' + (cancelRequestedJobId === String(id) ? 'やめています…' : '翻訳をやめる') + '</button></div>' +
      '</div></div>';
  }
  /* 別のアプリで仕事をしていても、終わったことに気づけるようにする。
     タスクバーのタイトルは、画面を見ていなくても目に入る唯一の場所。 */
  function setJobTitle(text) {
    /* 呼び名は画面の題（cat.html の <title>）に合わせて「翻訳」に統一する。
       貼り付けた文章も資料と同じ作業になったので、「資料翻訳」だけを名乗ると
       貼り付けから来た人のタスクバーに違う名前が出る（2026-08-13）。 */
    document.title = (text ? text + ' - ' : '') + '翻訳 - YakuLingo';
  }
  function pollJob(id, token, failureCount) {
    window.clearTimeout(jobTimer);
    failureCount = Number(failureCount || 0);
    var startedAt = jobContext && jobContext.startedAt;
    /* 差分カーソル。次に欲しいのは自前累積の後ろから(=既に受け取った件数)。
       cancelled/error/done の最後の1回も同じ形で取り、キャンセル・失敗時に
       画面へ残す分を取りこぼさない(設計判断5)。 */
    var partialAfter = (jobContext && Array.isArray(jobContext.partialRows)) ? jobContext.partialRows.length : 0;
    var partialQuery = partialAfter > 0 ? ('?partial_after=' + partialAfter) : '';
    YakuCommon.json('/api/jobs/' + encodeURIComponent(id) + partialQuery).then(function (data) {
      if (!jobContext || jobContext.token !== token) return;
      /* 終端応答だけに載った先出し行も失わない。ただし先出し表示の不調で
         完了・停止そのものを隠さないよう、終端判定とは分離する。 */
      try { applyPartialPreview(data); } catch (_) {}
      if (['done','completed_with_warnings'].indexOf(data.mode) >= 0) {
        /* apply後の応答（プロジェクトのJSON）にはマスク件数が無い。消える前の
           このポーリング応答だけが持っているので、ここで拾っておく。まとめ翻訳・
           1行だけ翻訳のときだけ見せる（直す・過去訳の突き合わせは対象外）。 */
        if (jobContext && jobContext.type === 'translate' && String(data.kind || '') === 'cat') jobContext.maskedCount = Number(data.masked_count || 0);
        setJobTitle('✔ 翻訳が終わりました'); finishJob(id, token); return;
      }
      if (data.mode === 'cancelled') { cancelRequestedJobId = ''; setJobTitle(''); setBusy(false); el('cat-job').innerHTML = ''; status('翻訳をやめました。ここまでにできた訳文は保存されています。「Copilotで未訳を翻訳」を押すと続きから再開できます。'); return; }
      if (['error','failed','interrupted'].indexOf(data.mode) >= 0) { cancelRequestedJobId = ''; setJobTitle(''); setBusy(false); status(data.detail || '翻訳が途中で止まりました。ここまでにできた訳文は保存されています。もう一度「Copilotで未訳を翻訳」を押すと、続きから再開します。', true); return; }
      try {
        el('cat-job').innerHTML = jobHtml(id, data, startedAt);
        setJobTitle(Math.round(Number(data.progress) || 0) + '% 翻訳中');
        jobTimer = window.setTimeout(function () { pollJob(id, token, 0); }, 1000);
      } catch (error) {
        setJobTitle(''); setBusy(false); status(error && error.message ? error.message : '画面を更新できませんでした。', true);
      }
    }, function () {
      /* 一瞬の通信断でエラーにすると、サーバ側では翻訳が続いているのに利用者が
         やり直してしまう。Copilotの利用回数を二重に使うので、必ず待つ。 */
      if (!jobContext || jobContext.token !== token) return;
      var next = failureCount + 1;
      el('cat-job').innerHTML = jobHtml(id, { label: next < 3 ? '進み具合をもう一度確認しています' : '接続の回復を待っています', detail: '翻訳は続いています。画面の更新だけを待っています。', progress: 0 }, startedAt);
      jobTimer = window.setTimeout(function () { pollJob(id, token, next); }, Math.min(6000, 800 * Math.pow(2, Math.min(next, 3))));
    });
  }
  /* テキスト/パレット経路にある New-YakuMaskingNoticeHtml と同じ文言・同じ
     流儀。0件も明示する（何も出さないと、安全を毎回見せる目的を外す）。 */
  function maskNoticeText(count) {
    return count > 0
      ? ('数値 ' + count + ' 件をマスクして送信しました。数値以外の文はマスクせずに送っています。')
      : 'この翻訳で外部へ送った数値はありません。数値以外の文はマスクせずに送っています。';
  }
  function finishJob(jobId, token) {
    var context = jobContext;
    if (!context || context.token !== token) return Promise.resolve();
    jobContext = null; el('cat-job').innerHTML = ''; window.setTimeout(function () { setJobTitle(''); }, 8000);
    if (context.type === 'align') return post('align-apply', { job_id: jobId, file_name: context.name }, false, null).then(function (data) { if (context.viewEpoch === viewEpoch) render(data, true); else setBusy(false); }).catch(function (error) { setBusy(false); status(error.message, true); });
    return post('apply', { job_id: jobId }, true, context.scope).then(function (data) {
      if (scopeIsCurrent(context.scope, true) && data && String(data.id || '') === context.scope.id) {
        if (context.type === 'revise' && context.comparison) {
          var revised = (data.segments || []).find(function (segment) { return Number(segment.index) === Number(context.comparison.index); });
          revisionComparison = revised && String(revised.translation || '') !== context.comparison.before ? { projectId: String(data.id || ''), index: Number(context.comparison.index), before: context.comparison.before } : null;
          /* The revised canonical translation is rendered directly in the row. */
        }
        render(data, true);
        /* 操作ゼロで件数が見える。次の翻訳まで残す（自動では消さない）。 */
        if (context.type === 'translate' && typeof context.maskedCount === 'number') el('cat-mask-notice').textContent = maskNoticeText(context.maskedCount);
      }
      else { setBusy(false); loadRecent(true); }
      return data;
    }).catch(function (error) { setBusy(false); if (project && String(project.id || '') === context.scope.id) status(error.message, true); });
  }
  function translate() {
    var glossaryScope = null, jobScope = null;
    return flush().then(function () { glossaryScope = currentScope(); if (!glossaryScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('用語集を適用しています…'); return post('glossary', {}, true, glossaryScope); }).then(function (data) {
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示している資料が切り替わったため、翻訳をやめました。もう一度「Copilotで未訳を翻訳」を押してください。');
      project = data; jobScope = currentScope(); status('訳していない行を訳しています…');
      var translateBody = { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate' };
      return YakuCommon.postText('/api/cat/translate', translateBody);
    }).then(function (html) { startJobHtml(html, { type: 'translate', scope: jobScope }); }).catch(function (error) { setBusy(false); status(error.message, true); });
  }
  /* 貼り付けから来たときだけ、そのまま訳しにいく。Copilot の準備は起動直後だと
     まだ終わっていないので、終わるのを待ってから1回だけ送る。押しっぱなしに
     ならないよう、送ったら二度と自動では送らない。 */
  var autoTranslateDone = false;
  function translateWhenReady() {
    if (autoTranslateDone) return;
    if (!project || Number(project.untranslated) <= 0) { autoTranslateDone = true; return; }
    if (ready) { autoTranslateDone = true; translate(); return; }
    status('Copilotの準備ができ次第、送ります。このままお待ちください。');
    YakuCommon.onReady(function (value) {
      if (autoTranslateDone || !value) return;
      if (!project || Number(project.untranslated) <= 0) { autoTranslateDone = true; return; }
      autoTranslateDone = true;
      translate();
    });
  }
  /* この行だけ訳す。まとめて訳すのと同じ口（mode: 'translate'）へ index を足す。
     別の道を作らないので、用語集も数値の伏せ方も待ち方も全部同じになる。 */
  function translateRow(index) {
    var glossaryScope = null, jobScope = null;
    return flush().then(function () {
      glossaryScope = currentScope(); if (!glossaryScope) throw new Error('資料が開かれていません。');
      setBusy(true); status('用語集を適用しています…'); return post('glossary', {}, true, glossaryScope);
    }).then(function (data) {
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示している資料が切り替わったため、翻訳をやめました。');
      project = data; jobScope = currentScope(); status((index + 1) + '行目を訳しています…');
      var translateRowBody = { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate', index: index };
      return YakuCommon.postText('/api/cat/translate', translateRowBody);
    }).then(function (html) { startJobHtml(html, { type: 'translate', scope: jobScope }); })
      .catch(function (error) { setBusy(false); status(error.message, true); });
  }
  /* この行の訳文だけ写す。まとめて写すのは道具の帯の「訳文をコピー」。 */
  function copyRowTarget(index) {
    var segment = project && (project.segments || []).find(function (item) { return Number(item.index) === index; });
    var input = document.querySelector('[data-cat-input="' + index + '"]');
    var text = String((input && input.value) || (segment && segment.translation) || '');
    if (!text.trim()) { status('この行にはまだ訳文がありません。', true); return Promise.resolve(); }
    return YakuCommon.copyText(text, input, el('cat-status')).then(function () { status((index + 1) + '行目の訳文をコピーしました。'); });
  }
  function revise(form, instructionOverride) {
    var index = Number(form.getAttribute('data-cat-revise')), instruction = String(instructionOverride || form.querySelector('input').value || '').trim(), jobScope = null;
    var segment = project && (project.segments || []).find(function (item) { return Number(item.index) === index; });
    var before = String(segment && segment.translation || '');
    if (!instruction || !before) return;
    revisionComparison = null;
    return flush().then(function () {
      jobScope = currentScope(); if (!jobScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status(instructionOverride ? '意味と数値を保ったまま短くしています…' : '指示に合わせて訳案を直しています…');
      return YakuCommon.postText('/api/cat/translate', { id: jobScope.id, expected_revision: jobScope.revision, mode: 'revise', index: index, instruction: instruction });
    }).then(function (html) { startJobHtml(html, { type: 'revise', scope: jobScope, comparison: { index: index, before: before } }); }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function acceptRevisionComparison() {
    revisionComparison = null; renderRows(); status('修正後の訳案を残しました。確認済みにする前に、表現をご確認ください。'); focusActive();
  }
  function revertRevisionComparison() {
    if (!revisionComparison || !project || revisionComparison.projectId !== String(project.id || '')) return;
    var snapshot = revisionComparison; revisionComparison = null;
    return mutate('segment', { index: snapshot.index, text: snapshot.before }, '変更前の訳文に戻しています…').then(function (data) {
      if (data) { status('変更前の訳文に戻しました。'); window.setTimeout(focusActive, 0); }
      return data;
    });
  }

  function focusActive() { var input = document.querySelector('.is-active [data-cat-input]'); if (input) YakuCommon.focus(input); }
  function activateIndex(index, focus) {
    return flush().then(function () {
      var segment = (project.segments || []).find(function (item) { return Number(item.index) === Number(index); });
      if (!segment) return;
      activeIndex = Number(segment.index); activeSegmentId = String(segment.segment_id || '');
      var body = el('cat-grid-body'), currentRow = body && body.querySelector('tr.is-active'), nextRow = body && body.querySelector('tr[data-cat-row="' + Number(segment.index) + '"]');
      /* 行を移るだけなら一覧の全DOMを作り直さない。以前は body.innerHTML を
         毎回置き換えていたため、エディタが一瞬消えて点滅し、入力欄の選択も
         失われていた。絞り込みで対象行がDOMに無い場合だけ従来の再描画へ戻す。 */
      if (currentRow && nextRow && currentRow !== nextRow) {
        currentRow.classList.remove('is-active');
        nextRow.classList.add('is-active');
        renderSegmentActions(segment);
        /* Premium側の「この行の詳細」は、操作リボンからノードを移して
           保持している。行DOMを作り直さない切替でも同じ更新フックを即時に
           通し、前の行のボタンが詳細欄へ残らないようにする。 */
        window.dispatchEvent(new CustomEvent('yaku-cat-rows-rendered'));
      } else {
        renderRows();
      }
      if (focus !== false) window.setTimeout(focusActive, 0);
    }).catch(function (error) { status('変更を保存できなかったため、行を移動しませんでした。' + error.message, true); });
  }
  function moveActive(delta) {
    var shown = visibleSegments(), position = shown.findIndex(function (segment) { return Number(segment.index) === Number(activeIndex); });
    if (!shown.length) return Promise.resolve();
    if (position < 0) position = 0;
    var next = Math.max(0, Math.min(shown.length - 1, position + delta));
    return activateIndex(Number(shown[next].index), true);
  }
  function focusAfter(index) {
    var all = project ? (project.segments || []) : [];
    var next = all.find(function (segment) { return Number(segment.index) > index && segmentActionable(segment); }) || all.find(segmentActionable);
    if (next) { activateIndex(Number(next.index), true); return; }
    if (!el('cat-export').disabled) { YakuCommon.focus(el('cat-export')); return; }
    status('検索条件の外に未確認の行があります。絞り込みを変更してください。'); YakuCommon.focus(el('cat-search'));
  }
  /* 過去に確認した訳を言葉で探す（市販CATのコンコーダンス）。いまの行に対して
     自動で出る候補とは別で、こちらは利用者が言葉を入れて引く。状態は変えない。 */
  function copySourceToTarget(index) {
    if (busy) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
    var segment = (project ? (project.segments || []) : []).find(function (item) { return Number(item.index) === Number(index); });
    if (!segment) return;
    var input = document.querySelector('[data-cat-input="' + index + '"]');
    if (!input) { activateIndex(index, true); window.setTimeout(function () { copySourceToTarget(index); }, 0); return; }
    if (String(input.value || '').trim() && String(input.value) !== String(segment.source)) {
      if (!window.confirm('この行の訳文を、原文と同じ内容で置き換えます。いまの訳文は失われます。置き換えますか？')) return;
    }
    input.value = String(segment.source || '');
    input.focus();
    commit(input);
    status('原文をそのまま訳文へ入れました。数字だけの行など、訳す必要がない行に使えます。');
  }

  function confirmRow(index) {
    return mutate('confirm', { index: index, confirmed: true }, '確認内容を保存しています…').then(function (data) {
      if (!data) return null;
      var reviewed = (data.segments || []).find(function (segment) { return Number(segment.index) === Number(index); });
      if (data.review_blocked || (reviewed && !reviewed.confirmed)) {
        status('確認済みにできませんでした。下の「点検」に出ている内容を直してから、もう一度お試しください。', true);
        currentFilter = 'qc'; renderRows();
        window.setTimeout(function () { var same = document.querySelector('[data-cat-input="' + index + '"]'); YakuCommon.focus(same); }, 0);
        return data;
      }
      /* 同じ原文の行へ配ったときは、必ず言う。黙って他の行が変わるのがいちばん困る。
         配るのは訳文が空の行だけで、確認済みにはしない（数字の点検は確定のときに
         しか走らないため）。市販のCATツールと同じ仕組みだが、上書きはしない。 */
      var propagated = Number(data.propagated || 0);
      if (propagated > 0) {
        status('同じ原文の ' + propagated + ' 行にも同じ訳を入れました。まだ確認済みではないので、目を通してから確定してください。');
      }
      window.setTimeout(function () { focusAfter(index); }, 0);
      return data;
    });
  }

  /* 一括確定。取り消せること・点検を通らない行は確定
     されないことを、押す前に伝える。あとから気づいても戻せる操作だが、
     何が起きるか知らずに押させない。 */
  function confirmBulk(button) {
    var indexes = String(button.getAttribute('data-cat-bulk-indexes') || '').split(',').filter(Boolean).map(Number);
    if (!indexes.length) return;
    if (!window.confirm('表示中の' + indexes.length + '行を、まとめて確認済みにします。\n\n・数字の自動点検を通らない行は、確認済みになりません\n・確認だけでは翻訳メモリへ登録しません\n・あとから1行ずつ「確認を取り消す」で戻せます\n\n進めますか？')) return;
    return mutate('confirm-bulk', { indexes: indexes }, '表示中の行をまとめて確認しています…').then(function (data) {
      if (!data) return null;
      var done = Number(data.bulk_confirmed || 0), blocked = (data.bulk_blocked || []).length;
      if (blocked) {
        status(done + '行を確認済みにしました。' + blocked + '行は数字の自動点検を通らなかったので、確認済みにしていません。左の「点検の指摘」で絞り込めます。', true);
      } else {
        status(done + '行を確認済みにしました。');
      }
      return data;
    });
  }

  /* 資料を切り替えたら検索条件も戻す。前の資料の検索語のまま次を開くと、
     行が0件の画面が出て「訳が消えた」に見える。 */
  function resetSearchTools() {
    searchScope = 'both'; searchCase = false; searchRegex = false;
    if (el('cat-search')) el('cat-search').value = '';
    if (el('cat-replace-input')) el('cat-replace-input').value = '';
    var menu = el('cat-search-menu'); if (menu) menu.open = false;
  }
  /* 検索と置換の帯。押す前に、何行に掛かるかを必ず書く（一括確定・事前翻訳と
     同じ作法）。式が読めないときは、その理由をここに出す。 */
  function renderSearchTools() {
    document.querySelectorAll('[data-cat-search-scope]').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-search-scope') === searchScope));
    });
    if (el('cat-search-case')) el('cat-search-case').checked = searchCase;
    if (el('cat-search-regex')) el('cat-search-regex').checked = searchRegex;
    var runButton = el('cat-replace-run'), summary = el('cat-replace-summary');
    if (!runButton || !summary) return;
    var undo = project && project.bulk_replace_undo;
    var undoButton = el('cat-replace-undo');
    if (undo && undo.available) {
      if (!undoButton) {
        undoButton = document.createElement('button');
        undoButton.type = 'button'; undoButton.id = 'cat-replace-undo';
        undoButton.className = 'secondary-button compact';
      }
      /* Ctrl+H の詳細を閉じても、戻せることは画面に残す。詳細の中だけだと
         置換直後にメニューが畳まれた場合、利用者には undo が無いように見える。 */
      var searchMenu = el('cat-search-menu');
      if (searchMenu && undoButton.parentNode !== searchMenu.parentNode) searchMenu.parentNode.insertBefore(undoButton, searchMenu.nextSibling);
      undoButton.disabled = !!busy;
      undoButton.textContent = '直前の一括置換を元に戻す（' + Number(undo.affected_count || 0) + '行）';
    } else if (undoButton) {
      undoButton.remove();
    }
    var structuralUndo = project && project.structural_undo;
    var structuralUndoButton = el('cat-structure-undo');
    if (structuralUndo && structuralUndo.available) {
      if (!structuralUndoButton) {
        structuralUndoButton = document.createElement('button');
        structuralUndoButton.type = 'button'; structuralUndoButton.id = 'cat-structure-undo';
        structuralUndoButton.className = 'secondary-button compact';
      }
      /* Ctrl+H の中に置かない。構造を変えた直後も常に見える、直前1回だけの
         専用の復元口であり、一般のUndoや Ctrl+Z を約束するものではない。 */
      var structureNames = { merge: '行の結合', split: '行の分割解除', 'split-at': '原文の途中での分割' };
      var structureName = structureNames[String(structuralUndo.operation || '')] || '構造編集';
      var structureRows = Number(structuralUndo.affected_count || 0);
      var structuralAnchor = el('cat-search-menu');
      if (structuralAnchor && structuralUndoButton.parentNode !== structuralAnchor.parentNode) structuralAnchor.parentNode.insertBefore(structuralUndoButton, structuralAnchor.nextSibling);
      structuralUndoButton.disabled = !!busy;
      structuralUndoButton.textContent = '直前の' + structureName + 'を元に戻す（' + structureRows + '行）';
    } else if (structuralUndoButton) {
      structuralUndoButton.remove();
    }
    var matcher = searchMatcher();
    if (matcher.empty) {
      runButton.disabled = true; runButton.textContent = '置換する';
      summary.textContent = '先に上の検索欄へ検索語を入力してください。'; summary.classList.remove('is-error');
      return;
    }
    if (matcher.invalid) {
      runButton.disabled = true; runButton.textContent = '置換する';
      summary.textContent = matcher.message; summary.classList.add('is-error');
      return;
    }
    summary.classList.remove('is-error');
    if (searchScope === 'source') {
      runButton.disabled = true; runButton.textContent = '置換する';
      summary.textContent = '原文は書き換えません。置換には「訳文」か「原文と訳文」を選んでください。';
      return;
    }
    var targets = replaceTargets();
    runButton.disabled = targets.length < 1;
    runButton.textContent = targets.length ? '一致する' + targets.length + '行を置換' : '置換する';
    summary.textContent = targets.length
      ? ('「' + String(el('cat-search').value || '') + '」に一致する' + targets.length + '行が対象です。')
      : '表示中の行の訳文には、この文字列は見つかりませんでした。';
  }

  /* 一括置換（市販CATの Ctrl+H）。用語を後からそろえるとき、手で1行ずつ直す
     以外の道が要る。memoQ・Phrase・Trados・XTM のどれも持っている。

     押す前に対象行数を告げるのは一括確定と同じ作法。数はサーバがもう一度
     数えたものを使う。画面の数と食い違ったら、その場で言ってから進める。

     いちばん大事なのは、置き換えた行の確認済みが外れることである。外さないと、
     点検を通っていない訳が確認済みのまま残る（「数値が抜けた訳は警告ではなく
     欠陥」）。落とすのはサーバ側で、手で直したときと同じ1本を通している。 */
  function runReplace() {
    if (!project) return;
    var matcher = searchMatcher();
    if (matcher.empty) { status('探す文字列を入れてください。', true); YakuCommon.focus(el('cat-search')); return; }
    if (matcher.invalid) { status(matcher.message, true); YakuCommon.focus(el('cat-search')); return; }
    if (searchScope === 'source') { status('原文は書き換えません。探す場所を「訳文だけ」か「原文と訳文」にしてください。', true); return; }
    var shown = visibleSegments();
    var indexes = shown.map(function (segment) { return Number(segment.index); });
    if (!indexes.length) { status('表示中の行がありません。絞り込みを見直してください。'); return; }
    var find = String(el('cat-search').value), into = String(el('cat-replace-input').value);
    var expected = replaceTargets().length;
    var scope = null;
    return flush().then(function () {
      scope = currentScope();
      if (!scope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status('置き換える行を数えています…');
      /* 「探す場所」をサーバへも渡す。原文だけを探しているときに訳文を書き換え
         ないという決まりを、画面の3か所（replaceTargets / renderSearchTools /
         runReplace）だけで守っていた。3つとも外しても回帰が全部緑だったので、
         サーバでも断る（CAT_REPLACE_SCOPE_SOURCE）。 */
      return post('replace-estimate', { indexes: indexes, find: find, replace: into, use_regex: searchRegex, match_case: searchCase, scope: searchScope }, false, scope);
    }).then(function (data) {
      setBusy(false);
      if (!scopeIsCurrent(scope, true)) { status('表示している資料が切り替わったため、置換をやめました。'); return null; }
      var rows = Number((data && data.rows) || 0);
      if (!rows) { status('表示中の行の訳文には、この文字列は見つかりませんでした。訳文はそのままです。'); return null; }
      var occurrences = Number((data && data.occurrences) || 0);
      var losing = Number((data && data.confirmed_rows) || 0);
      /* 画面の数え方とサーバの数え方が食い違うことがある（正規表現の細かい
         方言など）。黙って進めない。進めるのはサーバが数えた行である。 */
      var mismatch = (expected !== rows) ? ('・画面では' + expected + '行と数えましたが、実際に変わるのは' + rows + '行です\n') : '';
      if (!window.confirm('表示中の' + rows + '行の訳文を置き換えます（' + occurrences + 'か所）。\n\n'
        + mismatch
        + '・「' + find + '」→「' + into + '」に置き換えます\n'
        + '・原文は変わりません\n'
        + (losing ? '・確認済みの' + losing + '行は、確認済みが外れます。数字の点検は、確認済みにするときに走ります\n' : '')
        + '・完了後は、直前のこの一括置換だけを元に戻せます\n\n'
        + '進めますか？')) return null;
      return mutate('replace', { indexes: indexes, find: find, replace: into, use_regex: searchRegex, match_case: searchCase, scope: searchScope }, '訳文を置き換えています…').then(function (result) {
        if (!result) return null;
        var done = Number(result.replace_rows || 0), hits = Number(result.replace_occurrences || 0);
        var dropped = Number(result.replace_unconfirmed || 0);
        status(done + '行の訳文を置き換えました（' + hits + 'か所）。'
          + (dropped ? dropped + '行の確認済みが外れています。確認済みにするときに数字の点検を通ります。' : ''));
        return result;
      });
    }).catch(function (error) { setBusy(false); status(error.message, true); return null; });
  }

  function undoReplace() {
    if (!project || !project.bulk_replace_undo || !project.bulk_replace_undo.available) {
      status('元に戻せる一括置換はありません。'); return null;
    }
    var rows = Number(project.bulk_replace_undo.affected_count || 0);
    if (!window.confirm('直前の一括置換を元に戻します。\n\n'
      + '・' + rows + '行を置換前の状態へ戻します\n'
      + '・戻せるのは直前の一括置換だけです\n'
      + '・その後に行った変更は元に戻せません\n\n'
      + '進めますか？')) return null;
    return mutate('replace-undo', {}, '直前の一括置換を元に戻しています…').then(function (result) {
      if (!result) return null;
      status(Number(result.replace_undo_restored || rows) + '行を置換前の状態へ戻しました。');
      return result;
    });
  }

  function undoStructuralEdit() {
    if (!project || !project.structural_undo || !project.structural_undo.available) {
      status('元に戻せる構造編集はありません。'); return null;
    }
    var operation = String(project.structural_undo.operation || '');
    var names = { merge: '行の結合', split: '行の分割解除', 'split-at': '原文の途中での分割' };
    var name = names[operation] || '構造編集';
    var rows = Number(project.structural_undo.affected_count || 0);
    if (!window.confirm('直前の' + name + 'を元に戻します。\n\n'
      + '・' + rows + '行を編集前の状態へ戻します\n'
      + '・戻せるのは直前の構造編集だけです\n'
      + '・その後に行った変更は元に戻せません\n\n'
      + '進めますか？')) return null;
    return mutate('structure-undo', {}, '直前の構造編集を元に戻しています…').then(function (result) {
      if (!result) return null;
      status('直前の' + name + 'を元に戻しました。');
      return result;
    });
  }

  /* 事前翻訳（pre-translate）。翻訳メモリに完全一致がある行を、Copilot へ
     送る前に訳文欄へ入れる。市販CAT（memoQ / Trados / Phrase / XTM）はどれも
     持っているが、ここで効く理由はそれではない。翻訳の相手は API ではなく
     Copilot で使用上限があり、上限を超えたら再依頼しない決まりなので、
     1件当たるたびに、その分だけ訳せる分量が増える。

     押す前に対象行数を告げる（一括確定と同じ作法）。数える経路は何も
     書き換えない。翻訳メモリが読めなければ0件と出て、翻訳は従来どおり進む。

     置き場所は「そのほか」の一覧にした。上の帯は実機の窓幅 1380px で
     折り返さない設定（cat-workspace.css の @media 1400px）なので、4つ目の
     ボタンを足すと既にあるラベルから幅を奪う。 */
  function tmPretranslate() {
    var scope = null;
    return flush().then(function () {
      scope = currentScope();
      if (!scope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status('翻訳メモリで埋められる行を数えています…');
      return post('tm-pretranslate-estimate', {}, false, scope);
    }).then(function (data) {
      setBusy(false);
      if (!scopeIsCurrent(scope, true)) { status('表示している資料が切り替わったため、下訳をやめました。'); return null; }
      var rows = Number((data && data.rows) || 0);
      if (!rows) {
        if (data && data.memory_unavailable) {
          status('翻訳メモリを読めませんでした。下訳はできませんが、これまでどおり「Copilotで未訳を翻訳」で進められます。', true);
          return null;
        }
        status('翻訳メモリに完全一致する行はありませんでした。訳文はそのままです。');
        return null;
      }
      var kinds = Number((data && data.unique_texts) || 0);
      /* 途中まで読めた場合。翻訳メモリは最初の失敗でそこまでの分を返すので
         （CatProject.ps1 の計画側が break する）、rows が 0 でなくても
         「最後まで読めた」とは限らない。黙って rows 行だけ入れると、残りが
         未走査だったことが利用者に伝わらない。 */
      var partial = !!(data && data.memory_unavailable);
      if (!window.confirm('翻訳メモリに完全一致がある' + rows + '行へ、過去に確認した訳を入れます。\n\n'
        + (partial ? '・翻訳メモリを最後まで読めませんでした。ここまでで見つかった分だけ入れます\n' : '')
        + '・Copilotへ送る文が' + kinds + '件減ります\n'
        + '・入れた行は確認済みにはなりません。目を通してから確定してください\n'
        + '・すでに訳文がある行と、自分で直した行は変えません\n\n'
        + '進めますか？')) return null;
      return mutate('tm-pretranslate', {}, '翻訳メモリで下訳しています…').then(function (result) {
        if (!result) return null;
        var filled = Number(result.tm_pretranslate_filled || 0);
        if (!filled) { status('入れられる行がありませんでした。訳文はそのままです。'); return result; }
        var saved = Number(result.tm_pretranslate_requests_saved || 0);
        var before = Number(result.tm_pretranslate_calls_before || 0);
        var after = Number(result.tm_pretranslate_calls_after || 0);
        /* 依頼の回数はまとめて送る単位なので、送る文が減っても回数が変わらない
           ことがある。実機で「1回から1回になりました」と出た（2026-08-15）ので、
           変わったときだけ言う。減った文の数はいつでも言う。 */
        var callsPart = (before > after) ? ('依頼の見積りは' + before + '回から' + after + '回になりました。') : '';
        /* 入れたあとに「最後まで読めなかった」を伝える。サーバは
           tm_pretranslate_memory_unavailable で返しているのに、画面がどこでも
           読んでいなかった（2026-08-15 の批評）。返しているが誰も読まない値を
           残さない。 */
        var partialPart = result.tm_pretranslate_memory_unavailable
          ? '翻訳メモリを最後まで読めなかったので、残りは見ていません。もう一度押すと続きから探します。' : '';
        status(filled + '行に翻訳メモリの訳を入れました。Copilotへ送る文が' + saved + '件減りました。' + callsPart
          + partialPart + 'まだ確認済みではないので、目を通してから確定してください。');
        return result;
      });
    }).catch(function (error) { setBusy(false); status(error.message, true); return null; });
  }

  function registerTranslationMemory(index) {
    if (!window.confirm('この確認済みの訳を翻訳メモリへ登録します。\n\n次の資料で同じ表現の候補として使われます。登録しますか？')) return;
    return mutate('tm-register', { index: index }, '翻訳メモリへ登録しています…').then(function (data) {
      if (data) status('この訳を翻訳メモリへ登録しました。次の資料から候補として使えます。');
      return data;
    });
  }
  function registerAlignmentTranslationMemoryBulk() {
    if (!project || project.source !== 'align') {
      status('過去訳の対応確認でのみ一括登録できます。', true);
      return Promise.resolve(null);
    }
    var eligible = Number(project.tm_bulk_eligible_count);
    var pendingBefore = Math.max(0, Number(project.tm_pending || 0));
    var retryPending = isFinite(eligible) && eligible <= 0 && pendingBefore > 0;
    if (isFinite(eligible) && eligible <= 0 && !retryPending) {
      updateAlignmentRegistrationUi();
      status('現在、登録できる確認済み・最新の点検済み・非空・未登録の行はありません。', true);
      return Promise.resolve(null);
    }
    var confirmed = (project.segments || []).filter(function (segment) { return !!segment.confirmed; }).length;
    if (!retryPending && !window.confirm('確認済みの過去訳を翻訳メモリへ登録します。\n\n現在 ' + confirmed + ' 行が確認済みです。未確認・点検が古い・空欄の行は登録しません。続けますか？')) return Promise.resolve(null);
    return mutate('tm-register-bulk', {}, retryPending ? '翻訳メモリへの反映を再試行しています…' : '確認済みの過去訳を登録しています…').then(function (data) {
      if (!data) return data;
      var registered = Number(data.tm_registered_count || 0);
      var skipped = Number(data.tm_skipped_count || 0);
      var pending = Number(data.tm_pending || 0);
      if (pending > 0) {
        status('登録内容を保存しましたが、翻訳メモリへの反映待ちが' + pending + '件あります。同期が完了するまで登録完了とは扱いません。', true);
      } else if (retryPending) {
        status('翻訳メモリへの反映が完了しました。反映待ちはありません。');
      } else if (registered <= 0) {
        status('今回、登録できる過去訳はありませんでした。対象外 ' + skipped + ' 行。', true);
      } else {
        status('過去訳を登録しました。登録 ' + registered + ' 行、対象外 ' + skipped + ' 行。');
      }
      return data;
    });
  }

  /* 全文の退避はダイアログで出す。器の中に居座らせると、取り出した直後だけ
     スクロールする場所が6つに増え、一覧が1.5行まで潰れる（実測）。 */
  function openTextOutput() {
    var dialog = el('cat-text-output');
    if (dialog && !dialog.open) { try { dialog.showModal(); } catch (_) { dialog.setAttribute('open', 'open'); } }
  }
  function closeTextOutput() {
    var dialog = el('cat-text-output');
    if (dialog && dialog.open) { try { dialog.close(); } catch (_) { dialog.removeAttribute('open'); } }
  }

  /* 読み込んだ PDF のページ。範囲を選び直しても読み直さなくて済むよう、
     解析の結果をそのまま持っておく（本文はこの画面の中だけにある）。 */
  var alignPages = { source: [], target: [] };
  var alignSideText = { source: 'cat-align-source', target: 'cat-align-target' };

  /* ページの冒頭を並べる。対応するページを別のアプリで開いて調べ直さずに、
     この画面の中で左右を見比べて決められるようにする（2026-08-13）。
     市販ツールも対応づけは人が宣言する作りで、memoQ は名前が違いすぎると
     間違えると警告し、Phrase は完全一致を要求する。宣言してもらう代わりに、
     調べる手間はこちらで引き受ける。 */
  function renderAlignPages(side) {
    var host = el('cat-align-' + side + '-pages');
    if (!host) return;
    host.innerHTML = alignPages[side].map(function (p) {
      var head = String(p.text || '').split('\n').filter(function (t) { return t.trim(); })[0] || '（文字なし）';
      return '<div class="align-page-row"><span class="align-page-no">' + p.page + '</span>' + esc(head.slice(0, 48)) + '</div>';
    }).join('');
  }

  /* 選んだ範囲のページだけを、送る文へ組み直す。範囲を空にすると全部。 */
  function applyAlignRange(side) {
    var pages = alignPages[side];
    if (!pages || !pages.length) return;
    var fromInput = el('cat-align-' + side + '-from');
    var toInput = el('cat-align-' + side + '-to');
    fromInput.max = pages.length; toInput.max = pages.length;
    if (!fromInput.value) fromInput.value = 1;
    if (!toInput.value) toInput.value = pages.length;
    var from = Math.max(1, Math.min(pages.length, Number(fromInput.value) || 1));
    var to = Math.max(from, Math.min(pages.length, Number(toInput.value) || pages.length));
    fromInput.value = from; toInput.value = to;
    el(alignSideText[side]).value = pages.slice(from - 1, to).map(function (p) { return p.text; }).join('\n');
  }

  /* 送る前に、Copilot への往復回数と見込み時間を出す。実測 2026-08-13:
     144ページの資料は 5,742行 = 最低128往復で、20〜40分かかる。
     押したあとに知るのでは遅い。切り分けは Alignment.ps1 と同じ
     （日本語を軸に50行ずつ、5行重ね）。 */
  function updateAlignEstimate() {
    var status = el('cat-align-file-status');
    if (!status) return;
    var ja = String(el('cat-align-source').value || '').split(/\r?\n/).filter(function (t) { return t.trim().length >= 4; }).length;
    var en = String(el('cat-align-target').value || '').split(/\r?\n/).filter(function (t) { return t.trim().length >= 4; }).length;
    var open = el('cat-align-open');
    var ready = ja > 0 && en > 0;
    if (open) {
      open.disabled = !ready;
      open.textContent = ready ? '対応を作って確認する' : '日本語版と英語版を選んでください';
    }
    if (!ready) {
      if (ja > 0) status.textContent = '日本語 ' + ja.toLocaleString('ja-JP') + '行を読みました。次に英語版を選んでください。';
      else if (en > 0) status.textContent = '英語 ' + en.toLocaleString('ja-JP') + '行を読みました。次に日本語版を選んでください。';
      else status.textContent = '日本語版と英語版を1つずつ選んでください。';
      return;
    }
    var chunks = Math.max(1, Math.ceil(Math.max(0, ja - 5) / 45));
    var lo = Math.round(chunks * 10 / 60), hi = Math.round(chunks * 20 / 60);
    var time = chunks <= 3 ? '1分ほど' : (Math.max(1, lo) + '〜' + Math.max(2, hi) + '分ほど');
    status.textContent = '選んだ範囲は日本語 ' + ja.toLocaleString('ja-JP') + '行、英語 ' + en.toLocaleString('ja-JP') + '行です。両方の文をCopilotへ約' + chunks + '回送ります（' + time + '）。'
      + (chunks > 20 ? ' 途中で止まっても、そこまでの対応は残ります。' : '');
  }

  function bindFileDrop(drop, input) {
    if (!drop || !input) return;
    /* 枠そのものをドロップ先にしたので、中に入力欄があることがある
       （貼り付け欄）。そこで打った Enter や空白まで拾うと、文章を打つだけで
       ファイル選択の窓が開く。入力欄の中のキーには手を出さない。 */
    drop.addEventListener('keydown', function (event) { if (event.target.closest('textarea, input, select, button, a, [contenteditable]')) return; if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); input.click(); } });
    ['dragenter','dragover'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.add('dragover'); }); });
    ['dragleave','drop'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.remove('dragover'); }); });
    drop.addEventListener('drop', function (event) {
      event.stopPropagation();
      var files = event.dataTransfer && event.dataTransfer.files;
      if (!files || !files.length) return;
      /* FileList の代入・change 発火を経由せず、同じアップロード処理へ渡す。 */
      uploaded = null;
      openSource('file', 'auto', files[0]);
    });
  }

  var filterSeq = 0;
  function redrawAfterFlush() {
    var seq = ++filterSeq;
    return flush().then(function () { if (seq === filterSeq && project) { candidateSeq++; renderRows(); } }).catch(function (error) { status('変更を保存できなかったため、表示を切り替えませんでした。' + error.message, true); });
  }
  function markTermsInSource(terms) {
    var host = document.querySelector('tr.is-active .cat-source-text');
    if (!host) return;
    var text = host.getAttribute('data-plain');
    if (text === null) { text = host.textContent; host.setAttribute('data-plain', text); }
    var words = [];
    terms.forEach(function (item) {
      var word = String(item.source || '');
      if (word && words.indexOf(word) < 0) words.push(word);
    });
    if (!words.length) { host.textContent = text; return; }
    /* 長いものから当てないと、短い語が長い語の内側を先に食う。 */
    words.sort(function (a, b) { return b.length - a.length; });
    var marks = [];
    words.forEach(function (word) {
      var from = 0, at;
      while ((at = text.indexOf(word, from)) >= 0) {
        var clash = marks.some(function (m) { return at < m.end && (at + word.length) > m.start; });
        if (!clash) marks.push({ start: at, end: at + word.length, word: word });
        from = at + word.length;
      }
    });
    if (!marks.length) { host.textContent = text; return; }
    marks.sort(function (a, b) { return a.start - b.start; });
    var html = '', cursor = 0;
    marks.forEach(function (m) {
      html += esc(text.slice(cursor, m.start)) + '<mark class="cat-term-hit" title="登録した用語です">' + esc(m.word) + '</mark>';
      cursor = m.end;
    });
    host.innerHTML = html + esc(text.slice(cursor));
  }

  /* 原文の span の先頭から、押した位置までの文字数。**印が入っていても効く。**

     markTermsInSource は、いま開いている行の原文を <mark> 入りの HTML へ差し替える
     （候補を描くたびに無条件で走る）。つまり分けたい行は、ほぼ必ず子ノードが
     複数ある。かつてここは `span.firstChild` からの相対で位置を取っていたので、
     最初の <mark> より後ろを押すと位置を拾えず、しかも**前に拾えた位置が残った
     まま**だった。利用者は押した場所とは違う位置で黙って割られる
     （headless Chromium で実測、2026-08-15）。

     span 先頭からキャレットまでの範囲を1つ作り、その文字数を数える。<mark> は
     文字数を変えないので、markTermsInSource が data-plain に残している生原文と
     突き合わせられる。範囲外・別の行なら -1 を返し、呼び出し側は覚えている
     位置を捨てる。 */
  function sourceCaretOffset(span, range) {
    if (!span || !range || !range.startContainer || !span.contains(range.startContainer)) return -1;
    var measure = null;
    try {
      measure = (span.ownerDocument || document).createRange();
      measure.setStart(span, 0);
      measure.setEnd(range.startContainer, range.startOffset);
    } catch (_) { return -1; }
    var position = measure.toString().length;
    var plain = span.getAttribute('data-plain');
    if (plain === null) plain = span.textContent;
    if (position < 0 || position > String(plain).length) return -1;
    return position;
  }

  function insertTerm(button) {
    var index = Number(button.getAttribute('data-cat-index')), projectId = button.getAttribute('data-cat-project-id') || '';
    var input = document.querySelector('[data-cat-input="' + index + '"][data-cat-project-id="' + projectId + '"]');
    if (!input) { status('先に挿入先の訳文欄を選んでください。'); return Promise.resolve(); }
    var term = button.getAttribute('data-cat-term-insert') || '', start = input.selectionStart, end = input.selectionEnd;
    var requestScope = currentScope(); if (!requestScope || requestScope.id !== projectId) return Promise.resolve();
    var nextText = input.value.slice(0, start) + term + input.value.slice(end);
    setBusy(true); status('用語を挿入して保存しています…');
    return post('term-insert', { index: index, text: nextText, reference_id: button.getAttribute('data-cat-reference-id') || '' }, true, requestScope).then(function (data) {
      if (scopeIsCurrent(requestScope, true)) { render(data); status('用語だけを訳文へ挿入しました。文全体を確認してください。'); YakuCommon.focus(document.querySelector('[data-cat-input="' + index + '"]')); }
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }
  function insertReference(button) {
    var buttonProjectId = button.getAttribute('data-cat-project-id') || '';
    var index = Number(button.getAttribute('data-cat-index'));
    var current = currentScope(), currentSegment = activeSegment();
    if (!current || current.id !== buttonProjectId || Number(activeIndex) !== index || !currentSegment || Number(currentSegment.index) !== index || candidateDetailRequestIndex !== index || candidateDetailRequestProjectId !== buttonProjectId || candidateDetailRequestRevision !== current.revision) {
      status('候補が古くなりました。候補を読み直してから挿入してください。', true);
      return Promise.resolve();
    }
    var active = document.querySelector('[data-cat-input="' + index + '"][data-cat-project-id="' + buttonProjectId + '"]');
    if (!active) { status('先に挿入先の訳文欄を選んでください。'); return Promise.resolve(); }
    var referenceId = button.getAttribute('data-cat-reference-id') || '';
    var translation = button.getAttribute('data-cat-insert') || '';
    if (!referenceId) { status('この参考訳は現在利用できません。候補を読み直してください。', true); return Promise.resolve(); }
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope();
      if (!requestScope || requestScope.id !== buttonProjectId) throw new Error('表示中の作業が変わったため、挿入を中止しました。');
      setBusy(true); status('参考訳を挿入して保存しています…');
      return post('segment', { index: index, text: translation, reference_id: referenceId }, true, requestScope);
    }).then(function (data) {
      if (!scopeIsCurrent(requestScope, true) || !data || String(data.id || '') !== requestScope.id) { setBusy(false); return; }
      render(data); status('参考訳を挿入しました。内容を確認し、必要なら編集してください。');
      var restored = document.querySelector('[data-cat-input="' + index + '"]');
      YakuCommon.focus(restored);
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  /* ---- 原文の数字を訳文へ入れる（Ctrl+D → 番号キー） ------------------------
     一覧はサーバから取る。数字の切り出しは点検（numeric-value-mismatch）が
     原文に対して行うものと同じ関数（Get-YakuCatSegmentSourceNumericFacts）を
     通っており、画面側で正規表現を書き直すと「画面が勧めたとおり入れたのに
     点検が落ちる」食い違いが生まれる。表記も原文のまま（桁区切り・小数点を
     均さない）で届く。 */
  function closePlaceablePicker() {
    placeablePicker.open = false; placeablePicker.index = -1; placeablePicker.items = []; placeablePicker.input = null;
    var host = el('cat-placeable-picker');
    if (!host) return;
    host.hidden = true; host.innerHTML = '';
  }
  function renderPlaceablePicker(input, items) {
    var host = el('cat-placeable-picker');
    if (!host) return;
    host.innerHTML = items.map(function (item, position) {
      return '<button type="button" role="option" aria-selected="false" class="cat-placeable" data-cat-placeable="' + position + '" data-cat-placeable-text="' + esc(item.text) + '">' +
        '<span class="cat-placeable-key" aria-hidden="true">' + (position + 1) + '</span>' +
        '<span class="cat-placeable-text">' + esc(item.text) + '</span></button>';
    }).join('');
    host.hidden = false;
    /* 訳文欄のすぐ下に置く。表の中へ差し込むと、行を描き直すたびに消える。 */
    var rect = input.getBoundingClientRect();
    host.style.left = Math.round(Math.max(8, rect.left)) + 'px';
    host.style.top = Math.round(rect.bottom + 4) + 'px';
  }
  function openPlaceablePicker(input) {
    if (!input) { status('先に訳文欄を選んでから Ctrl+D を押してください。'); return Promise.resolve(); }
    var index = Number(input.getAttribute('data-cat-input'));
    var requestScope = currentScope();
    if (!requestScope || requestScope.id !== (input.getAttribute('data-cat-project-id') || '')) return Promise.resolve();
    var seq = ++placeablePicker.seq;
    return post('placeables', { index: index }, false, requestScope).then(function (data) {
      if (seq !== placeablePicker.seq) return;
      if (!scopeIsCurrent(requestScope, true) || !input.isConnected) return;
      if (data && data.available === false) { closePlaceablePicker(); status('この行の原文から数字を取り出せませんでした。手で入力してください。', true); return; }
      var items = ((data && data.placeables) || []).filter(function (item) { return item && String(item.text || '') !== ''; });
      if (!items.length) { closePlaceablePicker(); status('この行の原文に数字はありません。'); return; }
      placeablePicker.open = true; placeablePicker.index = index; placeablePicker.items = items; placeablePicker.input = input;
      renderPlaceablePicker(input, items);
      status('原文の数字を ' + items.length + ' 件出しました。番号キー（1〜' + Math.min(9, items.length) + '）で訳文へ入ります。');
    }).catch(function (error) { closePlaceablePicker(); status(error.message, true); });
  }
  function insertPlaceable(position) {
    if (!placeablePicker.open) return;
    var input = placeablePicker.input;
    var item = placeablePicker.items[position];
    if (!input || !input.isConnected) { closePlaceablePicker(); status('訳文欄が見つかりませんでした。もう一度お試しください。', true); return; }
    if (!item) { status('その番号の数字はありません。'); return; }
    var text = String(item.text || '');
    var start = input.selectionStart, end = input.selectionEnd;
    if (!Number.isInteger(start)) { start = input.value.length; end = start; }
    closePlaceablePicker();
    /* 原文どおりの表記をそのまま置く。ここで整形すると、点検が見ている値と
       画面が入れた文字が食い違う。 */
    input.value = input.value.slice(0, start) + text + input.value.slice(end);
    var caret = start + text.length;
    try { input.setSelectionRange(caret, caret); } catch (_) {}
    /* 保存の道は手入力と同じ（input → dirty → focusout / Ctrl+Enter で保存）。 */
    input.dispatchEvent(new Event('input', { bubbles: true }));
    YakuCommon.focus(input);
    status('原文の「' + text + '」を訳文へ入れました。');
  }

  function openTermDialog(index) {
    var segment = (project.segments || []).find(function (item) { return Number(item.index) === Number(index); });
    if (!segment) return;
    var useSelection = termSelection.index === Number(index);
    var source = useSelection ? termSelection.source : '', target = useSelection ? termSelection.target : '';
    if ((!source || !target) && segment.kind === 'cell' && String(segment.source || '').length <= 40 && String(segment.translation || '').length <= 80) {
      source = source || segment.source || ''; target = target || segment.translation || '';
    }
    el('cat-term-index').value = String(index); el('cat-term-id').value = ''; el('cat-term-version').value = ''; el('cat-term-source').value = source; el('cat-term-target').value = target;
    el('cat-term-allowed').value = ''; el('cat-term-forbidden').value = ''; el('cat-term-note').value = '';
    el('cat-term-submit').textContent = '登録して該当行を再検査';
    el('cat-term-dialog').showModal(); YakuCommon.focus(source ? el('cat-term-target') : el('cat-term-source'));
  }

  function openTermEdit(button) {
    var index = Number(button.getAttribute('data-cat-index'));
    el('cat-term-index').value = String(index); el('cat-term-id').value = button.getAttribute('data-cat-term-id') || ''; el('cat-term-version').value = button.getAttribute('data-cat-term-version') || '';
    el('cat-term-source').value = button.getAttribute('data-cat-term-source') || ''; el('cat-term-target').value = button.getAttribute('data-cat-term-target') || '';
    el('cat-term-allowed').value = button.getAttribute('data-cat-term-allowed') || ''; el('cat-term-forbidden').value = button.getAttribute('data-cat-term-forbidden') || ''; el('cat-term-note').value = '';
    var scope = button.getAttribute('data-cat-term-scope') || 'project', scopeNode = document.querySelector('[name="cat-term-scope"][value="' + scope + '"]'); if (scopeNode) scopeNode.checked = true;
    el('cat-term-submit').textContent = '変更して該当行を再検査'; el('cat-term-dialog').showModal(); YakuCommon.focus(el('cat-term-target'));
  }

  function saveTerm() {
    var index = Number(el('cat-term-index').value), scopeNode = document.querySelector('[name="cat-term-scope"]:checked');
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status('用語を登録し、該当行を再検査しています…');
      return post('term-add', { index: index, source_term: el('cat-term-source').value, preferred_target: el('cat-term-target').value,
        allowed_targets: el('cat-term-allowed').value, forbidden_targets: el('cat-term-forbidden').value,
        scope: scopeNode ? scopeNode.value : 'project', note: el('cat-term-note').value,
        term_id: el('cat-term-id').value, term_version: Number(el('cat-term-version').value || 0) }, true, requestScope);
    }).then(function (data) {
      el('cat-term-dialog').close(); termSelection = { index: -1, source: '', target: '' };
      if (scopeIsCurrent(requestScope, true)) { render(data); status('用語を登録しました。該当する' + Number(data.term_affected_count || 0) + '行は、訳文を変えずに再検査対象にしました。'); }
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function deactivateTerm(button) {
    if (!window.confirm('この用語の登録を取りやめますか？今後、候補にも自動点検にも使われなくなります。すでに確認した訳文はそのまま残ります。')) return Promise.resolve();
    var requestScope = currentScope(), index = Number(button.getAttribute('data-cat-index')); if (!requestScope) return Promise.resolve();
    setBusy(true); status('用語を使わない状態にしています…');
    return post('term-deactivate', { index: index, term_id: button.getAttribute('data-cat-term-deactivate') || '' }, true, requestScope).then(function (data) {
      if (scopeIsCurrent(requestScope, false)) { render(data); status('用語を使わない状態にしました。該当する訳文は変更していません。'); }
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function openTermException(button) {
    el('cat-term-exception-index').value = button.getAttribute('data-cat-term-exception') || '';
    el('cat-term-exception-id').value = button.getAttribute('data-cat-term-id') || '';
    el('cat-term-exception-version').value = button.getAttribute('data-cat-term-version') || '';
    el('cat-term-exception-description').textContent = '「' + (button.getAttribute('data-cat-term-source') || 'この用語') + '」について、この行だけ例外を記録します。原文・訳文・用語が変わると例外は失効します。';
    el('cat-term-exception-alternative').value = ''; el('cat-term-exception-note').value = '';
    el('cat-term-exception-dialog').showModal(); YakuCommon.focus(document.querySelector('[name="cat-term-exception-reason"]'));
  }

  function saveTermException() {
    var reason = document.querySelector('[name="cat-term-exception-reason"]:checked'), requestScope = currentScope();
    if (!requestScope) return Promise.resolve();
    setBusy(true); status('この行の用語例外を保存しています…');
    return post('term-exception', { index: Number(el('cat-term-exception-index').value), term_id: el('cat-term-exception-id').value,
      term_version: Number(el('cat-term-exception-version').value), reason_code: reason ? reason.value : 'not-applicable',
      alternative: el('cat-term-exception-alternative').value, note: el('cat-term-exception-note').value }, true, requestScope).then(function (data) {
      el('cat-term-exception-dialog').close(); if (scopeIsCurrent(requestScope, true)) { render(data); status('この行だけ、登録した訳を使わない設定にしました。「確認済みにする」を押すと、もう一度点検します。'); }
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function deleteMemory(button) {
    if (!window.confirm('この候補を、今後は出さないようにしますか？\n\nすでにこの候補を使った行の訳文は、そのまま残ります。')) return Promise.resolve();
    var requestScope=currentScope(), index=Number(button.getAttribute('data-cat-index'));
    if(!requestScope)return Promise.resolve(); setBusy(true); status('この候補を今後は出さない設定にしています…');
    return post('tm-delete',{index:index,reference_id:button.getAttribute('data-cat-tm-delete')||''},true,requestScope).then(function(){setBusy(false);button.disabled=true;button.hidden=true;status('この候補は、今後は出しません。');}).catch(function(error){setBusy(false);status(error.message,true);});
  }
  function exportProject() {
    var requestScope = null, finalRequested = !!el('cat-export-final-review').checked, finalReason = String(el('cat-export-final-reason').value || '').trim();
    return flush().then(function () { requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('出力しています…'); return post('export', {}, true, requestScope); }).then(function (data) {
      if (!project || String(project.id || '') !== requestScope.id) { setBusy(false); return; }
      var recordPromise = Promise.resolve(null);
      if (finalRequested) {
        recordPromise = post('final-review-decision', { output_token: data.output_token, reason: finalReason, acknowledge_unresolved: true }, true, requestScope).then(function (recorded) {
          project.revision = Number(recorded.revision); requestScope.revision = Number(recorded.revision);
          return recorded;
        }).catch(function (error) { return { record_error: error.message }; });
      }
      return recordPromise.then(function (recorded) {
      setBusy(false); outputScope = requestScope;
      if (recorded && recorded.record_error) status('出力は作成しましたが、確認記録は残せませんでした。' + recorded.record_error, true);
      else if (recorded) status(recorded.decision && recorded.decision.render_reviewed ? '出力内容とPDFの確認記録を残しました。' : '出力内容の確認記録を残しました。PDFの掲載確認は別に表示されます。');
      if (data.text) { if (!recorded) status(''); openTextOutput(); el('cat-text-output').setAttribute('data-cat-output-project', requestScope.id); el('cat-text-output-value').value = data.text; el('cat-text-output-note').textContent = ''; return YakuCommon.copyText(data.text, el('cat-text-output-value'), el('cat-status')); }
      /* 出したあとに同じことを2度言わない。行にファイル名が出ており、DRAFT_ の
         決まりは押す前の確認で読んでいる（2026-08-12、利用者の指摘
         「いちいち言われなくても、そのまま社外に送るひとなんていない」）。 */
      if (!recorded) status(''); el('cat-output-row').hidden = false; el('cat-output-row').setAttribute('data-cat-output-project', requestScope.id); el('cat-output-name').textContent = data.output_name || data.output_path; YakuCommon.focus(el('cat-output-row'));
      });
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function outputModeLabel(mode) {
    if (mode === 'word_draft') return '訳文入りのWordを作ります';
    if (mode === 'excel_draft') return '訳文入りのExcelを作ります';
    if (mode === 'copy_text') return '訳文をまとめてコピーします';
    return '現在は出力できません';
  }
  /* 確認済みの行だけを取り出す。全行そろうまで成果ゼロ、という状態をなくすための経路。
     出せるのは reviewed の行だけで、残りは含めない。何行を含めなかったかは必ず伝える。 */
  function exportReviewed() {
    if (busy || !project) return;
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status('確認済みの行を集めています…');
      return post('export-reviewed', {}, true, requestScope);
    }).then(function (data) {
      setBusy(false);
      if (!data || !scopeIsCurrent(requestScope, true)) return;
      openTextOutput();
      el('cat-text-output').setAttribute('data-cat-output-project', requestScope.id);
      el('cat-text-output-value').value = data.text || '';
      var note = data.partial
        ? ('全 ' + data.total + ' 行のうち、確認済みの ' + data.written + ' 行だけをコピーしました。まだ確認していない ' + data.skipped + ' 行は入っていません。')
        : ('全 ' + data.written + ' 行をコピーしました。');
      el('cat-text-output-note').textContent = note;
      return YakuCommon.copyText(data.text || '', el('cat-text-output-value'), el('cat-status')).then(function () { status(note); });
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  /* 「今後の資料でも使う」で登録した訳の一覧と取り消し。
     これまで登録はできるのに消す手段が無く、一度間違えると全資料へ入り続けていた。 */
  function loadPersonalGlossary() {
    var box = el('cat-personal-glossary-list');
    if (!box || !project) return;
    box.innerHTML = '<p class="muted">読み込んでいます…</p>';
    return post('personal-glossary-list', {}, true, currentScope()).then(function (data) {
      var items = (data && data.entries) ? data.entries : [];
      if (!items.length) { box.innerHTML = '<p class="muted">今後の資料でも使う登録は、まだありません。</p>'; return; }
      box.innerHTML = items.map(function (item) {
        return '<div class="cat-personal-glossary-item">' +
          '<div><strong>' + esc(item.source) + '</strong> → ' + esc(item.target) +
          '<span class="cat-personal-glossary-origin">' + esc(item.origin_file_name || '') + (item.origin_location ? '・' + esc(item.origin_location) : '') + '</span></div>' +
          '<button type="button" class="secondary-button" data-cat-personal-remove="' + esc(item.term_id) + '" data-cat-personal-source="' + esc(item.source) + '" data-cat-personal-target="' + esc(item.target) + '">この登録を取り消す</button>' +
          '</div>';
      }).join('');
    }).catch(function (error) { box.innerHTML = '<p class="alert-inline">登録した訳を読み込めませんでした。' + esc(error.message) + '</p>'; });
  }

  function removePersonalGlossary(button) {
    var source = button.getAttribute('data-cat-personal-source') || '';
    var target = button.getAttribute('data-cat-personal-target') || '';
    if (!window.confirm('この登録を取り消しますか？\n\n' + source + ' → ' + target + '\n\n今後の資料では自動で使われなくなります。\nすでに訳した文章はそのまま残ります。')) return Promise.resolve();
    setBusy(true); status('登録を取り消しています…');
    return post('personal-glossary-remove', { term_id: button.getAttribute('data-cat-personal-remove') || '' }, true, currentScope())
      .then(function (data) { setBusy(false); status((data && data.message) || '登録を取り消しました。'); return loadPersonalGlossary(); })
      .catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function openExportPreflight() {
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。');
      setBusy(true); status('出力条件を確認しています…'); return post('preflight', {}, true, requestScope);
    }).then(function (data) {
      setBusy(false);
      if (!scopeIsCurrent(requestScope, true) || !data || String(data.project_id || '') !== requestScope.id || Number(data.revision) !== requestScope.revision) throw new Error('表示中の作業が変わったため、出力前の確認を中止しました。');
      preflightScope = requestScope;
      var mode = String(data.mode || 'blocked'), blockers = Array.isArray(data.blockers) ? data.blockers : [], warnings = Array.isArray(data.warnings) ? data.warnings : [];
      if (data.eligible && blockers.length) { warnings = warnings.concat(blockers); blockers = []; }
      el('cat-export-mode').textContent = outputModeLabel(mode);
      el('cat-export-name').textContent = data.output_name ? ('出力名: ' + data.output_name) : '';
      /* 「確認済みの内容を出力できます」とは言えなくなった。未確認の行を含んだまま
         出せるので、残っている行数をそのまま出す（2026-08-12）。 */
      var unconfirmed = Number(data.unconfirmed_count || 0);
      /* 出す先はファイルとは限らない。訳文のコピーはクリップボードへ写すだけで、
         ファイルは作らない（2026-08-13、初回利用者として実機で確認）。 */
      var isCopy = mode === 'copy_text';
      var readyLine = !blockers.length
        ? (unconfirmed > 0
            ? ('<div class="cat-preflight-item is-ready">いまの訳文を' + (isCopy ? 'コピーできます。' : 'ファイルにできます。') + '</div>')
            : '<div class="cat-preflight-item is-ready">すべての行を確認し終えています。</div>')
        : '';
      el('cat-export-checks').innerHTML = blockers.map(function (item) { return '<div class="cat-preflight-item is-blocked">' + esc(item.message || item.code || (isCopy ? 'いまはコピーできません。上に出ている項目をご確認ください。' : 'いまはファイルを作れません。上に出ている項目をご確認ください。')) + '</div>'; }).join('') + warnings.map(function (item) { return '<div class="cat-preflight-item">' + esc(item.message || item.code || item) + '</div>'; }).join('') + readyLine;
      el('cat-export-notice').textContent = data.draft_notice || '原本はそのままで、訳文を入れたコピーを作ります。名前の先頭に「DRAFT_」が付きます。';
      el('cat-export-notice').hidden = mode === 'copy_text' || mode === 'blocked';
      /* 止まっているときは、どの行かを見に行けるようにする。「作れません」だけを
         出して行き先を示さないと、利用者は資料の中を目で探すことになる。 */
      el('cat-export-qa').hidden = !blockers.length;
      el('cat-export-confirm').disabled = !data.eligible || mode === 'blocked';
      el('cat-export-confirm').textContent = mode === 'copy_text' ? '訳文をコピー' : 'ファイルを作る';
      el('cat-export-final-review').checked = false; el('cat-export-final-reason').value = ''; el('cat-export-final-reason').disabled = true;
      var dialog = el('cat-export-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
    }).catch(function (error) { setBusy(false); preflightScope = null; status(error.message, true); });
  }

  /* 出す前に、資料ぜんぶの指摘を1枚で見る（市販CATの検証パネルに相当）。
     memoQ も Trados も、書き出し前にこの一覧から行へ飛んで直す。当アプリは
     行ごとの指摘と絞り込みは持っていたが、「あと何件残っているか」を出す前に
     見る場所が無かった。数えるのは画面が持っている行そのもので、
     出力を止める条件（訳文が空・数字の点検）と同じ2つを先に並べる。 */
  /* まだ一度も訳していない状態（作業を作った直後）を、指摘として数えない。
     数えていたころは、押した直後の画面に赤い「点検 2」が出て、開くと
     「ファイルを作れない指摘が 2 件あります／訳文が空 2」と出ていた。
     利用者は何もしていない。次に押すのは訳すボタンだ、と言うべき場面で、
     欠陥の言い方をしていた（2026-08-13、初回利用者として実機で確認）。
     同じ画面の取り出しボタンは、最初から「先に訳してください」と
     正しく言っていたので、言い方はそちらに合わせる。
     1行でも訳ができていれば、空の行は本物の指摘に戻る。 */
  function nothingTranslatedYet() {
    var all = (project && project.segments) || [];
    if (!all.length) return false;
    return all.every(function (segment) { return !String(segment.translation || '').trim(); });
  }
  /* 出力を止めない警告は、止める指摘と同じ群へ入れない。同じ群に入れると
     見出しの数字が「ファイルを作れない指摘」の件数として読まれ、押せるはずの
     書き出しが押せないように見える。群は意味ごとに分け、添字ではなく key で
     引く。warning を後から足しても未確認数や出力前要約がすり替わらない。 */
  function qaFindings() {
    var all = (project && project.segments) || [], groups = [
      { key: 'empty', title: '訳文が空', blocking: true, items: [] },
      /* 「数字の点検」ではない。ここへ来る指摘は18種あり、通貨・見出しの形・
         用語もその中に居る（2026-08-15）。名前が「数字」だと、用語で止まった
         人が数字を見に行く。書き出しの窓が言う理由と同じ顔ぶれにする。 */
      { key: 'qc', title: '自動点検の指摘', blocking: true, items: [] },
      { key: 'unconfirmed', title: '未確認', blocking: false, items: [] },
      { key: 'numeric-warning', title: '数字・単位の確認', blocking: false, items: [] },
      { key: 'label-warning', title: '用語集に無い短いラベル', blocking: false, items: [] },
      { key: 'delimiter-warning', title: '括弧・引用符の対応', blocking: false, items: [] },
      /* 正本へ warning が増えたのに専用群をまだ足していない場合も、warning を
         blocker 群へ落とさない。専用群を追加するまでの安全な受け皿である。 */
      { key: 'warning', title: '書き出しを止めない確認事項', blocking: false, items: [] }
    ];
    if (nothingTranslatedYet()) return groups;
    all.forEach(function (segment) {
      /* 群を種別で分けるので、文言だけでなく種別も要る。qcMessages は
         qcFindingViews と同じ並びを返すので、添字で対にできる。 */
      var views = qcFindingViews(segment), messages = qcMessages(segment);
      var empty = !String(segment.translation || '').trim();
      var emptyGroup = qaGroupByKey(groups, 'empty'), qcGroupItems = qaGroupByKey(groups, 'qc'), unconfirmedGroup = qaGroupByKey(groups, 'unconfirmed');
      if (empty) emptyGroup.items.push({ index: Number(segment.index), source: segment.source, message: '' });
      views.forEach(function (view, viewIndex) {
        var message = String(messages[viewIndex] || '');
        var nonBlocking = qcFindingSeverity(view) !== 'error';
        var target = nonBlocking ? qaGroupByKey(groups, qcWarningGroupKey(view.code)) : qcGroupItems;
        if (!target) target = qcGroupItems;
        if (target === qcGroupItems) {
          if (empty && message.indexOf('訳文が空') >= 0) return;
          if (empty && /空/.test(message)) return;
        }
        target.items.push({ index: Number(segment.index), source: segment.source, message: message });
      });
      if (!segment.confirmed && !empty) unconfirmedGroup.items.push({ index: Number(segment.index), source: segment.source, message: '' });
    });
    return groups;
  }
  var sourceUpdateJob = '', sourceUpdatePlan = null;

  function sourceUpdateKindLabel(kind) {
    return ({ unchanged: 'そのまま再利用', moved_unchanged: '移動（訳を再利用）', numeric_changed: '数字だけ更新', changed: '修正が必要', added: '新規', removed: '削除', split: '分割を確認', merged: '結合を確認', ambiguous: '対応先を確認' })[kind] || kind;
  }
  function showSourceUpdatePlan(plan) {
    sourceUpdatePlan = plan;
    var rows = plan.rows || [], blocking = rows.filter(function (row) { return !!row.blocking; }).length;
    var summary = plan.summary || {};
    el('cat-source-update-summary').textContent = 'そのまま再利用 ' + Number(summary.unchanged || 0) + '件、移動 ' + Number(summary.moved_unchanged || 0) + '件、数字だけ更新 ' + Number(summary.numeric_changed || 0) + '件、確認が必要 ' + blocking + '件、新規 ' + Number(summary.added || 0) + '件。';
    el('cat-source-update-list').innerHTML = rows.map(function (row) {
      var decision='';
      if(row.blocking){
        if(row.kind==='changed') decision='<label>扱い<select data-rebase-action data-mapping-id="'+esc(row.mapping_id)+'"><option value="preserve_as_candidate">現在の訳文を参考候補として残す</option><option value="retranslate">訳文を空にして再翻訳する</option></select></label>';
        else if(row.kind==='removed') decision='<label><input type="checkbox" data-rebase-action data-mapping-id="'+esc(row.mapping_id)+'" value="confirm_removed">新版では削除されたことを確認しました</label>';
        else if(row.kind==='split'||row.kind==='merged') decision='<label><input type="checkbox" data-rebase-action data-mapping-id="'+esc(row.mapping_id)+'" value="accept_structure_untranslated">新しい分割・結合を未訳として採用します</label>';
        else if(row.kind==='ambiguous') decision='<label>対応先<select data-rebase-action data-mapping-id="'+esc(row.mapping_id)+'"><option value="">選択してください</option>'+(row.targets||[]).map(function(target){return '<option value="select_target:'+Number(target.target_index)+'">'+esc(target.text||('候補 '+target.target_index))+'</option>';}).join('')+'</select></label>';
      }
      return '<section class="cat-source-update-row' + (row.blocking ? ' is-blocking' : '') + '"><h3>' + esc(sourceUpdateKindLabel(row.kind)) + (row.message ? ' — ' + esc(row.message) : '') + '</h3>' +
        '<p><span class="cat-source-update-label">旧原文</span>' + esc(row.old_source || '—') + '</p>' +
        '<p><span class="cat-source-update-label">現在の訳文</span>' + esc(row.current_translation || '—') + '</p>' +
        '<p><span class="cat-source-update-label">新原文</span>' + esc(row.new_source || '—') + '</p>'+(decision?'<div class="cat-source-update-decision">'+decision+'</div>':'')+'</section>';
    }).join('');
    el('cat-source-update-apply').disabled = false;
    el('cat-source-update-apply').title = blocking > 0 ? '赤枠の変更について扱いを選んでから採用します。' : '';
    el('cat-source-update-dialog').showModal();
  }
  function pollSourceUpdate(jobId) {
    return YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (String(jobId) !== sourceUpdateJob) return;
      if (data.mode === 'done' || data.mode === 'completed_with_warnings') {
        if (data.application_status !== 'current') throw new Error('確認中に作業内容が変わりました。新版を選び直してください。');
        return post('source-update-plan', { rebase_id: data.result_id }, false).then(showSourceUpdatePlan);
      }
      if (['error','failed','interrupted','cancelled'].indexOf(data.mode) >= 0) throw new Error(data.detail || '新版との比較に失敗しました。');
      status((data.label || '原文ファイルの変更を調べています') + ' ' + Math.max(0,Number(data.progress || 0)) + '%');
      window.setTimeout(function () { pollSourceUpdate(jobId).catch(function (error) { status(error.message,true); }); },900);
    });
  }
  function startSourceUpdate(file) {
    if (!project || project.source !== 'file') { status('ファイルから始めた作業で利用できます。',true); return; }
    if (!file) return;
    setBusy(true); status('新版を安全に取り込んでいます…');
    return flush().then(function () { return YakuCommon.upload('/api/upload',file); }).then(function (uploadedFile) {
      return post('source-update-preview',{file_handle:uploadedFile.file_handle},true);
    }).then(function (data) {
      sourceUpdateJob=String(data.job_id||''); if(!sourceUpdateJob) throw new Error('新版との比較を開始できませんでした。');
      setBusy(false); return pollSourceUpdate(sourceUpdateJob);
    }).catch(function (error) { setBusy(false); status(error.message,true); });
  }
  function applySourceUpdate() {
    if (!sourceUpdatePlan || !project) return;
    var button=el('cat-source-update-apply');button.disabled=true;
    var decisions=[];Array.prototype.forEach.call(el('cat-source-update-list').querySelectorAll('[data-rebase-action]'),function(control){
      var raw=control.type==='checkbox'?(control.checked?control.value:''):control.value;if(!raw)return;
      var parts=String(raw).split(':');decisions.push({mapping_id:control.getAttribute('data-mapping-id'),action:parts[0],target_index:parts.length>1?Number(parts[1]):-1,reason:'新版採用時に画面で確認'});
    });
    var blocking=(sourceUpdatePlan.rows||[]).filter(function(row){return !!row.blocking;}).length;
    if(decisions.length!==blocking){el('cat-source-update-summary').textContent='赤枠の変更すべてについて扱いを選んでください。';button.disabled=false;return;}
    var resolutionPromise=blocking?post('source-update-decision',{rebase_id:sourceUpdatePlan.rebase_id,plan_hash:sourceUpdatePlan.plan_hash,decisions:decisions},true):Promise.resolve({resolution_id:'',resolution_hash:''});
    return resolutionPromise.then(function(resolution){return post('source-update-apply',{
      rebase_id:sourceUpdatePlan.rebase_id,plan_hash:sourceUpdatePlan.plan_hash,resolution_id:resolution.resolution_id||'',resolution_hash:resolution.resolution_hash||'',
      base_source_id:sourceUpdatePlan.base_source_id,base_source_hash:sourceUpdatePlan.base_source_hash||project.source_artifact_sha256,target_source_id:sourceUpdatePlan.target_source_id,target_source_hash:sourceUpdatePlan.target_source_hash,base_project_revision:sourceUpdatePlan.base_project_revision
    },true);}).then(function(data){sourceUpdatePlan=null;el('cat-source-update-dialog').close();render(data,false);status('原文ファイルを差し替えました。変更された行だけ確認してください。');})
      .catch(function(error){el('cat-source-update-summary').textContent=error.message;button.disabled=false;});
  }
  /* 資料の切り替え。市販ツール（Crowdin の畳めるファイル一覧、memoQ の資料タブ、
     Phrase のブラウザタブ）はどれも作業画面に居たまま切り替える。ここもそれに倣い、
     一覧画面へ戻らずに入れ替える。開いている資料には印を付け、押しても何も起きない
     ことが分かるようにする。 */
  function renderDocsPane() {
    var list = el('cat-docs-pane-list');
    if (!list) return;
    var currentId = project ? String(project.id || '') : '';
    if (!resumeItems.length) { list.innerHTML = '<p class="muted">まだありません。</p>'; return; }
    list.innerHTML = resumeItems.map(function (item) {
      var isCurrent = String(item.id) === currentId;
      var name = documentDisplayName(item), meta = documentMeta(item, isCurrent).map(esc);
      return '<button type="button" class="cat-docs-pane-item' + (isCurrent ? ' is-current' : '') + '"' +
        (isCurrent ? ' aria-current="true" disabled' : '') +
        ' data-cat-doc-open="' + esc(item.id) + '" title="' + esc(name) + '">' +
        '<span class="cat-docs-pane-name">' + esc(name) + '</span>' +
        /* 同じ資料を2回取り込むと、名前も残り行数も同じ行が並ぶ。左欄でも時刻で
           見分けられるようにする（実測 2026-08-13: spec.docx が2件、ManualBuilder が
           2件、01_A4_format が2件並んでいた）。 */
        '<span class="cat-docs-pane-meta">' + meta.join('・') + '</span></button>';
    }).join('');
  }
  /* 開くかどうか。既定は閉じる。広い窓でも表を常に縮めず、必要なときだけ
     利用者が開く。明示した open 状態は CSS の重なり欄として尊重する。 */
  var DOCS_PANE_MIN_WIDTH = 1700;
  function applyDocsPane(open, fromUser) {
    var layout = el('cat-editor-layout'), toggle = el('cat-docs-toggle');
    if (!layout || !toggle) return;
    layout.classList.toggle('is-docs-open', open);
    toggle.setAttribute('aria-expanded', String(open));
    toggle.textContent = open ? '資料一覧を隠す' : '資料一覧';
    if (open) {
      renderDocsPane();
      /* 開いた時点で一覧を持っていなければ取りに行く（作業画面から直接開いた場合）。 */
      if (!resumeItems.length) loadRecent();
    }
    /* 覚えるのは、利用者が自分で開閉したときだけ。窓幅による自動の開閉を覚えると、
       一度狭い窓で見ただけで、以後ずっと閉じたままになる。 */
    if (fromUser) { try { window.localStorage.setItem('yaku-cat-docs-open', open ? '1' : '0'); } catch (_) {} }
  }
  /* 狭い窓では、覚えていても開かない。開くと原文・訳文が 2026-08-12 に
     却下された幅（1列 321px）を下回るため。 */
  function applyDocsPaneDefault() {
    var stored = null;
    try { stored = window.localStorage.getItem('yaku-cat-docs-open'); } catch (_) {}
    /* 既定で資料欄を出すと、1912pxでも表の主役へ恒常的な列を割り当てる。
       DOCS_PANE_MIN_WIDTH は狭い窓での既存判断を読みやすく残すための定数だが、
       広い窓の既定値は必ず閉じる。保存した明示的な open だけを通す。 */
    var roomy = false;
    if (stored === '1') { applyDocsPane(true); return; }
    if (stored === '0') { applyDocsPane(false); return; }
    applyDocsPane(roomy);
  }
  function initDocsPane() {
    applyDocsPaneDefault();
    /* 窓の大きさは、起動したあとに変わる。資料翻訳へ入ると外枠が窓を広げるので
       （実測 2026-08-13: ホーム 1240px -> 資料翻訳 1760px）、起動時の1回だけで
       決めると、広い窓なのに一覧が閉じたままになる。変わったら決め直す。 */
    var resizeTimer = null;
    window.addEventListener('resize', function () {
      if (resizeTimer) window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(applyDocsPaneDefault, 150);
    });
  }
  /* The compact workspace still updates this title dynamically.  These
     constants were accidentally dropped when the duplicated legacy workspace
     was removed, leaving the entire CAT bootstrap to fail before rendering. */
  var QA_BUTTON_TITLE_DEFAULT = '数字・単位・用語などの自動点検の結果です。押すと一覧を表示します（F8）';
  var QA_BUTTON_TITLE_EMPTY = '訳文が空の行の数です。押すと一覧を表示します（F8）';
  var QA_BUTTON_TITLE_BLOCKING = '書き出しを止める指摘のある行の数です。押すと一覧を表示します（F8）';
  function updateQaButton() {
    var button = el('cat-qa-open');
    if (!button) return;
    button.disabled = !project;
    if (!project) { button.textContent = '点検結果'; button.title = QA_BUTTON_TITLE_DEFAULT; return; }
    var groups = qaFindings();
    /* 群を添字で足さない。止めない群を足したときに、道具の帯の数字だけが
       「ファイルを作れない指摘」を水増しする（2026-08-16）。blocking の印は
       群そのものが持っているので、そこから数える。いまの3群では同じ数になる。 */
    var blockingGroups = groups.filter(function (group) { return group.blocking; });
    var blocking = blockingGroups.reduce(function (sum, group) { return sum + group.items.length; }, 0);
    /* ツールバーは資料全体で書き出しを止めている行の数。内訳が「訳文が空」
       （key 'empty'）だけなら、止めている理由は未訳そのものなので「未訳」と
       言う。ほかの理由（用語・数値など）が1件でも混じれば「書き出しを止める行」
       と言う。下部タブ（この行の点検）は選択中1行の指摘数で、こちらとは別物。 */
    var onlyEmpty = blocking > 0 && blockingGroups.every(function (group) { return group.key === 'empty' || !group.items.length; });
    var label = onlyEmpty ? '未訳' : '書き出しを止める行';
    button.textContent = blocking ? (label + ' ' + blocking) : '点検結果';
    button.title = !blocking ? QA_BUTTON_TITLE_DEFAULT : (onlyEmpty ? QA_BUTTON_TITLE_EMPTY : QA_BUTTON_TITLE_BLOCKING);
    button.classList.toggle('cat-qa-has-blockers', blocking > 0);
  }
  function openQaList() {
    if (!project) { status('資料が開かれていません。'); return; }
    var groups = qaFindings();
    var blocking = groups.filter(function (group) { return group.blocking; }).reduce(function (sum, group) { return sum + group.items.length; }, 0);
    var unconfirmedGroup = qaGroupByKey(groups, 'unconfirmed'), numericWarningGroup = qaGroupByKey(groups, 'numeric-warning'), labelWarningGroup = qaGroupByKey(groups, 'label-warning'), delimiterWarningGroup = qaGroupByKey(groups, 'delimiter-warning'), genericWarningGroup = qaGroupByKey(groups, 'warning');
    var unconfirmed = unconfirmedGroup ? unconfirmedGroup.items.length : 0;
    /* 止めない警告は、要約でも「止める指摘」と混ぜない。かといって黙らせない。
       警告が0件のときの文言は1文字も変えないので、「調べたが直すところは無かった」
       を見る表明（Test-YakuV9176CatScreenWiring の (k)）はそのまま生きる。 */
    var numericWarnings = numericWarningGroup ? numericWarningGroup.items.length : 0;
    var labelWarnings = labelWarningGroup ? labelWarningGroup.items.length : 0;
    var delimiterWarnings = delimiterWarningGroup ? delimiterWarningGroup.items.length : 0;
    var genericWarnings = genericWarningGroup ? genericWarningGroup.items.length : 0;
    var warned = numericWarnings + labelWarnings + delimiterWarnings + genericWarnings;
    var warnNote = (numericWarnings ? ('数字・単位を確認する行が ' + numericWarnings + ' 行あります。書き出しは止まりません。') : '') +
      (labelWarnings ? ('用語集に無い短いラベルが ' + labelWarnings + ' 行あります。書き出しは止まりません。') : '') +
      (delimiterWarnings ? ('括弧・引用符の対応を確認する行が ' + delimiterWarnings + ' 行あります。書き出しは止まりません。') : '') +
      (genericWarnings ? ('書き出しを止めない確認事項が ' + genericWarnings + ' 行あります。書き出しは止まりません。') : '');
    el('cat-qa-summary').textContent = nothingTranslatedYet()
      ? 'まだ訳していません。「Copilotで未訳を翻訳」を押すと、Copilotへ送ります。'
      : blocking
      ? ('ファイルを作れない指摘が ' + blocking + ' 件あります。' + (unconfirmed ? '未確認は ' + unconfirmed + ' 行です。' : '') + warnNote)
      : warned
      ? ((unconfirmed ? ('未確認は ' + unconfirmed + ' 行です。') : '') + 'ファイルを作れない指摘はありません。' + warnNote)
      /* かつてここは「点検は確認済みにするときに行う」と書いていたが、それは
         事実でなくなった。未確認の行にも点検は走っており（サーバが写しに掛けて
         いる）、その結果はこの一覧に出ている。出ていないのは、まだ調べていない
         からではなく、調べて通ったからである（2026-08-15 に文言を実装へ
         合わせた。CLAUDE.md「食い違ったら実装を採る」）。 */
      : (unconfirmed ? ('未確認は ' + unconfirmed + ' 行です。自動点検では、直すところは見つかりませんでした。') : '指摘はありません。すべての行を確認し終えています。');
    el('cat-qa-list').innerHTML = groups.filter(function (group) { return group.items.length; }).map(function (group) {
      return '<section class="cat-qa-group' + (group.blocking ? ' is-blocking' : '') + '"><h3>' + esc(group.title) + ' <span>' + group.items.length + '</span></h3>' +
        group.items.map(function (item) {
          return '<button type="button" class="cat-qa-item" data-cat-qa-jump="' + item.index + '">' +
            '<span class="cat-qa-row">' + (item.index + 1) + '行目</span>' +
            '<span class="cat-qa-source">' + esc(String(item.source || '').slice(0, 40)) + '</span>' +
            (item.message ? '<span class="cat-qa-message">' + esc(item.message) + '</span>' : '') + '</button>';
        }).join('') + '</section>';
    }).join('') || (nothingTranslatedYet()
      ? '<p class="muted">訳ができたら、ここに直すところが並びます。</p>'
      : '<p class="muted">直すところは見つかりませんでした。</p>');
    var dialog = el('cat-qa-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
    loadDocumentFindings();
  }
  function segmentIndexById(segmentId) {
    var found = (project && project.segments || []).find(function (segment) { return String(segment.segment_id || '') === String(segmentId || ''); });
    return found ? Number(found.index) : -1;
  }
  var pendingDocumentCoverage = {};
  var reviewLensLabels = {
    bilingual_block: '原文と訳文の対応', names_terms_abbreviations: '固有名詞・用語・略語',
    structure_notes: '見出し・注記・構造', gap: '見落とし確認',
    translation_consistency: '訳し方の一貫性',
    rendered_output_completeness: 'PDFへの掲載'
  };
  function renderReviewLenses(runs) {
    var host = el('cat-document-review-lenses');
    pendingDocumentCoverage = {};
    if (!runs || !runs.length) { host.innerHTML = ''; return; }
    var groups = {};
    runs.forEach(function (run) { (run.coverage_items || []).forEach(function (item) {
      var key = String(run.review_run_id || '') + '|' + String(item.scope || '') + '|' + String(item.lens || '');
      (groups[key] = groups[key] || { run: run, items: [] }).items.push(item);
    });
    });
    host.innerHTML = Object.keys(groups).sort().map(function (key) {
      var run = groups[key].run, items = groups[key].items, lens = String(items[0].lens || ''), label = lens === 'target_document_consistency' ? (project && project.direction === 'to_jp' ? '日本語訳文としての整合性' : '英語訳文としての整合性') : (reviewLensLabels[lens] || lens || '確認範囲');
      if (String(run.detector || '') === 'deterministic') label += '（機械比較）'; else if (String(run.detector || '') === 'copilot') label += '（Copilot）';
      var unresolved = items.filter(function (item) { return ['unreadable','unmapped','skipped'].indexOf(String(item.state || '')) >= 0 && !item.human_decision_current; });
      var findings = items.reduce(function (sum, item) { return sum + (String(item.state || '') === 'finding' ? 1 : 0); }, 0);
      var checked = items.reduce(function (sum, item) { return sum + (String(item.state || '') === 'checked' ? 1 : 0); }, 0);
      var state = unresolved.length ? '自動確認できない範囲 ' + unresolved.length + '件' : (findings ? '確認事項 ' + findings + '件' : '確認完了');
      var button = '';
      if (unresolved.length) {
        pendingDocumentCoverage[key] = { runId: run.review_run_id, ids: unresolved.map(function (item) { return item.coverage_item_id; }), label: label };
        button = '<button type="button" class="secondary-button compact" data-cat-coverage-key="' + esc(key) + '">この範囲を自分で確認した</button>';
      }
      var targetCount = Object.keys(items.reduce(function (set, item) { (item.target_ids || []).forEach(function (id) { set[String(id)] = true; }); return set; }, {})).length;
      var targetLabel = items.some(function (item) { return String(item.target_kind || '') === 'whole_document_cross_group'; }) ? '文書全体 ' + targetCount + '行' : '対象 ' + targetCount + '件';
      return '<section class="cat-review-lens"><div><strong>' + esc(label) + '</strong><span>' + esc(state) + '</span></div><p class="muted">' + esc(targetLabel) + '／自動照合 ' + checked + '件</p>' + button + '</section>';
    }).join('');
  }
  function renderDocumentFindings(data) {
    var findings = (data && data.findings || []).filter(function (finding) { return finding.current !== false && String(finding.status || '') !== 'stale'; });
    var runs = data && data.review_runs || [];
    var latestByDetector = {};
    runs.forEach(function (run) { latestByDetector[String(run.detector || 'other')] = run; });
    var selectedRuns = Object.keys(latestByDetector).map(function (key) { return latestByDetector[key]; });
    var complete = selectedRuns.length && selectedRuns.every(function (run) { return run.coverage_summary && run.coverage_summary.evidence_complete; });
    el('cat-document-review-status').textContent = !selectedRuns.length
      ? 'まだ文書全体の確認をしていません。'
      : (complete ? '下の観点ごとに対象範囲の確認が完了しました。' : '下の観点に、自動で確認できない範囲があります。');
    renderReviewLenses(selectedRuns);
    el('cat-document-findings').innerHTML = findings.length ? findings.map(function (finding) {
      var evidence = finding.evidence_locations || [];
      var target = evidence.find(function (location) { return String(location.side) === 'target'; }) || evidence[0] || {};
      var index = segmentIndexById(target.segment_id);
      var statusName = { open: '未処理', fixed_pending_verify: '修正後の再確認待ち', resolved: '解決済み', false_positive: '指摘は当てはまらない', accepted_risk: 'このまま使用', deferred: '後で確認' }[String(finding.status)] || String(finding.status || '');
      var actions = String(finding.status) === 'open'
        ? '<div class="cat-document-finding-actions">' + (index >= 0 ? '<button type="button" class="secondary-button compact" data-cat-doc-finding-jump="' + index + '">該当行を見る</button>' : '') +
          '<button type="button" class="secondary-button compact" data-cat-doc-finding-decision="false_positive" data-finding-id="' + esc(finding.finding_id) + '" data-finding-revision="' + Number(finding.finding_revision) + '">この指摘は当てはまらない</button>' +
          '<button type="button" class="secondary-button compact" data-cat-doc-finding-decision="accepted_risk" data-finding-id="' + esc(finding.finding_id) + '" data-finding-revision="' + Number(finding.finding_revision) + '">このまま使用</button></div>' : '';
      return '<article class="cat-document-finding"><div><strong>' + esc(finding.title || '確認事項') + '</strong><span class="cat-document-finding-status">' + esc(statusName) + '</span></div><p>' + esc(finding.message || '') + '</p>' + actions + '</article>';
    }).join('') : (selectedRuns.length ? '<p class="muted">文書全体の確認事項は見つかりませんでした。</p>' : '');
  }
  function loadDocumentFindings() {
    if (!project) return Promise.resolve();
    el('cat-document-review-status').textContent = '文書全体の確認結果を読み込んでいます…';
    return post('findings', {}, false).then(renderDocumentFindings).catch(function (error) { el('cat-document-review-status').textContent = error.message; });
  }
  function downloadQaReport() {
    if(!project)return Promise.resolve();var button=el('cat-qa-report-download');button.disabled=true;
    return post('qa-report',{},false).then(function(report){
      var blob=new Blob([JSON.stringify(report,null,2)],{type:'application/json'}),url=URL.createObjectURL(blob),link=document.createElement('a');
      var base=String(project.file_name||'YakuLingo').replace(/\.[^.]+$/,'').replace(/[\\/:*?"<>|]+/g,'_');
      link.href=url;link.download=base+'_QA-report.json';document.body.appendChild(link);link.click();link.remove();window.setTimeout(function(){URL.revokeObjectURL(url);},0);
      status('QAレポートを保存しました。対象revision、確認範囲、指摘、人の判断を含みます。');
    }).catch(function(error){status(error.message,true);}).finally(function(){button.disabled=false;});
  }
  function runDocumentReview() {
    if (!project || busy) return Promise.resolve();
    el('cat-document-review-run').disabled = true; el('cat-document-review-status').textContent = '文書全体を比較しています…';
    return flush().then(function () { return post('review-start', {}, true); }).then(function (data) {
      project.revision = Number(data.revision); renderDocumentFindings({ findings: data.findings || [], review_runs: [data.review_run] });
      status((data.findings || []).length ? '文書全体の確認事項を表示しました。内容を見て判断してください。' : '文書全体の機械的な比較が完了しました。');
    }).catch(function (error) { el('cat-document-review-status').textContent = error.message; status(error.message, true); }).finally(function () { el('cat-document-review-run').disabled = false; });
  }
  var copilotReviewJob = '';
  function pollCopilotDocumentReview(jobId) {
    return YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (String(jobId) !== copilotReviewJob) return;
      if (data.mode === 'done' || data.mode === 'completed_with_warnings') {
        if (data.application_status !== 'current') throw new Error('確認中に訳文が変わりました。もう一度Copilot確認を実行してください。');
        el('cat-document-review-status').textContent = '確認結果を現在の作業へ照合しています…';
        return post('copilot-review-apply', { job_id: jobId }, true).then(function (applied) {
          project.revision = Number(applied.revision); renderDocumentFindings({ findings: applied.findings || [], review_runs: [applied.review_run] });
          var summary = applied.review_run && applied.review_run.coverage_summary || {};
          status(summary.evidence_complete ? 'Copilotの確認事項を表示しました。採用するかは内容を見て判断してください。' : 'Copilotが確認できなかった範囲があります。確認事項と対象範囲を見てください。');
          el('cat-copilot-review-run').disabled = false;
        });
      }
      if (['error','failed','interrupted','cancelled'].indexOf(data.mode) >= 0) throw new Error(data.detail || 'Copilotによる文書確認を完了できませんでした。');
      el('cat-document-review-status').textContent = (data.label || 'Copilotで確認しています') + ' ' + Math.max(0, Number(data.progress || 0)) + '%';
      window.setTimeout(function () { pollCopilotDocumentReview(jobId).catch(finishCopilotReviewError); }, 900);
    });
  }
  function finishCopilotReviewError(error) { el('cat-copilot-review-run').disabled = false; el('cat-document-review-status').textContent = error.message; status(error.message, true); }
  function previewCopilotDocumentReview() {
    if (!project || busy) return Promise.resolve();
    var button=el('cat-copilot-review-preview');button.disabled=true;el('cat-document-review-status').textContent='保護済みの送信内容を作っています…';
    return flush().then(function(){return post('copilot-review-preview',{},false);}).then(function(data){
      el('cat-copilot-review-preview-summary').textContent=String(data.disclosure||'')+' 表示: '+Number(data.shown_segments||0)+' / '+Number(data.total_segments||0)+'行、数値placeholder '+Number(data.masked_value_count||0)+'件。';
      el('cat-copilot-review-preview-text').textContent=String(data.protected_prompt||'');
      el('cat-copilot-review-preview-dialog').showModal();el('cat-document-review-status').textContent='送信内容を表示しました。確認後にCopilot校正を開始してください。';
    }).catch(function(error){el('cat-document-review-status').textContent=error.message;status(error.message,true);}).finally(function(){button.disabled=false;});
  }
  function runCopilotDocumentReview() {
    if (!project || busy) return Promise.resolve();
    var button = el('cat-copilot-review-run'); button.disabled = true; el('cat-document-review-status').textContent = 'Copilot確認を準備しています…';
    return flush().then(function () { return post('copilot-review-start', {}, true); }).then(function (data) {
      copilotReviewJob = String(data.job_id || ''); if (!copilotReviewJob) throw new Error('Copilot確認を開始できませんでした。');
      return pollCopilotDocumentReview(copilotReviewJob);
    }).catch(finishCopilotReviewError);
  }
  function decideDocumentFinding(button) {
    var action = button.getAttribute('data-cat-doc-finding-decision');
    var explanation = window.prompt(action === 'false_positive' ? 'この指摘が当てはまらない理由を入力してください。' : '問題を認識したうえで、このまま使用する理由を入力してください。', '');
    if (explanation === null) return Promise.resolve();
    if (!String(explanation).trim()) { status('理由を入力してください。', true); return Promise.resolve(); }
    button.disabled = true;
    return post('finding-decision', {
      finding_id: button.getAttribute('data-finding-id'), finding_revision: Number(button.getAttribute('data-finding-revision')),
      decision_action: action, reason_code: action === 'false_positive' ? 'not_applicable' : 'user_accepted', note: String(explanation).trim()
    }, true).then(function (data) { project.revision = Number(data.revision); return loadDocumentFindings(); }).catch(function (error) { status(error.message, true); }).finally(function () { button.disabled = false; });
  }
  function acceptDocumentCoverage(key, button) {
    var pending = pendingDocumentCoverage[String(key || '')];
    if (!pending) return Promise.resolve();
    var note = window.prompt('「' + pending.label + '」で自動確認できなかった範囲を、どのように確認したか入力してください。', '原文と訳文を画面で読み比べた');
    if (!String(note || '').trim()) return Promise.resolve();
    button.disabled = true;
    return post('coverage-decision', { review_run_id: pending.runId, coverage_item_ids: pending.ids, note: String(note).trim() }, true).then(function (data) { project.revision = Number(data.revision); return loadDocumentFindings(); }).catch(function (error) { status(error.message, true); }).finally(function () { button.disabled = false; });
  }
  function jumpFromQa(index) {
    var dialog = el('cat-qa-dialog'); if (dialog.open) dialog.close('cancel');
    var exportDialog = el('cat-export-dialog'); if (exportDialog.open) exportDialog.close('cancel');
    /* 飛んだ先が絞り込みで隠れていては直せない。表示を「すべて」に戻す。 */
    currentFilter = 'all'; currentLocation = 'all'; currentChange = 'all';
    return redrawAfterFlush().then(function () { return activateIndex(Number(index), true); });
  }

  function goToNextQc() {
    if (!project) return Promise.resolve();
    var all = project.segments || [], after = all.find(function (segment) { return Number(segment.index) > Number(activeIndex) && segmentHasQc(segment); });
    var target = after || all.find(segmentHasQc);
    if (!target) { status('数字と単位の自動点検では、気になる点は見つかりませんでした。'); return Promise.resolve(); }
    currentFilter = 'qc'; currentLocation = 'all';
    return activateIndex(Number(target.index), true);
  }

  /* ツールバーの高さは、画面幅・文字サイズ・ボタンの折り返しで変わる。
     CSSの固定値では必ずどこかでずれ、左右のペインと表の見出しがツールバーの下へ隠れる。
     実測した値をそのまま変数へ入れる。CSS側の値は、これが走る前の初期値として残す。 */
  function trackToolbarHeight() {
    var toolbar = el('cat-editor-toolbar');
    if (!toolbar) return;
    function apply() {
      if (getComputedStyle(toolbar).position !== 'sticky') {
        document.documentElement.style.removeProperty('--cat-toolbar-h');
        return;
      }
      var height = Math.round(toolbar.getBoundingClientRect().height);
      if (height > 0) document.documentElement.style.setProperty('--cat-toolbar-h', height + 'px');
    }
    apply();
    if (window.ResizeObserver) { try { new ResizeObserver(apply).observe(toolbar); } catch (_) {} }
    window.addEventListener('resize', apply);
    /* 窓幅や拡大率が変わると訳文の行数が変わる。伸ばし直さないと下が切れる
       （実測 249px の欄に 376px の中身が入っていた）。Ctrl+スクロールでの
       拡大も resize として届く。 */
    function regrow() { document.querySelectorAll('textarea[data-cat-input]').forEach(autoGrow); }
    window.addEventListener('resize', regrow);
  }

  function bindIf(id, eventName, handler) {
    var node = el(id);
    if (node) node.addEventListener(eventName, handler);
  }

  function bind() {
    trackToolbarHeight();
    /* 資料単位の管理は資料オーバーレイへ移す。トップ帯は翻訳・出力・点検と、
       選択行の短い操作だけを残す。IDは移動しても既存のイベント契約を保つ。 */
    var docsHead = document.querySelector('#cat-docs-pane .cat-docs-pane-head');
    if (docsHead) {
      ['cat-switch-project', 'cat-source-update-open', 'cat-danger-zone'].forEach(function (id) {
        var control = el(id); if (control) docsHead.appendChild(control);
      });
    }
    var tmButton = el('cat-tm-pretranslate');
    if (tmButton) {
      tmButton.textContent = '';
      tmButton.setAttribute('aria-label', '翻訳メモリから未訳を入力');
      tmButton.title = '翻訳メモリの完全一致を未訳の行へ先に入れます';
      tmButton.innerHTML = icon('i-translate') + '<span class="cat-segment-button-label">TMで下訳</span>';
      tmButton.classList.add('cat-segment-button');
    }
    var keyHelp = document.querySelector('.cat-key-help');
    if (keyHelp && !keyHelp.id) keyHelp.id = 'cat-key-help';
    if (keyHelp) {
      var helpSummary = keyHelp.querySelector(':scope > summary');
      if (helpSummary) {
        helpSummary.setAttribute('aria-label', 'キーボード操作');
        helpSummary.innerHTML = icon('i-help') + '<span class="cat-segment-button-label">キーボード操作</span>';
      }
    }
    appendStaticSegmentActions(el('cat-segment-actions'));
    /* 帯の操作。role="tablist" の作法どおり、左右の矢印でも移れるようにする。 */
    /* 資料の切り替え。左上の資料名と、折りたたみの中の項目の両方から同じ口を開く。
       以前の「ほかの資料に切り替える」は作業画面を畳んで一覧へ戻していた。 */
    bindIf('cat-doc-switch', 'click', function () { window.location.assign('/cat?view=work'); });
    /* 左の資料一覧。開閉と、その中からの切り替え。 */
    bindIf('cat-docs-toggle', 'click', function () {
      applyDocsPane(!el('cat-editor-layout').classList.contains('is-docs-open'), true);
    });
    bindIf('cat-docs-import', 'click', function () { window.location.assign('/cat'); });
    bindIf('cat-align-next-document', 'click', function () { window.location.assign('/cat'); });
    bindIf('cat-docs-pane-list', 'click', function (event) {
      var choice = event.target.closest ? event.target.closest('[data-cat-doc-open]') : null;
      if (!choice || choice.disabled) return;
      var id = choice.getAttribute('data-cat-doc-open');
      flush().then(function () { resume(id); }).catch(function (error) { status(error.message, true); });
    });
    /* URL から開始画面の状態を一度だけ適用する。開始画面同士の履歴移動は
       pickerを描き直すだけで、読み込み済みのrecent snapshotを再利用する。
       資料から開始画面へ出る場合だけ、従来どおり lease を閉じて一覧を更新する。 */
    function applyLocationFromUrl() {
      if (historyRestoreGuard) { historyRestoreGuard = false; rememberAppliedHistoryEntry(); return; }
      var historyTarget = readCatHistoryState();
      if (busy) {
        if (pendingHistoryResume && !sameHistoryEntry(historyTarget, pendingHistoryResume.targetEntry)) {
          cancelPendingHistoryResume();
        } else {
          restoreBusyHistory(); return;
        }
      }
      var params = new URLSearchParams(location.search);
      var wanted = params.get('project');
      if (wanted) {
        if (project && String(project.id || '') === wanted) {
          rememberAppliedHistoryEntry();
          return;
        }
        resumeFromHistory(wanted);
        return;
      }
      var startSurface = !project && document.body.getAttribute('data-cat-view') === 'start';
      var refreshRecent = !startSurface;
      if (params.get('import') === '1') { showPicker(true, false, refreshRecent); showStart('align'); return; }
      if (params.get('view') === 'work') { showPicker(false, true, refreshRecent); return; }
      showPicker(false, false, refreshRecent);
    }
    window.addEventListener('popstate', applyLocationFromUrl);
    /* 通常の終了では確認を出さない。画面が隠れる直前に打ちかけを保存し、
       翻訳中の終了確認だけはcommon.jsが担当する。 */
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden' && !busy) { try { flush(true); } catch (_) {} }
    });
    document.querySelectorAll('[data-cat-direction]').forEach(function (button) { button.addEventListener('click', function () { el('cat-direction-choice').hidden = true; if (pendingDirection) pendingDirection(button.getAttribute('data-cat-direction')); }); });
    /* 過去の日英資料の入口。PDF を読むには WebAssembly が要り、それは
       ?import=1 で開いた画面にしか許していない（普段の作業では CSP を
       'self' のままにするため）。押したらその画面へ移る。 */
    bindIf('cat-open-align-entry', 'click', function () {
      if (document.querySelector('meta[name="yaku-import"]') &&
          document.querySelector('meta[name="yaku-import"]').getAttribute('content') === '1') { showStart('align'); return; }
      if (window.YakuInstant && window.YakuInstant.preserveDraft) window.YakuInstant.preserveDraft();
      window.location.assign('/cat?import=1');
    });
    /* PDF を選んだら、この画面の中で解析して貼り付け欄へ入れる。
       ファイルそのものはサーバへ送らない。送るのは取り出した文だけ。 */
    function readPdfInto(input, side, label) {
      var file = input.files && input.files[0];
      if (!file) return;
      var selectionEpoch = ++alignReadEpoch[side]; alignReadEpoch.pair++; alignExcelHandles[side] = '';
      if (/\.(xlsx|xlsm)$/i.test(String(file.name || ''))) {
        var statusNode = el('cat-align-file-status');
        statusNode.hidden = false; statusNode.textContent = label + 'のExcelを読み込んでいます…';
        el('cat-align-ranges').hidden = true;
        YakuCommon.upload('/api/upload', file).then(function (data) {
          if (selectionEpoch !== alignReadEpoch[side]) return null;
          if (!data || !data.file_handle) throw new Error('Excelを受け付けられませんでした。');
          alignExcelHandles[side] = String(data.file_handle);
          el('cat-align-' + side + '-file-name').textContent = file.name;
          if (!el('cat-align-name').value.trim()) el('cat-align-name').value = file.name.replace(/\.(xlsx|xlsm)$/i, '');
          if (!alignExcelHandles.source || !alignExcelHandles.target) {
            statusNode.textContent = 'もう一方のExcelファイルを選んでください。'; updateAlignEstimate(); return null;
          }
          statusNode.textContent = '2つのExcelから対訳候補を抽出しています…';
          var pairEpoch = ++alignReadEpoch.pair, sourceHandle = alignExcelHandles.source, targetHandle = alignExcelHandles.target;
          return YakuCommon.post('/api/cat/align-files', { source_file_handle:sourceHandle, target_file_handle:targetHandle }).then(function (result) { return { result: result, pairEpoch: pairEpoch, sourceHandle: sourceHandle, targetHandle: targetHandle }; });
        }).then(function (data) {
          if (!data || data.pairEpoch !== alignReadEpoch.pair || data.sourceHandle !== alignExcelHandles.source || data.targetHandle !== alignExcelHandles.target) return;
          data = data.result;
          el('cat-align-source').value = String(data.source_text || '');
          el('cat-align-target').value = String(data.target_text || '');
          statusNode.textContent = '日本語 ' + Number(data.source_count || 0) + '件 / 英語 ' + Number(data.target_count || 0) + '件を取得しました。';
          updateAlignEstimate();
        }).catch(function (error) {
          if (selectionEpoch !== alignReadEpoch[side]) return;
          alignExcelHandles[side] = '';
          statusNode.textContent = label + 'を読めませんでした。' + (error && error.message ? error.message : '');
          updateAlignEstimate();
        });
        return;
      }
      /* 選んだファイル名は、押した直後にボタンの下へ日本語で出す。素の
         <input type="file"> は既定のボタン文言が英語（Choose File）のことが
         あり、選んだあとの状態も画面のどこにも出ていなかった（2026-08-18）。 */
      var nameLabel = el('cat-align-' + side + '-file-name');
      if (nameLabel) nameLabel.textContent = file.name;
      var status = el('cat-align-file-status');
      status.textContent = label + 'を読んでいます…';
      import('/assets/pdf-extract.js').then(function (mod) {
        return file.arrayBuffer().then(function (buf) { return mod.extractPdfPages(new Uint8Array(buf)); });
      }).then(function (res) {
        if (res.lowText) {
          status.textContent = label + 'は文字が取れませんでした。画像として保存されたPDFのようです。OCRでテキスト付きのPDFにしてから、もう一度お試しください。';
          input.value = '';
          return;
        }
        alignPages[side] = res.pages;
        renderAlignPages(side);
        el('cat-align-ranges').hidden = false;
        applyAlignRange(side);
        status.textContent = label + 'を読みました（' + res.pages.length + 'ページ）。';
        if (!el('cat-align-name').value.trim()) el('cat-align-name').value = file.name;
        updateAlignEstimate();
      }).catch(function (error) {
        status.textContent = label + 'を読めませんでした。' + (error && error.message ? error.message : '');
      });
    }
    bindIf('cat-align-source-file', 'change', function () { readPdfInto(this, 'source', '日本語版'); });
    bindIf('cat-align-target-file', 'change', function () { readPdfInto(this, 'target', '英語版'); });
    /* ボタンは既定の見た目を持たない素の file input を隠して押す
       （cat-open-file-entry と同じ配線）。 */
    bindIf('cat-align-source-file-open', 'click', function () { el('cat-align-source-file').click(); });
    bindIf('cat-align-target-file-open', 'click', function () { el('cat-align-target-file').click(); });
    ['source', 'target'].forEach(function (side) {
      ['from', 'to'].forEach(function (end) {
        ['input', 'change'].forEach(function (eventName) {
          el('cat-align-' + side + '-' + end).addEventListener(eventName, function () { applyAlignRange(side); updateAlignEstimate(); });
        });
      });
    });
    bindIf('cat-align-source', 'input', updateAlignEstimate);
    bindIf('cat-align-target', 'input', updateAlignEstimate);
    bindIf('cat-align-open', 'click', function () { var epoch = viewEpoch; setBusy(true); YakuCommon.postText('/api/cat/align', { source_text: el('cat-align-source').value, target_text: el('cat-align-target').value, file_name: el('cat-align-name').value }).then(function (html) { startJobHtml(html, { type: 'align', name: el('cat-align-name').value, viewEpoch: epoch }); }).catch(function (error) { setBusy(false); status(error.message, true); }); });
    /* 同じ口へ寄せる。畳んで一覧へ戻すのではなく、その場で選ばせる。
       打ちかけの訳文は先に保存してから開く（開いたあと入れ替わるため）。 */
    bindIf('cat-switch-project', 'click', function () { if (!busy) window.location.assign('/cat?view=work'); });
    document.querySelectorAll('[name="cat-notation"]').forEach(function (radio) { radio.addEventListener('change', function () { if (!this.checked || !project || busy) return; mutate('notation', { notation: this.value }, '金額の書き方を切り替えています…').then(function () { status('金額の書き方を切り替えました。再翻訳はしていません。'); }); }); });
    bindIf('cat-translate', 'click', translate); bindIf('cat-export', 'click', openExportPreflight);
    bindIf('cat-export-reviewed', 'click', exportReviewed);
    bindIf('cat-qa-open', 'click', openQaList);
    bindIf('cat-document-review-run', 'click', runDocumentReview);
    bindIf('cat-copilot-review-preview', 'click', previewCopilotDocumentReview);
    bindIf('cat-qa-report-download', 'click', downloadQaReport);
    bindIf('cat-document-finding-search', 'input',function(){var needle=String(this.value||'').trim().toLowerCase();document.querySelectorAll('#cat-document-findings .cat-document-finding').forEach(function(item){item.hidden=!!needle&&item.textContent.toLowerCase().indexOf(needle)<0;});});
    bindIf('cat-copilot-review-run', 'click', runCopilotDocumentReview);
    bindIf('cat-document-review-lenses', 'click', function (event) { var button = event.target.closest('[data-cat-coverage-key]'); if (button) acceptDocumentCoverage(button.getAttribute('data-cat-coverage-key'), button); });
    /* 畳んだ帯（.cat-toolbar-menu）の開く向きを、開くたびに空きで決める。

       2026-08-15 に「検索と置換」へ is-drop-up を**固定で**付けていた。根拠は
       「実機の窓 1380x860 では帯が y=574 にあり、下へ開くと画面の外」だったが、
       **その 1380 が実機ではなかった。** 利用者の機械（inner 1912x987）では
       操作ブロックが折り返さないので帯は y=309 にあり、高さ 427 のパネルを
       上へ開くと top=-127。窓の上端の外へ出て、中のボタンが押せなかった（実測）。

       どちらの幅でも収まるように、**下に入るなら下、入らなければ上**にする。
       上下どちらにも入らないときは下にして、パネル側の overflow:auto に任せる
       （上へ出すと窓の外は掴めないが、下なら少なくとも中身を送れる）。 */
    function syncToolbarMenuDirection(details) {
        if (!details || !details.open) return;
        var panel = details.querySelector(':scope > div');
        if (!panel) return;
        var summary = details.querySelector(':scope > summary');
        if (!summary) return;
        details.classList.remove('is-drop-up');
        var rect = summary.getBoundingClientRect();
        var height = panel.getBoundingClientRect().height;
        var below = window.innerHeight - rect.bottom;
        var above = rect.top;
        if (below < height && above >= height) details.classList.add('is-drop-up');
    }
    document.querySelectorAll('.cat-toolbar-menu').forEach(function (details) {
        details.addEventListener('toggle', function () { syncToolbarMenuDirection(details); });
    });
    window.addEventListener('resize', function () {
        document.querySelectorAll('.cat-toolbar-menu[open]').forEach(syncToolbarMenuDirection);
    });

    bindIf('cat-source-update-open', 'click', function () { el('cat-source-update-file').value='';el('cat-source-update-file').click(); });
    bindIf('cat-source-update-file', 'change', function () { var file=this.files&&this.files[0];if(file)startSourceUpdate(file); });
    bindIf('cat-source-update-close', 'click', function () { el('cat-source-update-dialog').close(); });
    bindIf('cat-source-update-apply', 'click', applySourceUpdate);
    bindIf('cat-export-qa', 'click', openQaList);
    bindIf('cat-export-final-review', 'change', function () {
      var box = this; el('cat-export-final-reason').disabled = !box.checked; if (!box.checked) return;
      var scope = currentScope(); if (!scope) { box.checked = false; el('cat-export-final-reason').disabled = true; return; }
      post('final-review-readiness', {}, false, scope).then(function (readiness) {
        if (!readiness.complete) {
          box.checked = false; el('cat-export-final-reason').disabled = true; el('cat-export-qa').hidden = false;
          status('確認記録を残す前に、1. 機械比較、2. Copilot確認、表示された範囲の人による確認、ExcelではPDFの目視確認を完了してください。「点検一覧を開く」から続けられます。', true);
          return;
        }
        YakuCommon.focus(el('cat-export-final-reason'));
      }).catch(function (error) { box.checked = false; el('cat-export-final-reason').disabled = true; status(error.message, true); });
    });
    bindIf('cat-export-confirm', 'click', function (event) { if (el('cat-export-final-review').checked && !String(el('cat-export-final-reason').value || '').trim()) { event.preventDefault(); status('確認記録を残す場合は、確認した内容や判断理由を入力してください。', true); YakuCommon.focus(el('cat-export-final-reason')); } });
    bindIf('cat-danger-zone', 'toggle', function () { if (this.open) loadPersonalGlossary(); });
    initDocsPane();
    /* 訳文欄に入った時点で、その行が開いている行になる。押して開く操作は無くした。
       行を作り直すので、カーソルの位置を持ち越して同じ場所へ戻す。 */
    document.addEventListener('focusin', function (event) {
      var input = event.target.closest ? event.target.closest('textarea[data-cat-input]') : null;
      if (!input) return;
      var index = Number(input.getAttribute('data-cat-input'));
      if (index === Number(activeIndex)) return;
      var caret = input.selectionStart;
      activateIndex(index, false).then(function () {
        var moved = document.querySelector('.is-active textarea[data-cat-input]');
        if (!moved) return;
        YakuCommon.focus(moved);
        try { moved.setSelectionRange(caret, caret); } catch (_) {}
      });
    });
    /* 原文の中で押した位置を覚える。「原文の選んだ位置で2つに分ける」はこの位置で割る。
       click ではなく mouseup で取るのは、直後の listener が訳文欄へ焦点を移し、
       ボタンを押した時点では原文側の選択が残っていないためである。 */
    document.addEventListener('mouseup', function (event) {
      var span = event.target.closest ? event.target.closest('span.cat-source-text') : null;
      if (!span) return;
      var row = span.closest('[data-cat-row]');
      if (!row) return;
      var selection = window.getSelection ? window.getSelection() : null;
      if (!selection || selection.rangeCount === 0) { sourceCaret = { index: -1, position: -1 }; return; }
      var position = sourceCaretOffset(span, selection.getRangeAt(0));
      /* 拾えなかったら覚えている位置を必ず捨てる。残すと、前に押した場所で割れる。 */
      if (position < 0) { sourceCaret = { index: -1, position: -1 }; return; }
      sourceCaret = { index: Number(row.getAttribute('data-cat-row')), position: position };
    });
    /* 原文側を押したときも、同じ行の訳文欄へ入る（memoQ と同じ）。 */
    document.addEventListener('click', function (event) {
      var cell = event.target.closest ? event.target.closest('td.cat-source') : null;
      if (!cell || window.getSelection().toString()) return;
      var row = cell.closest('[data-cat-row]');
      var input = row ? row.querySelector('textarea[data-cat-input]') : null;
      if (input) YakuCommon.focus(input);
    });
    document.addEventListener('click', function (event) {
      var button = event.target.closest('button'); if (!button) return;
      if (busy && (button.id === 'cat-confirm-bulk' || button.id === 'cat-align-register-bulk' || button.id === 'cat-replace-run' || button.id === 'cat-replace-undo' || button.id === 'cat-structure-undo' || button.id === 'cat-tm-pretranslate' || button.hasAttribute('data-cat-translate-row') || button.hasAttribute('data-cat-confirm') || button.hasAttribute('data-cat-unconfirm') || button.hasAttribute('data-cat-tm-register') || button.hasAttribute('data-cat-revert') || button.hasAttribute('data-cat-merge') || button.hasAttribute('data-cat-split') || button.hasAttribute('data-cat-split-at') || button.hasAttribute('data-cat-glossary') || button.hasAttribute('data-cat-insert') || button.hasAttribute('data-cat-term-open') || button.hasAttribute('data-cat-term-insert') || button.hasAttribute('data-cat-term-edit') || button.hasAttribute('data-cat-term-deactivate') || button.hasAttribute('data-cat-term-exception') || button.hasAttribute('data-cat-tm-delete') || button.hasAttribute('data-cat-accept-revision') || button.hasAttribute('data-cat-revert-revision') || button.hasAttribute('data-cat-review-note-state'))) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
      if (button.hasAttribute('data-cat-qa-jump')) return jumpFromQa(button.getAttribute('data-cat-qa-jump'));
      if (button.hasAttribute('data-cat-doc-finding-jump')) return jumpFromQa(button.getAttribute('data-cat-doc-finding-jump'));
      if (button.hasAttribute('data-cat-doc-finding-decision')) return decideDocumentFinding(button);
      if (button.hasAttribute('data-cat-filter')) { currentFilter = button.getAttribute('data-cat-filter') || 'actionable'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-location')) {
        currentLocation = button.getAttribute('data-cat-location') || 'all';
        var menu = el('cat-location-menu'); if (menu) menu.open = false;
        return redrawAfterFlush();
      }
      if (button.hasAttribute('data-cat-change')) { currentChange = button.getAttribute('data-cat-change') || 'all'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-search-scope')) { searchScope = button.getAttribute('data-cat-search-scope') || 'both'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-review-note-state')) {
        var noteStateIndex = Number(button.getAttribute('data-cat-review-note-index'));
        var noteStateId = String(button.getAttribute('data-cat-review-note-id') || '');
        var noteState = button.getAttribute('data-cat-review-note-state') || 'open';
        return mutate('review-note-state', { index: noteStateIndex, note_id: noteStateId, state: noteState }, '作業メモを更新しています…').then(function (data) {
          if (data) status(noteState === 'resolved' ? '作業メモを解決済みにしました。' : '作業メモを未解決に戻しました。');
          return data;
        });
      }
      if (button.hasAttribute('data-yaku-cancel-job')) {
        if (cancelRequestedJobId === String(button.getAttribute('data-yaku-cancel-job') || '')) return;
        if (!window.confirm('翻訳をやめますか？\n\nここまでにできあがった訳文は保存されています。\nあとで「Copilotで未訳を翻訳」を押すと、続きから再開できます。')) return;
        cancelRequestedJobId = String(button.getAttribute('data-yaku-cancel-job') || ''); button.disabled = true; button.textContent = 'やめています…';
        return YakuCommon.post('/api/cancel-translation', { job_id: button.getAttribute('data-yaku-cancel-job') })
          .catch(function (error) { status(error.message, true); });
      }
      if (button.hasAttribute('data-cat-personal-remove')) return removePersonalGlossary(button);
      if (button.hasAttribute('data-cat-resume')) return resume(button.getAttribute('data-cat-resume'));
      if (button.id === 'cat-confirm-bulk') return confirmBulk(button);
      if (button.id === 'cat-align-register-bulk') return registerAlignmentTranslationMemoryBulk();
      if (button.id === 'cat-replace-run') return runReplace();
      if (button.id === 'cat-replace-undo') return undoReplace();
      if (button.id === 'cat-structure-undo') return undoStructuralEdit();
      if (button.id === 'cat-tm-pretranslate') return tmPretranslate();
      if (button.hasAttribute('data-cat-confirm')) return confirmRow(Number(button.getAttribute('data-cat-confirm')));
      if (button.hasAttribute('data-cat-tm-register')) return registerTranslationMemory(Number(button.getAttribute('data-cat-tm-register')));
      /* 押し間違えた確認を戻す道。サーバは以前から confirmed:false を受け付けていたが、
         画面に入口が無く、訳文を書き換える以外に戻す方法が無かった。 */
      if (button.hasAttribute('data-cat-unconfirm')) {
        var undoIndex = Number(button.getAttribute('data-cat-unconfirm'));
        return mutate('confirm', { index: undoIndex, confirmed: false }, '確認を取り消しています…')
          .then(function (data) { if (data) status('確認を取り消しました。もう一度直せます。'); return data; });
      }
      /* 訳文を打ち直したあと、保存はフォーカスが外れた時点で走る。undo が無いので、
         この行を開いたときの訳文へ戻す道だけは用意する。 */
      if (button.hasAttribute('data-cat-revert')) {
        var revertIndex = Number(button.getAttribute('data-cat-revert'));
        var revertInput = document.querySelector('[data-cat-input="' + revertIndex + '"]');
        if (!revertInput) return;
        var undoSnapshot = revertInput.hasAttribute('data-undo-original') ? revertInput.getAttribute('data-undo-original') : revertInput.getAttribute('data-original');
        var undoValue = String(undoSnapshot || '');
        revertInput.value = undoValue;
        revertInput.dispatchEvent(new Event('input', { bubbles: true }));
        YakuCommon.focus(revertInput);
        return commit(revertInput).then(function (data) {
          var saved = !!data && String(data.id || '') === String(revertInput.getAttribute('data-cat-project-id') || '') && String(revertInput.getAttribute('data-original') || '') === undoValue;
          if (saved) {
            revertInput.removeAttribute('data-undo-original');
            status('この行の変更を元に戻しました。');
          }
        });
      }
      if (button.hasAttribute('data-cat-copy-source')) { return copySourceToTarget(Number(button.getAttribute('data-cat-copy-source'))); }
      if (button.hasAttribute('data-cat-copy-target')) { return copyRowTarget(Number(button.getAttribute('data-cat-copy-target'))); }
      if (button.hasAttribute('data-cat-translate-row')) { return translateRow(Number(button.getAttribute('data-cat-translate-row'))); }
      if (button.hasAttribute('data-cat-merge')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('この行と次の行をつなげて1文にします。\n\n両方の行に入っている訳文は消えます。完了後、直前のこの結合だけを元に戻せます。\n\nつなげますか？')) return; return mutate('merge', { index: Number(button.getAttribute('data-cat-merge')) }, '行をつなげています…'); }
      if (button.hasAttribute('data-cat-split')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('つなげた行を元の2行に戻します。\n\nこの行に入っている訳文は消えます。完了後、直前のこの分割解除だけを元に戻せます。\n\n戻しますか？')) return; return mutate('split', { index: Number(button.getAttribute('data-cat-split')) }, 'つなげた行を元に戻しています…'); }
      if (button.hasAttribute('data-cat-split-at')) {
        var splitIndex = Number(button.getAttribute('data-cat-split-at'));
        var splitRow = ((project && project.segments) || []).find(function (item) { return Number(item.index) === splitIndex; });
        var splitSource = String((splitRow && splitRow.source) || '');
        var splitPosition = (Number(sourceCaret.index) === splitIndex) ? Number(sourceCaret.position) : -1;
        if (!(splitPosition > 0 && splitPosition < splitSource.length)) { status('分けたい位置を、まず原文の中でクリックしてください。行の先頭と末尾では分けられません。'); return; }
        if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('この行を、原文の選んだ位置で2つに分けます。\n\n分けたあと：\n' + splitSource.slice(0, splitPosition) + '\n---\n' + splitSource.slice(splitPosition) + '\n\nこの行に入っている訳文は消えます。完了後、直前のこの分割だけを元に戻せます。\n\n分けますか？')) return;
        sourceCaret = { index: -1, position: -1 };
        return mutate('split-at', { index: splitIndex, position: splitPosition }, '原文を分けています…');
      }
      if (button.hasAttribute('data-cat-glossary')) {
        /* 今後すべての資料へ自動で入る登録。取り消し手段が乏しいので、
           何がどう登録されるのかを見せてから確定する。 */
        var glossaryIndex = Number(button.getAttribute('data-cat-glossary'));
        var target = (project.segments || []).find(function (segment) { return Number(segment.index) === glossaryIndex; });
        var confirmText = 'このセルの訳を、今後すべての資料で自動的に使うように登録します。\n\n'
          + '原文: ' + String((target && target.source) || '') + '\n'
          + '訳文: ' + String((target && target.translation) || '') + '\n\n登録しますか？';
        if (!window.confirm(confirmText)) return;
        return post('glossary-add', { id: project.id, index: glossaryIndex }).then(function (data) { status(data.message); });
      }
      if (button.hasAttribute('data-cat-term-open')) return openTermDialog(Number(button.getAttribute('data-cat-term-open')));
      if (button.hasAttribute('data-cat-term-insert')) return insertTerm(button);
      if (button.hasAttribute('data-cat-term-edit')) return openTermEdit(button);
      if (button.hasAttribute('data-cat-term-deactivate')) return deactivateTerm(button);
      if (button.hasAttribute('data-cat-term-exception')) return openTermException(button);
      if (button.hasAttribute('data-cat-tm-delete')) return deleteMemory(button);
      if (button.hasAttribute('data-cat-insert')) return insertReference(button);
      if (button.hasAttribute('data-cat-placeable')) return insertPlaceable(Number(button.getAttribute('data-cat-placeable')));
      if (button.hasAttribute('data-cat-accept-revision')) return acceptRevisionComparison();
      if (button.hasAttribute('data-cat-revert-revision')) return revertRevisionComparison();
    });
    document.addEventListener('input', function (event) {
      if (!event.target.hasAttribute('data-cat-input')) return;
      /* 打ち始めたら一覧は畳む。番号キーを食べたままにすると、数字が打てなくなる。 */
      closePlaceablePicker();
      var index = Number(event.target.getAttribute('data-cat-input'));
      /* data-original は直近のautosave基準なので、保存成功時にBetaへ更新
         されても、今回の編集セッション開始時のAlphaを別に残す。行を作り
         直すと属性ごと消えるため、別行の編集へ古いundoを持ち越さない。 */
      if (!event.target.hasAttribute('data-undo-original')) event.target.setAttribute('data-undo-original', event.target.getAttribute('data-original') || '');
      dirty.set(dirtyKey(event.target.getAttribute('data-cat-project-id'), index), true); event.target.closest('[data-cat-row]').classList.add('cat-dirty');
      autoGrow(event.target);
      /* 戻せるのは「開いたときの訳文と違うとき」だけ。常時出すと、押しても何も
         起きないボタンになって信用を失う。 */
      var revertButton = event.target.closest('.cat-target');
      revertButton = revertButton && revertButton.querySelector('[data-cat-revert]');
      if (revertButton) revertButton.hidden = event.target.value === (event.target.getAttribute('data-original') || '');
      var note = event.target.closest('.cat-target');
      note = note && note.querySelector('.cat-example-trace');
      if (note) note.textContent = note.textContent.replace('その後編集なし', 'その後編集あり');
      saveStatus('変更を保存していません', false); el('cat-export').disabled = true; clearOutputDisplay();
    });
    document.addEventListener('mousedown', function (event) { if (event.target.closest('[data-cat-insert],[data-cat-term-insert],[data-cat-placeable]')) event.preventDefault(); });
    document.addEventListener('mouseup', function (event) {
      var row = event.target.closest && event.target.closest('[data-cat-row]'); if (!row) return;
      var index = Number(row.getAttribute('data-cat-row'));
      if (event.target.closest('.cat-source-text')) {
        var selectedSource = String(window.getSelection ? window.getSelection().toString() : '').trim();
        if (selectedSource) { if (termSelection.index !== index) termSelection = { index: index, source: '', target: '' }; termSelection.source = selectedSource; }
      }
      var input = event.target.closest('[data-cat-input]');
      if (input && Number.isInteger(input.selectionStart) && input.selectionEnd > input.selectionStart) {
        if (termSelection.index !== index) termSelection = { index: index, source: '', target: '' };
        termSelection.target = input.value.slice(input.selectionStart, input.selectionEnd).trim();
      }
    });
    document.addEventListener('select', function (event) {
      var input = event.target.closest && event.target.closest('[data-cat-input]'); if (!input || input.selectionEnd <= input.selectionStart) return;
      var index = Number(input.getAttribute('data-cat-input')); if (termSelection.index !== index) termSelection = { index: index, source: '', target: '' };
      termSelection.target = input.value.slice(input.selectionStart, input.selectionEnd).trim();
    });
    document.addEventListener('focusout', function (event) { if (event.target.hasAttribute('data-cat-input')) { closePlaceablePicker(); commit(event.target).catch(function () {}); } });
    document.addEventListener('focusin', function (event) {
      var input = event.target.closest('[data-cat-input]');
      if (input) { activeIndex = Number(input.getAttribute('data-cat-input')); var row = input.closest('[data-cat-row]'); activeSegmentId = row ? String(row.getAttribute('data-cat-segment-id') || '') : activeSegmentId; }
    });
    document.addEventListener('submit', function (event) {
      if (event.target.id === 'cat-term-form') { event.preventDefault(); if (!busy) saveTerm(); return; }
      if (event.target.id === 'cat-term-exception-form') { event.preventDefault(); if (!busy) saveTermException(); return; }
      var form = event.target.closest('[data-cat-revise]'); if (form) { event.preventDefault(); if (busy) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; } revise(form); }
    });
    document.addEventListener('keydown', function (event) {
      if (event.isComposing) return;
      var candidate = event.target.closest && event.target.closest('[data-cat-candidate-index]');
      if (candidate && (event.key === 'Enter' || event.key === ' ')) {
        event.preventDefault(); selectCandidateDetail(Number(candidate.getAttribute('data-cat-candidate-index'))); return;
      }
      var input = event.target.closest && event.target.closest('[data-cat-input]');
      /* 原文の数字を訳文へ入れる。市販CATの placeable 挿入に当たる（memoQ の
         QuickPlace、Trados の Ctrl+, ）。打ち直させないことが目的なので、
         一覧は原文どおりの表記で出す。数字の抜けは点検で止まるが、止める前に
         入れ違いを起こさせない側の手当てがこれである。 */
      if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === 'd') {
        event.preventDefault();
        if (busy) { status('処理中は数字を挿入できません。完了してからもう一度お試しください。'); return; }
        openPlaceablePicker(input);
        return;
      }
      /* 一覧を開けているあいだだけ、番号キーが挿入になる。開けていなければ
         素通しで、訳文欄に数字をそのまま打てる。 */
      if (placeablePicker.open && !event.ctrlKey && !event.metaKey && !event.altKey && event.key >= '1' && event.key <= '9') {
        event.preventDefault();
        insertPlaceable(Number(event.key) - 1);
        return;
      }
      if (placeablePicker.open && event.key === 'Escape') { event.preventDefault(); closePlaceablePicker(); return; }
      /* 点検一覧。Trados の検証（F8）に合わせる。 */
      if (event.key === 'F8' && !el('cat-workspace').hidden) { event.preventDefault(); openQaList(); return; }
      /* 資料の切り替え。作業画面から離れずに開く。 */
      if (event.key === 'F7' && !el('cat-workspace').hidden) { event.preventDefault(); window.location.assign('/cat?view=work'); return; }
      /* 資料一覧の開閉。Crowdin と同じ Ctrl+[ に合わせる。 */
      if ((event.ctrlKey || event.metaKey) && event.key === '[' && !el('cat-workspace').hidden) {
        event.preventDefault();
        applyDocsPane(!el('cat-editor-layout').classList.contains('is-docs-open'), true);
        return;
      }
      if (event.altKey && !event.ctrlKey && !event.metaKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) { event.preventDefault(); if (!busy) moveActive(event.key === 'ArrowUp' ? -1 : 1); return; }
      if (event.key === 'Escape' && el('cat-search') === document.activeElement) { event.preventDefault(); focusActive(); return; }
      /* 行の操作をキーボードから触れるようにする。市販CATは確定以外にも
         原文コピー・結合・分割が割り当てられている（memoQ の Copy source to target は
         Ctrl+Shift+S）。ブラウザが握る組み合わせ（Ctrl+T / Ctrl+N / Ctrl+W）は避ける。 */
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && event.key.toLowerCase() === 's') {
        event.preventDefault();
        if (activeIndex >= 0) copySourceToTarget(activeIndex);
        return;
      }
      if ((event.ctrlKey || event.metaKey) && event.shiftKey && event.key.toLowerCase() === 'u') {
        event.preventDefault();
        var undoButton = document.querySelector('[data-cat-unconfirm="' + activeIndex + '"]');
        if (undoButton) { undoButton.click(); } else { status('この行はまだ確認済みではありません。'); }
        return;
      }
      if (!(event.ctrlKey || event.metaKey)) return;
      if (input && event.key === 'Enter') {
        event.preventDefault();
        if (busy) { status('処理中は確認できません。完了してからもう一度お試しください。'); return; }
        confirmRow(Number(input.getAttribute('data-cat-input')));
        return;
      }
      if (event.key < '1' || event.key > '9') return;
      event.preventDefault();
      if (busy) { status('処理中は参考訳を挿入できません。完了してからもう一度お試しください。'); return; }
      var picks = document.querySelectorAll('#cat-terms-list [data-cat-term-insert]');
      var pick = picks[Number(event.key) - 1];
      if (pick) { if (pick.hasAttribute('data-cat-term-insert')) insertTerm(pick); else insertReference(pick); }
    });
    bindIf('cat-search', 'input', redrawAfterFlush);
    /* 検索の掛け方を変えたら、表も置換の帯も引き直す。置換後の文字列だけは
       表を絞らないので、帯の行数だけを数え直す。 */
    bindIf('cat-search-case', 'change', function () { searchCase = !!this.checked; redrawAfterFlush(); });
    bindIf('cat-search-regex', 'change', function () { searchRegex = !!this.checked; redrawAfterFlush(); });
    bindIf('cat-replace-input', 'input', function () { if (project) renderSearchTools(); });
    document.querySelector('[data-cat-term-cancel]').addEventListener('click', function () { el('cat-term-dialog').close(); });
    document.querySelector('[data-cat-term-exception-cancel]').addEventListener('click', function () { el('cat-term-exception-dialog').close(); });
    bindIf('cat-next-qc', 'click', goToNextQc);
    bindIf('cat-copy-again', 'click', function () { YakuCommon.copyText(el('cat-text-output-value').value, el('cat-text-output-value'), el('cat-status')); });
    bindIf('cat-text-output-close', 'click', closeTextOutput);
    bindIf('cat-select-all', 'click', function () { el('cat-text-output-value').focus(); el('cat-text-output-value').select(); status('全文を選択しました。Ctrl+Cでコピーできます。'); });
    bindIf('cat-open-folder', 'click', function () { if (!outputScope || !project || outputScope.id !== String(project.id || '')) { status('この作業の出力をもう一度作成してください。', true); return; } YakuCommon.post('/api/open-output', { project_id: outputScope.id }).then(function () { status('フォルダを開きました。'); }).catch(function (error) { status(error.message, true); }); });
    bindIf('cat-delete', 'click', function () {
      if (busy || !project) return;
      flush().then(function () {
        deleteTarget = currentScope(); if (!deleteTarget) return;
        deleteTarget.name = project.file_name || 'この翻訳作業'; el('cat-delete-name').textContent = deleteTarget.name;
        var dialog = el('cat-delete-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
      }).catch(function (error) { status(error.message, true); });
    });
    bindIf('cat-export-dialog', 'close', function () {
      var scope = preflightScope; preflightScope = null;
      if (this.returnValue !== 'export' || !scope) return;
      if (!scopeIsCurrent(scope, true)) { status('出力前の確認後に作業内容が変わったため、もう一度確認してください。', true); return; }
      exportProject();
    });
    bindIf('cat-delete-dialog', 'close', function () {
      var target = deleteTarget; deleteTarget = null;
      if (this.returnValue !== 'delete' || !target) return;
      /* 一覧から消すときは、その作業を開いていない。開いている作業を消すときだけ
         「表示中のものと同じか」を確かめる。 */
      if (!target.fromList && !scopeIsCurrent(target, true)) { status('表示中の作業が変わったため、削除を中止しました。'); return; }
      setBusy(true); status('作業を消しています…');
      var selectedMemory=document.querySelector('input[name="cat-delete-memory"]:checked');
      post('delete', { id: target.id, memory_policy: selectedMemory ? selectedMemory.value : 'retain_tm', client_id: YakuCommon.clientId() }, true, target).then(function () {
        setBusy(false);
        if (target.fromList) { loadRecent(true); status(target.name + ' を一覧から消しました。元のファイルは残っています。'); return; }
        if (!project || String(project.id || '') !== target.id) return;
        showPicker(); status('翻訳作業と途中保存を消しました。元のファイルは残っています。');
      }).catch(function (error) { setBusy(false); if (target.fromList || (project && String(project.id || '') === target.id)) status(error.message, true); });
    });
    /* 一覧のその場で消す。押した瞬間に消さず、同じ確認の窓を通す。 */
  }
  /* 貼り付け欄は最初の画面の中にある（cat.html）。中身は quick-page.js が持つ。
     状態としては出し入れしないので、ここで受けるのは「最初の画面へ戻して
     入力欄を使えるようにする」ことだけ。 */
  function requestDelete(id, name, expectedRevision) {
    if (busy || !id) return;
    deleteTarget = { id: String(id), revision: Number(expectedRevision) || 0, name: String(name || 'この翻訳作業'), fromList: true };
    el('cat-delete-name').textContent = deleteTarget.name;
    var dialog = el('cat-delete-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
  }

  function bindInstant() {
    window.addEventListener('yaku-instant-open', function () {
      if (el('cat-workspace').hidden) return;
      showPicker();
    });
    /* 1回の依頼に入りきらない長さの文章は、その場で訳す状態では分けて送れない。
       貼り付けた本文をそのまま確認作業へ渡し、1文ずつ確認しながら進めてもらう。
       （本文をブラウザーから送るのは、もともと「長い文章を貼り付ける」が通って
       いた経路。訳文を送り返す promote とは別で、そちらは artifact ID だけ） */
    window.addEventListener('yaku-instant-handoff', function (event) {
      var detail = (event && event.detail) || {};
      /* 外部ランチャーのイベントは detail.filePath に絶対パスを渡す。
         旧 #cat-path 欄へ書き戻す経路は撤去したが、この外部入口そのものは
         単一CAT入口へ残す。前後の引用符と空白だけを整え、NULや文字列以外は
         サーバへ送らない。実在性・共有フォルダ可否はサーバ側で判定する。 */
      var rawFilePath = detail.filePath;
      var filePath = typeof rawFilePath === 'string' ? rawFilePath.trim().replace(/^"(.*)"$/, '$1').trim() : '';
      if (rawFilePath != null && String(rawFilePath).trim() && (!filePath || filePath.indexOf('\0') >= 0)) {
        directFilePath = '';
        status('ファイルの保存場所を読み込めませんでした。', true);
        return;
      }
      if (filePath) {
        showPicker();
        directFilePath = filePath;
        openSource('file', 'auto');
        return;
      }
      var text = String(detail.text || '');
      if (!text.trim()) return;
      /* パレットからの昇格は、明示に選んだ方向を運んでくることがある
         （quick-page.js の貼り付け欄からの受け口はここを渡さないので常に auto）。
         to_en/to_jp 以外は auto のまま——方向は確認画面で選び直せる。 */
      var handoffDirection = detail.direction === 'to_en' || detail.direction === 'to_jp' ? detail.direction : 'auto';
      /* 先に選ぶ画面へ戻してから始める。訳す向きを聞き返されたときの二択は
         選ぶ画面の中に居るので、隠したままだと行き止まりになる。 */
      showPicker();
      setBusy(true); status('取り込んでいます…');
      post('open', { text: text, direction_intent: handoffDirection }, false, null)
        .then(function (data) { render(data, true); })
        .catch(function (error) { setBusy(false); status(error.message, true); });
    });
  }

  function start() {
    YakuCommon.start(); installRecentSnapshotAdapter(); YakuCommon.onReady(function (value) { ready = value; setBusy(busy); }); bind(); bindInstant(); loadRecent();
    var params = new URLSearchParams(location.search);
    var wanted = params.get('project');
    if (wanted) {
      var autoTranslate = params.get('translate') === '1';
      resume(wanted).then(function () { if (autoTranslate) translateWhenReady(); });
      return;
    }
    var importMeta = document.querySelector('meta[name="yaku-import"]');
    var importMode = importMeta && importMeta.getAttribute('content') === '1';
    var workMode = params.get('view') === 'work';
    if (importMode) { showPicker(importMode); showStart('align'); return; }
    if (workMode) { showPicker(false, true); return; }
    showPicker();
  }

  function getPremiumSnapshot() {
    return project ? (project.segments || []).map(function (segment) {
      var effective = segmentEffectiveTranslation(segment), state = segmentState(segment), views = qcFindingViews(segment), blockingError = segmentHasBlockingError(segment), warning = views.some(function (view) { return qcFindingSeverity(view) === 'warning'; }), saveFailed = !!segment.save_failed || dirty.has(dirtyKey(project.id, Number(segment.index))), stale = state === 'stale', blocking = blockingError || !effective.trim() || stale || saveFailed, recommended = !blocking && (!segment.confirmed || warning || segmentHasReviewNotes(segment));
      return { index: String(segment.index), location: String(segment.location || ''), source: String(segment.source || ''), target: effective.trim(), canonical: String(segment.translation || '').trim(), state: state, reviewed: !!segment.confirmed, warning: warning, blocking: blocking, saveFailed: saveFailed, qcError: blockingError, stale: stale, recommended: recommended, reason: !effective.trim() ? '未翻訳' : saveFailed ? '保存失敗' : blockingError ? '点検エラー' : stale ? '再点検' : warning ? '指摘あり' : !segment.confirmed ? '未確認' : '確認済み' };
    }) : [];
  }
  window.YakuCat = {
    isBusy: function () { return busy; },
    getRecentSnapshot: function () { return recentSnapshot; },
    getRecent: function () { return loadRecent(); },
    refreshRecent: function () { return loadRecent(true); },
    navigateStart: navigateStart,
    getPremiumSnapshot: getPremiumSnapshot,
    resave: function () { return flush(); },
    requestDelete: requestDelete,
    hasUnsavedChanges: function () { return dirty.size > 0; },
    explainOutput: function () { var message = outputGuidance(); if (message) status(message, true); return message; }
  };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
