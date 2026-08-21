(function () {
  'use strict';
  /* パレット(/palette)の昇格(「CATで開く」)が使う、移動の直前だけの
     sessionStorage退避キー。quick.js の draftStorageKey と同じ流儀
     （作業や翻訳メモリには保存せず、読まれれば消える）。palette.js と
     同じ文字列を持つ。 */
  var paletteHandoffStorageKey = 'yaku.palette.handoff';
  var ready = false, busy = false, project = null, pendingDirection = null, uploaded = null, directFilePath = '';
  var dirty = new Map(), saveChain = Promise.resolve(), jobTimer = null, jobContext = null, candidateSeq = 0;
  var deleteTarget = null, preflightScope = null, jobSerial = 0, viewEpoch = 0, outputScope = null;
  var fileLoadingOwner = 0;
  var activeSegmentId = '', activeIndex = -1, currentFilter = 'actionable', currentLocation = 'all', currentChange = 'all', inspectorTab = 'candidates';
  /* 作業メモの入力途中はサーバへ送らない。行や資料を切り替えても、別の行へ
     誤登録しないよう、保存先の資料IDとsegment_idをキーにして画面内だけで保持する。 */
  var reviewNoteDrafts = {};
  /* 検索の掛け方。市販CAT（memoQ / Phrase / Trados / XTM）はどれも「どこを探すか」
     「大文字小文字を区別するか」「正規表現か」を持っている。ここまでは原文・訳文・
     場所を連結した小文字化部分一致1本だけで、絞りようが無かった。 */
  var searchScope = 'both', searchCase = false, searchRegex = false;
  var revisionComparison = null;
  var publicationJobId = '', publicationCandidateSet = null;
  /* 「まとめて収める」の先回りキャッシュと、そのページ内寿命の根拠。
     実装前調査（2026-08-19）: サーバ側に candidate_set を project／segment
     単位で残す仕組みは無い。job テーブルは job_id だけの索引で in-memory
     （src/Server.ps1:18 `[hashtable]::Synchronized(@{})`）、既定30分で失効し
     （:21 `$script:YakuTranslateJobRetentionMinutes = 30`）、件数での保護も
     無効（:22 `$script:YakuTranslateJobKeepCompleted = 0`）、起動時に
     jobsディレクトリから復元する処理も無い（再起動で全消去）。
     publication-apply（:3134-3151）も project にではなく、渡された job_id で
     job テーブルから candidate_set を引く。CatProject.ps1・Publication.ps1にも
     project 側に candidate_set を持たせるフィールドは無い。
     つまりこのキャッシュは「サーバ側にある仕組みの二重持ち」ではなく、無い
     ものをページ表示中だけ補う最小限のものである。キーは segment_id、値は
     {jobId, candidateSet, revisionAtGeneration, translationAtGeneration}。
     保存・再読み込み・タブを閉じる・再起動のどれでも消える（保存しない）。
     読むときは訳文が生成時から変わっていないかだけ見る（fitBatchCacheEntry）。
     最終権威はサーバ側 publication-apply の dependency_fingerprint／
     candidate_text_hash であり、ここは表示を早めるだけ。

     この訳文一致は鮮度の必要条件であって十分条件ではない（CoD審査 REWORK-1
     MEDIUM-M2）。サーバの dependency_fingerprint（Publication.ps1:65）は
     このセグメントの訳文だけでなく、前後の行の原文・訳文（:73-76の
     surrounding_context）・用語スナップショット（Project.TerminologySnapshotHash）・
     略語登録台帳のハッシュ（Get-YakuCatAbbreviationRegistryHash）も畳み込む。
     つまり、この行自体を編集していなくても、隣の行（i±1）を編集した・
     略語を承認した・用語が変わった、だけでキャッシュは古くなり得るが、
     ここではそれを検知できない（隣接行やproject全体の変化まで見に行くのは
     過剰な仕組みになる）。実害は無い: 古いキャッシュを適用しようとすると
     publication-apply が dependency_fingerprint の不一致で
     CAT_PUBLICATION_CANDIDATE_STALE を返し（Publication.ps1:215-221、
     humanMessage が人向け文へ直す）、applyPublicationCandidate の失敗経路が
     キャッシュを消して「作り直す」へ導く。**サーバの再検査が最終権威であり、
     ここが見逃しても必ず回復できる。** */
  var fitBatchCandidateCache = {};
  var fitBatchQueue = null;
  var pendingMutationKeys = {};
  var projectLeaseSequence = 0, projectLeaseId = '', projectLeaseTimer = null;
  var termSelection = { index: -1, source: '', target: '' };
  var candidateDetailItems = [], candidateDetailSource = '', candidateDetailIndex = -1;
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
  function clearCandidateDetail(message) {
    candidateDetailItems = [];
    candidateDetailSource = '';
    candidateDetailIndex = -1;
    candidateDetailRequestIndex = -1;
    candidateDetailRequestProjectId = '';
    candidateDetailRequestRevision = -1;
    document.querySelectorAll('[data-cat-candidate-index]').forEach(function (node) {
      node.setAttribute('aria-selected', 'false');
      node.classList.remove('is-selected');
    });
    var heading = el('cat-candidate-detail-title'), subtitle = el('cat-candidate-detail-subtitle'), diff = el('cat-candidate-detail-diff'), meta = el('cat-candidate-detail-meta'), actions = el('cat-candidate-detail-actions');
    if (heading) heading.textContent = '翻訳メモリ一致';
    if (subtitle) subtitle.textContent = '原文との差';
    if (diff) diff.textContent = message || '候補を読み込んでいます…';
    if (meta) meta.innerHTML = '';
    if (actions) actions.innerHTML = '';
  }
  function renderCandidateDetail(item, index) {
    var heading = el('cat-candidate-detail-title'), subtitle = el('cat-candidate-detail-subtitle'), diff = el('cat-candidate-detail-diff'), meta = el('cat-candidate-detail-meta'), actions = el('cat-candidate-detail-actions');
    if (!heading || !subtitle || !diff || !meta) return;
    candidateDetailIndex = item ? Number(index) : -1;
    if (!item) {
      heading.textContent = '翻訳メモリ一致'; subtitle.textContent = '原文との差'; diff.textContent = '候補を選ぶと差分が出ます。'; meta.innerHTML = ''; if (actions) actions.innerHTML = ''; return;
    }
    var isPrior = String(item.kind || '') === 'prior';
    heading.textContent = isPrior ? '前回資料の一致' : '翻訳メモリ一致';
    subtitle.textContent = '原文との差';
    var candidateSource = String(item.source || '');
    var currentSource = String(candidateDetailSource || (activeSegment() && activeSegment().source) || '');
    diff.setAttribute('aria-label', '原文との差分');
    diff.innerHTML = diffMarkup(candidateSource, currentSource) || '<span class="muted">原文がありません。</span>';
    var material = item.source_name || item.database || item.material;
    var location = item.location || item.page;
    var fields = [];
    if (material) fields.push('<div><dt>翻訳メモリ</dt><dd>' + esc(material) + '</dd></div>');
    if (item.saved) fields.push('<div><dt>確認日</dt><dd>' + esc(savedLabel(item.saved) || String(item.saved).slice(0, 10)) + '</dd></div>');
    if (location) fields.push('<div><dt>場所</dt><dd>' + esc(Number(item.page) > 0 && !item.location ? 'ページ ' + Number(item.page) : location) + '</dd></div>');
    meta.innerHTML = fields.join('');
    if (actions) {
      var requestScope = currentScope();
      var segment = activeSegment();
      var referenceId = String(item.reference_id || '');
      var translation = item.translation != null ? String(item.translation) : String(item.target || '');
      if (!requestScope || !segment || !referenceId) {
        actions.innerHTML = '<p class="muted">この候補は現在利用できません。</p>';
      } else {
        var segmentIndex = Number(segment.index);
        var forget = isPrior ? '' : '<button type="button" class="secondary-button" data-cat-tm-delete="' + esc(referenceId) + '" data-cat-index="' + segmentIndex + '">この候補を今後は出さない</button>';
        actions.innerHTML = '<button type="button" class="cat-candidate-detail-insert" data-cat-insert="' + esc(translation) + '" data-cat-reference-id="' + esc(referenceId) + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + segmentIndex + '">この訳を挿入</button>' + forget;
      }
    }
  }
  function selectCandidateDetail(index) {
    var item = candidateDetailItems[Number(index)];
    if (!item) return;
    candidateDetailIndex = Number(index);
    document.querySelectorAll('[data-cat-candidate-index]').forEach(function (node) {
      var selected = Number(node.getAttribute('data-cat-candidate-index')) === candidateDetailIndex;
      node.setAttribute('aria-selected', String(selected));
      node.classList.toggle('is-selected', selected);
    });
    renderCandidateDetail(item, candidateDetailIndex);
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
    /* CAT_PUBLICATION_CANDIDATE_STALE はサーバの生コードがそのまま返る
       （throw に本文が無く、Convert-YakuExceptionToUserMessage の
       「コード: 本文」変換[src/Server.ps1:433]は本文の無いコードには効かない）。
       「まとめて収める」のキャッシュ（fitBatchCandidateCache）はこの経路を
       大幅に踏みやすくした（生成後に依存関係が変わっていれば必ずここへ来る）
       ので、ここで人向け文へ直す（CoD審査 REWORK-1 MEDIUM-M2b）。 */
    if (raw === 'CAT_PUBLICATION_CANDIDATE_STALE') {
      return '内容が変わったため、この候補は使えません。作り直してください。';
    }
    /* ジョブは完了から30分でサーバが破棄する（メモリ内ジョブ表、restart でも消える）。
       キャッシュした候補を30分後に適用しようとすると、この2コードが本文無しで
       そのまま届く（CoD審査 ROUND-2 備考N1）。どちらも「作り直す」で復旧できる。 */
    if (raw === 'CAT_PUBLICATION_JOB_NOT_FOUND' || raw === 'CAT_PUBLICATION_JOB_NOT_COMPLETE') {
      return '候補の作成結果が残っていません（時間が経つと消えます）。作り直してください。';
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
  function syncLocation(projectId, preserveImport, preserveWork) {
    try {
      var next = projectId ? ('/cat?project=' + encodeURIComponent(projectId)) : (preserveImport ? '/cat?import=1' : preserveWork ? '/cat?view=work' : '/cat');
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
  function showPicker(preserveImport, preserveWork) { if(project) reportProjectLease('closed'); syncLocation('', !!preserveImport, !!preserveWork); viewEpoch++; candidateSeq++; project = null; activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; resetSearchTools(); termSelection = { index: -1, source: '', target: '' }; dirty.clear(); directFilePath = ''; clearOutputDisplay(); document.body.removeAttribute('data-cat-source'); document.title = '翻訳 - YakuLingo'; el('cat-page-title').textContent = '翻訳'; setView('start'); el('cat-picker').hidden = false; el('cat-workspace').hidden = true; el('cat-current-summary').hidden = true; closeStartPanels(); loadRecent(); }
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
    /* 貼り付け側の主ボタンは quick.js が持ち場を持っている（文章の有無・翻訳先・
       準備状況で押せるかどうかを決める）。ここで一律に触ると、文章が空でも
       押せる状態に戻ってしまう。実測 2026-08-16: 起動直後の #quick-submit は
       ラベルが空欄の操作指示なのに disabled=false だった。 */
    if (button.id === 'quick-submit') return true;
    if (button.hasAttribute('data-cat-filter') || button.hasAttribute('data-cat-location') ||
        button.hasAttribute('data-cat-change') || button.hasAttribute('data-cat-inspector')) return true;
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
      document.querySelectorAll('[data-cat-filter],[data-cat-location],[data-cat-change],[data-cat-inspector]').forEach(function (button) { button.disabled = false; });
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

  function renderRecent() {
    var list = el('cat-resume-list');
    var more = el('cat-resume-more');
    var shown = resumeExpanded ? resumeItems : resumeItems.slice(0, RESUME_VISIBLE);
    list.innerHTML = shown.map(function (item, i) {
      var name = esc(documentDisplayName(item));
      var saved = savedLabel(item.saved);
      /* 左のレールへ移したので、1件目の「前回開いた作業」の札は外した
         （2026-08-16）。並びは新しい順で、1件目は必ずいちばん上にあり、
         保存時刻もカードの中に出ている。向きは記号で足りる（ツールバーと同じ）。 */
      /* 資料名・進み具合・日時は性質が違うので、1本の「・」で繋がない
         （2026-08-16、利用者の指摘「レールの1件が読みにくい」）。
         実測 1912x987 では 3件とも資料名が2行に折り返し、どこまでが
         ファイル名なのかが読み取れなかった。資料名だけを1行目に置いて
         溢れは「…」で切り、向き・残り・日時は2行目へまとめる。 */
      var meta = documentMeta(item, false).map(esc);
      return '<div class="cat-resume-row">' +
        '<button type="button" class="cat-resume-card secondary-button" data-cat-resume="' + esc(item.id) + '">' +
        '<span class="cat-resume-name">' + name + '</span>' +
        '<span class="cat-resume-time">' + meta.join('・') + '</span>' + '</button>' +
        '<button type="button" class="cat-resume-drop link-button" data-cat-resume-drop="' + esc(item.id) + '" data-cat-resume-revision="' + (Number(item.revision) || 0) + '" data-cat-resume-name="' + name + '" title="この作業を一覧から消す" aria-label="' + name + ' の作業を消す">消す</button>' +
        '</div>';
    }).join('');
    var hiddenCount = resumeItems.length - RESUME_VISIBLE;
    more.hidden = hiddenCount <= 0;
    more.textContent = resumeExpanded ? '3件だけ表示' : ('ほかに' + hiddenCount + '件');
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
      /* /recent は一覧を読むだけの経路であり、表示名を作るために各資料を
         resume してはいけない。resume は作業状態を開く操作なので、一覧を
         開いただけで現在の資料やロック状態を変えてしまう（2026-08-17）。
         API が読み取り専用の source_preview を返す場合だけ使い、無い資料は
         保存時刻を見出しにする。現在開いている資料だけは、既に画面にある
         segments から原文を使える。 */
      var fallbackNames = {}, previewNames = {};
      items.forEach(function (item) {
        if (!isGenericPastedName(item.file_name) || item.display_name) return;
        var preview = shortDocumentPreview(item.source_preview || item.source_text || item.first_source || item.preview);
        if (!preview && project && String(project.id || '') === String(item.id || '')) preview = firstDocumentSource(project);
        if (preview) {
          var previewKey = preview, previewCount = (previewNames[previewKey] || 0) + 1;
          previewNames[previewKey] = previewCount;
          item.display_name = previewCount === 1 ? preview : previewCount + ': ' + preview;
          return;
        }
        var saved = savedLabel(item.saved), base = '貼り付け' + (saved ? ' ' + saved : ''), candidate = base;
        var suffix = String(item.id || '').slice(-6);
        if (fallbackNames[base]) candidate = base + (suffix ? '・' + suffix : '・' + (fallbackNames[base] + 1));
        fallbackNames[base] = (fallbackNames[base] || 0) + 1;
        item.display_name = candidate;
      });
      ++resumePreviewSeq;
      renderRecent();
      return Promise.resolve();
    }).catch(function (error) { el('cat-resume').hidden = false; el('cat-resume-list').innerHTML = '<div class="alert alert-error">途中まで進めた作業の一覧を読み込めませんでした。画面を読み込み直してください（Ctrl+R）。' + esc(error.message) + '</div>'; });
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
    };
    return qcFindingViews(segment).map(function (view) { return labels[view.code] || '自動点検で気になる点が見つかりました。左の原文と見比べてください。'; });
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
  var QC_WARNING_CODES = ['numeric-value-mismatch', 'numeric-value-extra', 'numeric-value-order-mismatch', 'numeric-sign-missing', 'numeric-scale-mismatch', 'currency-mismatch', 'accounting-polarity-mismatch', 'label-not-in-glossary', 'paired-delimiter-mismatch'];
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
  function segmentState(segment) { return segment.status || segment.state || (segment.translation ? 'machine_draft' : 'untranslated'); }
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
  function syncReviewNoteFormState(hasSegment) {
    var input = el('cat-review-notes-input'), submit = el('cat-review-notes-submit');
    if (input) input.disabled = busy || !hasSegment;
    if (submit) submit.disabled = busy || !hasSegment;
  }
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
    /* 収まらない見込み（収まりの見える化）。書き出しは止めない。知らせるだけ。 */
    fit: function (segment) { return segmentFitRiskInfo(segment).risk; },
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
    ['qc','repetition','review_notes','fit'].forEach(function (name) {
      var button = document.querySelector('[data-cat-filter="' + name + '"]');
      if (!button) return;
      button.hidden = Number(counts[name] || 0) < 1;
      if (button.hidden && currentFilter === name) currentFilter = 'actionable';
    });
  }
  function renderInspector() {
    /* 選択が動いたら、常設の体裁の印も動かす。ここは行を移るたびに通る唯一の
       場所なので、追随の入口をここに置く。組み直しはしない（印の付け替えだけ）。 */
    if (candidateDetailRequestIndex >= 0 && Number(activeIndex) !== Number(candidateDetailRequestIndex)) clearCandidateDetail('候補を読み込んでいます…');
    syncDockActive(false);
    var segment = activeSegment(), all = project.segments || [];
    document.querySelectorAll('[data-cat-inspector]').forEach(function (button) { var selected = button.getAttribute('data-cat-inspector') === inspectorTab; button.setAttribute('aria-selected', String(selected)); });
    var inspectorPanels = { candidates: 'candidates', concordance: 'concordance', revisions: 'revisions', qc: 'qc', context: 'context', review_notes: 'review-notes', preview: 'preview' };
    Object.keys(inspectorPanels).forEach(function (name) { el('cat-panel-' + inspectorPanels[name]).hidden = name !== inspectorTab; });
    if (!segment) {
      el('cat-qc-count').textContent = '0'; el('cat-qc-list').innerHTML = '<p class="muted">行を選ぶと、その行の点検結果が出ます。</p>'; el('cat-context').innerHTML = '<p class="muted">行を選ぶと、資料のどこにある文かが分かります。</p>';
      el('cat-review-notes-count').textContent = '0'; el('cat-review-notes-list').innerHTML = '<p class="muted">行を選ぶと、その行の作業メモが出ます。</p>'; syncReviewNoteFormState(false);
      el('cat-revisions-list').innerHTML = '<p class="muted">行を選ぶと、その行の変更を確認できます。</p>';
      var emptyNoteInput = el('cat-review-notes-input'); if (emptyNoteInput) emptyNoteInput.value = '';
      syncDockHeightForContent();
      return;
    }
    var reviewNotes = reviewNotesOf(segment), openReviewNotes = unresolvedReviewNotes(segment);
    el('cat-review-notes-count').textContent = String(openReviewNotes.length);
    el('cat-review-notes-list').innerHTML = reviewNotes.length ? reviewNotes.map(function (note) {
      var resolved = String(note.state || '') === 'resolved', nextState = resolved ? 'open' : 'resolved';
      return '<article class="cat-review-note' + (resolved ? ' is-resolved' : '') + '">' +
        '<div class="cat-review-note-head"><span class="cat-review-note-state">' + reviewNoteStateLabel(note) + '</span><time class="cat-review-note-time" datetime="' + esc(note.created_at || '') + '">' + esc(reviewNoteCreatedLabel(note)) + '</time></div>' +
        '<p class="cat-review-note-text">' + esc(note.text || '') + '</p>' +
        '<div class="cat-review-note-actions"><button type="button" class="secondary-button" data-cat-review-note-state="' + nextState + '" data-cat-review-note-index="' + Number(segment.index) + '" data-cat-review-note-id="' + esc(note.note_id || '') + '">' + (resolved ? '未解決に戻す' : '解決済みにする') + '</button></div>' +
        '</article>';
    }).join('') : '<p class="muted">この行には作業メモがありません。</p>';
    syncReviewNoteFormState(true);
    var noteInput = el('cat-review-notes-input'); if (noteInput) noteInput.value = reviewNoteDraftFor(segment);
    var revisionIndex = Number(segment.index), revisionHtml = '';
    var hasComparison = revisionComparison && revisionComparison.projectId === String(project.id || '') && Number(revisionComparison.index) === revisionIndex;
    if (hasComparison) {
      revisionHtml += '<section class="cat-revision-compare" aria-labelledby="cat-revision-title-' + revisionIndex + '"><h4 id="cat-revision-title-' + revisionIndex + '">修正結果を確認</h4><div class="cat-revision-pair"><div><strong>変更前</strong><p>' + esc(revisionComparison.before) + '</p></div><div><strong>変更後</strong><p>' + esc(segment.translation || '') + '</p></div></div><p class="muted">数字と単位は自動で点検しました。言い回しが適切かどうかは、ご自身でお確かめください。</p><div class="cat-revision-actions"><button type="button" data-cat-accept-revision="' + revisionIndex + '">この案を使う</button><button type="button" class="secondary-button" data-cat-revert-revision="' + revisionIndex + '">元に戻す</button></div></section>';
    }
    var revisionInput = document.querySelector('[data-cat-input="' + revisionIndex + '"]');
    var undoSnapshot = revisionInput && revisionInput.hasAttribute('data-undo-original') ? revisionInput.getAttribute('data-undo-original') : null;
    var localUndo = !!revisionInput && undoSnapshot !== null && String(revisionInput.value || '') !== String(undoSnapshot || '');
    if (localUndo) {
      revisionHtml += '<section class="cat-revision-local"><h4>この行の変更</h4><p class="muted">保存前の訳文へ戻せます。</p><button type="button" class="secondary-button" data-cat-revert="' + revisionIndex + '">この行の変更を元に戻す</button></section>';
    }
    el('cat-revisions-list').innerHTML = revisionHtml || '<p class="muted">この行には変更履歴がありません。</p>';
    var views = qcFindingViews(segment), findings = qcMessages(segment);
    el('cat-qc-count').textContent = String(findings.length);
    el('cat-qc-list').innerHTML = findings.length ? findings.map(function (message, findingIndex) {
      var view = views[findingIndex] || { code: '', finding: {}, preview: false }, finding = view.finding || {}, code = view.code;
      /* 用語の免除は、その語を「この行では使わない」と決める操作である。
         決めるには、どの語の・どの版の登録を外すのかが要る。写しの点検
         （qc_preview）は種別と重大度しか持たず、用語の詳細が無いので、そもそも
         作れないし、作らない。
         確定を1回通してから決める、という順序をここで守る。 */
      var termAction = (!view.preview && (code === 'terminology-missing' || code === 'terminology-forbidden')) ? '<button type="button" class="secondary-button" data-cat-term-exception="' + Number(segment.index) + '" data-cat-term-id="' + esc(finding.termId || finding.TermId || '') + '" data-cat-term-version="' + Number(finding.termVersion || finding.TermVersion || 0) + '" data-cat-term-source="' + esc(finding.sourceTerm || finding.SourceTerm || '') + '">この行では別の表現を使う</button>' : '';
      return '<div class="cat-qc-card is-' + qcCardGroup(view) + '"' + (view.preview ? ' data-cat-qc-preview="1"' : '') + '><p>' + esc(message) + '</p>' + termAction + '</div>';
    }).join('') : '<div class="cat-qc-card">自動点検では、気になる点は見つかりませんでした。</div>';
    el('cat-next-qc').disabled = !all.some(segmentHasQc);
    var index = Number(segment.index), previous = all.find(function (item) { return Number(item.index) === index - 1; }), next = all.find(function (item) { return Number(item.index) === index + 1; });
    el('cat-context').innerHTML = '<div class="cat-context-card"><span class="cat-context-label">現在の場所</span><p class="cat-context-text">' + esc(segment.location || '本文') + '</p></div>' +
      (segment.prior_source && changeGroup(segment) === 'changed' ? '<div class="cat-context-card"><span class="cat-context-label">前回からの変更</span><p class="cat-context-text"><strong>前回</strong><br>' + esc(segment.prior_source) + '</p><p class="cat-context-text"><strong>今回</strong><br>' + esc(segment.source) + '</p></div>' : '') +
      (previous ? '<div class="cat-context-card"><span class="cat-context-label">前の原文</span><p class="cat-context-text">' + esc(previous.source) + '</p></div>' : '') +
      (next ? '<div class="cat-context-card"><span class="cat-context-label">次の原文</span><p class="cat-context-text">' + esc(next.source) + '</p></div>' : '');
    syncDockHeightForContent();
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
    ['cat-tm-pretranslate', 'cat-preview-dock-toggle', 'cat-preview-open', 'cat-key-help', 'cat-confirm-bulk', 'cat-fit-batch-open'].forEach(function (id) {
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
    var dynamic = host.querySelector(':scope > .cat-segment-actions-dynamic');
    if (!dynamic) {
      dynamic = document.createElement('span');
      dynamic.className = 'cat-segment-actions-dynamic';
      host.insertBefore(dynamic, host.firstChild);
    }
    if (!segment) { dynamic.innerHTML = ''; appendStaticSegmentActions(host); host.hidden = true; return; }
    host.hidden = false;
    var index = Number(segment.index), hasTranslation = String(segment.translation || '').trim().length > 0;
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
    if (segment.prior_source || segment.prior_translation) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-inspector="context" title="前回資料との差を表示" aria-label="前回資料との差を表示">' + segmentActionIcon('i-eye', '前回との差') + '</button>';
    if (qcMessages(segment).length) html += '<button type="button" class="cat-segment-button secondary-button" data-cat-inspector="qc" title="この行の点検結果を表示" aria-label="この行の点検結果を表示">' + segmentActionIcon('i-check', '点検結果') + '</button>';
    /* 収まらない見込みの行から、配置ダイアログを経由せず「収める候補」へ1クリックで
       進む導線（既存の配置ダイアログ＋既存の cat-publication-open を自動で発火する。
       新しいAPIは作らない）。調整できるセル配置（placement.destinations）が無い行は
       openPlacementEditor 自体が断るので、ここでも同じ条件で先に隠す。 */
    if (isFitBatchEligible(segment)) {
      html += '<button type="button" class="cat-segment-button secondary-button" data-cat-fit-candidates="' + index + '" title="収める候補を開く（情報を保って短くする）" aria-label="収める候補を開く">' + segmentActionIcon('i-fit', '収める候補') + '</button>';
    }
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
    ['qc','repetition','review_notes','fit'].forEach(function (name) { optionalFilterCounts[name] = all.filter(stateFilters[name]).length; });
    syncOptionalStateFilters(optionalFilterCounts);
    /* 行を作り直すと、一覧が指していた訳文欄は消える。浮いたままにしない。 */
    closePlaceablePicker();
    clearCandidateDetail('候補を読み込んでいます…');
    candidateSeq++;
    el('cat-candidates').hidden = true;
    chooseInitialActive();
    var shown = visibleSegments(), current = activeSegment();
    renderNavigation(); renderInspector(); renderSearchTools();
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
    /* まとめて収める。数える式は isFitBatchEligible（行の1クリック導線と同じ、
       fitリスクかつ配置計画がある行）で、0件なら隠す（点検の指摘などと同じ扱い）。 */
    var fitBatchButton = el('cat-fit-batch-open');
    if (fitBatchButton) {
      var fitBatchList = fitBatchTargets();
      fitBatchButton.hidden = fitBatchList.length < 1;
      var fitBatchLabel = 'まとめて収める（' + fitBatchList.length + '行）';
      fitBatchButton.title = '収まらない見込みで、配置を調整できる行をまとめて処理し、Copilotで短縮候補を先回りして作ります（適用は行ごとの比較確認のまま）。';
      fitBatchButton.setAttribute('aria-label', fitBatchLabel);
      fitBatchButton.innerHTML = icon('i-fit') + '<span class="cat-segment-button-label">' + esc(fitBatchLabel) + '</span>';
      fitBatchButton.classList.add('cat-segment-button');
    }
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
      var findings = qcMessages(segment), findingId = 'cat-qc-' + index, origin = referenceOriginLabel(segment) || originLabel(segment.origin), ops = '';
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
      /* 収まらない見込み（収まりの見える化）。判定は segmentFitRiskInfo（プレビューの
         印・絞り込みと同じ判定）。書き出しは止めない、知らせるだけ。 */
      var fitInfo = segmentFitRiskInfo(segment);
      /* 訳文欄は全行に置く。押して「開く」段を挟むと、1行直すのに2動作かかる。
         memoQ の表は訳文セルをその場で直す作り（"type or edit the translation in
         the cell on the right"／未確認でも自動保存）で、押して開く段は無い。
         開いている行だけは、下に操作と点検結果を出す。 */
      var blockingError = segmentHasBlockingError(segment);
      var editor = '<textarea rows="1" data-cat-input="' + index + '" data-cat-project-id="' + esc(project.id) + '" data-original="' + esc(segment.translation || '') + '" lang="' + languages.target + '" spellcheck="true" aria-label="' + row + '行目の訳文" aria-invalid="' + (blockingError ? 'true' : 'false') + '"' + (blockingError ? ' aria-describedby="cat-qc-list"' : '') + '>' + esc(segment.translation || '') + '</textarea>';
      var confirmation = segment.confirmed
        ? '<button type="button" class="cat-confirm-control is-confirmed" data-cat-unconfirm="' + index + '" title="確認済み。押すと確認を取り消す（Ctrl+Shift+U）" aria-label="' + row + '行目は確認済み。押すと確認を取り消す（Ctrl+Shift+U）" aria-keyshortcuts="Control+Shift+U"><span class="cat-confirm-mark" aria-hidden="true">✓</span><span>確認済み</span></button>'
        : '<button type="button" class="cat-confirm-control" data-cat-confirm="' + index + '" title="この行を確認済みにする（Ctrl+Enter）" aria-label="' + row + '行目を確認済みにする（Ctrl+Enter）" aria-keyshortcuts="Control+Enter"><span class="cat-confirm-mark" aria-hidden="true">–</span><span>未確認</span></button>';
      /* 行の高さを操作の置き場にしない。行固有の操作は上部の選択行リボンへ
         移し、点検結果・修正比較は下部ドックで表示する。 */
      var extras = '';
      var change = changeLabel(segment), reviewNoteCount = unresolvedReviewNotes(segment).length;
      return '<tr class="' + (isActive ? 'is-active' : '') + '" data-cat-row="' + index + '" data-cat-segment-id="' + esc(segment.segment_id || '') + '" data-cat-confirmed="' + (segment.confirmed ? '1' : '0') + '" data-yaku-cat-state="' + esc(state) + '">' +
        '<td class="cat-col-no"><span class="cat-card-label">行番号・状態</span>' + row + '<span class="cat-state cat-state-' + esc(state) + '" title="' + esc(stateTitle(state)) + '">' + stateIcon(state) + '<span>' + esc(stateLabel(state)) + '</span></span>' + ((change && isActive) ? '<span class="cat-change-badge cat-change-' + esc(changeGroup(segment)) + '" title="' + esc(changeTitle(segment)) + '">' + esc(change) + '</span>' : '') + (reviewNoteCount ? '<span class="cat-review-note-badge" title="未解決の作業メモ ' + reviewNoteCount + '件">メモ ' + reviewNoteCount + '</span>' : '') + '</td>' +
        /* 場所は幅が狭く、長いシート名だと番地まで届かない（実測 2026-08-13、
           窓 1760px: 「2026年3月期 連結決算サマリー, AB123」は 366px 必要なのに
           89px しか無く、番地が1文字も出ない）。どのセルかは Excel の作業では
           いちばん要る情報なので、全文を title に持たせて指せば読めるようにする。 */
        '<td class="cat-col-loc"><span class="cat-card-label">場所</span><span class="cat-location-main" title="' + esc(segment.location || '本文') + '">' + esc(segment.location || '本文') + '</span><span class="cat-location-kind">' + esc(kind) + '</span>' + (Number(segment.split_parts || 0) > 1 ? '<span class="cat-repetition" title="この行は1つのセル（段落）を手で分けたものです。書き出すときは、同じ組の行を繋いで元の1つへ戻します。Alt+M でも元へ戻せます。">分けた行 ' + Number(segment.split_part) + '/' + Number(segment.split_parts) + '</span>' : '') + (Number(segment.repetition_count || 1) > 1 ? '<span class="cat-repetition" title="この原文は資料の中に ' + segment.repetition_count + ' 行あります。確認済みにすると、まだ訳が入っていない同じ原文の行へ同じ訳を入れます。">同じ原文×' + segment.repetition_count + '</span>' : '') +
        /* 判定の物差し（何pxで測ったか）はここにも出す（利用者判断）。押す前の
           画面に必ず出す、という決まり（未確認行数と同じ流儀）に合わせる。 */
        (fitInfo.risk ? '<span class="cat-fit-risk-badge" title="使える幅 ' + Math.round(fitInfo.displayWidthPx) + 'px' + (fitInfo.spillColumnCount > 0 ? '（右の空きセル' + fitInfo.spillColumnCount + '個を含む）' : '') + '。PDFで文字が切れていないか確認してください。">収まらない見込み</span>' : '') +
        (origin ? '<span class="cat-origin">' + esc(origin) + '</span>' : '') + '</td>' +
        /* 行の作りは、開いていても閉じていても同じ（原文｜訳文）。以前は開いた行だけ
           上下2段のカードに化けていたが、行を移るたびに表がずれて、いま何行目かを
           見失う。市販の CAT（memoQ・Trados・Phrase）はどれも表の形を保ったまま
           その場で直す。上下2段は memoQ でも「横表示」という別の表示であって既定では
           ない（Läubli et al. arXiv:2011.05978 が速いとしたのもこの表示のこと）。 */
        '<td class="cat-source"><span class="cat-card-label">原文</span><span class="cat-source-text" lang="' + languages.source + '">' + esc(segment.source) + '</span></td>' +
         '<td class="cat-target"><span class="cat-card-label">訳文</span>' + editor + extras + '</td>' +
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
    /* 常設の体裁は、中身が変わったここでだけ組み直す。行を移るたびではない。 */
    renderDockPreview();
    if (focusFirst) window.setTimeout(function () { var first = document.querySelector('.is-active [data-cat-input]') || document.querySelector('[data-cat-input]'); YakuCommon.focus(first); }, 0);
  }

  function handleDirection(error, retry) {
    if (!(error.status === 409 && error.data && error.data.code === 'DIRECTION_CONFIRMATION_REQUIRED')) return false;
    pendingDirection = retry; el('cat-direction-choice').hidden = false; status(error.data.error || '翻訳先を選んでください。'); YakuCommon.focus(el('cat-direction-choice').querySelector('[data-cat-direction]')); return true;
  }
  function source(mode, fileOverride) {
    if (mode === 'text') { var text = el('quick-input').value; return text.trim() ? Promise.resolve({ text: text }) : Promise.reject(new Error('翻訳したい文章を貼り付けてください。')); }
    /* Edgeでは、ドロップした FileList を hidden input.files へ代入してから
       change を発火する経路が安定しない。ドロップ時は File を直接渡し、
       ファイル選択ダイアログのときだけ input.files を読む。 */
    var file = fileOverride || (el('cat-file-input').files && el('cat-file-input').files[0]);
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
    context = context || {}; context.token = ++jobSerial; context.startedAt = Date.now();
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
    return '<div class="job-loading"><div class="job-loading-inner">' +
      '<div class="job-topline"><div class="job-phase">' + esc(data.label || data.phase || '翻訳しています') + '</div><div class="job-percent">' + percent + '%</div></div>' +
      '<div class="job-progress-line" role="progressbar" aria-label="翻訳の進み具合" aria-valuemin="0" aria-valuemax="100" aria-valuenow="' + percent + '"><span class="job-progress-bar" style="width:' + percent + '%"></span></div>' +
      '<div class="job-bottomline"><div class="job-meta">' + (detail ? esc(detail) : 'Copilotの返事を待っています。') +
      '<br><span class="job-elapsed">' + esc(elapsedLabel(startedAt)) + '</span>' + partialLine + '</div>' +
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
    /* 差分カーソル。次に欲しいのは自前累積の後ろから(=既に受け取った件数)。
       cancelled/error/done の最後の1回も同じ形で取り、キャンセル・失敗時に
       画面へ残す分を取りこぼさない(設計判断5)。 */
    var partialAfter = (jobContext && Array.isArray(jobContext.partialRows)) ? jobContext.partialRows.length : 0;
    var partialQuery = partialAfter > 0 ? ('?partial_after=' + partialAfter) : '';
    YakuCommon.json('/api/jobs/' + encodeURIComponent(id) + partialQuery).then(function (data) {
      if (!jobContext || jobContext.token !== token) return;
      applyPartialPreview(data);
      el('cat-job').innerHTML = jobHtml(id, data, startedAt);
      if (['done','completed_with_warnings'].indexOf(data.mode) >= 0) {
        /* apply後の応答（プロジェクトのJSON）にはマスク件数が無い。消える前の
           このポーリング応答だけが持っているので、ここで拾っておく。まとめ翻訳・
           1行だけ翻訳のときだけ見せる（直す・過去訳の突き合わせは対象外）。 */
        if (jobContext && jobContext.type === 'translate' && String(data.kind || '') === 'cat') jobContext.maskedCount = Number(data.masked_count || 0);
        setJobTitle('✔ 翻訳が終わりました'); finishJob(id, token); return;
      }
      if (data.mode === 'cancelled') { setJobTitle(''); setBusy(false); el('cat-job').innerHTML = ''; status('翻訳をやめました。ここまでにできた訳文は保存されています。「Copilotで未訳を翻訳」を押すと続きから再開できます。'); return; }
      if (['error','failed'].indexOf(data.mode) >= 0) { setJobTitle(''); setBusy(false); status(data.detail || '翻訳が途中で止まりました。ここまでにできた訳文は保存されています。もう一度「Copilotで未訳を翻訳」を押すと、続きから再開します。', true); return; }
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
          if (revisionComparison) { inspectorTab = 'revisions'; setDockOpen(true, true); }
        }
        render(data, true);
        /* 操作ゼロで件数が見える。次の翻訳まで残す（自動では消さない）。 */
        if (context.type === 'translate' && typeof context.maskedCount === 'number') el('cat-mask-notice').textContent = maskNoticeText(context.maskedCount);
      }
      else { setBusy(false); loadRecent(); }
      return data;
    }).catch(function (error) { setBusy(false); if (project && String(project.id || '') === context.scope.id) status(error.message, true); });
  }
  function translate() {
    var glossaryScope = null, jobScope = null;
    return flush().then(function () { glossaryScope = currentScope(); if (!glossaryScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('用語集を適用しています…'); return post('glossary', {}, true, glossaryScope); }).then(function (data) {
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示している資料が切り替わったため、翻訳をやめました。もう一度「Copilotで未訳を翻訳」を押してください。');
      project = data; jobScope = currentScope(); status('訳していない行を訳しています…');
      /* 幅を知って最初から訳す。訳す行（訳文が空の行）の index だけを渡す。
         目標が出せない行は buildFitTargets が自分で除くので、ここでは
         絞り込みだけ行う。1件も無ければ body に fit_targets を付けない。 */
      var translateFitTargets = buildFitTargets((project.segments || []).filter(function (s) { return !String(s.translation || '').trim(); }).map(function (s) { return Number(s.index); }));
      var translateBody = { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate' };
      if (translateFitTargets.length) translateBody.fit_targets = translateFitTargets;
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
      /* まとめて訳すのと同じ考えで、この1行だけの fit_targets を渡す。 */
      var rowFitTargets = buildFitTargets([index]);
      var translateRowBody = { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate', index: index };
      if (rowFitTargets.length) translateRowBody.fit_targets = rowFitTargets;
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
    if (query.length < 2) { list.innerHTML = '<p class="muted">2文字以上で探せます。</p>'; syncDockHeightForContent(); return; }
    if (!project) return;
    list.innerHTML = '<p class="muted">探しています…</p>';
    var scope = currentScope();
    post('concordance', { query: query }, false, scope).then(function (data) {
      if (!scopeIsCurrent(scope, true)) return;
      var hits = (data && data.hits) || [];
      if (!hits.length) { list.innerHTML = '<p class="muted">' + esc(query) + ' を含む過去の訳は見つかりませんでした。確認済みにした訳から探しています。</p>'; syncDockHeightForContent(); return; }
      list.innerHTML = hits.map(function (hit) {
        var where = hit.file_name ? esc(hit.file_name) + (hit.location ? '・' + esc(hit.location) : '') : '';
        return '<div class="cat-candidate-card">' +
          '<p class="cat-concordance-source">' + esc(hit.source) + '</p>' +
          '<p class="cat-concordance-target">' + esc(hit.target) + '</p>' +
          (where ? '<p class="cat-candidate-meta">' + where + '</p>' : '') +
          '</div>';
      }).join('');
      syncDockHeightForContent();
    }).catch(function (error) {
      list.innerHTML = '<p class="muted">' + esc(error.message || '探せませんでした。') + '</p>';
      syncDockHeightForContent();
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
        status('確認済みにできませんでした。下の「点検」に出ている内容を直してから、もう一度お試しください。', true);
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
    return flush().then(function () { if (seq === filterSeq && project) { candidateSeq++; el('cat-candidates').hidden = true; renderRows(); } }).catch(function (error) { status('変更を保存できなかったため、表示を切り替えませんでした。' + error.message, true); });
  }
  function candidates(index) {
    clearCandidateDetail('候補を読み込んでいます…');
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
      candidateDetailItems = items;
      candidateDetailSource = activeSource;
      candidateDetailIndex = -1;
      candidateDetailRequestIndex = Number(index);
      candidateDetailRequestProjectId = requestScope.id;
      candidateDetailRequestRevision = requestScope.revision;
      var panel = el('cat-candidates'); panel.hidden = false;
      el('cat-candidate-count').textContent = String(terms.length + items.length);
      el('cat-terms-list').innerHTML = terms.length ? terms.map(function (item, termIndex) {
        var termNumber = termIndex + 1;
        var allowed = (item.allowed_targets || []).filter(Boolean), forbidden = (item.forbidden_targets || []).filter(Boolean);
        var scopeLabel = item.scope === 'project' ? 'この資料だけ' : '今後の資料でも使用';
        return '<article class="cat-candidate-card cat-term-card">' + (termNumber <= 9 ? '<span class="cat-candidate-number">' + termNumber + '</span><span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + termNumber + '</kbd></span>' : '') + '<div class="cat-candidate-meta"><span class="cat-cand-tag">登録用語</span><span>' + esc(item.source_name || '用語集') + '</span><span>' + esc(scopeLabel) + '</span></div>' +
          '<div class="cat-candidate-source"><strong>原文の用語</strong><p class="cat-cand-src">' + esc(item.source) + '</p></div><div class="cat-candidate-target"><strong>推奨訳</strong><p class="cat-cand-tgt">' + esc(item.translation || item.target) + '</p></div>' +
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
        /* 一致の度合いは、市販CATと同じくカードの先頭に出す。どこが違うかは
           原文側の印で示すので、下の説明文は日付だけでよくなった。

           **「%」を出す（2026-08-16 に戻した）。**

           2026-08-15 に一度やめた。理由は「中身が 3-gram の Dice 係数で、
           翻訳者が読む 100 / 95-99 / 85-94 / 75-84 の帯は編集距離を前提に
           しているから、別の尺度の数字をその帯へ当てはめさせるのは誤読させるのと
           同じ」だった。**その前提が両側で消えた。**

           - 実装が編集距離になった（src/TranslationMemory.ps1 の
             Get-YakuTranslationMemoryEditRatio。拾うのは MinScore=0.70 以上）
           - **Smartcat を実機で見たら「%」を出していた。** 閾値の選択肢も
             75 / 85 / 95 / 99 / 100 / 101 で、その帯そのものだった

           帯の色は実測に合わせた（出典 `_docs/測定_一致率_2026-08-16.md`）。
           Smartcat は 100%=緑、86〜92%=黄、75〜77%=赤で、境目は 78〜85 の間。
           設定が刻む 85 をその境目として採る。

               100%      is-exact  塗りつぶし
               85〜99%   is-high   輪郭（実線）
               70〜84%   is-low    輪郭（破線）

           **色だけに頼らない。** 塗りの形を3種類に分けてあるので、
           色が見えなくても3段が見分けられる（塗りつぶし／実線／破線）。
           言葉は title に置く。

           **99%より上は完全一致だけにする。** 0.999 以上を丸めると、1文字だけ
           違う長文が「100%」と出る。数字の 100 は「同じ」の意味で読まれるので、
           完全一致でないものは 99% で止める。

           並び順と件数はサーバの Weight（ratio の降順）のままで、
           今回それには触っていない。 */
        /* **前回版の候補（kind='prior'）に数字を出さない。** そこへ来る ratio は
           一致率ではなく 0 が入る。かつては 1% に丸めて描いていたが、
           1% という数字は「ほぼ別物」と読まれてしまう。実際には
           「前回の同じ場所の訳」であって、原文が変わったかどうかだけが問題である。 */
        var isPrior = (item.kind === 'prior');
        var exact = isPrior ? !!item.exact : (ratio >= .999 || !!item.exact);
        var percent = exact ? 100 : Math.min(99, Math.max(0, Math.round(ratio * 100)));
        var scoreClass = exact ? 'is-exact' : (!isPrior && percent >= 85 ? 'is-high' : 'is-low');
        var scoreLabel = isPrior ? (exact ? '原文が同じ' : '原文に変更あり') : (percent + '%');
        var scoreTitle = isPrior
            ? (exact ? '前回と同じ場所で、原文も同じ' : '前回と同じ場所だが、原文が変わっている')
            : (exact
                ? '完全一致。いまの原文と同じ'
                : (percent >= 85
                    ? ('一致率 ' + percent + '%。ほぼそのまま使える')
                    : ('一致率 ' + percent + '%。手直しが要る')));
        var scoreBadge = '<span class="cat-cand-score ' + scoreClass + '" title="' + esc(scoreTitle) + '">' + esc(scoreLabel) + '</span>';
        /* 一致の度合いは先頭の札が持っているので、ここで繰り返さない。 */
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
        return '<article class="cat-candidate-card cat-memory-candidate" role="button" tabindex="0" aria-selected="' + String(itemIndex === 0) + '" data-cat-candidate-index="' + itemIndex + '" aria-label="' + esc(label + ' ' + (isPrior ? '前回資料の一致' : '翻訳メモリ一致')) + '"><span class="cat-candidate-number">' + number + '</span>' + (number <= 9 ? '<span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + number + '</kbd></span>' : '') + '<div class="cat-candidate-meta">' + scoreBadge + '<span class="cat-cand-tag">' + esc(label) + '</span><span>' + esc(material) + '</span>' + (location ? '<span>' + esc(location) + '</span>' : '') + (place ? '<span>' + esc(place) + '</span>' : '') + '</div>' +
          '<div class="cat-candidate-source"><strong>原文</strong><p class="cat-cand-src">' + diffMarkup(item.source, activeSource) + '</p></div><div class="cat-candidate-target"><strong>訳文</strong><p class="cat-cand-tgt">' + esc(translation) + '</p></div>' +
          /* 「原文が似ているというだけです。訳文が正しいかは…」は消した。
             見出しが「似ている過去の訳」で、入れるかどうかは押して決める。
             読む人はそれを分かっている（2026-08-12、利用者の指摘）。 */
          '<p class="muted">' + esc([match, saved, diffHint].filter(Boolean).join('・')) + '</p>' +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-insert="' + esc(translation) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">' + number + ' この訳を挿入</button>' + deleteButton + '</div></article>';
      /* 2026-08-18: 待機文を短くした（「確認済みにした訳が」→「確認済みの訳は」）。
         180pxへ縮めたドックでも、この行だけなら折り返さず収まる。 */
      }).join('') : '<p class="muted">確認済みの訳は、次の資料で候補になります。</p>';
      renderCandidateDetail(items[0] || null, 0);
      syncDockHeightForContent();
    }).catch(function () { if (seq === candidateSeq && scopeIsCurrent(requestScope, true) && Number(activeIndex) === Number(index)) { el('cat-candidate-count').textContent = '0'; el('cat-terms-list').innerHTML = '<p class="muted">用語を読み込めませんでした。行を選び直すと、もう一度探します。</p>'; el('cat-candidates-list').innerHTML = '<p class="muted">似た訳を読み込めませんでした。行を選び直すと、もう一度探します。</p>'; syncDockHeightForContent(); } });
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
      return '<button type="button" class="cat-placeable" data-cat-placeable="' + position + '" data-cat-placeable-text="' + esc(item.text) + '">' +
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
    var widths = {}, heights = {}, wrap = {}, shrink = {}, align = {}, bold = {}, spans = {}, covered = {}, hidden = {};
    (found.columns || []).forEach(function (col) {
      for (var c = Number(col.min); c <= Number(col.max); c++) {
        widths[c] = col.hidden ? 0 : Number(col.width);
        /* 幅を0にするだけでは「幅0の列」と区別が付かない。右への自動はみ出し
           （収まりの見える化）は非表示列で止める必要があり、幅とは別に持つ。 */
        if (col.hidden) hidden[c] = true;
      }
    });
    /* 行の高さは、既定と違う行だけ来る。来ない行は既定で埋める。 */
    (found.rows || []).forEach(function (row) { heights[Number(row.row)] = Number(row.height); });
    (found.cells || []).forEach(function (cell) {
      var ref = previewCellRef('x, ' + cell.address);
      if (!ref) return;
      if (cell.wrap) wrap[ref.row + ':' + ref.column] = true;
      if (cell.shrink) shrink[ref.row + ':' + ref.column] = true;
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
    /* 右への自動はみ出しは、値・数式のどちらが入っていても止める必要がある
       （src/CatProject.ps1 の Get-YakuCatRightSpillDisplayRegion と同じ条件）。
       番地の並びは previewCellRef（既存のA1解析）で行:列へ直す。新しい解析は書かない。
       同じ歩きで、シート全体の「最終内容列」（占有セル・数式セル・結合範囲の
       終端のうち最も右）も一度だけ求める。印刷範囲は通常、使用範囲（その資料に
       実際に中身がある最も右・最も下）で閉じる。そこから先は Excel 上は
       ただの空白の海であり、収まりの根拠にしてよい「使える幅」ではない
       （甘い側に外さない）。求めるのは1シートにつき1回で、行ごとには求めない
       （CoD審査 2026-08-18 REWORK-1: 求めないと、右に何も無い行の自動歩きが
       列16384まで走り、300行の資料で初回描画が441ms→11241msへ25倍に落ちた。
       さらに、実際の最終内容列そのもののセルは「右へ無限の余白」を得て
       絶対に収まり判定に引っかからなくなっていた）。 */
    var occupied = {};
    var lastContentColumn = 0;
    (found.occupied_cells || []).concat(found.formula_cells || []).forEach(function (address) {
      var ref = previewCellRef('x, ' + address);
      if (!ref) return;
      occupied[ref.row + ':' + ref.column] = true;
      if (ref.column > lastContentColumn) lastContentColumn = ref.column;
    });
    (found.merges || []).forEach(function (range) {
      var parts = String(range).split(':');
      if (parts.length !== 2) return;
      var to = previewCellRef('x, ' + parts[1]);
      if (to && to.column > lastContentColumn) lastContentColumn = to.column;
    });
    found.__prepared = {
      defaultWidth: Number(found.default_width) || 8.43,
      defaultHeight: Number(found.default_height) || 18.75,
      widths: widths, heights: heights, wrap: wrap, shrink: shrink, align: align, bold: bold, spans: spans, covered: covered,
      hidden: hidden, occupied: occupied, lastContentColumn: lastContentColumn,
      unknownWidthColumns: (found.unknown_width_columns || []).map(function (range) {
        return { min: Number(range.min), max: Number(range.max) };
      })
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
  /* 既定幅は格子を描くためだけに使う。width 属性の無い列を跨ぐときは、
     実際の幅が不明なので overflow の根拠にしてはいけない。 */
  function previewColumnsHaveKnownWidth(layout, column, count) {
    if (!layout) return false;
    for (var offset = 0; offset < count; offset++) {
      var current = column + offset;
      if ((layout.unknownWidthColumns || []).some(function (range) {
        return current >= range.min && current <= range.max;
      })) return false;
    }
    return true;
  }
  /* 使える幅（収まりの見える化）。自セルの右へ、中身の無い列を歩いて数える。
     止めるのは次のいずれか。
       - 占有セル・数式セル・非表示列・結合・未知幅列（src/CatProject.ps1 の
         Get-YakuCatRightSpillDisplayRegion が宣言スピルを検証する条件と同じ）
       - シートの最終内容列（layout.lastContentColumn、previewLayout が1回だけ
         求める）を超えたとき。最終内容列より右は「右へ無限の余白」であって、
         収まりの根拠にする使える幅ではない（上のコメントと同じ理由）
     Excel 自身の列数上限（XFD＝16384）は、その最終内容列の値そのものが壊れて
     いた場合の物理的な歯止めとして残す（2枚目の網）。 */
  var YAKU_PREVIEW_MAX_COLUMN = 16384;
  function autoSpillColumns(layout, row, column, span) {
    if (!layout) return [];
    var count = (span && span.columns) || 1;
    var next = column + count, result = [];
    var bound = Math.min(YAKU_PREVIEW_MAX_COLUMN, Number(layout.lastContentColumn) || 0);
    while (next <= bound) {
      if (!previewColumnsHaveKnownWidth(layout, next, 1)) break;
      if (layout.hidden[next]) break;
      var key = row + ':' + next;
      if (layout.covered[key] || layout.spans[key] || layout.occupied[key]) break;
      result.push(next);
      next++;
    }
    return result;
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
  /* 幅は「書き戻しが実際にセルへ設定する書体」で測る。
     2026-08-17 まで 14.7px Calibri 固定だった。書く側は Arial（和→英）/
     MS Pゴシック（英→和）で、Arial のほうが同じ字上げで広い。
     つまり測定は「収まる」と言い過ぎる側へ外れていた。甘い側の誤りは
     「収まると判定して実際は切れる」という形で出るので、判定に使うなら直す。
     設定が空（書体を変更しない）のときは、原本の書体が分からないので
     Calibri へは戻さず、Excel の既定である Calibri/MS Pゴシックを名乗る
     フォールバックだけを残す。 */
  function previewOutputFont() {
    var name = 'meta[name="yaku-output-font"]';
    if (project && project.direction === 'to_jp') name = 'meta[name="yaku-output-font-jp"]';
    var node = document.querySelector(name);
    var value = node ? String(node.getAttribute('content') || '').trim() : '';
    if (!value) return 'Calibri, Arial, sans-serif';
    /* 書体名に空白が入る（MS Pゴシック / Times New Roman）。CSS の font 短縮形へ
       そのまま置くと壊れるので引用する。 */
    return '"' + value.replace(/"/g, '') + '", Calibri, Arial, sans-serif';
  }
  function previewTextWidthPx(text, bold) {
    if (!previewMeasureCanvas) previewMeasureCanvas = document.createElement('canvas');
    var context = previewMeasureCanvas.getContext && previewMeasureCanvas.getContext('2d');
    if (!context) return Array.from(String(text || '')).length * 7;
    context.font = (bold ? '700 ' : '') + '14.7px ' + previewOutputFont();
    return context.measureText(String(text || '')).width;
  }
  /* 幅を知って最初から訳す。翻訳前は訳文が無いので segmentFitCapacity のように
     実測できない。代わりに出力書体の参照文字幅（平均px/字）を代表文字列で
     1回だけ測り、書体（太字・方向）ごとにキャッシュする。方向で出力される
     文字種が変わる（to_en はラテン文字、to_jp は和文）ため、代表文字列も
     方向で分ける。 */
  var previewOutputAvgCharPxCache = {};
  function previewOutputAvgCharPx(bold) {
    var font = previewOutputFont();
    var jp = !!(project && project.direction === 'to_jp');
    var cacheKey = (jp ? 'jp|' : 'en|') + (bold ? '1|' : '0|') + font;
    if (previewOutputAvgCharPxCache[cacheKey] !== undefined) return previewOutputAvgCharPxCache[cacheKey];
    var sample = jp ? '日本語で書かれた代表的な文章の一例であり幅の目安にする' : 'The quick brown fox jumps over the lazy dog 0123456789';
    var width = previewTextWidthPx(sample, bold) / sample.length;
    previewOutputAvgCharPxCache[cacheKey] = width;
    return width;
  }
  /* 収まりの判定に使う文字列。プレビューの表示切替（原文／訳文）とは独立に、
     「実際にセルへ入る文字」＝訳文（無ければ原文）で見る。絞り込みや行の印は
     プレビューの表示側と連動させない（表示は見る側の都合、収まりは書く内容の
     都合で、別のもの）。 */
  function segmentFitText(segment) {
    /* Measure the actual publication text after a concise variant is adopted.
       Keep the canonical translation intact; fit checks prefer publication_translation. */
    var publication = String(segment && segment.publication_translation || '');
    if (publication.trim()) return publication;
    var target = String(segment && segment.translation || '');
    return target.trim() ? target : String(segment && segment.source || '');
  }
  /* 収まりの判定そのもの。プレビューの印（previewCellHtml）と、絞り込み・行の
     印（segmentFitRiskInfo 経由）の両方がこの1つを使う。呼び出し側が層・行・列・
     結合幅・測る文字列・太字を渡す点は元の previewCellHtml のインライン計算と
     同じにし、判定式も変えない（純粋な抽出）。変えたのは使える幅の出し方だけで、
     自動計算した右への空きセル（autoSpillColumns）を優先し、それが0列のときだけ
     利用者が宣言した表示領域（従来の spill_right_display_only）を使う。
     宣言セルは検証済みの空セルなので、自動計算に必ず含まれるはずである
     （届いていれば自動計算のほうが必ず勝つ）。自動が届かない例外だけ、
     従来の経路（元の計算そのまま）へ落ちる。 */
  function segmentFitRisk(segment, layout, row, column, span, text, bold) {
    var key = row + ':' + column;
    var wrap = layout ? !!layout.wrap[key] : false;
    var shrink = layout ? !!layout.shrink[key] : false;
    var align = layout ? (layout.align[key] || '') : '';
    var spanColumns = (span && span.columns) || 1;
    var displayWidth = layout ? previewColumnPx(layout, column, span) : 0;
    var measurementKnown = !!layout && previewColumnsHaveKnownWidth(layout, column, spanColumns);
    var spillColumnCount = 0, spillSource = 'none';
    if (layout && measurementKnown && !wrap && !shrink) {
      /* 中央寄せ・右寄せは左右にはみ出すため、自動の右スピルは対象にしない
         （空か左寄せのセルだけ）。 */
      var autoColumns = (align === '' || align === 'left') ? autoSpillColumns(layout, row, column, span) : [];
      if (autoColumns.length) {
        autoColumns.forEach(function (col) { displayWidth += previewColumnPx(layout, col, null); });
        spillColumnCount = autoColumns.length; spillSource = 'auto';
      } else {
        var spillRegion = segment.placement && (segment.placement.display_regions || []).find(function (region) {
          return region.mode === 'spill_right_display_only' && String(region.anchor_address || '').toUpperCase() === String(segment.location || '').split(',').pop().trim().toUpperCase();
        });
        if (spillRegion) {
          (spillRegion.cells || []).forEach(function (_, offset) {
            var spillColumn = column + offset + 1;
            displayWidth += previewColumnPx(layout, spillColumn, null);
            if (!previewColumnsHaveKnownWidth(layout, spillColumn, 1)) measurementKnown = false;
          });
          spillColumnCount = (spillRegion.cells || []).length; spillSource = 'declared';
        }
      }
    }
    var textWidth = previewTextWidthPx(text, bold);
    var risk = !!(layout && measurementKnown && !wrap && !shrink && textWidth > Math.max(0, displayWidth - 8));
    return { risk: risk, measurementKnown: measurementKnown, displayWidthPx: displayWidth, textWidthPx: textWidth, spillColumnCount: spillColumnCount, spillSource: spillSource };
  }
  /* 絞り込み・行の印・文字目標の3つが、生の segment（プレビューの destination
     展開を経ていないもの）から判定を引くための入口。番地の解析は既存の
     previewCellRef を使う（新しいA1解析は書かない）。Excel以外・層が引けない
     資料では常に false。
     訳がまだ空の行も常に false（CoD審査 2026-08-18 REWORK-1）。配置計画は
     掲載訳が空でないことを前提にしており（src/CatProject.ps1:1877）、
     「収める候補」は空の行には作れない。未翻訳の資料を開いた瞬間に
     「収まらない見込み」を名乗るのは、原文の長さで判定してしまっているだけで、
     実際には1行も候補を出せない誤検知だった。
     プレビューの印（previewCellHtml）はここを経由しない別経路（プレビューの
     表示切替＝原文／訳文にそのまま追随する、従来どおりの仕様）なので、この
     ゲートの影響を受けない。 */
  function segmentFitRiskInfo(segment) {
    if (!segment || segment.kind !== 'cell') return { risk: false };
    if (!String(segment.translation || '').trim()) return { risk: false };
    var ref = previewCellRef(segment.location);
    if (!ref) return { risk: false };
    var layout = previewLayout(ref.sheet);
    if (!layout) return { risk: false };
    var key = ref.row + ':' + ref.column;
    return segmentFitRisk(segment, layout, ref.row, ref.column, layout.spans[key] || null, segmentFitText(segment), !!layout.bold[key]);
  }
  /* 「収める候補」を作れる行の条件（1クリック導線の行ボタンと、「まとめて収める」の
     対象選定の両方がここを呼ぶ。判定を2箇所に増やさない）。配置先（placement.
     destinations）が無い行は openPlacementEditor 自体が断るので、ここでも同じ
     条件で先に弾く。 */
  function isFitBatchEligible(segment) {
    return !!(segment && segment.kind === 'cell' && segment.placement && (segment.placement.destinations || []).length && segmentFitRiskInfo(segment).risk);
  }
  /* 「まとめて収める」の対象行。N はこの配列の件数（isFitBatchEligible と同じ
     1つの条件から数える。トグルの表示・確認ダイアログの文言・キューの対象の
     3箇所が同じ配列を使う）。 */
  function fitBatchTargets() {
    return (project && project.segments || []).filter(isFitBatchEligible);
  }
  /* 短縮候補へ渡す文字目標。現訳の実測幅から、使える幅に収まる文字数を比例で
     出す。層が引けない・訳が無いなど実幅が出せないときは null を返し、
     呼び出し側が従来の「現訳の長さ×0.8」へフォールバックする（そちらは
     20字下限を今までどおり残す）。

     実測できたときは、20字下限を掛けない（CoD審査 2026-08-18 REWORK-1）。
     実際の容量が8〜11字しかない行に「文字目標 20字」と出すのは、根拠を
     言うはずの文言が自分自身を裏切っていた。代わりに、サーバの使える窓
     [8,99]（src/Publication.ps1 のクランプ）へここでクランプしてから送る。
     生の値が99を超えるとき、送らなければ src/CopilotClient.ps1:5673-5675 が
     文字数の指示を1行も出さないのに、画面は「実測した使える幅から算出」と
     言い続けていた（クランプせずに送っていたのが原因）。raw（生の値）と
     basis（measured／below-min／above-max）を返し、状態行がどちらを言って
     いるかを正直に出せるようにする。 */
  function segmentFitCapacity(segment) {
    if (!segment || segment.kind !== 'cell') return null;
    var text = segmentFitText(segment);
    if (!text.trim()) return null;
    var ref = previewCellRef(segment.location);
    if (!ref) return null;
    var layout = previewLayout(ref.sheet);
    if (!layout) return null;
    var key = ref.row + ':' + ref.column;
    var fit = segmentFitRisk(segment, layout, ref.row, ref.column, layout.spans[key] || null, text, !!layout.bold[key]);
    if (!fit.measurementKnown || !(fit.displayWidthPx > 0) || !(fit.textWidthPx > 0)) return null;
    var raw = Math.floor(text.length * Math.max(0, fit.displayWidthPx - 8) / fit.textWidthPx);
    var basis = raw < 8 ? 'below-min' : (raw > 99 ? 'above-max' : 'measured');
    return { raw: raw, maxChars: Math.min(99, Math.max(8, raw)), basis: basis };
  }
  /* 幅を知って最初から訳す（翻訳前）。訳文がまだ無いので segmentFitCapacity の
     実測は使えない。代わりに参照文字幅（平均px/字、previewOutputAvgCharPx）で
     概算する。ゲート（既知幅・非wrap・非shrink・寄せ）は segmentFitRisk が
     見ている層（layout）をここでも直接読み、判定を2つに増やさない
     autoSpillColumns もそのまま呼ぶ。宣言spill（declared fallback）は使わない
     ―― 翻訳前は segment.placement（配置計画）がまだ無く、対象にできないため。
     8..99の範囲外・層が引けない行は null（従来どおり何も送らない）。 */
  function segmentSourceFitTarget(segment) {
    if (!segment || segment.kind !== 'cell') return null;
    var ref = previewCellRef(segment.location);
    if (!ref) return null;
    var layout = previewLayout(ref.sheet);
    if (!layout) return null;
    var key = ref.row + ':' + ref.column;
    if (layout.wrap[key] || layout.shrink[key]) return null;
    var span = layout.spans[key] || null;
    var spanColumns = (span && span.columns) || 1;
    if (!previewColumnsHaveKnownWidth(layout, ref.column, spanColumns)) return null;
    var align = layout.align[key] || '';
    var displayWidth = previewColumnPx(layout, ref.column, span);
    if (align === '' || align === 'left') {
      autoSpillColumns(layout, ref.row, ref.column, span).forEach(function (col) {
        displayWidth += previewColumnPx(layout, col, null);
      });
    }
    var avgCharPx = previewOutputAvgCharPx(!!layout.bold[key]);
    if (!(avgCharPx > 0)) return null;
    var raw = Math.floor((displayWidth - 8) / avgCharPx);
    if (raw < 8 || raw > 99) return null;
    return raw;
  }
  /* index の並びから fit_targets（幅の目標）配列を作る。目標が出せない行は
     配列に入れない（8..99の範囲外・層が引けない・訳がまだ無い行はそもそも
     対象にしない）。1件も無ければ呼び出し側が body に fit_targets 自体を
     付けない（従来どおり、送信内容は変わらない）。 */
  function buildFitTargets(indexes) {
    var targets = [];
    (indexes || []).forEach(function (idx) {
      var segment = project && (project.segments || []).find(function (item) { return Number(item.index) === Number(idx); });
      var maxChars = segment ? segmentSourceFitTarget(segment) : null;
      if (maxChars !== null) targets.push({ index: Number(idx), max_chars: maxChars });
    });
    return targets;
  }
  function previewCellHtml(segment, layout, row, column, span) {
    var value = previewText(segment);
    var key = row + ':' + column;
    var wrap = layout ? !!layout.wrap[key] : false;
    var align = layout ? (layout.align[key] || '') : '';
    var style = '';
    var fit = segmentFitRisk(segment, layout, row, column, span, value.text, !!(layout && layout.bold[key]));
    var overflowRisk = fit.risk;
    if (layout) {
      style = ' style="width:' + previewColumnPx(layout, column, span) + 'px' +
        (align === 'center' ? ';text-align:center' : align === 'right' ? ';text-align:right' : '') + '"';
    }
    var placementTitle = previewSide === 'target' && segment.placement_root_index !== undefined ? 'セルごとの区切りを調整' : '';
    var placementAction = previewSide === 'target' && segment.placement_root_index !== undefined
      ? ' data-cat-placement-edit="' + Number(segment.placement_root_index) + '"'
      : ' data-cat-qa-jump="' + Number(segment.index) + '"';
    /* 判定の物差し（何pxで測ったか）は行側に必ず出す（利用者判断）。既存の
       title（セルごとの区切りを調整）とは1つの title へ両方書く。 */
    var fitTitle = overflowRisk ? ('使える幅 ' + Math.round(fit.displayWidthPx) + 'px' + (fit.spillColumnCount > 0 ? '（右の空きセル' + fit.spillColumnCount + '個を含む）' : '')) : '';
    var combinedTitle = [placementTitle, fitTitle].filter(Boolean).join(' / ');
    var titleAttr = combinedTitle ? ' title="' + esc(combinedTitle) + '"' : '';
    return '<button type="button" class="cat-preview-cell' + (value.missing ? ' is-missing' : '') +
      (wrap ? ' is-wrap' : '') + (layout && layout.bold[key] ? ' is-bold' : '') +
      (overflowRisk ? ' is-overflow-risk' : '') +
      (Number(segment.index) === Number(activeIndex) ? ' is-active' : '') +
      /* 常設の体裁が選択に追随するとき、印を付け替える相手をここで名指しできる
         ようにする。data-cat-qa-jump は配置つきのセルには付かないので当てにできない。 */
      '" data-cat-preview-index="' + Number(segment.index) + '"' + style + placementAction + titleAttr +
      (overflowRisk ? ' aria-label="収まり要確認: PDFで切れを確認してください"' : '') + '>' +
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
      '" data-cat-preview-index="' + Number(segment.index) + '"' +
      ' data-cat-qa-jump="' + Number(segment.index) + '">' + esc(value.text) + '</button>';
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
    /* 原文の途中で分けた行は、元の1つのセルへ戻して置く。分けた行をそれぞれ
       置くと同じ番地へ二重に描き、あとの行だけが見える（原文側は前半が消える）。 */
    var splitSources = {};
    all.forEach(function (segment) {
      if (!segment.split_group) return;
      splitSources[segment.split_group] = String(splitSources[segment.split_group] || '') + String(segment.source || '');
    });
    all.forEach(function (segment) {
      if (segment.split_group && Number(segment.split_part) !== 1) return;
      var whole = segment;
      if (segment.split_group) {
        var merged = { source: String(splitSources[segment.split_group] || '') };
        /* 訳文はサーバが繋いだもの（split_translation）を使う。ここで自分で
           繋いではいけない。繋ぎ方の規則（トークンの内側には空白を入れない・
           日本語なら詰める）は Join-YakuCatSplitTranslations だけが持ち、
           写せば必ず片方が腐る。配置先のある行が placement.destinations[].text を
           そのまま使っているのと同じ形である。
           古い応答には項目が無いので、そのときは今までどおり part 1 の訳文に
           落とす（後半が欠けるより、画面が空白になるほうが悪い）。 */
        if (typeof segment.split_translation === 'string' && segment.split_translation !== '') {
          merged.translation = segment.split_translation;
        }
        whole = Object.assign({}, segment, merged);
      }
      var placed = whole.kind === 'cell' && whole.placement && (whole.placement.destinations || []).length
        ? whole.placement.destinations.map(function (destination) {
          return Object.assign({}, whole, {
            translation: String(destination.text || ''),
            location: String(destination.sheet || '') + ', ' + String(destination.address || ''),
            placement_root_index: Number(whole.index)
          });
        }) : [whole];
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

  /* ---------------------------------------------------------------- 体裁の常設
     格子の下に体裁を出したまま訳す（2026-08-16）。これまでは「体裁で見る」
     ダイアログの中だけにあり、開くと格子が見えないので、訳しながらの
     手がかりにならなかった。Smartcat はプレビューを下部に常設し、細い仕切りで
     広げられ、選択に追随する（実測。出典 _docs/対比_Smartcat_2026-08-16.md）。

     ここに出すのは「Excelへの配置」だけである。元のファイルを開かず、画面が
     既に持っている行だけで組むので軽い。印刷結果PDFは重いのでダイアログに残す。

     **選択が動くたびに組み直さない。** buildPreview() は全行ぶんのHTMLを作るので、
     行を1つ移るたびに走らせると、行数に比例した費用を毎回払うことになる。
     中身が変わったとき（render）だけ組み直し、選択の追随は印の付け替えだけにする。 */
  var dockSide = 'target', dockOpen = false, dockHeight = 280;
  /* 2026-08-18（利用者判断）: 開いている行の参考情報が待機文だけ（候補も
     指摘も無い）のときは、ドックを180px程度へ縮めて余りを表へ渡す。実内容
     が入ったら元の高さへ戻す。dockAutoManaged は、利用者がドラッグ／矢印
     キーで実際に高さを変えた時点で false にし、以後は自動で縮めない
     （利用者が決めた高さを尊重する）。dockExpandedHeight は縮める直前の
     高さで、戻すときに使う。 */
  var dockAutoManaged = true, dockAutoCollapsed = false, dockExpandedHeight = null;
  var DOCK_WAITING_HEIGHT = 180;

  function buildPreviewFor(side) {
    /* buildPreview() とその下請けは previewSide を見る。引数で引き回すと
       触る場所が増えるので、ここだけで入れ替えて必ず戻す。 */
    var keep = previewSide;
    previewSide = side;
    try { return buildPreview(); } finally { previewSide = keep; }
  }

  function setDockHeight(px, fromUser) {
    dockHeight = Math.max(80, Math.min(600, Math.round(Number(px) || 280)));
    var dock = el('cat-preview-dock');
    if (dock) dock.style.setProperty('--cat-dock-height', dockHeight + 'px');
    var splitter = el('cat-preview-dock-splitter');
    if (splitter) splitter.setAttribute('aria-valuenow', String(dockHeight));
    if (fromUser) {
      /* 利用者が実際に高さを決めた。以後、待機文だけを理由に自動で縮めない。 */
      dockAutoManaged = false;
      dockAutoCollapsed = false;
      try { window.localStorage.setItem('yaku-cat-dock-height', String(dockHeight)); } catch (_) {}
    }
  }

  /* 開いているタブの中身が「待機文だけ」かどうか。タブごとに、実際に埋まる
     場所（件数の札やリストの文字）で判定する。件数がまだ「…」（取得中）の
     ときは、直前の状態を保って揺らさない。文脈・体裁は行を選べば必ず何か
     出るので待機文とはしない。 */
  function dockContentIsWaiting() {
    if (inspectorTab === 'candidates') {
      var candidateCount = el('cat-candidate-count') ? el('cat-candidate-count').textContent : '';
      if (candidateCount === '…') return dockAutoCollapsed;
      return candidateCount === '0';
    }
    if (inspectorTab === 'qc') {
      return (el('cat-qc-count') ? el('cat-qc-count').textContent : '') === '0';
    }
    if (inspectorTab === 'review_notes') {
      /* cat-review-notes-count は未解決だけの数なので、解決済みメモしか
         無い行だと0のまま実内容を見落とし、リストが縮んで隠れていた
         （2026-08-18実測: バッジ0でも .cat-review-note が3件）。concordance
         と同じく、DOMそのものを見る。 */
      var notesList = el('cat-review-notes-list');
      return !notesList || !notesList.querySelector('.cat-review-note');
    }
    if (inspectorTab === 'revisions') {
      var revisionsList = el('cat-revisions-list');
      return !revisionsList || /この行には変更履歴がありません/.test(revisionsList.textContent || '');
    }
    if (inspectorTab === 'concordance') {
      var concordanceList = el('cat-concordance-list');
      return !concordanceList || !concordanceList.querySelector('.cat-candidate-card');
    }
    return false;
  }
  /* 待機文だけのときは180px程度へ縮め、余りを表（#cat-grid-wrap）へ渡す。
     実内容が入ったら、縮める直前の高さへ戻す。利用者が手で決めた高さ
     （dockAutoManaged=false）には触らない。

     Alt+↓ の連打など、候補の有無が行ごとに交互の題材で1行ごとに呼ばれると
     180↔280 で表の下端が毎回跳ねる（2026-08-18実測: 5回連続振動）。呼び出し
     そのものは全箇所そのままで、実際の高さ変更だけを約200ms 遅らせて束ねる。
     連打中は呼ぶたびにタイマーを引き直すので、最後の呼び出しから200ms
     経つまで一度も動かない。そのときにはもう掃引先の行の描画が終わっている
     ので、最終的な高さは移動先の内容に追従する。 */
  var dockHeightSyncTimer = null;
  function syncDockHeightForContent() {
    if (dockHeightSyncTimer) { window.clearTimeout(dockHeightSyncTimer); }
    dockHeightSyncTimer = window.setTimeout(function () {
      dockHeightSyncTimer = null;
      applyDockHeightForContent();
    }, 200);
  }
  function applyDockHeightForContent() {
    if (!dockOpen || !dockAutoManaged) return;
    var waiting = dockContentIsWaiting();
    if (waiting && !dockAutoCollapsed) {
      dockExpandedHeight = dockHeight;
      dockAutoCollapsed = true;
      setDockHeight(DOCK_WAITING_HEIGHT, false);
    } else if (!waiting && dockAutoCollapsed) {
      dockAutoCollapsed = false;
      setDockHeight(dockExpandedHeight || 280, false);
      dockExpandedHeight = null;
    }
  }

  function renderDockPreview() {
    if (!dockOpen || !project) return;
    document.querySelectorAll('[data-cat-dock-side]').forEach(function (button) {
      button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-dock-side') === dockSide));
    });
    var missing = ((project && project.segments) || []).filter(function (segment) {
      return !String(segment.translation || '').trim();
    }).length;
    el('cat-preview-dock-note').textContent = dockSide === 'target' && missing
      ? '薄い字は、訳文がまだ無いところです。'
      : '';
    el('cat-preview-dock-body').innerHTML = buildPreviewFor(dockSide);
    syncDockActive(true);
  }

  function syncDockActive(center) {
    if (!dockOpen) return;
    var host = el('cat-preview-dock-body');
    if (!host) return;
    var next = host.querySelector('[data-cat-preview-index="' + Number(activeIndex) + '"]');
    var current = host.querySelector('.is-active');
    if (current === next) return;
    if (current) current.classList.remove('is-active');
    if (!next) return;
    next.classList.add('is-active');
    /* 既に見えている行までスクロールし直すと、体裁の絵が行を移るたびに跳ねる。
       nearest は見えていれば動かさない。開いた直後だけ真ん中へ寄せる。 */
    if (next.scrollIntoView) next.scrollIntoView({ block: center ? 'center' : 'nearest' });
  }

  function syncInspectorToggle() {
    var toggle = el('cat-inspector-toggle');
    if (!toggle) return;
    toggle.setAttribute('aria-expanded', String(dockOpen));
    toggle.textContent = dockOpen ? '参考情報を隠す' : '参考情報を出す';
  }

  function setDockOpen(open, fromUser) {
    dockOpen = !!open;
    var dock = el('cat-preview-dock');
    var toggle = el('cat-preview-dock-toggle');
    if (dock) dock.hidden = !dockOpen;
    if (toggle) {
      toggle.setAttribute('aria-pressed', String(dockOpen));
      toggle.setAttribute('aria-label', dockOpen ? 'プレビュータブを表示中' : 'プレビュータブを開く');
      toggle.title = dockOpen ? '下部のプレビュータブを表示中' : '下部のプレビュータブを開きます';
    }
    syncInspectorToggle();
    if (fromUser) {
      try {
        window.localStorage.setItem('yaku-cat-dock-open', dockOpen ? '1' : '0');
        window.localStorage.removeItem('yaku-cat-inspector-hidden');
      } catch (_) {}
    }
    if (dockOpen) { renderDockPreview(); syncDockHeightForContent(); }
  }

  function restoreDockState() {
    var storedHeight = '', storedOpen = null, layoutVersion = null, height = 280;
    try { storedHeight = window.localStorage.getItem('yaku-cat-dock-height') || ''; } catch (_) {}
    try { storedOpen = window.localStorage.getItem('yaku-cat-dock-open'); } catch (_) {}
    try { layoutVersion = window.localStorage.getItem('yaku-cat-dock-layout-v2'); } catch (_) {}
    height = storedHeight ? Number(storedHeight) : 280;
    /* Existing releases could leave a tall inspector value (for example 388px)
       in localStorage. Migrate that one time to the compact bottom dock; after
       the marker is present a deliberate resize, including a tall one, is kept.

       2026-08-18（利用者判断）: height はここでは「実内容があるときの高さ」
       （既定280px）を表す。実際に開いた直後、待機文しか無ければ
       syncDockHeightForContent()（setDockOpen 経由）がこれを180pxへ縮め、
       実内容が入り次第この値へ戻す。localStorage に保存されるのは、利用者が
       手でドラッグ／矢印キーで決めた高さだけで、自動で縮めた180pxは保存しない。 */
    if (layoutVersion !== '1') {
      if (!storedHeight || !Number.isFinite(height) || height > 320) height = 280;
      try { window.localStorage.setItem('yaku-cat-dock-layout-v2', '1'); } catch (_) {}
    }
    setDockHeight(height, false);
    /* 初回は補助情報の存在に気づけるように開く。明示的に畳んだあとだけ、
       ひとつの保存値（yaku-cat-dock-open）を尊重する。旧 inspector-hidden は
       競合を避けるためここでは読まない。 */
    setDockOpen(storedOpen === null ? true : storedOpen === '1', false);
  }

  function bindDockSplitter() {
    var splitter = el('cat-preview-dock-splitter');
    var dock = el('cat-preview-dock');
    if (!splitter || !dock) return;
    var dragging = false, startY = 0, startHeight = 0;
    splitter.addEventListener('pointerdown', function (event) {
      dragging = true; startY = event.clientY; startHeight = dockHeight;
      dock.classList.add('is-resizing');
      try { splitter.setPointerCapture(event.pointerId); } catch (_) {}
      event.preventDefault();
    });
    splitter.addEventListener('pointermove', function (event) {
      if (!dragging) return;
      /* 上へ動かすほど高くする。仕切りは体裁の上端にあるので、
         そうしないと掴んだ向きと逆に動く。 */
      setDockHeight(startHeight + (startY - event.clientY), false);
    });
    function stop(event) {
      if (!dragging) return;
      dragging = false;
      dock.classList.remove('is-resizing');
      try { splitter.releasePointerCapture(event.pointerId); } catch (_) {}
      setDockHeight(dockHeight, true);
    }
    splitter.addEventListener('pointerup', stop);
    splitter.addEventListener('pointercancel', stop);
    /* **掴めない人のための道（WCAG 2.2 SC 2.5.7）。**
       ドラッグでしか動かせない仕切りは、それだけで使えない人が出る。 */
    splitter.addEventListener('keydown', function (event) {
      var step = event.shiftKey ? 48 : 16;
      if (event.key === 'ArrowUp') { setDockHeight(dockHeight + step, true); event.preventDefault(); return; }
      if (event.key === 'ArrowDown') { setDockHeight(dockHeight - step, true); event.preventDefault(); return; }
      if (event.key === 'Home') { setDockHeight(80, true); event.preventDefault(); return; }
      if (event.key === 'End') { setDockHeight(600, true); event.preventDefault(); }
    });
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
    if (!placement || !(placement.destinations || []).length) { status('この行には調整できるセル配置がありません。', true); return false; }
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
    return true;
  }
  /* 収まらない見込みの行から1クリックで「収める候補」へ。既存の配置ダイアログ
     （調整できるセル配置の読み込み・cat-placement-index の設定）を経てから、
     既存の cat-publication-open の流れをそのまま自動で発火する。開けなかった
     ときは openPlacementEditor 側の案内（ステータス）で止める。新しいAPIは
     作らない（既存の openPlacementEditor / openPublicationCandidates を呼ぶだけ）。 */
  function openFitPublicationFlow(index) {
    if (openPlacementEditor(index) === false) return;
    openPublicationCandidates();
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
    var maxCharsNote = el('cat-publication-maxchars-note'); if (maxCharsNote) maxCharsNote.textContent = '';
    var regenerateButton = el('cat-publication-regenerate');
    if (regenerateButton) regenerateButton.hidden = true;
    el('cat-publication-generate').hidden = false;
    el('cat-publication-dialog').showModal();
    /* 「まとめて収める」が先回りで作った候補があり、訳文が生成時から変わって
       いなければ、再生成せずにそのまま出す（実装前調査は fitBatchCandidateCache
       の定義コメントを参照。表示を早めるだけで、適用時の最終判定はサーバ側の
       dependency_fingerprint／candidate_text_hash が持つ）。 */
    var cachedFitEntry = fitBatchCacheEntry(segment);
    if (cachedFitEntry) {
      publicationJobId = cachedFitEntry.jobId; publicationCandidateSet = cachedFitEntry.candidateSet;
      el('cat-publication-generate').hidden = true;
      if (regenerateButton) regenerateButton.hidden = false;
      /* showPublicationCandidateSet は状態行を自分で決め打ちして書き換える
         （候補あり／収まらずの2通り）。キャッシュ由来の注記はその後に前置きする
         （先に書いても showPublicationCandidateSet に上書きされて消えるため）。 */
      showPublicationCandidateSet(cachedFitEntry.candidateSet);
      var cacheStatusNode = el('cat-publication-status');
      cacheStatusNode.textContent = '「まとめて収める」で作成済みの候補です。' + cacheStatusNode.textContent;
    }
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
  /* 「収める候補」の文字目標の算出。1行ダイアログの generatePublicationCandidates と
     「まとめて収める」キューの両方がここを呼ぶ（生成部分の純粋な抽出。DOMは
     一切触らない。呼び出し側がそれぞれの見せ方をする）。
     実測できるときは使える幅から出す（収まりの見える化）。実幅が取れないセル
     （層が引けない・Excel以外）は、従来どおり「現訳の長さ×0.8」へフォールバック
     する（20字下限はそちらだけに残す。実測できた側では外す。理由は
     segmentFitCapacity の註）。サーバの使える窓 [8,99] へは、送る前にここで
     クランプする（クランプせずに99超をそのまま送ると、src/CopilotClient.ps1 が
     文字数の指示を1行も出さない一方で、画面だけが「実測した使える幅から算出」と
     言い続ける食い違いになる。CoD審査 2026-08-18 REWORK-1）。状態行は、
     クランプが効いたかどうかまで正直に言う。 */
  function computeFitBudget(segment) {
    var measuredCapacity = segmentFitCapacity(segment);
    var currentText = segmentFitText(segment);
    var maxChars = measuredCapacity ? measuredCapacity.maxChars : Math.max(20, Math.floor(currentText.length * 0.8));
    var note;
    if (measuredCapacity) {
      note = measuredCapacity.basis === 'below-min'
        ? '文字目標 8字（下限。実測の容量は ' + measuredCapacity.raw + '字）'
        : measuredCapacity.basis === 'above-max'
        ? '文字目標 99字（上限。実測の容量は ' + measuredCapacity.raw + '字）'
        : '文字目標 ' + measuredCapacity.maxChars + '字（実測した使える幅から算出）';
    } else {
      note = '文字目標 ' + maxChars + '字（実幅を測れないため、現訳の長さの目安から算出）';
    }
    return { maxChars: maxChars, measuredCapacity: measuredCapacity, note: note };
  }
  /* publication-candidates を投げてジョブを起こすだけの、状態を持たない口。
     1行ダイアログとキューの両方がここを呼ぶ（純粋な抽出）。 */
  function requestFitCandidateJobStart(index, maxChars, destinationCount) {
    return flush().then(function () { return post('publication-candidates', { index: index, max_chars: maxChars, destination_count: destinationCount }, true); });
  }
  function generatePublicationCandidates() {
    var index = Number(el('cat-publication-index').value), segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
    if (!segment) return;
    el('cat-publication-generate').disabled = true; el('cat-publication-status').textContent = '候補を作っています…';
    var destinationCount = segment.placement && segment.placement.destinations ? segment.placement.destinations.length : 1;
    var budget = computeFitBudget(segment);
    var maxChars = budget.maxChars;
    var maxCharsNote = el('cat-publication-maxchars-note');
    if (maxCharsNote) maxCharsNote.textContent = budget.note;
    return requestFitCandidateJobStart(index, maxChars, destinationCount).then(function (data) {
      publicationJobId = String(data.job_id || ''); if (!publicationJobId) throw new Error('候補作成を開始できませんでした。'); return pollPublicationCandidates(publicationJobId);
    }).catch(function (error) { el('cat-publication-status').textContent = error.message; el('cat-publication-generate').disabled = false; });
  }
  function applyPublicationCandidate(candidateId) {
    if (!publicationCandidateSet || !publicationJobId) return;
    var candidate = (publicationCandidateSet.candidates || []).find(function (item) { return String(item.candidate_id || '') === String(candidateId || ''); }); if (!candidate) return;
    el('cat-publication-status').textContent = '掲載訳だけを保存しています…';
    return post('publication-apply', { job_id: publicationJobId, candidate_set_id: publicationCandidateSet.candidate_set_id, candidate_id: candidateId, candidate_text_hash: candidate.text_hash, dependency_fingerprint: publicationCandidateSet.dependency_fingerprint, meaning_preservation_confirmed: true, reason: '原文・基準訳・候補を比較し、情報の欠落がないことを人が確認' }, true).then(function (data) {
      el('cat-publication-dialog').close(); el('cat-placement-dialog').close(); render(data, false); renderPreview(); status('Excelに入れる訳を保存しました。基準訳と翻訳メモリは変更していません。PDFを更新して印刷結果を確認してください。');
    }).catch(function (error) {
      /* humanMessage を通す: CAT_PUBLICATION_CANDIDATE_STALE はサーバの生コード
         がそのまま返ってくる（本文が無いコードなので Convert-YakuExceptionToUserMessage
         は日本語化しない）。キャッシュ由来の候補はこのエラーへ特に来やすい
         （CoD審査 REWORK-1 MEDIUM-M2b）。 */
      el('cat-publication-status').textContent = humanMessage(error.message);
      /* 適用が失敗した＝いま出ている候補はもう使えない可能性が高い（ジョブが
         30分retention・再起動で消えた、または fingerprint／text_hash が食い違った。
         CoD審査 2026-08-19 決定4）。キャッシュに残っていれば消し、「作り直す」で
         この場から回復できるようにする。 */
      var index = Number(el('cat-publication-index').value);
      var segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
      if (segment && segment.segment_id) delete fitBatchCandidateCache[String(segment.segment_id)];
      var regenerateButton = el('cat-publication-regenerate');
      if (regenerateButton) regenerateButton.hidden = false;
      el('cat-publication-generate').hidden = true;
    });
  }
  /* 「まとめて収める」で作った候補をこの場で作り直す（キャッシュを捨てて
     既存の生成経路をそのまま再実行するだけ。新しいAPIは作らない）。 */
  function regeneratePublicationCandidates() {
    var index = Number(el('cat-publication-index').value);
    var segment = (project && project.segments || []).find(function (item) { return Number(item.index) === index; });
    if (segment && segment.segment_id) delete fitBatchCandidateCache[String(segment.segment_id)];
    var regenerateButton = el('cat-publication-regenerate');
    if (regenerateButton) regenerateButton.hidden = true;
    el('cat-publication-generate').hidden = false;
    el('cat-publication-candidates').innerHTML = '';
    publicationJobId = ''; publicationCandidateSet = null;
    generatePublicationCandidates();
  }
  /* まとめて収める: キャッシュの読み書き・キュー本体。 */
  function fitBatchCacheEntry(segment) {
    var id = String(segment && segment.segment_id || ''); if (!id) return null;
    var entry = fitBatchCandidateCache[id];
    if (!entry) return null;
    /* 生成時から訳文が変わっていたら使わない（Ordinal一致）。サーバ側の最終
       判定は publication-apply が持つが、ここで先に落として「作り直す」へ
       誘導したほうが、押してから初めて食い違いに気づくより早い。 */
    if (String(segment.translation || '') !== entry.translationAtGeneration) { delete fitBatchCandidateCache[id]; return null; }
    return entry;
  }
  function cacheFitBatchResult(segment, jobId, candidateSet) {
    var id = String(segment && segment.segment_id || ''); if (!id) return;
    /* revisionAtGeneration は診断用の記録だけ（ログ・調査で「いつのproject
       revisionで作ったか」を辿るためだけに持つ）。有効性の判定には使わない
       ―― project.revision は行の編集以外（他行の確定・用語登録など）でも
       進むため、鮮度の根拠にすると無関係な変化でキャッシュを毎回捨てる側へ
       倒れる。有効性の唯一の根拠は translationAtGeneration（この行の訳文
       そのもの、fitBatchCacheEntry が Ordinal 一致で見る）。 */
    fitBatchCandidateCache[id] = { jobId: jobId, candidateSet: candidateSet || null, revisionAtGeneration: revision(), translationAtGeneration: String(segment.translation || '') };
  }
  /* サーバの直列契約（Start-YakuTranslationJob は同時1本しか許さず、超過は
     throw する。src/Server.ps1:949）。/api/cat/publication-candidates はこれを
     CAT_REQUEST_FAILED（400）として包み、専用の code は付けない（palette側の
     JOB_RUNNING/409 とは違う経路。src/Server.ps1:2606-2609 と 4186-4189 を
     比較して確認した）。よってここは応答本文の文言で拾う。 */
  function isJobRunningConflict(error) {
    return /別の翻訳が実行中です/.test(String((error && error.message) || ''));
  }
  /* キューだけが使う、DOMに触れない汎用ポーラー。1行ダイアログ側の
     pollPublicationCandidates は publicationJobId の陳腐化ガードと、1tickごとに
     独立した catch を持つ既存の作りに手を入れたくないため、あえて分けている
     （挙動を変えない、が優先）。 */
  function pollFitCandidateJob(jobId, onTick) {
    return YakuCommon.json('/api/jobs/' + encodeURIComponent(jobId)).then(function (data) {
      if (data.mode === 'done' || data.mode === 'completed_with_warnings') {
        if (data.application_status !== 'current') throw new Error('候補作成中に基準訳が変わりました。もう一度作り直してください。');
        return data;
      }
      if (['error', 'failed', 'interrupted', 'cancelled'].indexOf(data.mode) >= 0) throw new Error(data.detail || '候補を作れませんでした。');
      if (onTick) onTick(data);
      return new Promise(function (resolve) { window.setTimeout(resolve, 900); }).then(function () { return pollFitCandidateJob(jobId, onTick); });
    });
  }
  function fitBatchProgressText(position, total, percent) {
    return position + '/' + total + '行目を処理中…' + (percent > 0 ? '（' + percent + '%）' : '');
  }
  function fitBatchSummaryText(state, aborted) {
    var remaining = state.ids.length - state.cursor;
    var counts = '候補を作った行: ' + state.generated + '件 / 収まる候補が無かった行: ' + state.cannotFit + '件' + (state.errors ? ' / 作れなかった行: ' + state.errors + '件' : '') + '。';
    return (aborted && remaining > 0 ? '中断しました（残り' + remaining + '行）。' : '完了しました。') + counts;
  }
  function openFitBatchDialog() {
    if (busy) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
    var targets = fitBatchTargets();
    if (!targets.length) return;
    fitBatchQueue = null;
    el('cat-fit-batch-confirm').hidden = false;
    el('cat-fit-batch-confirm').textContent = targets.length + '行の短縮候補を順番に作ります。Copilotを' + targets.length + '回呼びます。';
    el('cat-fit-batch-progress').hidden = true; el('cat-fit-batch-progress').textContent = '';
    el('cat-fit-batch-summary').hidden = true; el('cat-fit-batch-summary').textContent = '';
    el('cat-fit-batch-filter').hidden = true;
    el('cat-fit-batch-abort').hidden = true;
    el('cat-fit-batch-start').hidden = false; el('cat-fit-batch-start').disabled = false;
    el('cat-fit-batch-close').hidden = false; el('cat-fit-batch-close').textContent = '閉じる';
    el('cat-fit-batch-dialog').showModal();
  }
  /* JOB_RUNNINGの再試行に上限を付ける（CoD審査 REWORK-1 MEDIUM-M3）。
     サーバが直列契約違反を返し続ける病的な状況でも、この行を永遠に
     待ち続けない（1回あたり1.5秒待ちなので、上限20回で最大約30秒）。
     超えたらその行だけをエラーとして数え、キューは次の行へ進む
     （「生成失敗した行があってもキューは続行」の一部として扱う）。 */
  var YAKU_FIT_BATCH_JOB_RUNNING_RETRY_LIMIT = 20;
  function beginFitBatchQueue() {
    var targets = fitBatchTargets();
    if (!targets.length) { el('cat-fit-batch-dialog').close(); return; }
    fitBatchQueue = { ids: targets.map(function (segment) { return String(segment.segment_id || ''); }), cursor: 0, generated: 0, cannotFit: 0, errors: 0, abortRequested: false, running: true, currentJobId: '', currentAttempt: 0 };
    setBusy(true);
    el('cat-fit-batch-confirm').hidden = true;
    el('cat-fit-batch-start').hidden = true;
    el('cat-fit-batch-close').hidden = true;
    el('cat-fit-batch-abort').hidden = false; el('cat-fit-batch-abort').disabled = false;
    el('cat-fit-batch-progress').hidden = false;
    el('cat-fit-batch-progress').textContent = fitBatchProgressText(1, fitBatchQueue.ids.length, 0);
    runFitBatchStep();
  }
  function continueFitBatchQueue() {
    if (!fitBatchQueue) return;
    if (fitBatchQueue.abortRequested) { finishFitBatchQueue(); return; }
    runFitBatchStep();
  }
  function runFitBatchStep() {
    var state = fitBatchQueue;
    if (!state || !state.running) return;
    if (state.abortRequested || state.cursor >= state.ids.length) { finishFitBatchQueue(); return; }
    var segment = (project && project.segments || []).find(function (item) { return String(item.segment_id || '') === state.ids[state.cursor]; });
    /* 行そのものが消えた（結合・分割・削除など）場合も、黙って飛ばさず
       エラーとして数える。数えないと 生成+収まらず+エラー の合計がNより
       小さくなり、要約の件数が対象行数と合わなくなる（CoD審査 REWORK-1 LOW-2）。 */
    if (!segment) { state.errors++; state.cursor++; state.currentAttempt = 0; runFitBatchStep(); return; }
    var position = state.cursor + 1, total = state.ids.length;
    el('cat-fit-batch-progress').textContent = fitBatchProgressText(position, total, 0);
    var index = Number(segment.index);
    var budget = computeFitBudget(segment);
    var destinationCount = segment.placement && segment.placement.destinations ? segment.placement.destinations.length : 1;
    requestFitCandidateJobStart(index, budget.maxChars, destinationCount).then(function (data) {
      /* job_id は abort の有無に関係なく必ず先に読む。ここを
         abortRequested のチェックより後に置くと、開始の往復中に押した
         中止がジョブを取り消さないまま捨ててしまい、サーバの直列枠
         （1ジョブしか同時に持てない）を握ったままになる。以降のあらゆる
         翻訳が「別の翻訳が実行中です」で失敗し続ける（CoD審査 REWORK-1
         BLOCKER-M1）。 */
      var jobId = String(data.job_id || '');
      if (state.abortRequested) {
        if (jobId) { state.currentJobId = jobId; YakuCommon.post('/api/cancel-translation', { job_id: jobId }).catch(function () {}); }
        finishFitBatchQueue();
        return;
      }
      if (!jobId) throw new Error('候補作成を開始できませんでした。');
      state.currentJobId = jobId;
      return pollFitCandidateJob(jobId, function (tick) {
        if (state.abortRequested) return;
        el('cat-fit-batch-progress').textContent = fitBatchProgressText(position, total, Math.max(0, Math.round(Number(tick.progress || 0))));
      }).then(function (result) {
        state.currentJobId = '';
        if (state.abortRequested) { finishFitBatchQueue(); return; }
        cacheFitBatchResult(segment, jobId, result.candidate_set);
        if (result.candidate_set && (result.candidate_set.candidates || []).length) state.generated++; else state.cannotFit++;
        state.cursor++; state.currentAttempt = 0;
        runFitBatchStep();
      });
    }).catch(function (error) {
      state.currentJobId = '';
      if (state.abortRequested) { finishFitBatchQueue(); return; }
      if (isJobRunningConflict(error)) {
        state.currentAttempt = (state.currentAttempt || 0) + 1;
        if (state.currentAttempt < YAKU_FIT_BATCH_JOB_RUNNING_RETRY_LIMIT) { window.setTimeout(continueFitBatchQueue, 1500); return; }
        /* 上限に達した。この行だけエラーとして数え、次の行へ進む
           （中止しなくても、いつか必ず終わる）。 */
      }
      state.errors++; state.cursor++; state.currentAttempt = 0; runFitBatchStep();
    });
  }
  function abortFitBatchQueue() {
    var state = fitBatchQueue;
    if (!state || !state.running || state.abortRequested) return;
    state.abortRequested = true;
    /* ここで disabled にしない（CoD審査 REWORK-1 MEDIUM-M3）。JOB_RUNNINGの
       再試行が上限（20回・最大約30秒）まで続く間、押せる状態のまま見せて
       いつでも出られることを示す。二重送信は abortRequested の早期returnで
       既に防いでいるので、押せたままでも安全。 */
    el('cat-fit-batch-progress').textContent = '中止しています…';
    if (state.currentJobId) YakuCommon.post('/api/cancel-translation', { job_id: state.currentJobId }).catch(function () {});
  }
  function finishFitBatchQueue() {
    var state = fitBatchQueue;
    if (!state || !state.running) return;
    state.running = false;
    setBusy(false);
    el('cat-fit-batch-progress').hidden = true;
    el('cat-fit-batch-summary').hidden = false;
    el('cat-fit-batch-summary').textContent = fitBatchSummaryText(state, state.abortRequested);
    el('cat-fit-batch-abort').hidden = true;
    el('cat-fit-batch-close').hidden = false;
    el('cat-fit-batch-filter').hidden = state.generated < 1;
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
      var isCurrent = String(item.id) === currentId;
      var name = documentDisplayName(item), meta = documentMeta(item, isCurrent).map(esc);
      return '<button type="button" class="cat-doc-choice' + (isCurrent ? ' is-current' : '') + '"' +
        (isCurrent ? ' aria-current="true" disabled' : '') +
        ' data-cat-doc-open="' + esc(item.id) + '">' +
        '<span class="cat-doc-choice-name">' + esc(name) + '</span>' +
        '<span class="cat-doc-choice-meta">' + meta.join('・') + '</span></button>';
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

  /* ラベルが変わるので、title も一緒に変える。「未訳 3」なのに title が
     「自動比較結果を表示します」のままだと、数字が何の数かラベルと title で
     食い違って読める（2026-08-18）。既定（資料が無い・止める指摘が無い）の
     文言は cat.html の静的 title（#cat-qa-open）と揃えてある。 */
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
    /* 資料単位の管理は資料オーバーレイへ移す。トップ帯は翻訳・出力・点検と、
       選択行の短い操作だけを残す。IDは移動しても既存のイベント契約を保つ。 */
    var docsHead = document.querySelector('#cat-docs-pane .cat-docs-pane-head');
    if (docsHead) {
      ['cat-switch-project', 'cat-source-update-open', 'cat-danger-zone'].forEach(function (id) {
        var control = el(id); if (control) docsHead.appendChild(control);
      });
    }
    var heavyPreview = el('cat-preview-open');
    if (heavyPreview) {
      heavyPreview.hidden = false;
      heavyPreview.setAttribute('aria-label', '体裁で見る');
      heavyPreview.title = '体裁で見る（詳細なプレビュー）';
      heavyPreview.innerHTML = icon('i-eye') + '<span class="cat-segment-button-label">体裁で見る</span>';
      heavyPreview.classList.add('cat-segment-button');
    }
    var tmButton = el('cat-tm-pretranslate');
    if (tmButton) {
      tmButton.textContent = '';
      tmButton.setAttribute('aria-label', '翻訳メモリから未訳を入力');
      tmButton.title = '翻訳メモリの完全一致を未訳の行へ先に入れます';
      tmButton.innerHTML = icon('i-translate') + '<span class="cat-segment-button-label">TMで下訳</span>';
      tmButton.classList.add('cat-segment-button');
    }
    var dockPreview = el('cat-preview-dock-toggle');
    if (dockPreview) {
      dockPreview.setAttribute('aria-label', 'プレビュータブを開く');
      dockPreview.innerHTML = icon('i-eye') + '<span class="cat-segment-button-label">プレビュー</span>';
      dockPreview.classList.add('cat-segment-button');
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
    el('cat-doc-switch').addEventListener('click', openDocDialog);
    /* 左の資料一覧。開閉と、その中からの切り替え。 */
    el('cat-docs-toggle').addEventListener('click', function () {
      applyDocsPane(!el('cat-editor-layout').classList.contains('is-docs-open'), true);
    });
    el('cat-docs-import').addEventListener('click', function () { showPicker(); YakuCommon.focus(el('cat-open-file-entry')); });
    el('cat-align-next-document').addEventListener('click', function () { showPicker(); YakuCommon.focus(el('cat-open-file-entry')); });
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
      YakuCommon.focus(el('cat-open-file-entry'));
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
      var params = new URLSearchParams(location.search);
      var wanted = params.get('project');
      if (wanted) { if (!project || String(project.id || '') !== wanted) resume(wanted); }
      else if (params.get('import') === '1') { showPicker(true); showStart('align'); }
      else if (params.get('view') === 'work') { showPicker(false, true); }
      else if (project) showPicker();
    });
    /* 通常の終了では確認を出さない。画面が隠れる直前に打ちかけを保存し、
       翻訳中の終了確認だけはcommon.jsが担当する。 */
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden' && !busy) { try { flush(); } catch (_) {} }
    });
    document.querySelectorAll('[data-cat-direction]').forEach(function (button) { button.addEventListener('click', function () { el('cat-direction-choice').hidden = true; if (pendingDirection) pendingDirection(button.getAttribute('data-cat-direction')); }); });
    /* 「Word・Excelを取り込む」は、ファイル選択をそのまま開く。押しても欄が
       開くだけだったころは、そこにもう一度「選ぶ」があり、さらに「取り込んで
       確認を始める」を押す必要があった（2026-08-13、利用者の指摘）。 */
    el('cat-open-file-entry').addEventListener('click', function () { directFilePath = ''; el('cat-file-input').value = ''; el('cat-file-input').click(); });
    /* 選んだ時点で取り込みを始める。押す回数を3回から1回にする。 */
    el('cat-file-input').addEventListener('change', function () {
      uploaded = null;
      directFilePath = '';
      if (this.files.length) openSource('file', 'auto');
    });
    /* 落とし先は外側の枠1か所だけにする（2026-08-16）。入口を1つにしたので
       #cat-file-area も #cat-open-file-entry も #quick-area の中にある。
       3か所へ付けると、ドロップが順に伝わって change が3回出て、同じファイルを
       3回取り込みにいく（drop は bubble する）。落とし先は枠だけに付ける。 */
    bindFileDrop(el('quick-area'), el('cat-file-input'));
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
    el('cat-align-source-file').addEventListener('change', function () { readPdfInto(this, 'source', '日本語版'); });
    el('cat-align-target-file').addEventListener('change', function () { readPdfInto(this, 'target', '英語版'); });
    /* ボタンは既定の見た目を持たない素の file input を隠して押す
       （cat-open-file-entry と同じ配線）。 */
    el('cat-align-source-file-open').addEventListener('click', function () { el('cat-align-source-file').click(); });
    el('cat-align-target-file-open').addEventListener('click', function () { el('cat-align-target-file').click(); });
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
    el('cat-translate').addEventListener('click', translate); el('cat-export').addEventListener('click', openExportPreflight);
    if (el('cat-preview-open-dock')) el('cat-preview-open-dock').addEventListener('click', openPreview);
    el('cat-export-reviewed').addEventListener('click', exportReviewed);
    el('cat-qa-open').addEventListener('click', openQaList);
    el('cat-document-review-run').addEventListener('click', runDocumentReview);
    el('cat-copilot-review-preview').addEventListener('click', previewCopilotDocumentReview);
    el('cat-qa-report-download').addEventListener('click', downloadQaReport);
    el('cat-document-finding-search').addEventListener('input',function(){var needle=String(this.value||'').trim().toLowerCase();document.querySelectorAll('#cat-document-findings .cat-document-finding').forEach(function(item){item.hidden=!!needle&&item.textContent.toLowerCase().indexOf(needle)<0;});});
    el('cat-copilot-review-run').addEventListener('click', runCopilotDocumentReview);
    el('cat-document-review-lenses').addEventListener('click', function (event) { var button = event.target.closest('[data-cat-coverage-key]'); if (button) acceptDocumentCoverage(button.getAttribute('data-cat-coverage-key'), button); });
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

    el('cat-preview-open').addEventListener('click', openPreview);
    el('cat-preview-dock-toggle').addEventListener('click', function () {
      inspectorTab = 'preview';
      setDockOpen(true, true);
      renderInspector();
    });
    el('cat-preview-dock-close').addEventListener('click', function () { setDockOpen(false, true); });
    bindDockSplitter();
    restoreDockState();
    el('cat-preview-pdf-update').addEventListener('click', updatePdfPreview);
    el('cat-preview-pdf-check').addEventListener('click', checkPdfPublicationText);
    el('cat-preview-pdf-accept').addEventListener('click', acceptPdfVisualReview);
    el('cat-placement-form').addEventListener('submit', savePlacement);
    el('cat-placement-cancel').addEventListener('click', function () { el('cat-placement-dialog').close(); });
    el('cat-placement-down').addEventListener('change', function () { renderPlacementSliceEditors(Number(this.value || 0)); });
    el('cat-publication-open').addEventListener('click', openPublicationCandidates);
    el('cat-publication-close').addEventListener('click', function () { el('cat-publication-dialog').close(); });
    el('cat-publication-generate').addEventListener('click', generatePublicationCandidates);
    el('cat-publication-regenerate').addEventListener('click', regeneratePublicationCandidates);
    el('cat-fit-batch-start').addEventListener('click', beginFitBatchQueue);
    el('cat-fit-batch-abort').addEventListener('click', abortFitBatchQueue);
    el('cat-fit-batch-close').addEventListener('click', function () { el('cat-fit-batch-dialog').close(); });
    el('cat-fit-batch-filter').addEventListener('click', function () { el('cat-fit-batch-dialog').close(); currentFilter = 'fit'; redrawAfterFlush(); });
    /* 実行中はESCでも閉じさせない。止めたいときは必ず「中止」を押させる
       （閉じただけで裏へ回る、という曖昧な状態を作らない）。 */
    el('cat-fit-batch-dialog').addEventListener('cancel', function (event) { if (fitBatchQueue && fitBatchQueue.running) event.preventDefault(); });
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
    /* 下部ドックは畳める。閉じると、原文と訳文が高さを使う。次に開いたときも
       同じ状態にする（市販CATでも補助ペインの開閉は覚える）。 */
    (function () {
      var toggle = el('cat-inspector-toggle');
      if (!toggle) return;
      syncInspectorToggle();
      toggle.addEventListener('click', function () {
        setDockOpen(!dockOpen, true);
        if (dockOpen) renderInspector();
      });
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
      var candidate = event.target.closest ? event.target.closest('[data-cat-candidate-index]') : null;
      if (!candidate || event.target.closest('button,a,input,textarea,select')) return;
      selectCandidateDetail(Number(candidate.getAttribute('data-cat-candidate-index')));
    });
    document.addEventListener('click', function (event) {
      var button = event.target.closest('button'); if (!button) return;
      if (busy && (button.id === 'cat-confirm-bulk' || button.id === 'cat-align-register-bulk' || button.id === 'cat-fit-batch-open' || button.id === 'cat-replace-run' || button.id === 'cat-replace-undo' || button.id === 'cat-structure-undo' || button.id === 'cat-tm-pretranslate' || button.hasAttribute('data-cat-translate-row') || button.hasAttribute('data-cat-confirm') || button.hasAttribute('data-cat-unconfirm') || button.hasAttribute('data-cat-tm-register') || button.hasAttribute('data-cat-revert') || button.hasAttribute('data-cat-merge') || button.hasAttribute('data-cat-split') || button.hasAttribute('data-cat-split-at') || button.hasAttribute('data-cat-glossary') || button.hasAttribute('data-cat-insert') || button.hasAttribute('data-cat-term-open') || button.hasAttribute('data-cat-term-insert') || button.hasAttribute('data-cat-term-edit') || button.hasAttribute('data-cat-term-deactivate') || button.hasAttribute('data-cat-term-exception') || button.hasAttribute('data-cat-tm-delete') || button.hasAttribute('data-cat-accept-revision') || button.hasAttribute('data-cat-revert-revision') || button.hasAttribute('data-cat-review-note-state') || button.hasAttribute('data-cat-fit-candidates'))) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
      if (button.hasAttribute('data-cat-preview-mode')) { setPreviewMode(button.getAttribute('data-cat-preview-mode')); return; }
      if (button.hasAttribute('data-cat-preview-side')) { previewSide = button.getAttribute('data-cat-preview-side') || 'target'; renderPreview(); return; }
      if (button.hasAttribute('data-cat-dock-side')) { dockSide = button.getAttribute('data-cat-dock-side') || 'target'; renderDockPreview(); return; }
      if (button.hasAttribute('data-cat-pdf-side')) {
        var pdfSide = button.getAttribute('data-cat-pdf-side') || 'target';
        if (previewRenderId) showRenderedPdf(previewRenderId, pdfSide).catch(function (error) { el('cat-preview-pdf-status').textContent = error.message; });
        else { previewPdfSide = pdfSide; document.querySelectorAll('[data-cat-pdf-side]').forEach(function (item) { item.setAttribute('aria-pressed', String(item === button)); }); }
        return;
      }
      if (button.hasAttribute('data-cat-placement-edit')) { return openPlacementEditor(button.getAttribute('data-cat-placement-edit')); }
      if (button.hasAttribute('data-cat-fit-candidates')) { return openFitPublicationFlow(button.getAttribute('data-cat-fit-candidates')); }
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
      if (button.hasAttribute('data-cat-inspector')) {
        inspectorTab = button.getAttribute('data-cat-inspector') || 'candidates';
        /* 行リボンから文脈・点検結果を開いた場合も、畳んだままでは
           選択先が見えない。先にドックを開いてから内容を描き直す。 */
        setDockOpen(true, true);
        renderInspector();
        if (inspectorTab === 'preview') renderDockPreview();
        return;
      }
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
        if (!window.confirm('翻訳をやめますか？\n\nここまでにできあがった訳文は保存されています。\nあとで「Copilotで未訳を翻訳」を押すと、続きから再開できます。')) return;
        button.disabled = true; button.textContent = 'やめています…';
        return YakuCommon.post('/api/cancel-translation', { job_id: button.getAttribute('data-yaku-cancel-job') })
          .catch(function (error) { status(error.message, true); });
      }
      if (button.hasAttribute('data-cat-personal-remove')) return removePersonalGlossary(button);
      if (button.hasAttribute('data-cat-resume')) return resume(button.getAttribute('data-cat-resume'));
      if (button.id === 'cat-confirm-bulk') return confirmBulk(button);
      if (button.id === 'cat-align-register-bulk') return registerAlignmentTranslationMemoryBulk();
      if (button.id === 'cat-fit-batch-open') return openFitBatchDialog();
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
            renderInspector();
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
      if (event.target.id === 'cat-review-notes-input') {
        var draftSegment = activeSegment(), draftKey = reviewNoteDraftKey(project, draftSegment);
        if (draftKey) reviewNoteDrafts[draftKey] = String(event.target.value || '');
        return;
      }
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
      if (dockOpen && inspectorTab === 'revisions') renderInspector();
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
      var candidate = event.target.closest && event.target.closest('[data-cat-candidate-index]');
      if (candidate) selectCandidateDetail(Number(candidate.getAttribute('data-cat-candidate-index')));
      var input = event.target.closest('[data-cat-input]');
      if (input) { activeIndex = Number(input.getAttribute('data-cat-input')); var row = input.closest('[data-cat-row]'); activeSegmentId = row ? String(row.getAttribute('data-cat-segment-id') || '') : activeSegmentId; renderInspector(); }
    });
    document.addEventListener('submit', function (event) {
      if (event.target.id === 'cat-concordance-form') { event.preventDefault(); runConcordance(); return; }
      if (event.target.id === 'cat-review-notes-form') {
        event.preventDefault();
        if (busy) { status('処理中です。終わってからもう一度お試しください。'); return; }
        var noteSegment = activeSegment(), noteInput = el('cat-review-notes-input'), noteKey = reviewNoteDraftKey(project, noteSegment), noteProjectId = String(project && project.id || ''), noteSegmentId = String(noteSegment && noteSegment.segment_id || ''), noteText = String(noteInput && noteInput.value || '').trim();
        if (!noteSegment) { status('作業メモを付ける行を選んでください。', true); return; }
        if (!noteText) { status('作業メモを入力してください。', true); if (noteInput) YakuCommon.focus(noteInput); return; }
        return mutate('review-note-add', { index: Number(noteSegment.index), text: noteText }, '作業メモを保存しています…').then(function (data) {
          if (data) {
            if (noteKey) delete reviewNoteDrafts[noteKey];
            var currentNoteSegment = activeSegment();
            if (noteInput && String(project && project.id || '') === noteProjectId && String(currentNoteSegment && currentNoteSegment.segment_id || '') === noteSegmentId) noteInput.value = '';
            status('作業メモを追加しました。');
          }
          return data;
        });
      }
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
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') { event.preventDefault(); YakuCommon.focus(el('cat-search')); el('cat-search').select(); return; }
      /* 検索と置換。memoQ・Phrase・Trados・XTM のどれも Ctrl+H である。
         開くだけで、押すのは中の「置き換える」ボタン。 */
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'h' && !el('cat-workspace').hidden) {
        event.preventDefault();
        var replaceMenu = el('cat-search-menu');
        if (replaceMenu) { replaceMenu.open = true; }
        var selected = String(window.getSelection ? window.getSelection().toString() : '');
        if (selected) { el('cat-search').value = selected; redrawAfterFlush(); }
        YakuCommon.focus(el('cat-search')); el('cat-search').select();
        return;
      }
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
      /* 原文の途中で分ける。Alt+M / Alt+K と同じ並びに置く。市販CATも同じ場所に
         割り当てている（memoQ Ctrl+T / Phrase Ctrl+E）。ブラウザが握る組み合わせは
         避けるので Alt にそろえる。 */
      if (event.altKey && !event.ctrlKey && !event.metaKey && event.key.toLowerCase() === 's') {
        event.preventDefault();
        var splitAtButton = document.querySelector('[data-cat-split-at="' + activeIndex + '"]');
        if (splitAtButton) { splitAtButton.click(); }
        else { status('この行は原文の途中では分けられません。つなげた行は、先に Alt+K で元に戻してください。'); }
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
    /* 検索の掛け方を変えたら、表も置換の帯も引き直す。置換後の文字列だけは
       表を絞らないので、帯の行数だけを数え直す。 */
    el('cat-search-case').addEventListener('change', function () { searchCase = !!this.checked; redrawAfterFlush(); });
    el('cat-search-regex').addEventListener('change', function () { searchRegex = !!this.checked; redrawAfterFlush(); });
    el('cat-replace-input').addEventListener('input', function () { if (project) renderSearchTools(); });
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
        el('cat-file-input').value = '';
        directFilePath = filePath;
        openSource('file', 'auto');
        return;
      }
      var text = String(detail.text || '');
      if (!text.trim()) return;
      /* パレットからの昇格は、明示に選んだ方向を運んでくることがある
         （quick.js の貼り付け欄からの受け口はここを渡さないので常に auto）。
         to_en/to_jp 以外は auto のまま——方向は確認画面で選び直せる。 */
      var handoffDirection = detail.direction === 'to_en' || detail.direction === 'to_jp' ? detail.direction : 'auto';
      /* 先に選ぶ画面へ戻してから始める。訳す向きを聞き返されたときの二択は
         選ぶ画面の中に居るので、隠したままだと行き止まりになる。 */
      showPicker();
      el('quick-input').value = text;
      openSource('text', handoffDirection);
    });
  }

  /* パレット(/palette)の昇格を、起動時に一度だけ受け取る。sessionStorage は
     読んだ瞬間に消す（読み捨て。ブラウザの戻る・再読み込みで二重に発火
     しない）。既存の yaku-instant-handoff 受け口へそのまま渡すだけで、
     その処理（showPicker/openSourceの配線）は複製しない。
     キー欠落・本文空・JSON壊れのいずれも、何もせず通常起動に落ちる。 */
  function consumePaletteHandoff() {
    var raw = '';
    try {
      raw = window.sessionStorage.getItem(paletteHandoffStorageKey) || '';
      window.sessionStorage.removeItem(paletteHandoffStorageKey);
    } catch (error) { return false; }
    if (!raw) return false;
    var payload = null;
    try { payload = JSON.parse(raw); } catch (error) { return false; }
    var text = payload && typeof payload.text === 'string' ? payload.text : '';
    if (!text.trim()) return false;
    var directionIntent = payload && payload.direction_intent;
    window.dispatchEvent(new CustomEvent('yaku-instant-handoff', { detail: { text: text, direction: directionIntent } }));
    return true;
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
    /* パレット(/palette)の「CATで開く」から来たとき(?handoff=palette)。
       consumePaletteHandoff が読み捨てと既存受け口への引き渡しを済ませる。
       何かを渡せたら、そこから先(showPicker等)はその受け口の中で完結する。 */
    if (params.get('handoff') === 'palette' && consumePaletteHandoff()) return;
    var importMeta = document.querySelector('meta[name="yaku-import"]');
    var importMode = importMeta && importMeta.getAttribute('content') === '1';
    var workMode = params.get('view') === 'work';
    /* ?import=1 で開いたときは、過去の対訳の取り込み欄をそのまま出す。
       この画面だけ WebAssembly が使える（PDF の解析に要る）。
       showPicker は通常 /cat へ戻すが、import 起動だけURLを保持する。 */
    if (importMode) { showPicker(importMode); showStart('align'); return; }
    if (workMode) { showPicker(false, true); return; }
    showPicker();
    if (cameFromInstant && window.YakuInstant) window.YakuInstant.show();
  }
  window.YakuCat = { isBusy: function () { return busy; } };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
