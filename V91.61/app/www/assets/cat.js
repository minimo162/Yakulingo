(function () {
  'use strict';
  var ready = false, busy = false, project = null, pendingDirection = null, uploaded = null;
  var dirty = new Map(), saveChain = Promise.resolve(), jobTimer = null, jobContext = null, candidateSeq = 0;
  var deleteTarget = null, preflightScope = null, jobSerial = 0, viewEpoch = 0, outputScope = null;
  var activeSegmentId = '', activeIndex = -1, currentFilter = 'actionable', currentLocation = 'all', currentChange = 'all', inspectorTab = 'candidates';
  var revisionComparison = null;
  var termSelection = { index: -1, source: '', target: '' };
  function el(id) { return document.getElementById(id); }
  function esc(value) { return YakuCommon.escape(value); }
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
  function saveStatus(text, error) { el('cat-save-status').textContent = text || ''; el('cat-current-save').textContent = text || '保存済み'; el('cat-save-status').classList.toggle('is-error', !!error); el('cat-current-save').classList.toggle('is-error', !!error); }
  function revision() { return project ? Number(project.revision) || 0 : -1; }
  function currentScope() { return project ? { id: String(project.id || ''), revision: revision() } : null; }
  function scopeIsCurrent(scope, checkRevision) {
    return !!(scope && project && String(project.id || '') === scope.id && (!checkRevision || revision() === scope.revision));
  }
  function dirtyKey(projectId, index) { return String(projectId || '') + ':' + String(index); }
  /* 開いている資料をアドレスに残す。スリープ復帰やネットワーク切替でシェルが
     読み込み直したとき、ここが空だと作業一覧へ戻ってしまう。 */
  function syncLocation(projectId) {
    try {
      var next = projectId ? ('/cat?project=' + encodeURIComponent(projectId)) : '/cat';
      if (location.pathname + location.search !== next) window.history.replaceState(null, '', next);
    } catch (_) {}
  }
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
    return YakuCommon.post('/api/cat/' + action, body);
  }
  function directionName(value) { return value === 'to_jp' ? '日本語に訳す作業' : '英語に訳す作業'; }
  /* 画面は一つで、状態は二つ（始める／1文ずつ確認する）。どれが出ているかは
     body の data-cat-view に書く。
     器の高さを窓に固定する規則（cat-workspace.css）は、一覧が主役の確認作業に
     しか合わない。選ぶ画面とその場で訳す状態は、内容の丈だけ縦に伸びてよい。 */
  function setView(name) { document.body.setAttribute('data-cat-view', name); }
  function showPicker() { syncLocation(''); viewEpoch++; candidateSeq++; project = null; activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; termSelection = { index: -1, source: '', target: '' }; dirty.clear(); clearOutputDisplay(); setView('start'); el('cat-picker').hidden = false; el('cat-workspace').hidden = true; el('cat-current-summary').hidden = true; closeStartPanels(); loadRecent(); }
  function closeStartPanels() { document.querySelectorAll('.cat-start-panel').forEach(function (panel) { panel.hidden = true; }); el('cat-direction-choice').hidden = true; }
  function showStart(mode) { closeStartPanels(); var panel = el('cat-source-' + mode); if (panel) { panel.hidden = false; YakuCommon.focus(panel.querySelector('input,textarea,[role="button"],button')); } }
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
        : !ready ? 'Copilotを準備しています（あと1〜2分）'
        : (project && Number(project.untranslated) <= 0) ? '訳案はすべてできています'
        : '残りの訳案を作る';
    }
  }
  /* Copilot は3時間の窓で使える回数に上限がある（値は非公開）。押したあとに上限へ
     当たると、そのバッチぶんの往復が無駄になる。サーバは以前から estimate で
     「この操作で何回使うか」「直近3時間で何回使ったか」を返していたが、画面が
     一度も呼んでいなかった。押す前に出す。 */
  var usageSeq = 0;
  function refreshCopilotUsage() {
    var host = el('cat-copilot-usage');
    if (!host) return;
    var scope = currentScope();
    if (!scope || !project || Number(project.untranslated) <= 0) { host.hidden = true; return; }
    var seq = ++usageSeq;
    return YakuCommon.post('/api/cat/estimate', { id: scope.id }).then(function (data) {
      if (seq !== usageSeq || !scopeIsCurrent(scope, true)) return;
      var calls = Number(data && data.estimated_calls) || 0;
      var recent = Number(data && data.calls_last_3h) || 0;
      if (calls <= 0) { host.hidden = true; return; }
      host.textContent = 'この操作でCopilotを約' + calls + '回使います（直近3時間で' + recent + '回）';
      host.hidden = false;
    }).catch(function () { if (seq === usageSeq) host.hidden = true; });
  }

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
      /* 1行でも確認済みなら取り出せる。全行そろうのを待たせない。 */
      el('cat-export-reviewed').disabled = !project || Number(project && project.confirmed) <= 0 || dirty.size > 0;
      document.querySelectorAll('[data-cat-filter],[data-cat-location],[data-cat-change],[data-cat-inspector]').forEach(function (button) { button.disabled = false; });
    }
  }

  function loadRecent() {
    return post('recent', {}).then(function (data) {
      var items = data.projects || [], box = el('cat-resume'), list = el('cat-resume-list');
      box.hidden = !items.length;
      list.innerHTML = items.map(function (item, i) {
        var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
        return '<button type="button" class="cat-resume-card secondary-button" data-cat-resume="' + esc(item.id) + '">' + (i === 0 ? '<span class="cat-resume-recent">前回開いた作業</span>' : '') + '<span>' + esc(item.file_name || '名称未設定') + '・' + esc(directionName(item.direction)) + '・' + (remaining ? 'あと' + remaining + '行' : '確認完了') + '</span></button>';
      }).join('');
    }).catch(function (error) { el('cat-resume').hidden = false; el('cat-resume-list').innerHTML = '<div class="alert alert-error">途中まで進めた作業の一覧を読み込めませんでした。画面を読み込み直してください（Ctrl+R）。' + esc(error.message) + '</div>'; });
  }

  function qcMessages(segment) {
    var labels = {
      empty: '訳文が空です。', 'invalid-or-source-fallback': '訳文として成立していないか、原文のままです。',
      'placeholder-residue': '訳文に「[[N1]]」のような記号が残っています。左の原文の同じ位置にある数字に、手で置き換えてください。', 'numeric-integrity': '左の原文と、訳文の数字または単位が合っていません。原文を見ながら直してください。',
      'numeric-value-mismatch': '原文にある数字が、訳文で違う値になっているか、抜けています。原文と見比べてください。', 'numeric-value-extra': '原文に無い数字が訳文に入っています。余分な数字を消してください。',
      'numeric-scale-mismatch': '数字の桁（億・百万など）が原文と合っていません。原文の単位をご確認ください。', 'numeric-sign-missing': '損失や減少を示すマイナスが訳文に入っていません。原文をご確認ください。',
      'accounting-polarity-mismatch': '利益と損失、または増加と減少が、原文と逆になっているようです。原文と見比べてください。', 'currency-mismatch': '通貨（円・ドルなど）が原文と合っていません。原文をご確認ください。',
      'proper-noun-missing': '会社名や人名が訳文に入っていないようです。左の原文を見て、必要なら書き足してください。', 'structure-integrity': '見出しや箇条書きの形が原文と違っています。原文と見比べてください。'
      , 'terminology-missing': '登録した訳語が使われていません。右の「用語・参考訳」に出ている訳語をお使いください。この行だけ別の言い方にしたい場合は、その行の設定から外せます。'
      , 'terminology-forbidden': '「使わない」と登録した表現が訳文に入っています。右の「用語・参考訳」に出ている訳語に置き換えてください。'
      , 'terminology-check-unavailable': '登録した用語を読み込めませんでした。いったんアプリを閉じて開き直してください。それでも直らない場合は、この画面のまま管理者へご連絡ください。'
      , 'terminology-conflict': '同じ語に、必ず使う訳が2つ以上登録されています。どちらか一方を「作業の管理」から取り消してください。'
    };
    return (segment.qc_findings || []).map(function (finding) { var code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-'); return labels[code] || '自動点検で気になる点が見つかりました。左の原文と見比べてください。'; });
  }
  /* 点検の指摘は「何が起きたか」で分かれる。14種を全部おなじ赤で出すと、
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
  function stateTitle(state) { return state === 'reviewed' ? '確認済み' : state === 'human_edited' ? '手直し済み・未確認' : state === 'machine_draft' ? 'Copilotの訳案・未確認' : state === 'stale' ? '原文が変わったので再確認が必要' : 'まだ訳がありません'; }
  function originLabel(origin) {
    if (origin === 'glossary') return '用語集';
    if (origin === 'copilot') return 'Copilot訳';
    if (origin === 'manual') return '手直し';
    if (origin === 'carried_forward' || origin === 'numeric_update') return '自分が確認した訳';
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
    var all = project.segments || [], counts = { actionable: 0, untranslated: 0, unconfirmed: 0, qc: 0, reviewed: 0, all: all.length };
    all.forEach(function (segment) {
      if (segmentActionable(segment)) counts.actionable++;
      if (segmentState(segment) === 'untranslated') counts.untranslated++;
      if (!segment.confirmed) counts.unconfirmed++;
      if (segmentHasQc(segment)) counts.qc++;
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
    var locationSection = el('cat-location-list').closest('section');
    if (locationSection) locationSection.hidden = locationNames.length < 2;
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
    }).join('') : '<div class="cat-qc-card">数字と単位の自動点検では、気になる点は見つかりませんでした。言い回しが適切かどうかは、ご自身でお確かめください。</div>';
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
      var findings = qcMessages(segment), findingId = 'cat-qc-' + index, origin = originLabel(segment.origin), ops = '';
      var nextSegment = all.find(function (candidate) { return Number(candidate.index) === index + 1; });
      var mergeLosesTranslation = !!(String(segment.translation || '').trim() || (nextSegment && String(nextSegment.translation || '').trim()));
      var splitLosesTranslation = !!String(segment.translation || '').trim();
      if (segment.can_merge) ops += '<button type="button" class="cat-op secondary-button" data-cat-merge="' + index + '" data-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '">' + icon('i-merge') + '次の行とつなげて1文にする</button>';
      if (segment.can_split) ops += '<button type="button" class="cat-op secondary-button" data-cat-split="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '">' + icon('i-split') + 'つなげた行を元に戻す</button>';
      var prior = (segment.prior_translation || segment.prior_source) ? '<details><summary>前回版を見る</summary>' + (segment.prior_source ? '<div><strong>前回の原文</strong><br>' + esc(segment.prior_source) + '</div>' : '') + (segment.prior_translation ? '<div><strong>前回の訳文</strong><br>' + esc(segment.prior_translation) + '</div>' : '') + '</details>' : '';
      var qc = findings.length ? '<div id="' + findingId + '" class="cat-qc-findings" role="alert">' + findings.map(function (m) { return '<div>' + esc(m) + '</div>'; }).join('') + '</div>' : '';
      var usage = segment.reference_usage || null;
      var referenceTrace = usage ? '<div class="cat-example-trace"><p>この参考訳から挿入（その後編集' + (usage.edited_after_insert ? 'あり' : 'なし') + '）・' + esc(usage.source_name || '資料名なし') + (usage.location ? '・' + esc(usage.location) : '') + (Number(usage.page) > 0 ? '・ページ ' + Number(usage.page) : '') + '</p>' +
        ((usage.source || usage.translation) ? '<details><summary>使った参考訳を確認</summary>' + (usage.source ? '<div><strong>原文</strong><br>' + esc(usage.source) + '</div>' : '') + (usage.translation ? '<div><strong>訳文</strong><br>' + esc(usage.translation) + '</div>' : '') + '</details>' : '') + '</div>' : '';
      var generatedTerms = (segment.terminology_generation || []).filter(Boolean).length ? '<details class="cat-term-trace"><summary>訳案作成時に指定した用語 ' + segment.terminology_generation.filter(Boolean).length + '件</summary>' + segment.terminology_generation.filter(Boolean).map(function (term) { return '<div><strong>' + esc(term.source || '') + '</strong> → ' + esc(term.preferred || '') + '</div>'; }).join('') + '</details>' : '';
      var compare = revisionComparison && revisionComparison.projectId === String(project.id || '') && Number(revisionComparison.index) === index ? '<section class="cat-revision-compare" aria-labelledby="cat-revision-title-' + index + '"><h4 id="cat-revision-title-' + index + '">修正結果を確認</h4><div class="cat-revision-pair"><div><strong>変更前</strong><p>' + esc(revisionComparison.before) + '</p></div><div><strong>変更後</strong><p>' + esc(segment.translation || '') + '</p></div></div><p class="muted">数字と単位は自動で点検しました。言い回しが適切かどうかは、ご自身でお確かめください。</p><div class="cat-revision-actions"><button type="button" data-cat-accept-revision="' + index + '">この案を使う</button><button type="button" class="secondary-button" data-cat-revert-revision="' + index + '">元に戻す</button></div></section>' : '';
      var kind = segment.kind === 'cell' ? 'セル' : /^word_/.test(segment.kind || '') ? 'Word' : '文';
      var target = isActive ? '<textarea rows="3" data-cat-input="' + index + '" data-cat-project-id="' + esc(project.id) + '" data-original="' + esc(segment.translation || '') + '" aria-label="' + row + '行目の訳文" aria-invalid="' + (findings.length ? 'true' : 'false') + '"' + (findings.length ? ' aria-describedby="' + findingId + '"' : '') + '>' + esc(segment.translation || '') + '</textarea>' + prior + referenceTrace + generatedTerms + '<div class="cat-row-primary">' + (segment.confirmed ? '<button type="button" class="cat-op secondary-button" data-cat-unconfirm="' + index + '">' + icon('i-undo') + '確認を取り消す</button>' : '<button type="button" class="cat-op cat-op-ok" data-cat-confirm="' + index + '">' + icon('i-reviewed') + '確認済みにする</button>') + '</div><details class="cat-more-row"><summary>この行のそのほかの操作</summary><div class="cat-ops">' + ops + '</div>' + '<button type="button" class="cat-op secondary-button" data-cat-revert="' + index + '" hidden>編集を取り消す</button>' + (segment.translation ? '<button type="button" class="cat-op secondary-button" data-cat-term-open="' + index + '">用語を登録</button>' : '') + ((segment.kind === 'cell' && segment.translation && String(segment.source).length <= 40) ? '<button type="button" class="cat-op secondary-button" data-cat-glossary="' + index + '">このセルの訳を今後も自動で使う</button>' : '') + '</details>' + qc + compare + (segment.can_revise ? '<details class="cat-more-row"><summary>Copilotに直してもらう</summary><form class="revise-form" data-cat-revise="' + index + '"><button class="secondary-button" type="button" data-cat-shorten="' + index + '">短くする</button><label class="revise-label">または、どこをどう直すか入力</label><div class="revise-row"><input class="revise-input" type="text" placeholder="例：「increase」を「rise」に変える"><button class="secondary-button" type="submit">この指示で直す</button></div></form></details>' : '') : '<button type="button" class="cat-row-activate" data-cat-activate="' + index + '"><span class="cat-target-preview">' + esc(segment.translation || '') + '</span></button>';
      var change = changeLabel(segment);
      return '<tr class="' + (isActive ? 'is-active' : '') + '" data-cat-row="' + index + '" data-cat-segment-id="' + esc(segment.segment_id || '') + '" data-cat-confirmed="' + (segment.confirmed ? '1' : '0') + '" data-yaku-cat-state="' + esc(state) + '">' +
        '<td class="cat-col-no"><span class="cat-card-label">行番号・状態</span>' + row + '<span class="cat-state cat-state-' + esc(state) + '" title="' + esc(stateTitle(state)) + '">' + stateIcon(state) + '<span>' + esc(stateLabel(state)) + '</span></span>' + ((change && isActive) ? '<span class="cat-change-badge cat-change-' + esc(changeGroup(segment)) + '" title="' + esc(changeTitle(segment)) + '">' + esc(change) + '</span>' : '') + '</td>' +
        '<td class="cat-col-loc"><span class="cat-card-label">場所</span><span class="cat-location-main">' + esc(segment.location || '本文') + '</span><span class="cat-location-kind">' + esc(kind) + '</span>' + (origin ? '<span class="cat-origin">' + esc(origin) + '</span>' : '') + '</td>' +
        /* 開いている行は、原文を上・訳文を下に積んで表の全幅を使う。左右2列は視線が
           横へ飛ぶうえ、「文字を大きく」だと1列が日本語11文字まで痩せる。上下配置の
           ほうが速いことは Läubli et al.(arXiv:2011.05978) の統制実験で示されている。
           閉じている行は一望性が要るので、従来どおり左右のままにする。 */
        (isActive
          ? '<td class="cat-work" colspan="2"><div class="cat-work-source"><span class="cat-work-label">原文</span><span class="cat-source-text">' + esc(segment.source) + '</span></div><div class="cat-work-target"><span class="cat-work-label">訳文</span>' + target + '</div></td>'
          : '<td class="cat-source"><span class="cat-card-label">原文</span><button type="button" class="cat-row-activate" data-cat-activate="' + index + '"><span class="cat-source-text">' + esc(segment.source) + '</span></button></td>') +
        (isActive ? '' : '<td class="cat-target"><span class="cat-card-label">訳文</span>' + target + '<span class="cat-row-flag"></span></td>') + '</tr>';
    }).join('');
    /* 翻訳中に絞り込みを変えると行が作り直される。編集不可の状態を引き継ぐ。 */
    if (busy) body.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.readOnly = true; });
    body.querySelectorAll('textarea[data-cat-input]').forEach(autoGrow);
    el('cat-candidates').hidden = false;
    if (current) candidates(Number(current.index)); else { el('cat-candidate-count').textContent = '0'; el('cat-candidates-list').innerHTML = '<p class="muted">行がありません。左の「すべて」を押すと、全部の行が表示されます。</p>'; }
  }

  function outputGuidance() {
    var left = Math.max(0, Number(project.total) - Number(project.confirmed));
    if (Number(project.untranslated) > 0) return '残り' + project.untranslated + '行の訳案を作ってください。';
    if (left > 0) return 'あと' + left + '行を確認済みにしてください。';
    return project.export_blocked ? '検査結果を確認し、必要な行を直してください。' : '';
  }
  function render(data, focusFirst) {
    var previousProjectId = project ? String(project.id || '') : '';
    if (data) project = data;
    if (!project) return;
    syncLocation(String(project.id || ''));
    if (previousProjectId && previousProjectId !== String(project.id || '')) { activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; }
    if (outputScope && (outputScope.id !== String(project.id || '') || outputScope.revision !== revision())) clearOutputDisplay();
    dirty.clear(); candidateSeq++;
    /* 画面遷移なしで確認作業へ入る道（その場で訳す → 長すぎるので渡す）ができた。
       外枠の広げ直しは読み込み完了に紐づいているので、その道では効かない。
       状態が変わったことを外枠へ知らせる。 */
    if (el('cat-workspace').hidden) YakuCommon.notifyDesktopShell('cat-workspace-opened');
    setView('workspace');
    el('cat-picker').hidden = true; el('cat-workspace').hidden = false; el('cat-current-summary').hidden = true;
    el('cat-current-title').textContent = project.file_name || '貼り付けた文章';
    el('cat-current-progress').textContent = directionName(project.direction) + '・全' + project.total + '行のうち' + project.confirmed + '行を確認済み・残り' + Math.max(0, project.total - project.confirmed) + '行';
    el('cat-toolbar-title').textContent = project.file_name || '貼り付けた文章';
    el('cat-toolbar-direction').textContent = directionName(project.direction);
    var pct = project.total ? Math.round(100 * Number(project.confirmed) / Number(project.total)) : 0;
    el('cat-progress-bar').style.width = pct + '%'; el('cat-progress-row').querySelector('[role="progressbar"]').setAttribute('aria-valuenow', String(pct)); el('cat-progress-text').textContent = project.confirmed + ' / ' + project.total + '行を確認済み';
    renderRows();
    var isFile = project.source === 'file', sourceMissing = (project.eligibility_reasons || []).indexOf('source-file-missing') >= 0;
    var wordReady = project.document_format === 'docx' && project.word_file_output_supported && !sourceMissing;
    var draft = isFile && !sourceMissing && (project.document_format !== 'docx' || wordReady);
    /* 読み上げにも同じ言い方を出す。ここだけ硬い言い方にしない。 */
    el('cat-output-help').textContent = draft ? '原本はそのままで、訳文を入れたコピーを作ります。名前と文書内に DRAFT が付きます。' : '';
    el('cat-export').textContent = isFile ? (project.document_format === 'docx' && wordReady ? '訳文入りのWordを作る' : project.document_format === 'docx' ? '確認済み訳文をコピー' : '訳文入りのExcelを作る') : '確認済み訳文をコピー';
    /* 出せない理由は、押す前の常時表示ではなく取り出しダイアログの点検で出す。
       常時 35px を占めながら、ほぼ always「あと N 行」としか言っていなかった。 */
    el('cat-export-blocked').textContent = '';
    /* 帯は畳んだが、理由は失わない。押せない理由はボタン自身が持つ（title）。
       押したあとの詳細は取り出しダイアログの点検一覧が出す。 */
    el('cat-export').title = outputGuidance() || '';
    saveStatus('保存済み', false); setBusy(false); refreshCopilotUsage();
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
  function resume(id) { var epoch = ++viewEpoch; setBusy(true); status('保存した作業を読み込んでいます…'); return post('resume', { project_id: id }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); }

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
    document.title = (text ? text + ' - ' : '') + '資料翻訳 - YakuLingo';
  }
  function pollJob(id, token, failureCount) {
    window.clearTimeout(jobTimer);
    failureCount = Number(failureCount || 0);
    var startedAt = jobContext && jobContext.startedAt;
    YakuCommon.json('/api/jobs/' + encodeURIComponent(id)).then(function (data) {
      if (!jobContext || jobContext.token !== token) return;
      el('cat-job').innerHTML = jobHtml(id, data, startedAt);
      if (['done','completed_with_warnings'].indexOf(data.mode) >= 0) { setJobTitle('✔ 翻訳が終わりました'); YakuCommon.notifyDesktopShell('translation-finished'); finishJob(id, token); return; }
      if (data.mode === 'cancelled') { setJobTitle(''); setBusy(false); el('cat-job').innerHTML = ''; status('翻訳をやめました。ここまでにできた訳文は保存されています。「残りの訳案を作る」を押すと続きから再開できます。'); return; }
      if (['error','failed'].indexOf(data.mode) >= 0) { setJobTitle(''); setBusy(false); status(data.detail || '翻訳が途中で止まりました。ここまでにできた訳文は保存されています。もう一度「残りの訳案を作る」を押すと、続きから再開します。', true); return; }
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
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示している資料が切り替わったため、翻訳をやめました。もう一度「残りの訳案を作る」を押してください。');
      project = data; jobScope = currentScope(); status('残りの訳案を作っています…'); return YakuCommon.postText('/api/cat/translate', { id: jobScope.id, expected_revision: jobScope.revision, mode: 'translate' });
    }).then(function (html) { startJobHtml(html, { type: 'translate', scope: jobScope }); }).catch(function (error) { setBusy(false); status(error.message, true); });
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
      window.setTimeout(function () { focusAfter(index); }, 0);
      return data;
    });
  }

  /* 一括確定。取り消せること・翻訳メモリに残ること・点検を通らない行は確定
     されないことを、押す前に伝える。あとから気づいても戻せる操作だが、
     何が起きるか知らずに押させない。 */
  function confirmBulk(button) {
    var indexes = String(button.getAttribute('data-cat-bulk-indexes') || '').split(',').filter(Boolean).map(Number);
    if (!indexes.length) return;
    if (!window.confirm('表示中の' + indexes.length + '行を、まとめて確認済みにします。\n\n・数字の自動点検を通らない行は、確認済みになりません\n・確認済みにした訳は、次の資料の候補としてこのパソコンに記録されます\n・あとから1行ずつ「確認を取り消す」で戻せます\n\n進めますか？')) return;
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
      }).join('') : '<p class="muted">この行で使う用語の登録はありません。</p>'
      + '<details class="pane-note"><summary>用語を登録するには</summary><p class="muted">原文と訳文から必要な語をマウスで選び、「用語を登録」を押します。この資料だけ、または今後の資料でも使えます。</p></details>';
      markTermsInSource(terms);
      el('cat-candidates-list').innerHTML = items.length ? items.map(function (item, itemIndex) {
        var label = item.kind === 'memory' ? '過去に確認した訳' : '前回の資料の訳';
        var material = item.source_name || item.database || '資料名なし';
        /* 無いものを「情報なし」と書かない。埋まっている行と見分けがつかず、
           カードの行数だけが増えていた（2026-08-12）。 */
        var place = Number(item.page) > 0 ? ('ページ ' + Number(item.page)) : '';
        var location = item.location ? String(item.location) : '';
        var ratio = Number(item.score != null ? item.score : (item.source_match_ratio != null ? item.source_match_ratio : item.ratio)) || 0;
        var match = item.kind === 'prior' ? (item.exact ? '前回と原文が同じ' : '前回から原文に変更あり') : (ratio >= .999 || item.exact ? '原文が同じ' : ('原文が ' + Math.round(ratio * 100) + '% 同じ'));
        var translation = item.translation != null ? item.translation : item.target;
        var number = terms.length + itemIndex + 1;
        /* 日時は「いつ確認した訳か」だけ分かればよい。秒まで出すと、
           見比べたい原文・訳文より目立つ（2026-08-12）。 */
        var saved = item.saved ? ('・' + String(item.saved).slice(0, 10) + ' 確認') : '';
        var deleteButton = item.kind === 'memory' ? '<button type="button" class="secondary-button" data-cat-tm-delete="' + esc(item.reference_id || '') + '" data-cat-index="' + index + '">この候補を今後は出さない</button>' : '';
        return '<article class="cat-candidate-card"><span class="cat-candidate-number">' + number + '</span>' + (number <= 9 ? '<span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + number + '</kbd></span>' : '') + '<div class="cat-candidate-meta"><span class="cat-cand-tag">' + esc(label) + '</span><span>' + esc(material) + '</span>' + (location ? '<span>' + esc(location) + '</span>' : '') + (place ? '<span>' + esc(place) + '</span>' : '') + '</div>' +
          '<div><strong>原文</strong><p class="cat-cand-src">' + esc(item.source) + '</p></div><div><strong>訳文</strong><p class="cat-cand-tgt">' + esc(translation) + '</p></div>' +
          /* 「原文が似ているというだけです。訳文が正しいかは…」は消した。
             見出しが「似ている過去の訳」で、入れるかどうかは押して決める。
             読む人はそれを分かっている（2026-08-12、利用者の指摘）。 */
          '<p class="muted">' + esc(match + saved) + '</p>' +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-insert="' + esc(translation) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">' + number + ' この訳を挿入</button>' + deleteButton + '</div></article>';
      }).join('') : '<p class="muted">この行に似た訳は、まだ見つかりません。訳文を「確認済みにする」と、このパソコンに記録され、次の資料から自動で候補に出ます。</p>';
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
    var requestScope = null;
    return flush().then(function () { requestScope = currentScope(); if (!requestScope) throw new Error('資料が開かれていません。「ほかの資料に切り替える」から選び直してください。'); setBusy(true); status('出力しています…'); return post('export', {}, true, requestScope); }).then(function (data) {
      if (!project || String(project.id || '') !== requestScope.id) { setBusy(false); return; }
      setBusy(false); outputScope = requestScope;
      if (data.text) { openTextOutput(); el('cat-text-output').setAttribute('data-cat-output-project', requestScope.id); el('cat-text-output-value').value = data.text; el('cat-text-output-note').textContent = ''; return YakuCommon.copyText(data.text, el('cat-text-output-value'), el('cat-status')); }
      /* 出したあとに同じことを2度言わない。行にファイル名が出ており、DRAFT_ の
         決まりは押す前の確認で読んでいる（2026-08-12、利用者の指摘
         「いちいち言われなくても、そのまま社外に送るひとなんていない」）。 */
      el('cat-output-row').hidden = false; el('cat-output-row').setAttribute('data-cat-output-project', requestScope.id); el('cat-output-name').textContent = data.output_name || data.output_path; YakuCommon.focus(el('cat-output-row'));
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function outputModeLabel(mode) {
    if (mode === 'word_draft') return '確認用Word DRAFTを作成します';
    if (mode === 'excel_draft') return '確認用Excel DRAFTを作成します';
    if (mode === 'copy_text') return '確認済み訳文をコピーします';
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
      el('cat-export-checks').innerHTML = blockers.map(function (item) { return '<div class="cat-preflight-item is-blocked">' + esc(item.message || item.code || 'いまはファイルを作れません。上に出ている項目をご確認ください。') + '</div>'; }).join('') + warnings.map(function (item) { return '<div class="cat-preflight-item">' + esc(item.message || item.code || item) + '</div>'; }).join('') + (!blockers.length ? '<div class="cat-preflight-item is-ready">確認済みの内容を出力できます。</div>' : '');
      el('cat-export-notice').textContent = data.draft_notice || '原本はそのままで、訳文を入れたコピーを作ります。名前の先頭に「DRAFT_」が付きます。';
      el('cat-export-notice').hidden = mode === 'copy_text' || mode === 'blocked';
      el('cat-export-confirm').disabled = !data.eligible || mode === 'blocked';
      el('cat-export-confirm').textContent = mode === 'copy_text' ? '訳文をコピー' : 'ファイルを作る';
      var dialog = el('cat-export-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
    }).catch(function (error) { setBusy(false); preflightScope = null; status(error.message, true); });
  }

  function goToNextQc() {
    if (!project) return Promise.resolve();
    var all = project.segments || [], after = all.find(function (segment) { return Number(segment.index) > Number(activeIndex) && segmentHasQc(segment); });
    var target = after || all.find(segmentHasQc);
    if (!target) { status('数字と単位の自動点検では、気になる点は見つかりませんでした。言い回しが適切かどうかは、ご自身でお確かめください。'); return Promise.resolve(); }
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
    /* 保存は入力欄からフォーカスが外れたときにだけ走る。打ちかけたままホームへ戻る、
       トレイのアイコンを押す、ウィンドウを閉じる、のいずれでも黙って消えていた。 */
    window.addEventListener('beforeunload', function (event) {
      var editing = document.activeElement;
      var hasUnsaved = dirty.size > 0 ||
        !!(editing && editing.matches && editing.matches('textarea[data-cat-input]') &&
           editing.value !== editing.getAttribute('data-original'));
      if (!hasUnsaved) return;
      event.preventDefault();
      event.returnValue = '';
    });
    /* 画面が隠れる直前に、打ちかけの内容を保存しておく。 */
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden' && !busy) { try { flush(); } catch (_) {} }
    });
    document.querySelectorAll('[data-cat-source-show]').forEach(function (button) { button.addEventListener('click', function () { showStart(button.getAttribute('data-cat-source-show')); }); });
    document.querySelectorAll('[data-cat-open]').forEach(function (button) { button.addEventListener('click', function () { openSource(button.getAttribute('data-cat-open'), 'auto'); }); });
    document.querySelectorAll('[data-cat-direction]').forEach(function (button) { button.addEventListener('click', function () { el('cat-direction-choice').hidden = true; if (pendingDirection) pendingDirection(button.getAttribute('data-cat-direction')); }); });
    el('cat-file-input').addEventListener('change', function () { uploaded = null; el('cat-file-name').textContent = this.files.length ? this.files[0].name : '.docx / .xlsx / .xlsm'; });
    bindFileDrop(el('cat-drop'), el('cat-file-input'));
    el('cat-prior-open').addEventListener('click', function () { var epoch = ++viewEpoch; setBusy(true); post('from-prior-version', { prior_ja: el('cat-prior-ja').value, prior_en: el('cat-prior-en').value, current_ja: el('cat-current-ja').value, document_name: el('cat-prior-name').value }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); });
    el('cat-align-open').addEventListener('click', function () { var epoch = viewEpoch; setBusy(true); YakuCommon.postText('/api/cat/align', { source_text: el('cat-align-source').value, target_text: el('cat-align-target').value, file_name: el('cat-align-name').value }).then(function (html) { startJobHtml(html, { type: 'align', name: el('cat-align-name').value, viewEpoch: epoch }); }).catch(function (error) { setBusy(false); status(error.message, true); }); });
    el('cat-switch-project').addEventListener('click', function () { if (busy) return; flush().then(showPicker).catch(function (error) { status(error.message, true); }); });
    el('cat-translate').addEventListener('click', translate); el('cat-export').addEventListener('click', openExportPreflight);
    el('cat-export-reviewed').addEventListener('click', exportReviewed);
    el('cat-danger-zone').addEventListener('toggle', function () { if (this.open) loadPersonalGlossary(); });
    document.addEventListener('click', function (event) {
      var button = event.target.closest('button'); if (!button) return;
      if (busy && (button.id === 'cat-confirm-bulk' || button.hasAttribute('data-cat-confirm') || button.hasAttribute('data-cat-unconfirm') || button.hasAttribute('data-cat-revert') || button.hasAttribute('data-cat-merge') || button.hasAttribute('data-cat-split') || button.hasAttribute('data-cat-glossary') || button.hasAttribute('data-cat-insert') || button.hasAttribute('data-cat-term-open') || button.hasAttribute('data-cat-term-insert') || button.hasAttribute('data-cat-term-edit') || button.hasAttribute('data-cat-term-deactivate') || button.hasAttribute('data-cat-term-exception') || button.hasAttribute('data-cat-tm-delete') || button.hasAttribute('data-cat-shorten') || button.hasAttribute('data-cat-accept-revision') || button.hasAttribute('data-cat-revert-revision'))) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; }
      if (button.hasAttribute('data-cat-activate')) return activateIndex(Number(button.getAttribute('data-cat-activate')), true);
      if (button.hasAttribute('data-cat-filter')) { currentFilter = button.getAttribute('data-cat-filter') || 'actionable'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-location')) { currentLocation = button.getAttribute('data-cat-location') || 'all'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-change')) { currentChange = button.getAttribute('data-cat-change') || 'all'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-inspector')) { inspectorTab = button.getAttribute('data-cat-inspector') || 'candidates'; renderInspector(); return; }
      if (button.hasAttribute('data-yaku-cancel-job')) {
        if (!window.confirm('翻訳をやめますか？\n\nここまでにできあがった訳文は保存されています。\nあとで「残りの訳案を作る」を押すと、続きから再開できます。')) return;
        button.disabled = true; button.textContent = 'やめています…';
        return YakuCommon.post('/api/cancel-translation', { job_id: button.getAttribute('data-yaku-cancel-job') })
          .catch(function (error) { status(error.message, true); });
      }
      if (button.hasAttribute('data-cat-personal-remove')) return removePersonalGlossary(button);
      if (button.hasAttribute('data-cat-resume')) return resume(button.getAttribute('data-cat-resume'));
      if (button.id === 'cat-confirm-bulk') return confirmBulk(button);
      if (button.hasAttribute('data-cat-confirm')) return confirmRow(Number(button.getAttribute('data-cat-confirm')));
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
      if (button.hasAttribute('data-cat-shorten')) return revise(button.closest('[data-cat-revise]'), '原文の意味と数値を変えず、表や資料に収まりやすい簡潔な表現にしてください。');
      if (button.hasAttribute('data-cat-accept-revision')) return acceptRevisionComparison();
      if (button.hasAttribute('data-cat-revert-revision')) return revertRevisionComparison();
    });
    document.addEventListener('input', function (event) {
      if (!event.target.hasAttribute('data-cat-input')) return;
      var index = Number(event.target.getAttribute('data-cat-input')); dirty.set(dirtyKey(event.target.getAttribute('data-cat-project-id'), index), true); event.target.closest('[data-cat-row]').classList.add('cat-dirty');
      autoGrow(event.target);
      /* 戻せるのは「開いたときの訳文と違うとき」だけ。常時出すと、押しても何も
         起きないボタンになって信用を失う。 */
      var revertButton = event.target.closest('.cat-work-target, .cat-target');
      revertButton = revertButton && revertButton.querySelector('[data-cat-revert]');
      if (revertButton) revertButton.hidden = event.target.value === (event.target.getAttribute('data-original') || '');
      var note = event.target.closest('.cat-work-target, .cat-target');
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
      if (event.target.id === 'cat-term-form') { event.preventDefault(); if (!busy) saveTerm(); return; }
      if (event.target.id === 'cat-term-exception-form') { event.preventDefault(); if (!busy) saveTermException(); return; }
      var form = event.target.closest('[data-cat-revise]'); if (form) { event.preventDefault(); if (busy) { status('いま翻訳しています。終わってからもう一度お試しください。'); return; } revise(form); }
    });
    document.addEventListener('keydown', function (event) {
      if (event.isComposing) return;
      var input = event.target.closest && event.target.closest('[data-cat-input]');
      if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'f') { event.preventDefault(); YakuCommon.focus(el('cat-search')); el('cat-search').select(); return; }
      if (event.altKey && !event.ctrlKey && !event.metaKey && (event.key === 'ArrowUp' || event.key === 'ArrowDown')) { event.preventDefault(); if (!busy) moveActive(event.key === 'ArrowUp' ? -1 : 1); return; }
      if (event.key === 'Escape' && (el('cat-search') === document.activeElement || event.target.closest('#cat-inspector-pane'))) { event.preventDefault(); focusActive(); return; }
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
      if (!scopeIsCurrent(target, true)) { status('表示中の作業が変わったため、削除を中止しました。'); return; }
      setBusy(true); status('作業を削除しています…');
      post('delete', { id: target.id }, true, target).then(function () {
        if (!project || String(project.id || '') !== target.id) { setBusy(false); return; }
        showPicker(); setBusy(false); status('翻訳作業と途中保存を削除しました。元のファイルは残っています。');
      }).catch(function (error) { setBusy(false); if (project && String(project.id || '') === target.id) status(error.message, true); });
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
      /* Ctrl+Alt+J で読んだ選択の出どころ（Word・Excelのファイル）を丸ごと取り込む。
         取り出しは既存の経路と同じで、原本ではなく DRAFT_ 付きのコピーを作る。 */
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
    /* Ctrl+Alt+J と開始画面の「その場で訳す」は /quick から来る。画面は一つなので
       同じ画面を出し、その場で訳す状態から始める。showPicker() がアドレスを
       /cat へ書き換えるので、判定は先に取っておく。 */
    var cameFromInstant = location.pathname === '/quick';
    var wanted = new URLSearchParams(location.search).get('project');
    if (wanted) { resume(wanted); return; }
    showPicker();
    if (cameFromInstant && window.YakuInstant) window.YakuInstant.show();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
