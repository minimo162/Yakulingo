(function () {
  'use strict';
  /* 「使い方を見る」は /cat?tour=1 へ来る。ところが下の syncLocation がアドレスを
     /cat（いまは /cat?tab=quick）へ書き換えるため、tour.js が読む前に tour=1 が消え、
     案内がいつまでも始まらなかった。実測 2026-08-13: /cat?tour=1 を開くと
     アドレスは /cat?tab=quick、meta は空、案内の要素は0個。
     変更前のコードも /cat へ書き換えていたので、これは前からの不具合である。

     ここで meta へ写しておく。cat.js は tour.js より先に読まれ、この即時実行は
     start() より前に走るので、アドレスが書き換わるより先に印が残る。
     tour.js の wanted() は meta を先に見る。 */
  try {
    if (new URLSearchParams(window.location.search).get('tour') === '1') {
      var tourMeta = document.querySelector('meta[name="yaku-tour"]');
      if (tourMeta) tourMeta.setAttribute('content', '1');
    }
  } catch (_) {}
  var ready = false, busy = false, project = null, pendingDirection = null, uploaded = null;
  var dirty = new Map(), saveChain = Promise.resolve(), jobTimer = null, jobContext = null, candidateSeq = 0;
  var deleteTarget = null, preflightScope = null, jobSerial = 0, viewEpoch = 0, outputScope = null;
  var activeSegmentId = '', activeIndex = -1, currentFilter = 'actionable', currentLocation = 'all', currentChange = 'all', inspectorTab = 'candidates';
  var revisionComparison = null;
  var publicationJobId = '', publicationCandidateSet = null;
  var pendingMutationKeys = {};
  var projectLeaseSequence = 0, projectLeaseId = '', projectLeaseTimer = null;
  var termSelection = { index: -1, source: '', target: '' };
  function el(id) { return document.getElementById(id); }
  function esc(value) { return YakuCommon.escape(value); }

  /* 過去訳の原文が、いまの原文とどこが違うかを示す。市販CAT（memoQ・Trados・
     Phrase）はどれも一致率だけでなく差分を出す。率だけでは「93%」がどこの93%か
     分からず、結局は目で2文を読み比べることになる。

     日本語は語の区切りが無いので1文字ずつ、英数字は語単位で比べる。長い文は
     比較そのものが重くなるので、上限を超えたら差分をあきらめて原文を出す
     （出さないより、印の無い原文を出すほうがまし）。 */
  function diffTokens(text) {
    var tokens = [], run = '';
    String(text || '').split('').forEach(function (ch) {
      if (/[A-Za-z0-9'’\-]/.test(ch)) { run += ch; return; }
      if (run) { tokens.push(run); run = ''; }
      tokens.push(ch);
    });
    if (run) tokens.push(run);
    return tokens;
  }
  function diffMarkup(candidateSource, currentSource) {
    var a = diffTokens(currentSource), b = diffTokens(candidateSource);
    if (!a.length || !b.length || a.length * b.length > 160000) return esc(candidateSource);
    var lcs = [], i, j;
    for (i = 0; i <= a.length; i++) lcs.push(new Uint16Array(b.length + 1));
    for (i = a.length - 1; i >= 0; i--) {
      for (j = b.length - 1; j >= 0; j--) {
        lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
      }
    }
    var html = '', same = '', diff = '';
    function flush() {
      if (same) { html += esc(same); same = ''; }
      if (diff) { html += '<span class="cat-diff-ins">' + esc(diff) + '</span>'; diff = ''; }
    }
    i = 0; j = 0;
    while (i < a.length && j < b.length) {
      if (a[i] === b[j]) { if (diff) flush(); same += b[j]; i++; j++; }
      else if (lcs[i + 1][j] >= lcs[i][j + 1]) { i++; }
      else { if (same) flush(); diff += b[j]; j++; }
    }
    while (j < b.length) { if (same) flush(); diff += b[j]; j++; }
    flush();
    return html;
  }
  /* 失敗の知らせは画面のいちばん上に出る。長い一覧の下を編集していると視界に入らず、
     「押したのに何も起きない」と受け取られるので、必ずそこまで運ぶ。 */
  /* 画面の不具合そのもの（TypeError など）を、そのまま利用者へ見せない。
     「Cannot read properties of null」と出ても、利用者にできることは何も無い。
     記録には残し、画面には次にやれることを書く。 */
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
    if (error && text) YakuCommon.focus(node);
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
  var locationSynced = false;
  function syncLocation(projectId) {
    try {
      var next = projectId ? ('/cat?project=' + encodeURIComponent(projectId)) : '/cat';
      var first = !locationSynced;
      locationSynced = true;
      if (location.pathname + location.search === next) return;
      if (projectId && !first) window.history.pushState(null, '', next);
      else window.history.replaceState(null, '', next);
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
  function post(action, body, mutate, scope) {
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
    return YakuCommon.post('/api/cat/' + action, body).then(function (result) {
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
  function showPicker() { if(project) reportProjectLease('closed'); syncLocation(''); viewEpoch++; candidateSeq++; project = null; activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; termSelection = { index: -1, source: '', target: '' }; dirty.clear(); clearOutputDisplay(); document.title = '翻訳 - YakuLingo'; el('cat-page-title').textContent = '翻訳'; setView('start'); el('cat-picker').hidden = false; el('cat-workspace').hidden = true; el('cat-current-summary').hidden = true; closeStartPanels(); loadRecent(); }
  function closeStartPanels() { document.querySelectorAll('.cat-start-panel').forEach(function (panel) { panel.hidden = true; }); el('cat-direction-choice').hidden = true; }
  /* 開いた欄は、いちばん少ない移動で見える所へ入れる（block:'nearest'）。
     画面の中央へ寄せていたころは、押しただけで 560px 飛び、押したボタン自身が
     画面の外へ出ていた。初回の案内が次に指すボタンも一緒に外れ、吹き出しだけが
     上端で切れて残っていた（2026-08-13 実測、1240x860）。 */
  function showStart(mode) {
    closeStartPanels();
    var panel = el('cat-source-' + mode);
    if (!panel) return;
    /* 保存場所から取り込む欄を開くときは、選び済みのファイルを忘れる。
       source() はファイルを先に見るので、前に選んで失敗したファイルが残っていると、
       入力した場所ではなくそちらを取り込みにいく（2026-08-13、実機で発生）。 */
    if (mode === 'file') { el('cat-file-input').value = ''; uploaded = null; }
    panel.hidden = false;
    if (mode === 'align') updateAlignEstimate();
    var first = panel.querySelector('input,textarea,[role="button"],button');
    if (!first) return;
    try { first.focus({ preventScroll: true }); } catch (_) { first.focus(); }
    var box = first.getBoundingClientRect();
    if (box.top < 0 || box.bottom > window.innerHeight) {
      try { first.scrollIntoView({ behavior: 'auto', block: 'nearest' }); } catch (_) { first.scrollIntoView(); }
    }
  }
  /* 翻訳中に画面ごと凍らせない。数十分かかるあいだ、できた訳を読む・探す・コピーする、
     そして「やめる」ことは常にできる必要がある。止めるのは作業を壊す操作だけ。 */
  function isAlwaysEnabled(button) {
    if (button.closest('dialog')) return true;
    if (button.classList.contains('job-cancel')) return true;
    if (button.hasAttribute('data-cat-filter') || button.hasAttribute('data-cat-location') ||
        button.hasAttribute('data-cat-change') || button.hasAttribute('data-cat-inspector')) return true;
    return false;
  }
  /* 押せないボタンには、押せない理由をそのまま書く。灰色になった理由が分からないと、
     利用者は「壊れた」と判断してそこで止まる。 */
  function updateActionLabels() {
    var translate = el('cat-translate');
    if (translate) {
      translate.textContent = busy ? '翻訳しています…'
        : !ready ? 'Copilotを準備しています（数秒〜十数秒）'
        : (project && Number(project.untranslated) <= 0) ? '訳していない行はありません'
        : '訳していない行を訳す';
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

  function setBusy(value) {
    busy = value;
    updateActionLabels();
    document.querySelectorAll('button').forEach(function (button) { if (!isAlwaysEnabled(button)) button.disabled = value || (button.id === 'cat-translate' && !ready); });
    /* readOnly なら、待っているあいだも訳文を読んで選択・コピーできる。 */
    document.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.readOnly = value; input.disabled = false; });
    if (!value) {
      el('cat-translate').disabled = !ready || !project || Number(project && project.untranslated) <= 0;
      updateActionLabels();
      el('cat-export').disabled = !project || !!(project && project.export_blocked) || dirty.size > 0;
      /* 出せないときは、どこを直すかへ行ける場所を出しておく。件数もボタンに出す
         （市販CATの検証パネルと同じ役目）。取り出しボタンは方針どおり止めたまま。 */
      updateQaButton();
      /* 1行でも確認済みなら取り出せる。全行そろうのを待たせない。 */
      el('cat-export-reviewed').disabled = !project || Number(project && project.confirmed) <= 0 || dirty.size > 0;
      document.querySelectorAll('[data-cat-filter],[data-cat-location],[data-cat-change],[data-cat-inspector]').forEach(function (button) { button.disabled = false; });
      /* 全体の待機解除は全ボタンを戻すため、日英が揃っていない対訳開始ボタンまで
         押せる状態にしない。開始条件だけは本文の有無からもう一度決める。 */
      if (el('cat-align-open')) updateAlignEstimate();
    }
  }

  /* 保存した作業は既定で直近3件だけ出す。実機で10件あり、この一覧だけで
     画面の44%（685px / 全体1555px）を占めていた（2026-08-12）。
     多いほうが困る一覧なので、隠すのではなく「あと何件あるか」を出して畳む。 */
  var RESUME_VISIBLE = 3;
  var resumeItems = [];
  var resumeExpanded = false;

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

  function renderRecent() {
    var list = el('cat-resume-list');
    var more = el('cat-resume-more');
    var shown = resumeExpanded ? resumeItems : resumeItems.slice(0, RESUME_VISIBLE);
    list.innerHTML = shown.map(function (item, i) {
      var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
      var name = esc(item.file_name || '名称未設定');
      var saved = savedLabel(item.saved);
      return '<div class="cat-resume-row">' +
        '<button type="button" class="cat-resume-card secondary-button" data-cat-resume="' + esc(item.id) + '">' + (i === 0 ? '<span class="cat-resume-recent">前回開いた作業</span>' : '') + '<span>' + name + '・' + esc(workName(item.source, item.direction)) + '・' + (remaining ? 'あと' + remaining + '行' : '確認完了') + '</span>' + (saved ? '<span class="cat-resume-time">' + esc(saved) + '</span>' : '') + '</button>' +
        '<button type="button" class="cat-resume-drop secondary-button" data-cat-resume-drop="' + esc(item.id) + '" data-cat-resume-revision="' + (Number(item.revision) || 0) + '" data-cat-resume-name="' + name + '" title="この作業を一覧から消す" aria-label="' + name + ' の作業を消す">消す</button>' +
        '</div>';
    }).join('');
    var hiddenCount = resumeItems.length - RESUME_VISIBLE;
    more.hidden = hiddenCount <= 0;
    more.textContent = resumeExpanded ? '直近3件だけ表示する' : ('続きの作業をすべて表示（あと' + hiddenCount + '件）');
    more.setAttribute('aria-expanded', resumeExpanded ? 'true' : 'false');
    /* 左の資料一覧も同じ元データで描く。読み込みが終わってから呼ぶ必要がある
       （開いた時点では resumeItems がまだ空のことがある）。 */
    if (el('cat-editor-layout') && el('cat-editor-layout').classList.contains('is-docs-open')) renderDocsPane();
  }

  function loadRecent() {
    return post('recent', {}).then(function (data) {
      /* 消す手段が「開いてから、そのほか → 管理」の奥にしかなく、要らない作業が
         溜まっていくだけだった（2026-08-12、利用者の指摘）。一覧のその場で消せる。
         消すのは途中保存だけで、元のファイルには触らない。 */
      var items = data.projects || [];
      el('cat-resume').hidden = !items.length;
      resumeItems = items;
      if (items.length <= RESUME_VISIBLE) resumeExpanded = false;
      renderRecent();
    }).catch(function (error) { el('cat-resume').hidden = false; el('cat-resume-list').innerHTML = '<div class="alert alert-error">途中まで進めた作業の一覧を読み込めませんでした。画面を読み込み直してください（Ctrl+R）。' + esc(error.message) + '</div>'; });
  }

  function qcMessages(segment) {
    var labels = {
      empty: '訳文が空です。', 'invalid-or-source-fallback': '訳文として成立していないか、原文のままです。',
      'placeholder-residue': '訳文に「[[N1]]」のような記号が残っています。左の原文の同じ位置にある数字に、手で置き換えてください。', 'numeric-integrity': '左の原文と、訳文の数字または単位が合っていません。原文を見ながら直してください。',
      'numeric-value-mismatch': '原文にある数字が、訳文で違う値になっているか、抜けています。原文と見比べてください。', 'numeric-value-extra': '原文に無い数字が訳文に入っています。余分な数字を消してください。',
      'numeric-value-order-mismatch': '原文と訳文で、数字の並ぶ順番が違っています。原文と見比べて、同じ順番に直してください。',
      'numeric-scale-mismatch': '数字の桁（億・百万など）が原文と合っていません。原文の単位をご確認ください。', 'numeric-sign-missing': '損失や減少を示すマイナスが訳文に入っていません。原文をご確認ください。',
      'accounting-polarity-mismatch': '利益と損失、または増加と減少が、原文と逆になっているようです。原文と見比べてください。', 'currency-mismatch': '通貨（円・ドルなど）が原文と合っていません。原文をご確認ください。',
      'numeric-validation-error': '数字の点検が最後まで終わりませんでした。この行は出力できません。もう一度「確認済みにする」を押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。',
      'structure-integrity': '見出しや箇条書きの形が原文と違っています。原文と見比べてください。', 'structure-validation-error': '見出しや箇条書きの形の点検が最後まで終わりませんでした。この行は出力できません。もう一度「確認済みにする」を押してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      , 'terminology-missing': '登録した訳語が使われていません。右の「用語・参考訳」に出ている訳語をお使いください。この行だけ別の言い方にしたい場合は、その行の設定から外せます。'
      , 'terminology-forbidden': '「使わない」と登録した表現が訳文に入っています。右の「用語・参考訳」に出ている訳語に置き換えてください。'
      , 'terminology-check-unavailable': '登録した用語を読み込めませんでした。いったんアプリを閉じて開き直してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      , 'terminology-conflict': '同じ語に、必ず使う訳が2つ以上登録されています。どちらか一方を「作業の管理」から取り消してください。'
    };
    return (segment.qc_findings || []).map(function (finding) { var code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-'); return labels[code] || '自動点検で気になる点が見つかりました。左の原文と見比べてください。'; });
  }
  /* 点検の指摘は「何が起きたか」で分かれる。18種を全部おなじ赤で出すと、
     数字の食い違い（出力を止める欠陥）と、用語集を読めなかった道具の不調とが
     同じ重さに見える。後者は利用者の訳の欠陥ではなく、直しようがない。
     赤は1種類のままにする。--error を複数作ると、どれが出力を止めるのか
     分からなくなる。 */
  function qcGroup(code) {
    if (code === 'terminology-check-unavailable') return 'tool';
    return 'error';
  }
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
  function segmentState(segment) { return segment.status || segment.state || (segment.translation ? 'machine_draft' : 'untranslated'); }
  function segmentHasQc(segment) { return qcMessages(segment).length > 0; }
  function segmentActionable(segment) { return !segment.confirmed || segmentHasQc(segment); }
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
  function segmentMatchesFilter(segment) {
    var state = segmentState(segment), keep = true;
    if (currentFilter === 'actionable') keep = segmentActionable(segment);
    else if (currentFilter === 'untranslated') keep = state === 'untranslated';
    else if (currentFilter === 'unconfirmed') keep = !segment.confirmed;
    else if (currentFilter === 'qc') keep = segmentHasQc(segment);
    else if (currentFilter === 'repetition') keep = Number(segment.repetition_count || 1) > 1;
    else if (currentFilter === 'reviewed') keep = !!segment.confirmed;
    if (!keep || (currentLocation !== 'all' && locationGroup(segment) !== currentLocation) || (currentChange !== 'all' && changeGroup(segment) !== currentChange)) return false;
    var needle = el('cat-search').value.trim().toLowerCase();
    return !needle || ((segment.source || '') + '\n' + (segment.translation || '') + '\n' + (segment.location || '')).toLowerCase().indexOf(needle) >= 0;
  }
  function visibleSegments() { return project ? (project.segments || []).filter(segmentMatchesFilter) : []; }
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
    var all = project.segments || [], counts = { actionable: 0, untranslated: 0, unconfirmed: 0, qc: 0, repetition: 0, reviewed: 0, all: all.length };
    all.forEach(function (segment) {
      if (segmentActionable(segment)) counts.actionable++;
      if (segmentState(segment) === 'untranslated') counts.untranslated++;
      if (!segment.confirmed) counts.unconfirmed++;
      if (segmentHasQc(segment)) counts.qc++;
      if (Number(segment.repetition_count || 1) > 1) counts.repetition++;
      if (segment.confirmed) counts.reviewed++;
    });
    Object.keys(counts).forEach(function (name) { var target = document.querySelector('[data-cat-count="' + name + '"]'); if (target) target.textContent = counts[name]; });
    /* 点検の指摘は例外の入口。1件も無いときに 0 と並べても、選べる場所が
       増えるだけで何も伝えない（2026-08-12）。 */
    var qcFilter = document.querySelector('[data-cat-filter="qc"]');
    if (qcFilter) {
      qcFilter.hidden = counts.qc < 1;
      if (qcFilter.hidden && currentFilter === 'qc') currentFilter = 'actionable';
    }
    /* 同じ原文の行も、無い資料では出さない（点検の指摘と同じ理由）。 */
    var repetitionFilter = document.querySelector('[data-cat-filter="repetition"]');
    if (repetitionFilter) {
      repetitionFilter.hidden = counts.repetition < 1;
      if (repetitionFilter.hidden && currentFilter === 'repetition') currentFilter = 'actionable';
    }
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
  function renderInspector() {
    var segment = activeSegment(), all = project.segments || [];
    document.querySelectorAll('[data-cat-inspector]').forEach(function (button) { var selected = button.getAttribute('data-cat-inspector') === inspectorTab; button.setAttribute('aria-selected', String(selected)); });
    ['candidates','qc','context'].forEach(function (name) { el('cat-panel-' + name).hidden = name !== inspectorTab; });
    if (!segment) {
      el('cat-qc-count').textContent = '0'; el('cat-qc-list').innerHTML = '<p class="muted">行を選ぶと、その行の点検結果が出ます。</p>'; el('cat-context').innerHTML = '<p class="muted">行を選ぶと、資料のどこにある文かが分かります。</p>'; return;
    }
    var rawFindings = segment.qc_findings || [], findings = qcMessages(segment);
    el('cat-qc-count').textContent = String(findings.length);
    el('cat-qc-list').innerHTML = findings.length ? findings.map(function (message, findingIndex) {
      var finding = rawFindings[findingIndex] || {}, code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-');
      var termAction = (code === 'terminology-missing' || code === 'terminology-forbidden') ? '<button type="button" class="secondary-button" data-cat-term-exception="' + Number(segment.index) + '" data-cat-term-id="' + esc(finding.termId || finding.TermId || '') + '" data-cat-term-version="' + Number(finding.termVersion || finding.TermVersion || 0) + '" data-cat-term-source="' + esc(finding.sourceTerm || finding.SourceTerm || '') + '">この行では別の表現を使う</button>' : '';
      return '<div class="cat-qc-card is-' + qcGroup(code) + '"><p>' + esc(message) + '</p>' + termAction + '</div>';
    }).join('') : '<div class="cat-qc-card">数字と単位の自動点検では、気になる点は見つかりませんでした。</div>';
    el('cat-next-qc').disabled = !all.some(segmentHasQc);
    var index = Number(segment.index), previous = all.find(function (item) { return Number(item.index) === index - 1; }), next = all.find(function (item) { return Number(item.index) === index + 1; });
    el('cat-context').innerHTML = '<div class="cat-context-card"><span class="cat-context-label">現在の場所</span><p class="cat-context-text">' + esc(segment.location || '本文') + '</p></div>' +
      (segment.prior_source && changeGroup(segment) === 'changed' ? '<div class="cat-context-card"><span class="cat-context-label">前回からの変更</span><p class="cat-context-text"><strong>前回</strong><br>' + esc(segment.prior_source) + '</p><p class="cat-context-text"><strong>今回</strong><br>' + esc(segment.source) + '</p></div>' : '') +
      (previous ? '<div class="cat-context-card"><span class="cat-context-label">前の原文</span><p class="cat-context-text">' + esc(previous.source) + '</p></div>' : '') +
      (next ? '<div class="cat-context-card"><span class="cat-context-label">次の原文</span><p class="cat-context-text">' + esc(next.source) + '</p></div>' : '');
  }
  /* 訳文欄は、開いている行の主役。中身が入りきらないと下が切れて読めなくなるので、
     行数に合わせて伸ばす。利用者が手で広げたあとは、その高さを縮めない。 */
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

  function renderRows() {
    var all = project.segments || [], body = el('cat-grid-body');
    candidateSeq++;
    el('cat-candidates').hidden = true;
    chooseInitialActive();
    var shown = visibleSegments(), current = activeSegment();
    renderNavigation(); renderInspector();
    el('cat-filter-count').textContent = shown.length + ' / ' + all.length + '件';
    /* 表示中の未確認行をまとめて確認済みにする。市販CATは12本すべて一括確定を持つ。
       いまも Ctrl+Enter を押し続ければ同じ結果になるので、押下回数だけを負わせない。
       QC は1行ずつと同じ検査が全行で走り、通らない行は確定しない。 */
    var bulkTargets = shown.filter(function (segment) { return !segment.confirmed && String(segment.translation || '').trim(); });
    var bulkButton = el('cat-confirm-bulk');
    bulkButton.hidden = bulkTargets.length < 2;
    bulkButton.textContent = '表示中の' + bulkTargets.length + '行をまとめて確認済みにする';
    bulkButton.setAttribute('data-cat-bulk-indexes', bulkTargets.map(function (segment) { return Number(segment.index); }).join(','));
    el('cat-complete-state').hidden = !(all.length && !all.some(segmentActionable));
    el('cat-empty-state').hidden = shown.length > 0;
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
      var findings = qcMessages(segment), findingId = 'cat-qc-' + index, origin = referenceOriginLabel(segment) || originLabel(segment.origin), ops = '';
      var nextSegment = all.find(function (candidate) { return Number(candidate.index) === index + 1; });
      var mergeLosesTranslation = !!(String(segment.translation || '').trim() || (nextSegment && String(nextSegment.translation || '').trim()));
      var splitLosesTranslation = !!String(segment.translation || '').trim();
      if (segment.can_merge) ops += '<button type="button" class="cat-op secondary-button" data-cat-merge="' + index + '" data-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '">' + icon('i-merge') + '次の行とつなげて1文にする</button>';
      if (segment.can_split) ops += '<button type="button" class="cat-op secondary-button" data-cat-split="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '">' + icon('i-split') + 'つなげた行を元に戻す</button>';
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
      var compare = revisionComparison && revisionComparison.projectId === String(project.id || '') && Number(revisionComparison.index) === index ? '<section class="cat-revision-compare" aria-labelledby="cat-revision-title-' + index + '"><h4 id="cat-revision-title-' + index + '">修正結果を確認</h4><div class="cat-revision-pair"><div><strong>変更前</strong><p>' + esc(revisionComparison.before) + '</p></div><div><strong>変更後</strong><p>' + esc(segment.translation || '') + '</p></div></div><p class="muted">数字と単位は自動で点検しました。言い回しが適切かどうかは、ご自身でお確かめください。</p><div class="cat-revision-actions"><button type="button" data-cat-accept-revision="' + index + '">この案を使う</button><button type="button" class="secondary-button" data-cat-revert-revision="' + index + '">元に戻す</button></div></section>' : '';
      var kind = segment.kind === 'cell' ? 'セル' : /^word_/.test(segment.kind || '') ? 'Word' : '文';
      /* 訳文欄は全行に置く。押して「開く」段を挟むと、1行直すのに2動作かかる。
         memoQ の表は訳文セルをその場で直す作り（"type or edit the translation in
         the cell on the right"／未確認でも自動保存）で、押して開く段は無い。
         開いている行だけは、下に操作と点検結果を出す。 */
      var editor = '<textarea rows="1" data-cat-input="' + index + '" data-cat-project-id="' + esc(project.id) + '" data-original="' + esc(segment.translation || '') + '" aria-label="' + row + '行目の訳文" aria-invalid="' + (findings.length ? 'true' : 'false') + '"' + (findings.length ? ' aria-describedby="' + findingId + '"' : '') + '>' + esc(segment.translation || '') + '</textarea>';
      var extras = !isActive ? '' : prior + referenceTrace + generatedTerms + '<div class="cat-row-primary">' + (segment.confirmed ? '<button type="button" class="cat-op secondary-button" data-cat-unconfirm="' + index + '">' + icon('i-undo') + '確認を取り消す</button>' + (segment.tm_registered ? '<span class="cat-memory-status">翻訳メモリ登録済み</span>' : '<button type="button" class="cat-op secondary-button" data-cat-tm-register="' + index + '">この訳を翻訳メモリに登録</button>') : /* 押しどころでキーの名前も言う。一覧は「そのほか」→「キーボード操作」の
   2段の折りたたみの中にあり、開くまで見えなかった（実測 2026-08-13）。
   1行ずつ確定していく作業なので、いちばん押す操作のそばに置く。 */
        '<button type="button" class="cat-op cat-op-ok" data-cat-confirm="' + index + '" title="確認して次の行へ（Ctrl+Enter）" aria-keyshortcuts="Control+Enter">' + icon('i-reviewed') + '確認済みにする<span class="cat-op-key" aria-hidden="true">Ctrl+Enter</span></button>') + rowPrimary + '</div><details class="cat-more-row"><summary>そのほかの操作</summary><div class="cat-ops">' + ops + '</div>' + '<button type="button" class="cat-op secondary-button" data-cat-revert="' + index + '" hidden>編集を取り消す</button>' + (segment.translation ? '<button type="button" class="cat-op secondary-button" data-cat-term-open="' + index + '">用語を登録</button>' : '') + ((segment.kind === 'cell' && segment.translation && String(segment.source).length <= 40) ? '<button type="button" class="cat-op secondary-button" data-cat-glossary="' + index + '">このセルの訳を今後も自動で使う</button>' : '') + '</details>' + qc + compare + (segment.can_revise ? '<details class="cat-more-row"><summary>基準訳をCopilotに直してもらう</summary><form class="revise-form" data-cat-revise="' + index + '"><p class="muted">ここで直すと、確認済み状態は解除されます。Excelの枠に合わせるだけなら「体裁で見る」から掲載候補を作ってください。</p><label class="revise-label">どこをどう直すか入力</label><div class="revise-row"><input class="revise-input" type="text" placeholder="例：「increase」を「rise」に変える"><button class="secondary-button" type="submit">この指示で基準訳を直す</button></div></form></details>' : '');
      var change = changeLabel(segment);
      return '<tr class="' + (isActive ? 'is-active' : '') + '" data-cat-row="' + index + '" data-cat-segment-id="' + esc(segment.segment_id || '') + '" data-cat-confirmed="' + (segment.confirmed ? '1' : '0') + '" data-yaku-cat-state="' + esc(state) + '">' +
        '<td class="cat-col-no"><span class="cat-card-label">行番号・状態</span>' + row + '<span class="cat-state cat-state-' + esc(state) + '" title="' + esc(stateTitle(state)) + '">' + stateIcon(state) + '<span>' + esc(stateLabel(state)) + '</span></span>' + ((change && isActive) ? '<span class="cat-change-badge cat-change-' + esc(changeGroup(segment)) + '" title="' + esc(changeTitle(segment)) + '">' + esc(change) + '</span>' : '') + '</td>' +
        /* 場所は幅が狭く、長いシート名だと番地まで届かない（実測 2026-08-13、
           窓 1760px: 「2026年3月期 連結決算サマリー, AB123」は 366px 必要なのに
           89px しか無く、番地が1文字も出ない）。どのセルかは Excel の作業では
           いちばん要る情報なので、全文を title に持たせて指せば読めるようにする。 */
        '<td class="cat-col-loc"><span class="cat-card-label">場所</span><span class="cat-location-main" title="' + esc(segment.location || '本文') + '">' + esc(segment.location || '本文') + '</span><span class="cat-location-kind">' + esc(kind) + '</span>' + (Number(segment.repetition_count || 1) > 1 ? '<span class="cat-repetition" title="この原文は資料の中に ' + segment.repetition_count + ' 行あります。確認済みにすると、まだ訳が入っていない同じ原文の行へ同じ訳を入れます。">同じ原文×' + segment.repetition_count + '</span>' : '') + (origin ? '<span class="cat-origin">' + esc(origin) + '</span>' : '') + '</td>' +
        /* 行の作りは、開いていても閉じていても同じ（原文｜訳文）。以前は開いた行だけ
           上下2段のカードに化けていたが、行を移るたびに表がずれて、いま何行目かを
           見失う。市販の CAT（memoQ・Trados・Phrase）はどれも表の形を保ったまま
           その場で直す。上下2段は memoQ でも「横表示」という別の表示であって既定では
           ない（Läubli et al. arXiv:2011.05978 が速いとしたのもこの表示のこと）。 */
        '<td class="cat-source"><span class="cat-card-label">原文</span><span class="cat-source-text">' + esc(segment.source) + '</span></td>' +
        '<td class="cat-target"><span class="cat-card-label">訳文</span>' + editor + '<span class="cat-row-flag"></span>' + extras + '</td></tr>';
    }).join('');
    /* 翻訳中に絞り込みを変えると行が作り直される。編集不可の状態を引き継ぐ。 */
    if (busy) body.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.readOnly = true; });
    body.querySelectorAll('textarea[data-cat-input]').forEach(autoGrow);
    el('cat-candidates').hidden = false;
    if (current) candidates(Number(current.index)); else { el('cat-candidate-count').textContent = '0'; el('cat-candidates-list').innerHTML = '<p class="muted">行がありません。左の「すべて」を押すと、全部の行が表示されます。</p>'; }
  }

  /* 押せないボタンには「してください」、押せるボタンには「こうなります」を書く。
     未確認が残っていても取り出せる決まりにした（2026-08-12）のに、押せる状態の
     ボタンに「あと2行を確認済みにしてください。」と出していた。命令に読めるので、
     押してはいけないのだと受け取られる（2026-08-13、初回利用者として実機で確認。
     同じ場面の取り出しダイアログは「まだ確認していない行が 2 行あります。そのまま
     コピーに入れます。」と、起きることのほうを書いていた）。 */
  function outputGuidance() {
    var left = Math.max(0, Number(project.total) - Number(project.confirmed));
    if (Number(project.untranslated) > 0) return '先に、訳していない' + project.untranslated + '行を訳してください。';
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
  function previewDependencyToken(value) {
    if (!value) return '';
    return JSON.stringify({
      source: String(value.active_source_id || value.source_snapshot_id || ''),
      placement: String(value.placement_set_hash || ''),
      publication: (value.segments || []).map(function (segment) {
        return [String(segment.segment_id || ''), String(segment.translation || ''), String(segment.publication_translation || ''), String(segment.publication_variant_id || ''), Number(segment.publication_variant_revision || 0)];
      })
    });
  }
  function render(data, focusFirst) {
    var previousProjectId = project ? String(project.id || '') : '';
    var previousPreviewDependency = previewDependencyToken(project);
    if (data) project = data;
    if (!project) return;
    if (previousProjectId && previousProjectId === String(project.id || '') && previousPreviewDependency !== previewDependencyToken(project) && previewRenderId) {
      clearPreviewPdfState();
      el('cat-preview-pdf-status').textContent = '内容または配置が変わりました。PDFを作り直してください。';
    }
    syncLocation(String(project.id || ''));
    if (el('cat-editor-layout').classList.contains('is-docs-open')) renderDocsPane();
    if (previousProjectId && previousProjectId !== String(project.id || '')) { activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; }
    if (outputScope && (outputScope.id !== String(project.id || '') || outputScope.revision !== revision())) clearOutputDisplay();
    dirty.clear(); candidateSeq++;
    /* 画面遷移なしで確認作業へ入る道（その場で訳す → 長すぎるので渡す）ができた。
       外枠の広げ直しは読み込み完了に紐づいているので、その道では効かない。
       状態が変わったことを外枠へ知らせる。 */
    setView('workspace');
    el('cat-picker').hidden = true; el('cat-workspace').hidden = false; el('cat-current-summary').hidden = true;
    el('cat-current-title').textContent = project.file_name || '貼り付けた文章';
    var isAlignment = project.source === 'align';
    document.title = (isAlignment ? '過去訳の対応確認' : '翻訳') + ' - YakuLingo';
    el('cat-page-title').textContent = isAlignment ? '過去訳の対応確認' : '翻訳';
    el('cat-current-progress').textContent = workName(project.source, project.direction) + '・全' + project.total + '行のうち' + project.confirmed + '行を確認済み・残り' + Math.max(0, project.total - project.confirmed) + '行';
    el('cat-toolbar-title').textContent = project.file_name || '貼り付けた文章';
    el('cat-toolbar-direction').textContent = directionMark(project.direction);
    el('cat-current-kicker').textContent = isAlignment ? '過去訳の対応確認' : '現在の確認作業';
    el('cat-align-review-guide').hidden = !isAlignment;
    el('cat-source-heading').textContent = isAlignment ? '日本語' : '原文';
    el('cat-target-heading').textContent = isAlignment ? '英語' : '訳文';
    el('cat-translate').hidden = isAlignment;
    /* 対応確認では訳さないので、下訳の入口も出さない（訳す入口と同じ扱い）。 */
    el('cat-tm-pretranslate').hidden = isAlignment;
    var transient = project.lifecycle === 'transient';
    el('cat-transient-actions').hidden = !transient;
    if (transient) {
      var expiry = new Date(project.retention_until || '');
      el('cat-transient-expiry').textContent = (isNaN(expiry.getTime()) ? 'この一時作業は自動削除の対象です。' : ('この一時作業は ' + expiry.toLocaleString('ja-JP') + ' 以降、開いていなければ削除されます。')) + ' 翻訳メモリへ登録済みの訳は残ります。';
    }
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
    el('cat-export').textContent = isFile ? (project.document_format === 'docx' && wordReady ? '訳文入りのWordを作る' : project.document_format === 'docx' ? 'すべての訳文をコピー' : '訳文入りのExcelを作る') : 'すべての訳文をコピー';
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
    if (el('cat-export-reviewed').disabled && reviewedGuidance()) outputReasons.push('「確認済みの行だけコピー」が押せません。' + reviewedGuidance());
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
  function source(mode) {
    if (mode === 'text') { var text = el('cat-text').value; return text.trim() ? Promise.resolve({ text: text }) : Promise.reject(new Error('翻訳したい文章を貼り付けてください。')); }
    var file = el('cat-file-input').files && el('cat-file-input').files[0];
    if (file) {
      if (!file.size) return Promise.reject(new Error('空のファイルは取り込めません。'));
      if (file.size > YakuCommon.maxUploadBytes) return Promise.reject(new Error('ファイルが大きすぎます。取り込めるのは ' + Math.round(YakuCommon.maxUploadBytes / 1048576) + 'MB までですが、このファイルは ' + (file.size / 1048576).toFixed(1) + 'MB あります。資料を分けてからお試しください。'));
      var key = [file.name, file.size, file.lastModified].join(':');
      if (uploaded && uploaded.key === key) return Promise.resolve({ file_handle: uploaded.handle });
      return YakuCommon.upload('/api/upload', file).then(function (data) { if (!data.file_handle) throw new Error('ファイルを読み込めませんでした。そのファイルがWordやExcelで開いたままになっていないかご確認のうえ、もう一度お選びください。'); uploaded = { key: key, handle: data.file_handle }; return { file_handle: data.file_handle }; });
    }
    var path = el('cat-path').value.trim(); return path ? Promise.resolve({ file_path: path }) : Promise.reject(new Error('Word・Excelを選択してください。'));
  }
  function openSource(mode, intent) {
    var epoch = ++viewEpoch;
    setBusy(true); status('取り込んでいます…');
    return source(mode).then(function (payload) { payload.direction_intent = intent || 'auto'; return post('open', payload, false, null); }).then(function (data) { if (epoch !== viewEpoch) return; pendingDirection = null; render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); if (!handleDirection(error, function (dir) { return openSource(mode, dir); })) status(error.message, true); });
  }
  function resume(id) { var epoch = ++viewEpoch; setBusy(true); status('続きの作業を開いています…'); return post('resume', { project_id: id }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); }

  function commit(input) {
    if (!input) return Promise.resolve();
    var index = Number(input.getAttribute('data-cat-input')), value = input.value;
    var projectId = input.getAttribute('data-cat-project-id') || '';
    var key = dirtyKey(projectId, index);
    if (value === input.getAttribute('data-original')) { dirty.delete(key); return Promise.resolve(); }
    saveStatus('保存しています…', false);
    saveChain = saveChain.catch(function () {}).then(function () {
      if (!project || String(project.id || '') !== projectId) return { stale: true };
      var requestScope = currentScope();
      return post('segment', { index: index, text: value }, true, requestScope).then(function (data) { return { data: data, scope: requestScope }; });
    }).then(function (packet) {
      if (!packet || packet.stale || !scopeIsCurrent(packet.scope, true) || !packet.data || String(packet.data.id || '') !== projectId) return packet && packet.data;
      project = packet.data;
      if (input.isConnected && input.value === value) {
        input.setAttribute('data-original', value); dirty.delete(key);
        var savedRow = input.closest('[data-cat-row]'); if (savedRow) { savedRow.classList.remove('cat-dirty'); savedRow.classList.remove('cat-unsaved'); }
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
  function flush() { var inputs = Array.from(document.querySelectorAll('[data-cat-input]')).filter(function (input) { return dirty.has(dirtyKey(input.getAttribute('data-cat-project-id'), Number(input.getAttribute('data-cat-input')))); }); var chain = Promise.resolve(); inputs.forEach(function (input) { chain = chain.then(function () { return commit(input); }); }); return chain; }
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
    context = context || {}; context.token = ++jobSerial; context.startedAt = Date.now(); jobContext = context;
    pollJob(node.getAttribute('data-yaku-job-id'), context.token);
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
    return '<div class="job-loading"><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase">' + esc(data.label || data.phase || '翻訳しています') + '</div><div class="job-percent">' + percent + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳の進み具合" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + percent + '"><span class="job-progress-bar" style="width:' + percent + '%"></span></div>' +
      '<div class="job-bottomline"><div class="job-meta">' + (detail ? esc(detail) : 'Copilotの返事を待っています。') +
      '<br><span class="job-elapsed">' + esc(elapsedLabel(startedAt)) + '</span></div>' +
      '<button type="button" class="secondary-button job-cancel" data-yaku-cancel-job="' + esc(id) + '">翻訳をやめる</button></div>' +
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
    YakuCommon.json('/api/jobs/' + encodeURIComponent(id)).then(function (data) {
      if (!jobContext || jobContext.token !== token) return;
      el('cat-job').innerHTML = jobHtml(id, data, startedAt);
      if (['done','completed_with_warnings'].indexOf(data.mode) >= 0) { setJobTitle('✔ 翻訳が終わりました'); finishJob(id, token); return; }
      if (data.mode === 'cancelled') { setJobTitle(''); setBusy(false); el('cat-job').innerHTML = ''; status('翻訳をやめました。ここまでにできた訳文は保存されています。「訳していない行を訳す」を押すと続きから再開できます。'); return; }
      if (['error','failed'].indexOf(data.mode) >= 0) { setJobTitle(''); setBusy(false); status(data.detail || '翻訳が途中で止まりました。ここまでにできた訳文は保存されています。もう一度「訳していない行を訳す」を押すと、続きから再開します。', true); return; }
      setJobTitle(Math.round(Number(data.progress) || 0) + '% 翻訳中');
      jobTimer = window.setTimeout(function () { pollJob(id, token, 0); }, 1000);
    }).catch(function () {
      /* 一瞬の通信断でエラーにすると、サーバ側では翻訳が続いているのに利用者が
         やり直してしまう。Copilotの利用回数を二重に使うので、必ず待つ。 */
      if (!jobContext || jobContext.token !== token) return;
      var next = failureCount + 1;
      el('cat-job').innerHTML = jobHtml(id, { label: next < 3 ? '進み具合をもう一度確認しています' : '接続の回復を待っています', detail: '翻訳は続いています。画面の更新だけを待っています。', progress: 0 }, startedAt);
      jobTimer = window.setTimeout(function () { pollJob(id, token, next); }, Math.min(6000, 800 * Math.pow(2, Math.min(next, 3))));
    });
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
        }
        render(data, true);
      }
      else { setBusy(false); loadRecent(); }
      return data;
    }).catch(function (error) { setBusy(false); if (project && String(project.id || '') === context.scope.id) status(error.message, true); });
  }
  function translate() {
    var glossaryScope = null, jobScope = null;
    return flush().then(function () { glossaryScope = currentScope(); if (!glossaryScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('用語集を適用しています…'); return post('glossary', {}, true, glossaryScope); }).then(function (data) {
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示している資料が切り替わったため、翻訳をやめました。もう一度「訳していない行を訳す」を押してください。');
      project = data; jobScope = currentScope(); status('訳していない行を訳しています…'); return YakuCommon.postText('/api/cat/translate', { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate' });
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
      return YakuCommon.postText('/api/cat/translate', { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate', index: index });
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
      activeIndex = Number(segment.index); activeSegmentId = String(segment.segment_id || ''); renderRows();
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
  function runConcordance() {
    var input = el('cat-concordance-input');
    var list = el('cat-concordance-list');
    if (!input || !list) return;
    var query = String(input.value || '').trim();
    if (query.length < 2) { list.innerHTML = '<p class="muted">2文字以上で探せます。</p>'; return; }
    if (!project) return;
    list.innerHTML = '<p class="muted">探しています…</p>';
    var scope = currentScope();
    post('concordance', { query: query }, false, scope).then(function (data) {
      if (!scopeIsCurrent(scope, true)) return;
      var hits = (data && data.hits) || [];
      if (!hits.length) { list.innerHTML = '<p class="muted">' + esc(query) + ' を含む過去の訳は見つかりませんでした。確認済みにした訳から探しています。</p>'; return; }
      list.innerHTML = hits.map(function (hit) {
        var where = hit.file_name ? esc(hit.file_name) + (hit.location ? '・' + esc(hit.location) : '') : '';
        return '<div class="cat-candidate-card">' +
          '<p class="cat-concordance-source">' + esc(hit.source) + '</p>' +
          '<p class="cat-concordance-target">' + esc(hit.target) + '</p>' +
          (where ? '<p class="cat-candidate-meta">' + where + '</p>' : '') +
          '</div>';
      }).join('');
    }).catch(function (error) {
      list.innerHTML = '<p class="muted">' + esc(error.message || '探せませんでした。') + '</p>';
    });
  }

  /* 原文をそのまま訳文へ入れる。既に訳文があるときは黙って消さない。
     memoQ は確認せず上書きするが、ここでは人が書いた訳を消す危険を採らない。 */
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
        status('確認済みにできませんでした。右の「数字の自動点検」に出ている内容を直してから、もう一度お試しください。', true);
        inspectorTab = 'qc'; renderInspector();
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
          status('翻訳メモリを読めませんでした。下訳はできませんが、これまでどおり「訳していない行を訳す」で進められます。', true);
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
    drop.addEventListener('keydown', function (event) { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); input.click(); } });
    ['dragenter','dragover'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.add('dragover'); }); });
    ['dragleave','drop'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.remove('dragover'); }); });
    drop.addEventListener('drop', function (event) { if (event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files.length) { input.files = event.dataTransfer.files; input.dispatchEvent(new Event('change')); } });
  }

  var filterSeq = 0;
  function redrawAfterFlush() {
    var seq = ++filterSeq;
    return flush().then(function () { if (seq === filterSeq && project) { candidateSeq++; el('cat-candidates').hidden = true; renderRows(); } }).catch(function (error) { status('変更を保存できなかったため、表示を切り替えませんでした。' + error.message, true); });
  }
  function candidates(index) {
    var seq = ++candidateSeq, requestScope = currentScope();
    if (!requestScope) return;
    el('cat-candidate-count').textContent = '…'; el('cat-terms-list').innerHTML = '<p class="muted">登録した用語を探しています…</p>'; el('cat-candidates-list').innerHTML = '<p class="muted">似た訳を探しています…</p>';
    YakuCommon.post('/api/cat/candidates', { id: requestScope.id, index: index }).then(function (data) {
      if (seq !== candidateSeq || !scopeIsCurrent(requestScope, true) || Number(activeIndex) !== Number(index)) return;
      var terms = (data.terms || []).filter(function (item) { return item.kind === 'term'; });
      var items = (data.segment_matches || []).filter(function (item) { return item.kind === 'memory' || item.kind === 'prior'; });
      var activeSegmentNow = activeSegment();
      var activeSource = activeSegmentNow ? String(activeSegmentNow.source || '') : '';
      var diffHintShown = false;
      var panel = el('cat-candidates'); panel.hidden = false;
      el('cat-candidate-count').textContent = String(terms.length + items.length);
      el('cat-terms-list').innerHTML = terms.length ? terms.map(function (item, termIndex) {
        var termNumber = termIndex + 1;
        var allowed = (item.allowed_targets || []).filter(Boolean), forbidden = (item.forbidden_targets || []).filter(Boolean);
        var scopeLabel = item.scope === 'project' ? 'この資料だけ' : '今後の資料でも使用';
        return '<article class="cat-candidate-card cat-term-card">' + (termNumber <= 9 ? '<span class="cat-candidate-number">' + termNumber + '</span><span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + termNumber + '</kbd></span>' : '') + '<div class="cat-candidate-meta"><span class="cat-cand-tag">登録用語</span><span>' + esc(item.source_name || '用語集') + '</span><span>' + esc(scopeLabel) + '</span></div>' +
          '<div><strong>原文の用語</strong><p class="cat-cand-src">' + esc(item.source) + '</p></div><div><strong>推奨訳</strong><p class="cat-cand-tgt">' + esc(item.translation || item.target) + '</p></div>' +
          (allowed.length ? '<p class="muted">許容する別訳: ' + esc(allowed.join('、')) + '</p>' : '') + (forbidden.length ? '<p class="muted">使用しない訳: ' + esc(forbidden.join('、')) + '</p>' : '') +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-term-insert="' + esc(item.translation || item.target) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">この訳語を入力位置に入れる</button>' +
          '<button type="button" class="secondary-button" data-cat-term-edit data-cat-index="' + index + '" data-cat-term-id="' + esc(item.term_id || '') + '" data-cat-term-version="' + Number(item.term_version || 0) + '" data-cat-term-source="' + esc(item.source || '') + '" data-cat-term-target="' + esc(item.translation || item.target || '') + '" data-cat-term-allowed="' + esc(allowed.join('|')) + '" data-cat-term-forbidden="' + esc(forbidden.join('|')) + '" data-cat-term-scope="' + esc(item.scope || 'project') + '">用語を修正</button><button type="button" class="secondary-button" data-cat-term-deactivate="' + esc(item.term_id || '') + '" data-cat-index="' + index + '">この用語の登録を取りやめる</button></div></article>';
      }).join('') : '<p class="muted">登録はありません。</p>'
      + '<details class="pane-note"><summary>用語を登録するには</summary><p class="muted">語をマウスで選び、「用語を登録」を押します。</p></details>';
      markTermsInSource(terms);
      el('cat-candidates-list').innerHTML = items.length ? items.map(function (item, itemIndex) {
        var label = item.kind === 'memory' ? '過去に確認した訳' : '前回の資料の訳';
        var material = item.source_name || item.database || '資料名なし';
        /* 無いものを「情報なし」と書かない。埋まっている行と見分けがつかず、
           カードの行数だけが増えていた（2026-08-12）。 */
        var place = Number(item.page) > 0 ? ('ページ ' + Number(item.page)) : '';
        var location = item.location ? String(item.location) : '';
        var ratio = Number(item.score != null ? item.score : (item.source_match_ratio != null ? item.source_match_ratio : item.ratio)) || 0;
        /* 一致率は、市販CATと同じくカードの先頭に大きく出す。どこが違うかは
           原文側の印で示すので、下の説明文は日付だけでよくなった。 */
        var exact = (item.kind === 'prior' ? !!item.exact : (ratio >= .999 || !!item.exact));
        var percent = exact ? 100 : Math.max(1, Math.min(99, Math.round(ratio * 100)));
        var scoreClass = exact ? 'is-exact' : (percent >= 85 ? 'is-high' : 'is-low');
        var scoreBadge = '<span class="cat-cand-score ' + scoreClass + '" title="いまの原文とどれだけ同じか">' + percent + '%</span>';
        /* 一致率は先頭の札が持っているので、ここで数字を繰り返さない。 */
        var match = item.kind === 'prior' ? (item.exact ? '前回と原文が同じ' : '前回から原文に変更あり') : '';
        var translation = item.translation != null ? item.translation : item.target;
        var number = terms.length + itemIndex + 1;
        /* 日時は「いつ確認した訳か」だけ分かればよい。秒まで出すと、
           見比べたい原文・訳文より目立つ（2026-08-12）。 */
        var saved = item.saved ? (String(item.saved).slice(0, 10) + ' 確認') : '';
        /* 「太字が違うところ」は、最初に印が付いたカードで一度だけ言う。
           全部のカードに書くと、読むのは印そのものではなく説明文になる。 */
        var diffHint = '';
        if (!exact && !diffHintShown) { diffHint = '太字が原文との違い'; diffHintShown = true; }
        var deleteButton = item.kind === 'memory' ? '<button type="button" class="secondary-button" data-cat-tm-delete="' + esc(item.reference_id || '') + '" data-cat-index="' + index + '">この候補を今後は出さない</button>' : '';
        return '<article class="cat-candidate-card"><span class="cat-candidate-number">' + number + '</span>' + (number <= 9 ? '<span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + number + '</kbd></span>' : '') + '<div class="cat-candidate-meta">' + scoreBadge + '<span class="cat-cand-tag">' + esc(label) + '</span><span>' + esc(material) + '</span>' + (location ? '<span>' + esc(location) + '</span>' : '') + (place ? '<span>' + esc(place) + '</span>' : '') + '</div>' +
          '<div><strong>原文</strong><p class="cat-cand-src">' + diffMarkup(item.source, activeSource) + '</p></div><div><strong>訳文</strong><p class="cat-cand-tgt">' + esc(translation) + '</p></div>' +
          /* 「原文が似ているというだけです。訳文が正しいかは…」は消した。
             見出しが「似ている過去の訳」で、入れるかどうかは押して決める。
             読む人はそれを分かっている（2026-08-12、利用者の指摘）。 */
          '<p class="muted">' + esc([match, saved, diffHint].filter(Boolean).join('・')) + '</p>' +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-insert="' + esc(translation) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">' + number + ' この訳を挿入</button>' + deleteButton + '</div></article>';
      }).join('') : '<p class="muted">確認済みにした訳が、次の資料から候補に出ます。</p>';
    }).catch(function () { if (seq === candidateSeq) { el('cat-candidate-count').textContent = '0'; el('cat-terms-list').innerHTML = '<p class="muted">用語を読み込めませんでした。行を選び直すと、もう一度探します。</p>'; el('cat-candidates-list').innerHTML = '<p class="muted">似た訳を読み込めませんでした。行を選び直すと、もう一度探します。</p>'; } });
  }

  /* 原文のどこが登録済みの用語かを、その場で示す。市販CATはほぼ全社がこれを持つ
     （Trados=赤い角括弧状の下線、MateCat=青い下線、Smartling=点線の下線、
     OmegaT=下線）。サーバは以前から用語の一致を返していたが、画面が捨てていて、
     利用者は右ペインの用語カードと左の原文を目で照合するしかなかった。 */
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
    return post('tm-delete',{index:index,reference_id:button.getAttribute('data-cat-tm-delete')||''},true,requestScope).then(function(){setBusy(false);status('この候補は、今後は出しません。');candidates(index);}).catch(function(error){setBusy(false);status(error.message,true);});
  }
  function exportProject() {
    var requestScope = null, finalRequested = !!el('cat-export-final-review').checked, finalReason = String(el('cat-export-final-reason').value || '').trim();
    return flush().then(function () { requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('出力しています…'); return post('export', { render_id: previewRenderId || '' }, true, requestScope); }).then(function (data) {
      if (!project || String(project.id || '') !== requestScope.id) { setBusy(false); return; }
      var recordPromise = Promise.resolve(null);
      if (finalRequested) {
        recordPromise = post('final-review-decision', { output_token: data.output_token, reason: finalReason, acknowledge_unresolved: true, render_id: previewRenderId || '' }, true, requestScope).then(function (recorded) {
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
      el('cat-export-confirm').textContent = mode === 'copy_text' ? 'すべての訳文をコピー' : 'ファイルを作る';
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
  function qaFindings() {
    var all = (project && project.segments) || [], groups = [
      { key: 'empty', title: '訳文が空', blocking: true, items: [] },
      { key: 'qc', title: '数字の点検', blocking: true, items: [] },
      { key: 'unconfirmed', title: '未確認', blocking: false, items: [] }
    ];
    if (nothingTranslatedYet()) return groups;
    all.forEach(function (segment) {
      var messages = qcMessages(segment);
      var empty = !String(segment.translation || '').trim();
      if (empty) groups[0].items.push({ index: Number(segment.index), source: segment.source, message: '' });
      messages.filter(function (message) { return !empty || message.indexOf('訳文が空') < 0; }).forEach(function (message) {
        if (empty && /空/.test(message)) return;
        groups[1].items.push({ index: Number(segment.index), source: segment.source, message: message });
      });
      if (!segment.confirmed && !empty) groups[2].items.push({ index: Number(segment.index), source: segment.source, message: '' });
    });
    return groups;
  }
  /* 体裁で見る。市販CAT（Trados のプレビュー、memoQ の Preview）に当たる。
     元のファイルは開かないし、作らない。画面が既に持っている行だけで組む。

     Excel は「Sheet1, A2」から行と列を読み、同じ位置にセルを置く。位置が
     ずれていないか、セルからはみ出していないかは、これで見て分かる。
     Word と貼り付けた文章は段落の並び順（画面の行の順）がそのまま本文になる。
     体裁そのものの再現ではない。書体や罫線までは持っていないので、
     見出しの大小や色は再現しない。 */
  var previewSide = 'target', previewPdfSide = 'target', previewMode = 'layout', previewPdfUrl = '', previewPdfBlob = null, previewPdfSha256 = '', previewRenderJob = '', previewRenderId = '', previewPdfReviewRun = null, sourceUpdateJob = '', sourceUpdatePlan = null;
  function clearPreviewPdfState() {
    if (previewPdfUrl) { URL.revokeObjectURL(previewPdfUrl); previewPdfUrl = ''; }
    previewPdfBlob = null; previewPdfSha256 = ''; previewRenderJob = ''; previewRenderId = ''; previewPdfReviewRun = null;
    el('cat-preview-pdf-frame').removeAttribute('src'); el('cat-preview-pdf-frame').hidden = true;
    el('cat-preview-pdf-check').hidden = true; el('cat-preview-pdf-accept').hidden = true;
  }
  function setPreviewMode(mode) {
    previewMode = mode === 'pdf' ? 'pdf' : 'layout';
    document.querySelectorAll('[data-cat-preview-mode]').forEach(function (button) {
      button.setAttribute('aria-selected', String(button.getAttribute('data-cat-preview-mode') === previewMode));
    });
    el('cat-preview-layout-panel').hidden = previewMode !== 'layout';
    el('cat-preview-pdf-panel').hidden = previewMode !== 'pdf';
  }
  function showRenderedPdf(renderId, side) {
    side = side === 'source' ? 'source' : 'target';
    previewPdfSide = side;
    document.querySelectorAll('[data-cat-pdf-side]').forEach(function (button) { button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-pdf-side') === side)); });
    var url = '/api/cat/render-pdf?id=' + encodeURIComponent(project.id) + '&render_id=' + encodeURIComponent(renderId) + '&kind=' + encodeURIComponent(side);
    return YakuCommon.request(url).then(function (response) { return response.blob(); }).then(function (blob) {
      if (side === 'target') previewPdfBlob = blob;
      if (previewPdfUrl) URL.revokeObjectURL(previewPdfUrl);
      previewPdfUrl = URL.createObjectURL(blob);
      el('cat-preview-pdf-frame').src = previewPdfUrl;
      el('cat-preview-pdf-frame').hidden = false;
      el('cat-preview-pdf-status').textContent = side === 'source' ? '原文PDFを表示しています。' : '訳文PDFを表示しています。';
      el('cat-preview-pdf-check').hidden = side !== 'target';
      el('cat-preview-pdf-accept').hidden = side !== 'target' || !previewPdfReviewRun;
    });
  }
  function pollRender(jobId) {
    return YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (String(jobId) !== previewRenderJob) return;
      if (data.mode === 'done' || data.mode === 'completed_with_warnings') {
        el('cat-preview-pdf-update').disabled = false;
        if (data.application_status !== 'current') { el('cat-preview-pdf-status').textContent = '作成中に内容が変わりました。もう一度更新してください。'; return; }
        previewRenderId = String(data.result_id || '');
        previewPdfSha256 = String(data.pdf_sha256 || '');
        return showRenderedPdf(previewRenderId, 'target').then(function () {
          el('cat-preview-pdf-status').textContent = data.writeback_completeness_status === 'verified'
            ? 'Excelへの書き戻しは照合済みです。PDF上の切れ・重なりは画面で確認してください。'
            : 'PDF上の文字と体裁を画面で確認してください。';
        });
      }
      if (['error','failed','interrupted','cancelled'].indexOf(data.mode) >= 0) {
        el('cat-preview-pdf-update').disabled = false;
        el('cat-preview-pdf-status').textContent = data.detail || 'PDFを作成できませんでした。';
        return;
      }
      el('cat-preview-pdf-status').textContent = (data.label || 'PDFを作成しています') + ' ' + Math.max(0, Number(data.progress || 0)) + '%';
      window.setTimeout(function () { pollRender(jobId).catch(function (error) { el('cat-preview-pdf-status').textContent = error.message; el('cat-preview-pdf-update').disabled = false; }); }, 900);
    });
  }
  function updatePdfPreview() {
    if (!project || project.source !== 'file' || ['xlsx','xlsm'].indexOf(String(project.document_format || '')) < 0) {
      el('cat-preview-pdf-status').textContent = 'PDF確認はExcelファイルで利用できます。'; return;
    }
    var button = el('cat-preview-pdf-update'); button.disabled = true; previewRenderId = ''; previewPdfBlob = null; previewPdfSha256 = ''; previewPdfReviewRun = null; el('cat-preview-pdf-check').hidden = true; el('cat-preview-pdf-accept').hidden = true;
    el('cat-preview-pdf-status').textContent = '作業内容を保存しています…';
    return flush().then(function () { return post('render-start', {}, true); }).then(function (data) {
      previewRenderJob = String(data.job_id || '');
      if (!previewRenderJob) throw new Error('PDF作成を開始できませんでした。');
      return pollRender(previewRenderJob);
    }).catch(function (error) { button.disabled = false; el('cat-preview-pdf-status').textContent = error.message; });
  }
  function checkPdfPublicationText() {
    if (!previewPdfBlob || !previewRenderId || !previewPdfSha256) { el('cat-preview-pdf-status').textContent = '先にPDFを作成してください。'; return Promise.resolve(); }
    var button = el('cat-preview-pdf-check'); button.disabled = true; el('cat-preview-pdf-status').textContent = 'PDFから掲載文字を読み取っています…';
    return Promise.all([import('/assets/pdf-review.js'), previewPdfBlob.arrayBuffer()]).then(function (values) {
      return values[0].extractReviewPdfPages(new Uint8Array(values[1]));
    }).then(function (extracted) {
      return post('pdf-review-apply', { render_id: previewRenderId, pdf_sha256: previewPdfSha256, extractor_contract: extracted.extractor_contract, page_count: extracted.page_count, pages: extracted.pages }, true);
    }).then(function (data) {
      project.revision = Number(data.revision); previewPdfReviewRun = data.review_run;
      var summary = previewPdfReviewRun && previewPdfReviewRun.coverage_summary || {}, unresolved = (previewPdfReviewRun.coverage_items || []).filter(function (item) { return ['unreadable','unmapped','skipped'].indexOf(String(item.state || '')) >= 0 && !item.human_decision_current; });
      el('cat-preview-pdf-accept').hidden = unresolved.length === 0;
      el('cat-preview-pdf-status').textContent = '文字の存在と候補位置を照合しました。' + unresolved.length + 'か所をPDF画面で見て、切れ・重なり・印刷範囲を確認してください。';
      return loadDocumentFindings();
    }).catch(function (error) { el('cat-preview-pdf-status').textContent = error.message; }).finally(function () { button.disabled = false; });
  }
  function acceptPdfVisualReview() {
    if (!previewPdfReviewRun) return Promise.resolve();
    var ids = (previewPdfReviewRun.coverage_items || []).filter(function (item) { return ['unreadable','unmapped','skipped'].indexOf(String(item.state || '')) >= 0 && !item.human_decision_current; }).map(function (item) { return item.coverage_item_id; });
    if (!ids.length) return Promise.resolve();
    var note = window.prompt('PDF画面で確認した内容を記録してください。\n例：全ページを見て、文字切れ・重なり・印刷範囲外がないことを確認', 'PDF全ページを目視し、掲載内容を確認した');
    if (!String(note || '').trim()) return Promise.resolve();
    var button = el('cat-preview-pdf-accept'); button.disabled = true;
    return post('coverage-decision', { review_run_id: previewPdfReviewRun.review_run_id, coverage_item_ids: ids, note: String(note).trim() }, true).then(function (data) {
      project.revision = Number(data.revision); ids.forEach(function (id) { var item = (previewPdfReviewRun.coverage_items || []).find(function (row) { return row.coverage_item_id === id; }); if (item) item.human_decision_current = true; });
      previewPdfReviewRun.coverage_summary = data.decision.coverage_summary; button.hidden = true; el('cat-preview-pdf-status').textContent = 'PDFを目で確認した記録を残しました。内容が変わると、この記録は失効します。';
    }).catch(function (error) { el('cat-preview-pdf-status').textContent = error.message; }).finally(function () { button.disabled = false; });
  }
  function previewCellRef(location) {
    var text = String(location || '');
    var match = text.match(/^(.*?),\s*([A-Z]+)(\d+)$/);
    if (!match) return null;
    var letters = match[2], column = 0;
    for (var i = 0; i < letters.length; i++) column = column * 26 + (letters.charCodeAt(i) - 64);
    return { sheet: match[1] || 'Sheet', column: column, row: Number(match[3]), address: letters + match[3] };
  }
  function previewText(segment) {
    var target = String(segment.translation || '');
    if (previewSide === 'source') return { text: String(segment.source || ''), missing: false };
    if (target.trim()) return { text: target, missing: false };
    return { text: String(segment.source || ''), missing: true };
  }
  /* 原本から読んだ体裁を、シート名で引く。 */
  function previewLayout(sheetName) {
    var sheets = (project && project.sheet_layout) || [];
    var found = null;
    sheets.forEach(function (sheet) { if (String(sheet.name) === String(sheetName)) found = sheet; });
    if (!found) return null;
    if (found.__prepared) return found.__prepared;
    var widths = {}, heights = {}, wrap = {}, align = {}, bold = {}, spans = {}, covered = {};
    (found.columns || []).forEach(function (col) {
      for (var c = Number(col.min); c <= Number(col.max); c++) widths[c] = col.hidden ? 0 : Number(col.width);
    });
    /* 行の高さは、既定と違う行だけ来る。来ない行は既定で埋める。 */
    (found.rows || []).forEach(function (row) { heights[Number(row.row)] = Number(row.height); });
    (found.cells || []).forEach(function (cell) {
      var ref = previewCellRef('x, ' + cell.address);
      if (!ref) return;
      if (cell.wrap) wrap[ref.row + ':' + ref.column] = true;
      if (cell.align) align[ref.row + ':' + ref.column] = String(cell.align);
      if (cell.bold) bold[ref.row + ':' + ref.column] = true;
    });
    /* 結合は「左上のセルが何列ぶん占めるか」と「隠れるセル」に分けて持つ。 */
    (found.merges || []).forEach(function (range) {
      var parts = String(range).split(':');
      if (parts.length !== 2) return;
      var from = previewCellRef('x, ' + parts[0]), to = previewCellRef('x, ' + parts[1]);
      if (!from || !to) return;
      spans[from.row + ':' + from.column] = { columns: (to.column - from.column + 1), rows: (to.row - from.row + 1) };
      for (var r = from.row; r <= to.row; r++) {
        for (var c = from.column; c <= to.column; c++) {
          if (r === from.row && c === from.column) continue;
          covered[r + ':' + c] = true;
        }
      }
    });
    found.__prepared = {
      defaultWidth: Number(found.default_width) || 8.43,
      defaultHeight: Number(found.default_height) || 18.75,
      widths: widths, heights: heights, wrap: wrap, align: align, bold: bold, spans: spans, covered: covered
    };
    return found.__prepared;
  }
  /* 列幅は「標準フォントの文字数」。1文字ぶんを 7px として px に直す（Excel の既定）。
     境目ぎりぎりは信用しない。ここでは幅を与えるだけで、はみ出しの判定はしない。 */
  function previewColumnPx(layout, column, span) {
    if (!layout) return 0;
    var total = 0, count = (span && span.columns) || 1;
    for (var i = 0; i < count; i++) {
      var width = layout.widths[column + i];
      if (width === undefined) width = layout.defaultWidth;
      total += Number(width) * 7 + 5;
    }
    return Math.max(24, Math.round(total));
  }
  /* 行の高さは「ポイント」。96dpi の px に直す（1pt = 4/3 px）。
     tr の height は最低の高さとして効くので、折り返して伸びた行は伸びたまま出る。
     縦に切ると、隠れた文字に気づく手がかりが画面に残らないため、そちらは採らない。 */
  function previewRowPx(layout, row) {
    if (!layout) return 0;
    var points = layout.heights[row];
    if (points === undefined) points = layout.defaultHeight;
    return Math.max(1, Math.round(Number(points) * 4 / 3));
  }
  var previewMeasureCanvas = null;
  function previewTextWidthPx(text, bold) {
    if (!previewMeasureCanvas) previewMeasureCanvas = document.createElement('canvas');
    var context = previewMeasureCanvas.getContext && previewMeasureCanvas.getContext('2d');
    if (!context) return Array.from(String(text || '')).length * 7;
    context.font = (bold ? '700 ' : '') + '14.7px Calibri, Arial, sans-serif';
    return context.measureText(String(text || '')).width;
  }
  function previewCellHtml(segment, layout, row, column, span) {
    var value = previewText(segment);
    var key = row + ':' + column;
    var wrap = layout ? !!layout.wrap[key] : false;
    var align = layout ? (layout.align[key] || '') : '';
    var style = '';
    var displayWidth = layout ? previewColumnPx(layout, column, span) : 0;
    var spillRegion = segment.placement && (segment.placement.display_regions || []).find(function (region) {
      return region.mode === 'spill_right_display_only' && String(region.anchor_address || '').toUpperCase() === String(segment.location || '').split(',').pop().trim().toUpperCase();
    });
    if (layout && spillRegion) {
      (spillRegion.cells || []).forEach(function (_, offset) { displayWidth += previewColumnPx(layout, column + offset + 1, null); });
    }
    var overflowRisk = !!(layout && !wrap && previewTextWidthPx(value.text, !!layout.bold[key]) > Math.max(0, displayWidth - 8));
    if (layout) {
      style = ' style="width:' + previewColumnPx(layout, column, span) + 'px' +
        (align === 'center' ? ';text-align:center' : align === 'right' ? ';text-align:right' : '') + '"';
    }
    var placementAction = previewSide === 'target' && segment.placement_root_index !== undefined
      ? ' data-cat-placement-edit="' + Number(segment.placement_root_index) + '" title="セルごとの区切りを調整"'
      : ' data-cat-qa-jump="' + Number(segment.index) + '"';
    return '<button type="button" class="cat-preview-cell' + (value.missing ? ' is-missing' : '') +
      (wrap ? ' is-wrap' : '') + (layout && layout.bold[key] ? ' is-bold' : '') +
      (overflowRisk ? ' is-overflow-risk' : '') +
      (Number(segment.index) === Number(activeIndex) ? ' is-active' : '') +
      '"' + style + placementAction + (overflowRisk ? ' aria-label="収まり要確認: PDFで切れを確認してください"' : '') + '>' +
      esc(value.text) + '</button>';
  }
  /* Word の並び。見出しは段の深さで、表は格子で出す。Excel と同じ考えで、
     原本を見た人が「どこの話か」を形で分かるようにするためのもの。
     見出しの段も表の位置も無い資料（古い作業を含む）は、今までどおり平らに出す。 */
  function previewParagraphHtml(segment, extraClass) {
    var value = previewText(segment);
    return '<button type="button" class="cat-preview-paragraph' + (extraClass || '') +
      (value.missing ? ' is-missing' : '') +
      (Number(segment.index) === Number(activeIndex) ? ' is-active' : '') +
      '" data-cat-qa-jump="' + Number(segment.index) + '">' + esc(value.text) + '</button>';
  }
  function buildFlow(flow) {
    var html = '', index = 0;
    while (index < flow.length) {
      var segment = flow[index];
      var table = Number(segment.table_index);
      if (!isFinite(table) || table < 0) {
        var level = Number(segment.heading_level) || 0;
        html += previewParagraphHtml(segment, level > 0 ? (' is-heading is-heading-' + Math.min(level, 4)) : '');
        index++;
        continue;
      }
      /* 同じ表のぶんをまとめて取り、行と列へ戻す。同じセルに段落が複数あることがある
         （Word ではふつう）ので、セルの中は積み重ねる。 */
      var cells = {}, maxRow = 0, maxColumn = 0;
      while (index < flow.length && Number(flow[index].table_index) === table) {
        var item = flow[index];
        var row = Number(item.table_row), column = Number(item.table_column);
        if (!isFinite(row) || row < 0) { row = 0; }
        if (!isFinite(column) || column < 0) { column = 0; }
        var key = row + ':' + column;
        if (!cells[key]) { cells[key] = { span: Math.max(1, Number(item.table_span) || 1), parts: [] }; }
        cells[key].parts.push(item);
        maxRow = Math.max(maxRow, row);
        maxColumn = Math.max(maxColumn, column + (Math.max(1, Number(item.table_span) || 1) - 1));
        index++;
      }
      var body = '';
      for (var r = 0; r <= maxRow; r++) {
        var tds = '', c = 0;
        while (c <= maxColumn) {
          var cell = cells[r + ':' + c];
          if (!cell) { tds += '<td></td>'; c++; continue; }
          tds += '<td' + (cell.span > 1 ? ' colspan="' + cell.span + '"' : '') + '>' +
            cell.parts.map(function (part) { return previewParagraphHtml(part, ' is-in-table'); }).join('') + '</td>';
          c += cell.span;
        }
        body += '<tr>' + tds + '</tr>';
      }
      html += '<table class="cat-preview-doctable"><tbody>' + body + '</tbody></table>';
    }
    return html;
  }
  function buildPreview() {
    var all = (project && project.segments) || [];
    var sheets = [], sheetIndex = {}, flow = [];
    all.forEach(function (segment) {
      var placed = segment.kind === 'cell' && segment.placement && (segment.placement.destinations || []).length
        ? segment.placement.destinations.map(function (destination) {
          return Object.assign({}, segment, {
            translation: String(destination.text || ''),
            location: String(destination.sheet || '') + ', ' + String(destination.address || ''),
            placement_root_index: Number(segment.index)
          });
        }) : [segment];
      placed.forEach(function (part) {
        var ref = part.kind === 'cell' ? previewCellRef(part.location) : null;
        if (!ref) { flow.push(part); return; }
        if (!sheetIndex[ref.sheet]) { sheetIndex[ref.sheet] = { name: ref.sheet, cells: [], maxRow: 0, maxColumn: 0 }; sheets.push(sheetIndex[ref.sheet]); }
        var sheet = sheetIndex[ref.sheet];
        sheet.cells.push({ ref: ref, segment: part });
        sheet.maxRow = Math.max(sheet.maxRow, ref.row);
        sheet.maxColumn = Math.max(sheet.maxColumn, ref.column);
      });
    });
    var html = sheets.map(function (sheet) {
      var grid = {};
      sheet.cells.forEach(function (item) { grid[item.ref.row + ':' + item.ref.column] = item.segment; });
      /* 元の体裁（列幅・折り返し・結合）。原本から読んだものがあれば使う。
         無ければ今までどおり均等幅で出す（体裁は足しであって前提ではない）。 */
      var layout = previewLayout(sheet.name);
      var rows = '';
      for (var row = 1; row <= sheet.maxRow; row++) {
        var cells = '<th scope="row">' + row + '</th>';
        for (var column = 1; column <= sheet.maxColumn; column++) {
          if (layout && layout.covered[row + ':' + column]) continue;
          var segment = grid[row + ':' + column];
          var span = (layout && layout.spans[row + ':' + column]) || null;
          var attrs = span ? (' colspan="' + span.columns + '" rowspan="' + span.rows + '"') : '';
          cells += '<td' + attrs + '>' + (segment ? previewCellHtml(segment, layout, row, column, span) : '') + '</td>';
        }
        rows += '<tr' + (layout ? ' style="height:' + previewRowPx(layout, row) + 'px"' : '') + '>' + cells + '</tr>';
      }
      /* 幅を効かせるには table-layout: fixed と colgroup が要る。auto のままだと
         中身の長さが勝ち、Excel なら切れるはずの文字で列が広がる。 */
      var group = '<col style="width:2.6rem">';
      for (var g = 1; g <= sheet.maxColumn; g++) group += '<col style="width:' + (layout ? previewColumnPx(layout, g, null) : 120) + 'px">';
      var head = '<th scope="col"><span class="sr-only">行番号</span></th>';
      for (var c = 1; c <= sheet.maxColumn; c++) {
        var letters = '', n = c;
        while (n > 0) { var mod = (n - 1) % 26; letters = String.fromCharCode(65 + mod) + letters; n = Math.floor((n - mod) / 26); }
        head += '<th scope="col">' + letters + '</th>';
      }
      /* 原本の高さが分かっているときだけ、押しやすさのための下限（1.9rem）を外す。
         外さないと、10pt の行も 30px になり、縦の詰まり具合が原本と変わってしまう。 */
      return '<section class="cat-preview-sheet"><h3>' + esc(sheet.name) + '</h3><table class="cat-preview-grid' +
        (layout ? ' is-measured' : '') + '"><colgroup>' + group + '</colgroup><thead><tr>' + head + '</tr></thead><tbody>' + rows + '</tbody></table></section>';
    }).join('');
    if (flow.length) {
      html += '<section class="cat-preview-flow">' + buildFlow(flow) + '</section>';
    }
    return html || '<p class="muted">まだ行がありません。</p>';
  }
  function renderPreview() {
    setPreviewMode(previewMode);
    document.querySelectorAll('[data-cat-preview-side]').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-preview-side') === previewSide));
    });
    var all = (project && project.segments) || [];
    var missing = all.filter(function (segment) { return !String(segment.translation || '').trim(); }).length;
    el('cat-preview-note').textContent = previewSide === 'target'
      ? '訳文セルを押すと、セル配置の調整と「情報を保って短くする候補」を使えます。' + (missing ? ' 薄い字は、訳文がまだ無いところです。' : '')
      : '';
    el('cat-preview-body').innerHTML = buildPreview();
    var active = el('cat-preview-body').querySelector('.is-active');
    if (active && active.scrollIntoView) active.scrollIntoView({ block: 'center' });
  }
  var placementEditorDestinations = [];
  function renderPlacementSliceEditors(downCount) {
    var host = el('cat-placement-slices');
    var base = placementEditorDestinations.filter(function (destination) { return String(destination.mode || 'replace_source_block') !== 'use_confirmed_empty'; });
    var existing = Array.prototype.map.call(host.querySelectorAll('[data-cat-placement-slice]'), function (input) { return input.value; });
    if (!existing.length) existing = placementEditorDestinations.map(function (destination) { return String(destination.text || ''); });
    var desired = base.length + Math.max(0, Math.min(3, Number(downCount || 0)));
    if (existing.length > desired && desired > 0) existing[desired - 1] += existing.slice(desired).join('');
    existing = existing.slice(0, desired); while (existing.length < desired) existing.push('');
    host.innerHTML = existing.map(function (text, sliceIndex) {
      var original = sliceIndex < base.length ? base[sliceIndex] : null;
      var label = original ? ((original.sheet || '') + ' ' + (original.address || '')) : ('下の空白 ' + (sliceIndex - base.length + 1) + 'セル目');
      return '<label>' + esc(label + '（' + (sliceIndex + 1) + '）') + '<textarea data-cat-placement-slice="' + sliceIndex + '">' + esc(text) + '</textarea></label>';
    }).join('');
  }
  function openPlacementEditor(index) {
    var segment = (project && project.segments || []).find(function (item) { return Number(item.index) === Number(index); });
    var placement = segment && segment.placement;
    if (!placement || !(placement.destinations || []).length) { status('この行には調整できるセル配置がありません。', true); return; }
    el('cat-placement-index').value = String(index);
    placementEditorDestinations = (placement.destinations || []).slice();
    var downDestinations = placementEditorDestinations.filter(function (destination) { return String(destination.mode || '') === 'use_confirmed_empty'; });
    el('cat-placement-down').value = String(downDestinations.length);
    renderPlacementSliceEditors(downDestinations.length);
    var spillRegion = (placement.display_regions || []).find(function (region) { return region.mode === 'spill_right_display_only'; });
    var spillCount = spillRegion && spillRegion.cells ? spillRegion.cells.length : 0;
    el('cat-placement-spill').value = String(spillCount);
    var baseDestinationCount = placementEditorDestinations.length - downDestinations.length;
    var excelPlacement = !!(project && ['xlsx', 'xlsm'].indexOf(project.document_format) >= 0);
    el('cat-placement-spill-row').hidden = baseDestinationCount !== 1 || !excelPlacement;
    el('cat-placement-down-row').hidden = !excelPlacement;
    el('cat-placement-down-note').hidden = !excelPlacement;
    el('cat-placement-message').textContent = '現在の掲載訳: ' + String(segment.publication_translation || segment.translation || '');
    el('cat-placement-dialog').showModal();
    var first = el('cat-placement-slices').querySelector('textarea'); if (first) YakuCommon.focus(first);
  }
  function savePlacement(event) {
    event.preventDefault();
    var index = Number(el('cat-placement-index').value);
    var segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
    var slices = Array.prototype.map.call(el('cat-placement-slices').querySelectorAll('[data-cat-placement-slice]'), function (input) { return input.value; });
    if (!segment || slices.join('') !== String(segment.publication_translation || segment.translation || '')) {
      el('cat-placement-message').textContent = '各欄を上からつないだ内容が現在の訳文と一致していません。文字を削らず、セルの境界だけ移してください。';
      return;
    }
    el('cat-placement-save').disabled = true;
    var spillRightCells = el('cat-placement-spill-row').hidden ? 0 : Number(el('cat-placement-spill').value || 0);
    var downEmptyCells = el('cat-placement-down-row').hidden ? 0 : Number(el('cat-placement-down').value || 0);
    return post('placement', { index: index, slices: slices, spill_right_cells: spillRightCells, down_empty_cells: downEmptyCells, placement_plan_hash: String(segment.placement && segment.placement.plan_hash || '') }, true).then(function (data) {
      el('cat-placement-dialog').close(); render(data, false); renderPreview(); status('セルごとの区切りを保存しました。PDFを更新して収まりを確認してください。');
    }).catch(function (error) { el('cat-placement-message').textContent = error.message; }).finally(function () { el('cat-placement-save').disabled = false; });
  }
  function openPublicationCandidates() {
    var index = Number(el('cat-placement-index').value);
    var segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
    if (!segment) return;
    publicationJobId = ''; publicationCandidateSet = null;
    el('cat-publication-index').value = String(index);
    el('cat-publication-source-heading').textContent = project && project.direction === 'to_jp' ? '英語原文' : '日本語原文';
    el('cat-publication-canonical-heading').textContent = project && project.direction === 'to_jp' ? '内容を確認する日本語訳' : '内容を確認する英訳';
    el('cat-publication-source').textContent = String(segment.source || '');
    el('cat-publication-canonical').textContent = String(segment.translation || '');
    el('cat-publication-status').textContent = '候補を作っても、まだExcelや基準訳は変わりません。';
    el('cat-publication-candidates').innerHTML = '';
    el('cat-publication-dialog').showModal();
  }
  function showPublicationCandidateSet(set) {
    publicationCandidateSet = set || null;
    var candidates = (set && set.candidates) || [];
    if (!candidates.length) {
      el('cat-publication-status').textContent = '正確さを保ったままでは収まりません。' + (set && set.cannot_fit_reason ? ' ' + set.cannot_fit_reason : ' 下セルへ分ける、右の空白を使う、または手動で調整してください。');
      el('cat-publication-candidates').innerHTML = '';
      return;
    }
    el('cat-publication-status').textContent = 'Copilotの「情報を保った」という申告だけでは確定しません。3つの文章を自分で見比べてください。';
    el('cat-publication-candidates').innerHTML = candidates.map(function (candidate) {
      var qc = String(candidate.deterministic_qc_status || '') === 'passed' && String(candidate.fit_verification_status || '') !== 'estimated_overflow';
      var uses = (candidate.used_abbreviations || []).map(function (use) { return '<li><strong>' + esc(use.abbreviation) + '</strong> — ' + esc(use.full_form) + '（' + esc(use.meaning) + '）</li>'; }).join('');
      var warnings = (candidate.warnings || []).map(function (warning) { return '<li>' + esc(warning) + '</li>'; }).join('');
      return '<section class="cat-publication-candidate"><h3>Excelに入れる候補</h3><p class="cat-publication-text">' + esc(candidate.text || '') + '</p>' +
        '<p class="muted">自動点検: ' + (qc ? '数字・単位などの機械点検を通過' : (String(candidate.fit_verification_status || '') === 'estimated_overflow' ? '指定した文字数の目安を超えるため採用不可' : '不一致の可能性があるため採用不可')) + ' / 収容見込み: ' + esc(candidate.fit_verification_status || candidate.fit_estimate || '未判定') + '</p>' +
        (uses ? '<details><summary>使用する略語</summary><ul>' + uses + '</ul></details>' : '<p class="muted">登録済み略語は使用していません。</p>') +
        (warnings ? '<ul class="alert-inline">' + warnings + '</ul>' : '') +
        '<label><input type="checkbox" data-publication-reviewed="' + esc(candidate.candidate_id) + '"' + (qc ? '' : ' disabled') + '> 原文・基準訳・候補を比較し、情報の欠落がないことを確認しました</label>' +
        '<button type="button" data-publication-apply="' + esc(candidate.candidate_id) + '" disabled>この候補をExcelに入れる</button></section>';
    }).join('');
  }
  function pollPublicationCandidates(jobId) {
    return YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (jobId !== publicationJobId) return;
      if (data.mode === 'done' || data.mode === 'completed_with_warnings') {
        el('cat-publication-generate').disabled = false;
        if (data.application_status !== 'current') throw new Error('候補作成中に基準訳が変わりました。もう一度作り直してください。');
        showPublicationCandidateSet(data.candidate_set); return;
      }
      if (['error','failed','interrupted','cancelled'].indexOf(data.mode) >= 0) throw new Error(data.detail || '候補を作れませんでした。');
      el('cat-publication-status').textContent = (data.label || '候補を作っています') + ' ' + Math.max(0, Number(data.progress || 0)) + '%';
      window.setTimeout(function () { pollPublicationCandidates(jobId).catch(function (error) { el('cat-publication-status').textContent = error.message; el('cat-publication-generate').disabled = false; }); }, 900);
    });
  }
  function generatePublicationCandidates() {
    var index = Number(el('cat-publication-index').value), segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
    if (!segment) return;
    el('cat-publication-generate').disabled = true; el('cat-publication-status').textContent = '候補を作っています…';
    var destinationCount = segment.placement && segment.placement.destinations ? segment.placement.destinations.length : 1;
    var maxChars = Math.max(20, Math.floor(String(segment.translation || '').length * 0.8));
    return flush().then(function () { return post('publication-candidates', { index: index, max_chars: maxChars, destination_count: destinationCount }, true); }).then(function (data) {
      publicationJobId = String(data.job_id || ''); if (!publicationJobId) throw new Error('候補作成を開始できませんでした。'); return pollPublicationCandidates(publicationJobId);
    }).catch(function (error) { el('cat-publication-status').textContent = error.message; el('cat-publication-generate').disabled = false; });
  }
  function applyPublicationCandidate(candidateId) {
    if (!publicationCandidateSet || !publicationJobId) return;
    var candidate = (publicationCandidateSet.candidates || []).find(function (item) { return String(item.candidate_id || '') === String(candidateId || ''); }); if (!candidate) return;
    el('cat-publication-status').textContent = '掲載訳だけを保存しています…';
    return post('publication-apply', { job_id: publicationJobId, candidate_set_id: publicationCandidateSet.candidate_set_id, candidate_id: candidateId, candidate_text_hash: candidate.text_hash, dependency_fingerprint: publicationCandidateSet.dependency_fingerprint, meaning_preservation_confirmed: true, reason: '原文・基準訳・候補を比較し、情報の欠落がないことを人が確認' }, true).then(function (data) {
      el('cat-publication-dialog').close(); el('cat-placement-dialog').close(); render(data, false); renderPreview(); status('Excelに入れる訳を保存しました。基準訳と翻訳メモリは変更していません。PDFを更新して印刷結果を確認してください。');
    }).catch(function (error) { el('cat-publication-status').textContent = error.message; });
  }
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
    },true);}).then(function(data){sourceUpdatePlan=null;el('cat-source-update-dialog').close();clearPreviewPdfState();render(data,false);status('原文ファイルを差し替えました。変更された行だけ確認し、PDFを作り直してください。');})
      .catch(function(error){el('cat-source-update-summary').textContent=error.message;button.disabled=false;});
  }
  /* 資料の切り替え。市販ツール（Crowdin の畳めるファイル一覧、memoQ の資料タブ、
     Phrase のブラウザタブ）はどれも作業画面に居たまま切り替える。ここもそれに倣い、
     一覧画面へ戻らずに入れ替える。開いている資料には印を付け、押しても何も起きない
     ことが分かるようにする。 */
  function renderDocDialogList() {
    var list = el('cat-doc-dialog-list');
    var currentId = project ? String(project.id || '') : '';
    if (!resumeItems.length) {
      list.innerHTML = '<p class="muted">続きから開ける作業はまだありません。</p>';
      return;
    }
    list.innerHTML = resumeItems.map(function (item) {
      var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
      var isCurrent = String(item.id) === currentId;
      var saved = savedLabel(item.saved);
      return '<button type="button" class="cat-doc-choice' + (isCurrent ? ' is-current' : '') + '"' +
        (isCurrent ? ' aria-current="true" disabled' : '') +
        ' data-cat-doc-open="' + esc(item.id) + '">' +
        '<span class="cat-doc-choice-name">' + esc(item.file_name || '名称未設定') + '</span>' +
        '<span class="cat-doc-choice-meta">' + esc(workName(item.source, item.direction)) + '・' +
        (remaining ? 'あと' + remaining + '行' : '確認完了') + (saved ? '・' + esc(saved) : '') +
        (isCurrent ? '・開いています' : '') + '</span></button>';
    }).join('');
  }
  /* 左の資料一覧。中身は切替ダイアログと同じものを、畳める欄として出す。
     開いているあいだは、資料名を押さなくても隣の資料へ移れる。 */
  function renderDocsPane() {
    var list = el('cat-docs-pane-list');
    if (!list) return;
    var currentId = project ? String(project.id || '') : '';
    if (!resumeItems.length) { list.innerHTML = '<p class="muted">まだありません。</p>'; return; }
    list.innerHTML = resumeItems.map(function (item) {
      var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
      var isCurrent = String(item.id) === currentId;
      return '<button type="button" class="cat-docs-pane-item' + (isCurrent ? ' is-current' : '') + '"' +
        (isCurrent ? ' aria-current="true" disabled' : '') +
        ' data-cat-doc-open="' + esc(item.id) + '" title="' + esc(item.file_name || '') + '">' +
        '<span class="cat-docs-pane-name">' + esc(item.file_name || '名称未設定') + '</span>' +
        /* 同じ資料を2回取り込むと、名前も残り行数も同じ行が並ぶ。左欄でも時刻で
           見分けられるようにする（実測 2026-08-13: spec.docx が2件、ManualBuilder が
           2件、01_A4_format が2件並んでいた）。 */
        '<span class="cat-docs-pane-meta">' + (remaining ? 'あと' + remaining + '行' : '確認完了') +
        (savedLabel(item.saved) ? '・' + esc(savedLabel(item.saved)) : '') +
        (isCurrent ? '・開いています' : '') + '</span></button>';
    }).join('');
  }
  /* 開くかどうか。既定は「広い窓のときだけ」。一度でも自分で開閉したら、その選択を覚える
     （市販CATでもペインの開閉は覚える。MateCat は明記している）。 */
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
    var roomy = window.innerWidth >= DOCS_PANE_MIN_WIDTH;
    if (stored === '1') { applyDocsPane(roomy); return; }
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
  function openDocDialog() {
    var dialog = el('cat-doc-dialog');
    /* 開いてから読み直す。作業中に別の作業が増えている（別窓・前回の続き）ことがある。
       読み直しを待たずに一度出すので、押せるまでの間が空かない。 */
    renderDocDialogList();
    dialog.showModal();
    var first = dialog.querySelector('.cat-doc-choice:not([disabled])') || el('cat-doc-dialog-import');
    if (first) YakuCommon.focus(first);
    loadRecent().then(function () { if (dialog.open) renderDocDialogList(); }).catch(function () {});
  }
  function openPreview() {
    if (!project) { status('資料が開かれていません。'); return; }
    var pdfAvailable = project.source === 'file' && ['xlsx','xlsm'].indexOf(String(project.document_format || '')) >= 0;
    var pdfTab = document.querySelector('[data-cat-preview-mode="pdf"]');
    if (pdfTab) { pdfTab.hidden = !pdfAvailable; pdfTab.disabled = !pdfAvailable; }
    if (!pdfAvailable) previewMode = 'layout';
    renderPreview();
    if (!pdfAvailable) el('cat-preview-note').textContent = 'PDF確認はExcelファイルの作業で利用できます。';
    var dialog = el('cat-preview-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
  }

  function updateQaButton() {
    var button = el('cat-qa-open');
    if (!button) return;
    button.disabled = !project;
    if (!project) { button.textContent = '点検'; return; }
    var groups = qaFindings();
    var blocking = groups[0].items.length + groups[1].items.length;
    button.textContent = blocking ? ('点検 ' + blocking) : '点検';
    button.classList.toggle('cat-qa-has-blockers', blocking > 0);
  }
  function openQaList() {
    if (!project) { status('資料が開かれていません。'); return; }
    var groups = qaFindings();
    var blocking = groups.filter(function (group) { return group.blocking; }).reduce(function (sum, group) { return sum + group.items.length; }, 0);
    var unconfirmed = groups[2].items.length;
    el('cat-qa-summary').textContent = nothingTranslatedYet()
      ? 'まだ訳していません。「訳していない行を訳す」を押すと、Copilotへ送ります。'
      : blocking
      ? ('ファイルを作れない指摘が ' + blocking + ' 件あります。' + (unconfirmed ? '未確認は ' + unconfirmed + ' 行です。' : ''))
      : (unconfirmed ? ('未確認は ' + unconfirmed + ' 行です。数字の点検は、確認済みにするときに行います。') : '指摘はありません。すべての行を確認し終えています。');
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
    var previewDialog = el('cat-preview-dialog'); if (previewDialog.open) previewDialog.close('cancel');
    /* 飛んだ先が絞り込みで隠れていては直せない。表示を「すべて」に戻す。 */
    currentFilter = 'all'; currentLocation = 'all'; currentChange = 'all';
    return redrawAfterFlush().then(function () { return activateIndex(Number(index), true); });
  }

  function goToNextQc() {
    if (!project) return Promise.resolve();
    var all = project.segments || [], after = all.find(function (segment) { return Number(segment.index) > Number(activeIndex) && segmentHasQc(segment); });
    var target = after || all.find(segmentHasQc);
    if (!target) { status('数字と単位の自動点検では、気になる点は見つかりませんでした。'); return Promise.resolve(); }
    currentFilter = 'qc'; currentLocation = 'all'; inspectorTab = 'qc';
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

  function bind() {
    trackToolbarHeight();
    /* 帯の操作。role="tablist" の作法どおり、左右の矢印でも移れるようにする。 */
    /* 資料の切り替え。左上の資料名と、折りたたみの中の項目の両方から同じ口を開く。
       以前の「ほかの資料に切り替える」は作業画面を畳んで一覧へ戻していた。 */
    el('cat-doc-switch').addEventListener('click', openDocDialog);
    /* 左の資料一覧。開閉と、その中からの切り替え。 */
    el('cat-docs-toggle').addEventListener('click', function () {
      applyDocsPane(!el('cat-editor-layout').classList.contains('is-docs-open'), true);
    });
    el('cat-docs-import').addEventListener('click', function () { showPicker(); showStart('file'); });
    el('cat-align-next-document').addEventListener('click', function () { showPicker(); showStart('file'); });
    el('cat-docs-pane-list').addEventListener('click', function (event) {
      var choice = event.target.closest ? event.target.closest('[data-cat-doc-open]') : null;
      if (!choice || choice.disabled) return;
      var id = choice.getAttribute('data-cat-doc-open');
      flush().then(function () { resume(id); }).catch(function (error) { status(error.message, true); });
    });
    el('cat-doc-dialog-close').addEventListener('click', function () { el('cat-doc-dialog').close(); });
    el('cat-doc-dialog-import').addEventListener('click', function () {
      el('cat-doc-dialog').close();
      showPicker();
      showStart('file');
    });
    /* 貼り付けも同じ扱いの入口になったので、ここから始められるようにする。
       開始画面へ戻して、貼り付け欄へ焦点を置くだけでよい。 */
    el('cat-doc-dialog-paste').addEventListener('click', function () {
      el('cat-doc-dialog').close();
      showPicker();
      YakuCommon.focus(el('quick-input'));
    });
    el('cat-doc-dialog-list').addEventListener('click', function (event) {
      var choice = event.target.closest ? event.target.closest('[data-cat-doc-open]') : null;
      if (!choice || choice.disabled) return;
      var id = choice.getAttribute('data-cat-doc-open');
      el('cat-doc-dialog').close();
      /* 一覧画面を経由しない。ここで直接その資料へ入れ替える。
         打ちかけの訳文は先に保存する。保存できなければ入れ替えない。 */
      flush().then(function () { resume(id); }).catch(function (error) { status(error.message, true); });
    });
    /* ブラウザの戻る。資料を開くかどうかだけで決まるようになった（帯を外したため）。 */
    window.addEventListener('popstate', function () {
      var wanted = new URLSearchParams(location.search).get('project');
      if (wanted) { if (!project || String(project.id || '') !== wanted) resume(wanted); }
      else if (project) showPicker();
    });
    /* 通常の終了では確認を出さない。画面が隠れる直前に打ちかけを保存し、
       翻訳中の終了確認だけはcommon.jsが担当する。 */
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden' && !busy) { try { flush(); } catch (_) {} }
    });
    document.querySelectorAll('[data-cat-source-show]').forEach(function (button) { button.addEventListener('click', function () { showStart(button.getAttribute('data-cat-source-show')); }); });
    document.querySelectorAll('[data-cat-open]').forEach(function (button) { button.addEventListener('click', function () { openSource(button.getAttribute('data-cat-open'), 'auto'); }); });
    document.querySelectorAll('[data-cat-direction]').forEach(function (button) { button.addEventListener('click', function () { el('cat-direction-choice').hidden = true; if (pendingDirection) pendingDirection(button.getAttribute('data-cat-direction')); }); });
    /* 「Word・Excelを取り込む」は、ファイル選択をそのまま開く。押しても欄が
       開くだけだったころは、そこにもう一度「選ぶ」があり、さらに「取り込んで
       確認を始める」を押す必要があった（2026-08-13、利用者の指摘）。 */
    el('cat-open-file-entry').addEventListener('click', function () { el('cat-file-input').value = ''; el('cat-file-input').click(); });
    /* 選んだ時点で取り込みを始める。押す回数を3回から1回にする。 */
    el('cat-file-input').addEventListener('change', function () {
      uploaded = null;
      if (this.files.length) openSource('file', 'auto');
    });
    /* ドロップ先はボタン自身。専用の枠を置くと、押す場所が2つに見える。 */
    bindFileDrop(el('cat-open-file-entry'), el('cat-file-input'));
    el('cat-prior-open').addEventListener('click', function () { var epoch = ++viewEpoch; setBusy(true); post('from-prior-version', { prior_ja: el('cat-prior-ja').value, prior_en: el('cat-prior-en').value, current_ja: el('cat-current-ja').value, document_name: el('cat-prior-name').value }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); });
    /* 過去の日英資料の入口。PDF を読むには WebAssembly が要り、それは
       ?import=1 で開いた画面にしか許していない（普段の作業では CSP を
       'self' のままにするため）。押したらその画面へ移る。 */
    el('cat-open-align-entry').addEventListener('click', function () {
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
    el('cat-align-source-file').addEventListener('change', function () { readPdfInto(this, 'source', '日本語版'); });
    el('cat-align-target-file').addEventListener('change', function () { readPdfInto(this, 'target', '英語版'); });
    ['source', 'target'].forEach(function (side) {
      ['from', 'to'].forEach(function (end) {
        ['input', 'change'].forEach(function (eventName) {
          el('cat-align-' + side + '-' + end).addEventListener(eventName, function () { applyAlignRange(side); updateAlignEstimate(); });
        });
      });
    });
    el('cat-align-source').addEventListener('input', updateAlignEstimate);
    el('cat-align-target').addEventListener('input', updateAlignEstimate);
    el('cat-align-open').addEventListener('click', function () { var epoch = viewEpoch; setBusy(true); YakuCommon.postText('/api/cat/align', { source_text: el('cat-align-source').value, target_text: el('cat-align-target').value, file_name: el('cat-align-name').value }).then(function (html) { startJobHtml(html, { type: 'align', name: el('cat-align-name').value, viewEpoch: epoch }); }).catch(function (error) { setBusy(false); status(error.message, true); }); });
    /* 同じ口へ寄せる。畳んで一覧へ戻すのではなく、その場で選ばせる。
       打ちかけの訳文は先に保存してから開く（開いたあと入れ替わるため）。 */
    el('cat-switch-project').addEventListener('click', function () { if (busy) return; flush().then(openDocDialog).catch(function (error) { status(error.message, true); }); });
    el('cat-project-save').addEventListener('click', function () {
      return mutate('project-save', {}, 'この作業を保存しています…').then(function (data) {
        if (data) status('この作業を保存しました。あとから「最近の作業」から再開できます。');
        return data;
      });
    });
    el('cat-project-retain').addEventListener('click', function () {
      return mutate('project-retain', {}, '削除予定を延長しています…').then(function (data) { if (data) status('一時作業の削除予定を7日延ばしました。'); return data; });
    });
    el('cat-copy-close').addEventListener('click', function () {
      if (!project || project.lifecycle !== 'transient' || busy) return;
      var target=null;setBusy(true);status('訳文をコピーして一時作業を削除しています…');
      return flush().then(function(){target=currentScope();if(!target)throw new Error('一時作業を確認できません。');return post('export',{},true,target);}).then(function(output){return YakuCommon.copyText(String(output.text||''),null,el('cat-status')).then(function(copied){if(!copied)throw new Error('クリップボードへコピーできなかったため、一時作業は削除していません。');return post('project-close-delete',{memory_policy:'retain_tm',client_id:YakuCommon.clientId()},true,target);});}).then(function(){setBusy(false);showPicker();status('訳文をコピーし、一時作業を削除しました。翻訳メモリへ登録済みの訳は残しています。');}).catch(function(error){setBusy(false);status(error.message,true);});
    });
    el('cat-translate').addEventListener('click', translate); el('cat-export').addEventListener('click', openExportPreflight);
    el('cat-export-reviewed').addEventListener('click', exportReviewed);
    el('cat-qa-open').addEventListener('click', openQaList);
    el('cat-document-review-run').addEventListener('click', runDocumentReview);
    el('cat-copilot-review-preview').addEventListener('click', previewCopilotDocumentReview);
    el('cat-qa-report-download').addEventListener('click', downloadQaReport);
    el('cat-document-finding-search').addEventListener('input',function(){var needle=String(this.value||'').trim().toLowerCase();document.querySelectorAll('#cat-document-findings .cat-document-finding').forEach(function(item){item.hidden=!!needle&&item.textContent.toLowerCase().indexOf(needle)<0;});});
    el('cat-copilot-review-run').addEventListener('click', runCopilotDocumentReview);
    el('cat-document-review-lenses').addEventListener('click', function (event) { var button = event.target.closest('[data-cat-coverage-key]'); if (button) acceptDocumentCoverage(button.getAttribute('data-cat-coverage-key'), button); });
    el('cat-preview-open').addEventListener('click', openPreview);
    el('cat-preview-pdf-update').addEventListener('click', updatePdfPreview);
    el('cat-preview-pdf-check').addEventListener('click', checkPdfPublicationText);
    el('cat-preview-pdf-accept').addEventListener('click', acceptPdfVisualReview);
    el('cat-placement-form').addEventListener('submit', savePlacement);
    el('cat-placement-cancel').addEventListener('click', function () { el('cat-placement-dialog').close(); });
    el('cat-placement-down').addEventListener('change', function () { renderPlacementSliceEditors(Number(this.value || 0)); });
    el('cat-publication-open').addEventListener('click', openPublicationCandidates);
    el('cat-publication-close').addEventListener('click', function () { el('cat-publication-dialog').close(); });
    el('cat-publication-generate').addEventListener('click', generatePublicationCandidates);
    el('cat-abbreviation-form').addEventListener('submit', function (event) {
      event.preventDefault();
      return post('abbreviation-register', { full_form: el('cat-abbreviation-full').value, abbreviation: el('cat-abbreviation-short').value, meaning: el('cat-abbreviation-meaning').value, scope: 'document', first_use_rule: el('cat-abbreviation-first').value, abbreviation_registry_hash: String(project.abbreviation_registry_hash || '') }, true).then(function (data) {
        project = data;
        el('cat-abbreviation-form').reset(); publicationCandidateSet = null; el('cat-publication-candidates').innerHTML = ''; el('cat-publication-status').textContent = '略語を承認しました。候補を作り直すと使用できます。';
      }).catch(function (error) { el('cat-publication-status').textContent = error.message; });
    });
    el('cat-publication-candidates').addEventListener('change', function (event) {
      var checkbox = event.target.closest('[data-publication-reviewed]'); if (!checkbox) return;
      var candidateId = checkbox.getAttribute('data-publication-reviewed') || '';
      var button = Array.prototype.find.call(el('cat-publication-candidates').querySelectorAll('[data-publication-apply]'), function (item) { return item.getAttribute('data-publication-apply') === candidateId; });
      if (button) button.disabled = !checkbox.checked;
    });
    el('cat-publication-candidates').addEventListener('click', function (event) {
      var button = event.target.closest('[data-publication-apply]'); if (button && !button.disabled) applyPublicationCandidate(button.getAttribute('data-publication-apply'));
    });
    el('cat-source-update-open').addEventListener('click', function () { el('cat-source-update-file').value='';el('cat-source-update-file').click(); });
    el('cat-source-update-file').addEventListener('change', function () { var file=this.files&&this.files[0];if(file)startSourceUpdate(file); });
    el('cat-source-update-close').addEventListener('click', function () { el('cat-source-update-dialog').close(); });
    el('cat-source-update-apply').addEventListener('click', applySourceUpdate);
    el('cat-preview-dialog').addEventListener('close', function () {
      clearPreviewPdfState();
    });
    el('cat-export-qa').addEventListener('click', openQaList);
    el('cat-export-final-review').addEventListener('change', function () {
      var box = this; el('cat-export-final-reason').disabled = !box.checked; if (!box.checked) return;
      var scope = currentScope(); if (!scope) { box.checked = false; el('cat-export-final-reason').disabled = true; return; }
      post('final-review-readiness', { render_id: previewRenderId || '' }, false, scope).then(function (readiness) {
        if (!readiness.complete) {
          box.checked = false; el('cat-export-final-reason').disabled = true; el('cat-export-qa').hidden = false;
          status('確認記録を残す前に、1. 機械比較、2. Copilot確認、表示された範囲の人による確認、ExcelではPDFの目視確認を完了してください。「点検一覧を開く」から続けられます。', true);
          return;
        }
        YakuCommon.focus(el('cat-export-final-reason'));
      }).catch(function (error) { box.checked = false; el('cat-export-final-reason').disabled = true; status(error.message, true); });
    });
    el('cat-export-confirm').addEventListener('click', function (event) { if (el('cat-export-final-review').checked && !String(el('cat-export-final-reason').value || '').trim()) { event.preventDefault(); status('確認記録を残す場合は、確認した内容や判断理由を入力してください。', true); YakuCommon.focus(el('cat-export-final-reason')); } });
    el('cat-danger-zone').addEventListener('toggle', function () { if (this.open) loadPersonalGlossary(); });
    /* 右の参考情報は畳める。閉じると、原文と訳文が右端まで使う。次に開いたときも
       同じ状態にする（市販CATでもペインの開閉は覚える）。 */
    (function () {
      var toggle = el('cat-inspector-toggle'), layout = el('cat-editor-layout');
      if (!toggle || !layout) return;
      function apply(hidden) {
        layout.classList.toggle('is-inspector-hidden', hidden);
        toggle.setAttribute('aria-expanded', String(!hidden));
        toggle.textContent = hidden ? '参考情報を出す' : '参考情報を隠す';
        try { window.localStorage.setItem('yaku-cat-inspector-hidden', hidden ? '1' : '0'); } catch (_) {}
      }
      var stored = '0';
      try { stored = window.localStorage.getItem('yaku-cat-inspector-hidden') || '0'; } catch (_) {}
      apply(stored === '1');
      toggle.addEventListener('click', function () { apply(!layout.classList.contains('is-inspector-hidden')); });
    })();
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
      if (busy && (button.id === 'cat-confirm-bulk' || button.id === 'cat-tm-pretranslate' || button.hasAttribute('data-cat-translate-row') || button.hasAttribute('data-cat-confirm') || button.hasAttribute('data-cat-unconfirm') || button.hasAttribute('data-cat-tm-register') || button.hasAttribute('data-cat-revert') || button.hasAttribute('data-cat-merge') || button.hasAttribute('data-cat-split') || button.hasAttribute('data-cat-glossary') || button.hasAttribute('data-cat-insert') || button.hasAttribute('data-cat-term-open') || button.hasAttribute('data-cat-term-insert') || button.hasAttribute('data-cat-term-edit') || button.hasAttribute('data-cat-term-deactivate') || button.hasAttribute('data-cat-term-exception') || button.hasAttribute('data-cat-tm-delete') || button.hasAttribute('data-cat-accept-revision') || button.hasAttribute('data-cat-revert-revision'))) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
      if (button.hasAttribute('data-cat-preview-mode')) { setPreviewMode(button.getAttribute('data-cat-preview-mode')); return; }
      if (button.hasAttribute('data-cat-preview-side')) { previewSide = button.getAttribute('data-cat-preview-side') || 'target'; renderPreview(); return; }
      if (button.hasAttribute('data-cat-pdf-side')) {
        var pdfSide = button.getAttribute('data-cat-pdf-side') || 'target';
        if (previewRenderId) showRenderedPdf(previewRenderId, pdfSide).catch(function (error) { el('cat-preview-pdf-status').textContent = error.message; });
        else { previewPdfSide = pdfSide; document.querySelectorAll('[data-cat-pdf-side]').forEach(function (item) { item.setAttribute('aria-pressed', String(item === button)); }); }
        return;
      }
      if (button.hasAttribute('data-cat-placement-edit')) { return openPlacementEditor(button.getAttribute('data-cat-placement-edit')); }
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
      if (button.hasAttribute('data-cat-inspector')) { inspectorTab = button.getAttribute('data-cat-inspector') || 'candidates'; renderInspector(); return; }
      if (button.hasAttribute('data-yaku-cancel-job')) {
        if (!window.confirm('翻訳をやめますか？\n\nここまでにできあがった訳文は保存されています。\nあとで「訳していない行を訳す」を押すと、続きから再開できます。')) return;
        button.disabled = true; button.textContent = 'やめています…';
        return YakuCommon.post('/api/cancel-translation', { job_id: button.getAttribute('data-yaku-cancel-job') })
          .catch(function (error) { status(error.message, true); });
      }
      if (button.hasAttribute('data-cat-personal-remove')) return removePersonalGlossary(button);
      if (button.hasAttribute('data-cat-resume')) return resume(button.getAttribute('data-cat-resume'));
      if (button.id === 'cat-confirm-bulk') return confirmBulk(button);
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
        revertInput.value = revertInput.getAttribute('data-original') || '';
        revertInput.dispatchEvent(new Event('input', { bubbles: true }));
        YakuCommon.focus(revertInput);
        return commit(revertInput).then(function () { status('この行を開いたときの訳文に戻しました。'); });
      }
      if (button.hasAttribute('data-cat-copy-source')) { return copySourceToTarget(Number(button.getAttribute('data-cat-copy-source'))); }
      if (button.hasAttribute('data-cat-copy-target')) { return copyRowTarget(Number(button.getAttribute('data-cat-copy-target'))); }
      if (button.hasAttribute('data-cat-translate-row')) { return translateRow(Number(button.getAttribute('data-cat-translate-row'))); }
      if (button.hasAttribute('data-cat-merge')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('この行と次の行をつなげて1文にします。\n\n両方の行に入っている訳文は消えます。消えた訳文は元に戻せません。\n\nつなげますか？')) return; return mutate('merge', { index: Number(button.getAttribute('data-cat-merge')) }, '行をつなげています…'); }
      if (button.hasAttribute('data-cat-split')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('つなげた行を元の2行に戻します。\n\nこの行に入っている訳文は消えます。消えた訳文は元に戻せません。\n\n戻しますか？')) return; return mutate('split', { index: Number(button.getAttribute('data-cat-split')) }, 'つなげた行を元に戻しています…'); }
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
      if (button.hasAttribute('data-cat-accept-revision')) return acceptRevisionComparison();
      if (button.hasAttribute('data-cat-revert-revision')) return revertRevisionComparison();
    });
    document.addEventListener('input', function (event) {
      if (!event.target.hasAttribute('data-cat-input')) return;
      var index = Number(event.target.getAttribute('data-cat-input')); dirty.set(dirtyKey(event.target.getAttribute('data-cat-project-id'), index), true); event.target.closest('[data-cat-row]').classList.add('cat-dirty');
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
    document.addEventListener('mousedown', function (event) { if (event.target.closest('[data-cat-insert],[data-cat-term-insert]')) event.preventDefault(); });
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
    document.addEventListener('focusout', function (event) { if (event.target.hasAttribute('data-cat-input')) commit(event.target).catch(function () {}); });
    document.addEventListener('focusin', function (event) { var input = event.target.closest('[data-cat-input]'); if (input) { activeIndex = Number(input.getAttribute('data-cat-input')); var row = input.closest('[data-cat-row]'); activeSegmentId = row ? String(row.getAttribute('data-cat-segment-id') || '') : activeSegmentId; renderInspector(); } });
    document.addEventListener('submit', function (event) {
      if (event.target.id === 'cat-concordance-form') { event.preventDefault(); runConcordance(); return; }
      if (event.target.id === 'cat-term-form') { event.preventDefault(); if (!busy) saveTerm(); return; }
      if (event.target.id === 'cat-term-exception-form') { event.preventDefault(); if (!busy) saveTermException(); return; }
      var form = event.target.closest('[data-cat-revise]'); if (form) { event.preventDefault(); if (busy) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; } revise(form); }
    });
    document.addEventListener('keydown', function (event) {
      if (event.isComposing) return;
      var input = event.target.closest && event.target.closest('[data-cat-input]');
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') { event.preventDefault(); YakuCommon.focus(el('cat-search')); el('cat-search').select(); return; }
      /* 点検一覧。Trados の検証（F8）に合わせる。 */
      if (event.key === 'F8' && !el('cat-workspace').hidden) { event.preventDefault(); openQaList(); return; }
      /* 資料の切り替え。作業画面から離れずに開く。 */
      if (event.key === 'F7' && !el('cat-workspace').hidden) { event.preventDefault(); openDocDialog(); return; }
      /* 資料一覧の開閉。Crowdin と同じ Ctrl+[ に合わせる。 */
      if ((event.ctrlKey || event.metaKey) && event.key === '[' && !el('cat-workspace').hidden) {
        event.preventDefault();
        applyDocsPane(!el('cat-editor-layout').classList.contains('is-docs-open'), true);
        return;
      }
      /* 過去訳を言葉で探す。memoQ / Trados もコンコーダンスに専用キーを割いている。 */
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault();
        var concordanceInput = el('cat-concordance-input');
        if (concordanceInput) {
          var selected = String(window.getSelection ? window.getSelection().toString() : '').trim();
          if (selected) concordanceInput.value = selected;
          YakuCommon.focus(concordanceInput); concordanceInput.select();
          if (selected) runConcordance();
        }
        return;
      }
      if (event.altKey && !event.ctrlKey && !event.metaKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) { event.preventDefault(); if (!busy) moveActive(event.key === 'ArrowUp' ? -1 : 1); return; }
      if (event.key === 'Escape' && (el('cat-search') === document.activeElement || event.target.closest('#cat-inspector-pane'))) { event.preventDefault(); focusActive(); return; }
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
      if (event.altKey && !event.ctrlKey && !event.metaKey && (event.key.toLowerCase() === 'm' || event.key.toLowerCase() === 'k')) {
        event.preventDefault();
        var joinButton = document.querySelector('[data-cat-' + (event.key.toLowerCase() === 'm' ? 'merge' : 'split') + '="' + activeIndex + '"]');
        if (joinButton) { joinButton.click(); }
        else { status(event.key.toLowerCase() === 'm' ? 'この行は次の行とつなげられません。' : 'この行は分けられません。'); }
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
      var picks = document.querySelectorAll('#cat-terms-list [data-cat-term-insert], #cat-candidates-list [data-cat-insert]');
      var pick = picks[Number(event.key) - 1];
      if (pick) { if (pick.hasAttribute('data-cat-term-insert')) insertTerm(pick); else insertReference(pick); }
    });
    el('cat-search').addEventListener('input', redrawAfterFlush);
    document.querySelector('[data-cat-term-cancel]').addEventListener('click', function () { el('cat-term-dialog').close(); });
    document.querySelector('[data-cat-term-exception-cancel]').addEventListener('click', function () { el('cat-term-exception-dialog').close(); });
    el('cat-next-qc').addEventListener('click', goToNextQc);
    el('cat-copy-again').addEventListener('click', function () { YakuCommon.copyText(el('cat-text-output-value').value, el('cat-text-output-value'), el('cat-status')); });
    el('cat-text-output-close').addEventListener('click', closeTextOutput);
    el('cat-select-all').addEventListener('click', function () { el('cat-text-output-value').focus(); el('cat-text-output-value').select(); status('全文を選択しました。Ctrl+Cでコピーできます。'); });
    el('cat-open-folder').addEventListener('click', function () { if (!outputScope || !project || outputScope.id !== String(project.id || '')) { status('この作業の出力をもう一度作成してください。', true); return; } YakuCommon.post('/api/open-output', { project_id: outputScope.id }).then(function () { status('フォルダを開きました。'); }).catch(function (error) { status(error.message, true); }); });
    el('cat-delete').addEventListener('click', function () {
      if (busy || !project) return;
      flush().then(function () {
        deleteTarget = currentScope(); if (!deleteTarget) return;
        deleteTarget.name = project.file_name || 'この翻訳作業'; el('cat-delete-name').textContent = deleteTarget.name;
        var dialog = el('cat-delete-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
      }).catch(function (error) { status(error.message, true); });
    });
    el('cat-export-dialog').addEventListener('close', function () {
      var scope = preflightScope; preflightScope = null;
      if (this.returnValue !== 'export' || !scope) return;
      if (!scopeIsCurrent(scope, true)) { status('出力前の確認後に作業内容が変わったため、もう一度確認してください。', true); return; }
      exportProject();
    });
    el('cat-delete-dialog').addEventListener('close', function () {
      var target = deleteTarget; deleteTarget = null;
      if (this.returnValue !== 'delete' || !target) return;
      /* 一覧から消すときは、その作業を開いていない。開いている作業を消すときだけ
         「表示中のものと同じか」を確かめる。 */
      if (!target.fromList && !scopeIsCurrent(target, true)) { status('表示中の作業が変わったため、削除を中止しました。'); return; }
      setBusy(true); status('作業を消しています…');
      var selectedMemory=document.querySelector('input[name="cat-delete-memory"]:checked');
      post('delete', { id: target.id, memory_policy: selectedMemory ? selectedMemory.value : 'retain_tm', client_id: YakuCommon.clientId() }, true, target).then(function () {
        setBusy(false);
        if (target.fromList) { loadRecent(); status(target.name + ' を一覧から消しました。元のファイルは残っています。'); return; }
        if (!project || String(project.id || '') !== target.id) return;
        showPicker(); status('翻訳作業と途中保存を消しました。元のファイルは残っています。');
      }).catch(function (error) { setBusy(false); if (target.fromList || (project && String(project.id || '') === target.id)) status(error.message, true); });
    });
    el('cat-resume-more').addEventListener('click', function () {
      resumeExpanded = !resumeExpanded;
      renderRecent();
      if (!resumeExpanded) YakuCommon.focus(el('cat-resume-more'));
    });
    /* 一覧のその場で消す。押した瞬間に消さず、同じ確認の窓を通す。 */
    el('cat-resume-list').addEventListener('click', function (event) {
      var drop = event.target.closest('[data-cat-resume-drop]');
      if (!drop || busy) return;
      event.preventDefault(); event.stopPropagation();
      deleteTarget = { id: drop.getAttribute('data-cat-resume-drop'), revision: Number(drop.getAttribute('data-cat-resume-revision')) || 0, name: drop.getAttribute('data-cat-resume-name') || 'この作業', fromList: true };
      el('cat-delete-name').textContent = deleteTarget.name;
      var dialog = el('cat-delete-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
    });
  }
  /* 貼り付け欄は最初の画面の中にある（cat.html）。中身は quick.js が持つ。
     状態としては出し入れしないので、ここで受けるのは「最初の画面へ戻して
     入力欄を使えるようにする」ことだけ。 */
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
      var filePath = String(detail.filePath || '');
      if (filePath) {
        showPicker();
        el('cat-file-input').value = '';
        el('cat-path').value = filePath;
        openSource('file', 'auto');
        return;
      }
      var text = String(detail.text || '');
      if (!text.trim()) return;
      /* 先に選ぶ画面へ戻してから始める。訳す向きを聞き返されたときの二択は
         選ぶ画面の中に居るので、隠したままだと行き止まりになる。 */
      showPicker();
      el('cat-text').value = text;
      openSource('text', 'auto');
    });
  }
  function start() {
    YakuCommon.start(); YakuCommon.onReady(function (value) { ready = value; setBusy(busy); }); bind(); bindInstant(); loadRecent();
    /* 旧URLの /quick も同じ画面を返す。showPicker() がアドレスを /cat へ
       書き換えるので、判定は先に取っておく。 */
    var cameFromInstant = location.pathname === '/quick';
    var params = new URLSearchParams(location.search);
    var wanted = params.get('project');
    if (wanted) {
      var autoTranslate = params.get('translate') === '1';
      resume(wanted).then(function () { if (autoTranslate) translateWhenReady(); });
      return;
    }
    showPicker();
    /* ?import=1 で開いたときは、過去の対訳の取り込み欄をそのまま出す。
       この画面だけ WebAssembly が使える（PDF の解析に要る）。 */
    var importMeta = document.querySelector('meta[name="yaku-import"]');
    if (importMeta && importMeta.getAttribute('content') === '1') { showStart('align'); return; }
    if (cameFromInstant && window.YakuInstant) window.YakuInstant.show();
  }
  window.YakuCat = { isBusy: function () { return busy; } };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
