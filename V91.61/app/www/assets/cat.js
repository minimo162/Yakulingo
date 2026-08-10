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
  function status(text, error) { el('cat-status').textContent = text || ''; el('cat-status').classList.toggle('alert-inline', !!error); }
  function saveStatus(text, error) { el('cat-save-status').textContent = text || ''; el('cat-current-save').textContent = text || '保存済み'; el('cat-save-status').classList.toggle('is-error', !!error); el('cat-current-save').classList.toggle('is-error', !!error); }
  function revision() { return project ? Number(project.revision) || 0 : -1; }
  function currentScope() { return project ? { id: String(project.id || ''), revision: revision() } : null; }
  function scopeIsCurrent(scope, checkRevision) {
    return !!(scope && project && String(project.id || '') === scope.id && (!checkRevision || revision() === scope.revision));
  }
  function dirtyKey(projectId, index) { return String(projectId || '') + ':' + String(index); }
  function clearOutputDisplay() {
    outputScope = null;
    el('cat-output-row').hidden = true; el('cat-output-row').removeAttribute('data-cat-output-project');
    el('cat-text-output').hidden = true; el('cat-text-output').removeAttribute('data-cat-output-project');
    el('cat-output-name').textContent = ''; el('cat-text-output-value').value = '';
  }
  function post(action, body, mutate, scope) {
    body = Object.assign({}, body || {});
    var requestScope = scope || currentScope();
    if (requestScope && !body.id && ['resume','recent','open','from-prior-version'].indexOf(action) < 0) body.id = requestScope.id;
    if (mutate && requestScope) body.expected_revision = requestScope.revision;
    return YakuCommon.post('/api/cat/' + action, body);
  }
  function directionName(value) { return value === 'to_jp' ? '日本語に訳す作業' : '英語に訳す作業'; }
  function showPicker() { viewEpoch++; candidateSeq++; project = null; activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; termSelection = { index: -1, source: '', target: '' }; dirty.clear(); clearOutputDisplay(); el('cat-picker').hidden = false; el('cat-workspace').hidden = true; el('cat-current-summary').hidden = true; closeStartPanels(); loadRecent(); }
  function closeStartPanels() { document.querySelectorAll('.cat-start-panel').forEach(function (panel) { panel.hidden = true; }); el('cat-direction-choice').hidden = true; }
  function showStart(mode) { closeStartPanels(); var panel = el('cat-source-' + mode); if (panel) { panel.hidden = false; YakuCommon.focus(panel.querySelector('input,textarea,[role="button"],button')); } }
  function setBusy(value) {
    busy = value;
    document.querySelectorAll('button').forEach(function (button) { if (!button.closest('dialog')) button.disabled = value || (button.id === 'cat-translate' && !ready); });
    document.querySelectorAll('textarea[data-cat-input], input.revise-input').forEach(function (input) { input.disabled = value; });
    if (!value) {
      el('cat-translate').disabled = !ready || !project || Number(project && project.untranslated) <= 0;
      el('cat-export').disabled = !project || !!(project && project.export_blocked) || dirty.size > 0;
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
    }).catch(function (error) { el('cat-resume').hidden = false; el('cat-resume-list').innerHTML = '<div class="alert alert-error">保存した作業を読み込めませんでした。' + esc(error.message) + '</div>'; });
  }

  function qcMessages(segment) {
    var labels = {
      empty: '訳文が空です。', 'invalid-or-source-fallback': '訳文として成立していないか、原文のままです。',
      'placeholder-residue': '保護用の記号が訳文に残っています。', 'numeric-integrity': '数値または単位が原文と一致しません。',
      'numeric-value-mismatch': '原文と異なる数値、または不足している数値があります。', 'numeric-value-extra': '原文にない数値があります。',
      'numeric-scale-mismatch': '数値の桁が一致しません。', 'numeric-sign-missing': '損失・減少を示す符号が反映されていません。',
      'accounting-polarity-mismatch': '利益と損失、増加と減少の向きが一致しません。', 'currency-mismatch': '通貨単位が一致しません。',
      'proper-noun-missing': '固有名詞が訳文に反映されていません。', 'structure-integrity': '見出しまたは箇条書きの構造が一致しません。'
      , 'terminology-missing': '登録した用語の推奨訳または許容訳が使われていません。'
      , 'terminology-forbidden': '用語集で「使用しない訳」にした表現が使われています。'
      , 'terminology-check-unavailable': '用語集を検査できないため、確認を止めました。'
      , 'terminology-conflict': '同じ用語に複数の必須訳が登録されています。用語集を整理してください。'
    };
    return (segment.qc_findings || []).map(function (finding) { var code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-'); return labels[code] || '確認が必要な問題があります。'; });
  }
  function stateLabel(state) { return state === 'reviewed' ? '確認済み' : state === 'human_edited' ? '手直し済み・未確認' : state === 'machine_draft' ? 'AI訳・未確認' : state === 'stale' ? '再確認が必要' : '未翻訳'; }
  function originLabel(origin) {
    if (origin === 'glossary') return '用語集';
    if (origin === 'copilot') return 'AI訳';
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
  function changeLabel(segment) {
    var group = changeGroup(segment);
    return group === 'unchanged' ? '前回と同じ' : group === 'changed' ? '前回から変更' : group === 'new' ? '今回追加' : '';
  }
  function locationGroup(segment) {
    var location = String(segment.location || '').trim();
    if (segment.kind === 'cell') { var bang = location.lastIndexOf('!'); return bang > 0 ? location.slice(0, bang) : (location || 'Excel'); }
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
    document.querySelectorAll('[data-cat-filter]').forEach(function (button) { button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-filter') === currentFilter)); });
    var changeCounts = { unchanged: 0, changed: 0, new: 0 }, hasChanges = false;
    all.forEach(function (segment) { var group = changeGroup(segment); if (group) { changeCounts[group]++; hasChanges = true; } });
    el('cat-change-filter').hidden = !hasChanges;
    Object.keys(changeCounts).forEach(function (name) { var target = document.querySelector('[data-cat-change-count="' + name + '"]'); if (target) target.textContent = changeCounts[name]; });
    document.querySelectorAll('[data-cat-change]').forEach(function (button) { button.setAttribute('aria-pressed', String(button.getAttribute('data-cat-change') === currentChange)); });
    var groups = {};
    all.forEach(function (segment) { var name = locationGroup(segment); groups[name] = (groups[name] || 0) + 1; });
    el('cat-location-list').innerHTML = '<button type="button" data-cat-location="all" aria-pressed="' + String(currentLocation === 'all') + '">すべての場所 <span>' + all.length + '</span></button>' + Object.keys(groups).map(function (name) {
      return '<button type="button" data-cat-location="' + esc(name) + '" aria-pressed="' + String(currentLocation === name) + '">' + esc(name) + ' <span>' + groups[name] + '</span></button>';
    }).join('');
  }
  function renderInspector() {
    var segment = activeSegment(), all = project.segments || [];
    document.querySelectorAll('[data-cat-inspector]').forEach(function (button) { var selected = button.getAttribute('data-cat-inspector') === inspectorTab; button.setAttribute('aria-selected', String(selected)); });
    ['candidates','qc','context'].forEach(function (name) { el('cat-panel-' + name).hidden = name !== inspectorTab; });
    if (!segment) {
      el('cat-qc-count').textContent = '0'; el('cat-qc-list').innerHTML = '<p class="muted">行を選ぶと検査結果を表示します。</p>'; el('cat-context').innerHTML = '<p class="muted">行を選ぶと文書内の位置を表示します。</p>'; return;
    }
    var rawFindings = segment.qc_findings || [], findings = qcMessages(segment);
    el('cat-qc-count').textContent = String(findings.length);
    el('cat-qc-list').innerHTML = findings.length ? findings.map(function (message, findingIndex) {
      var finding = rawFindings[findingIndex] || {}, code = String(finding.code || finding.Code || '').toLowerCase().replace(/_/g, '-');
      var termAction = (code === 'terminology-missing' || code === 'terminology-forbidden') ? '<button type="button" class="secondary-button" data-cat-term-exception="' + Number(segment.index) + '" data-cat-term-id="' + esc(finding.termId || finding.TermId || '') + '" data-cat-term-version="' + Number(finding.termVersion || finding.TermVersion || 0) + '" data-cat-term-source="' + esc(finding.sourceTerm || finding.SourceTerm || '') + '">この行では別の表現を使う</button>' : '';
      return '<div class="cat-qc-card is-error"><p>' + esc(message) + '</p>' + termAction + '</div>';
    }).join('') : '<div class="cat-qc-card">数値・単位などの機械チェックで問題は見つかりません。表現の適切さはご自身で確認してください。</div>';
    el('cat-next-qc').disabled = !all.some(segmentHasQc);
    var index = Number(segment.index), previous = all.find(function (item) { return Number(item.index) === index - 1; }), next = all.find(function (item) { return Number(item.index) === index + 1; });
    el('cat-context').innerHTML = '<div class="cat-context-card"><span class="cat-context-label">現在の場所</span><p class="cat-context-text">' + esc(segment.location || '本文') + '</p></div>' +
      (segment.prior_source && changeGroup(segment) === 'changed' ? '<div class="cat-context-card"><span class="cat-context-label">前回からの変更</span><p class="cat-context-text"><strong>前回</strong><br>' + esc(segment.prior_source) + '</p><p class="cat-context-text"><strong>今回</strong><br>' + esc(segment.source) + '</p></div>' : '') +
      (previous ? '<div class="cat-context-card"><span class="cat-context-label">前の原文</span><p class="cat-context-text">' + esc(previous.source) + '</p></div>' : '') +
      (next ? '<div class="cat-context-card"><span class="cat-context-label">次の原文</span><p class="cat-context-text">' + esc(next.source) + '</p></div>' : '');
  }
  function renderRows() {
    var all = project.segments || [], body = el('cat-grid-body');
    candidateSeq++;
    el('cat-candidates').hidden = true;
    chooseInitialActive();
    var shown = visibleSegments(), current = activeSegment();
    renderNavigation(); renderInspector();
    el('cat-filter-count').textContent = shown.length + ' / ' + all.length + '件';
    el('cat-complete-state').hidden = !(all.length && !all.some(segmentActionable));
    el('cat-empty-state').hidden = shown.length > 0;
    el('cat-grid-wrap').hidden = shown.length === 0;
    body.innerHTML = shown.map(function (segment) {
      var index = Number(segment.index), row = index + 1, state = segmentState(segment), isActive = current && Number(current.index) === index;
      var findings = qcMessages(segment), findingId = 'cat-qc-' + index, origin = originLabel(segment.origin), ops = '';
      var nextSegment = all.find(function (candidate) { return Number(candidate.index) === index + 1; });
      var mergeLosesTranslation = !!(String(segment.translation || '').trim() || (nextSegment && String(nextSegment.translation || '').trim()));
      var splitLosesTranslation = !!String(segment.translation || '').trim();
      if (segment.can_merge) ops += '<button type="button" class="cat-op secondary-button" data-cat-merge="' + index + '" data-cat-loss="' + (mergeLosesTranslation ? '1' : '0') + '">次の行と結合</button>';
      if (segment.can_split) ops += '<button type="button" class="cat-op secondary-button" data-cat-split="' + index + '" data-cat-loss="' + (splitLosesTranslation ? '1' : '0') + '">結合を解除</button>';
      var prior = (segment.prior_translation || segment.prior_source) ? '<details><summary>過去の翻訳例を見る</summary>' + (segment.prior_source ? '<div><strong>前回の文章</strong><br>' + esc(segment.prior_source) + '</div>' : '') + (segment.prior_translation ? '<div><strong>過去の翻訳例</strong><br>' + esc(segment.prior_translation) + '</div>' : '') + '</details>' : '';
      var qc = findings.length ? '<div id="' + findingId + '" class="cat-qc-findings" role="alert">' + findings.map(function (m) { return '<div>' + esc(m) + '</div>'; }).join('') + '</div>' : '';
      var usage = segment.reference_usage || null;
      var referenceTrace = usage ? '<div class="cat-example-trace"><p>この翻訳例から挿入（その後編集' + (usage.edited_after_insert ? 'あり' : 'なし') + '）・' + esc(usage.source_name || '資料名なし') + (usage.location ? '・' + esc(usage.location) : '') + (Number(usage.page) > 0 ? '・ページ ' + Number(usage.page) : '') + '</p>' +
        ((usage.source || usage.translation) ? '<details><summary>使った翻訳例を確認</summary>' + (usage.source ? '<div><strong>原文</strong><br>' + esc(usage.source) + '</div>' : '') + (usage.translation ? '<div><strong>訳文</strong><br>' + esc(usage.translation) + '</div>' : '') + '</details>' : '') + '</div>' : '';
      var generatedTerms = (segment.terminology_generation || []).length ? '<details class="cat-term-trace"><summary>訳案作成時に指定した用語 ' + segment.terminology_generation.length + '件</summary>' + segment.terminology_generation.map(function (term) { return '<div><strong>' + esc(term.source || '') + '</strong> → ' + esc(term.preferred || '') + '</div>'; }).join('') + '</details>' : '';
      var compare = revisionComparison && revisionComparison.projectId === String(project.id || '') && Number(revisionComparison.index) === index ? '<section class="cat-revision-compare" aria-labelledby="cat-revision-title-' + index + '"><h4 id="cat-revision-title-' + index + '">修正結果を確認</h4><div class="cat-revision-pair"><div><strong>変更前</strong><p>' + esc(revisionComparison.before) + '</p></div><div><strong>変更後</strong><p>' + esc(segment.translation || '') + '</p></div></div><p class="muted">数値・単位などは機械チェック済みです。表現の適切さはご自身で確認してください。</p><div class="cat-revision-actions"><button type="button" data-cat-accept-revision="' + index + '">この案を使う</button><button type="button" class="secondary-button" data-cat-revert-revision="' + index + '">元に戻す</button></div></section>' : '';
      var kind = segment.kind === 'cell' ? 'セル' : /^word_/.test(segment.kind || '') ? 'Word' : '文';
      var target = isActive ? '<textarea data-cat-input="' + index + '" data-cat-project-id="' + esc(project.id) + '" data-original="' + esc(segment.translation || '') + '" aria-label="' + row + '行目の訳文" aria-invalid="' + (findings.length ? 'true' : 'false') + '"' + (findings.length ? ' aria-describedby="' + findingId + '"' : '') + '>' + esc(segment.translation || '') + '</textarea>' + prior + referenceTrace + generatedTerms + '<div class="cat-row-actions">' + (segment.confirmed ? '' : '<button type="button" class="cat-op cat-op-ok" data-cat-confirm="' + index + '">確認済みにする</button>') + (segment.translation ? '<button type="button" class="cat-op secondary-button" data-cat-term-open="' + index + '">用語を登録</button>' : '') + ((segment.kind === 'cell' && segment.translation && String(segment.source).length <= 40) ? '<button type="button" class="cat-op secondary-button" data-cat-glossary="' + index + '">セル全体を固定訳に登録</button>' : '') + '</div>' + qc + compare + (segment.can_revise ? '<form class="revise-form" data-cat-revise="' + index + '"><button class="secondary-button" type="button" data-cat-shorten="' + index + '">短くする</button><label class="revise-label">または、どこをどう直すか入力</label><div class="revise-row"><input class="revise-input" type="text" placeholder="例：「increase」を「rise」に変える"><button class="secondary-button" type="submit">この指示で直す</button></div></form>' : '') : '<button type="button" class="cat-row-activate" data-cat-activate="' + index + '"><span class="cat-target-preview">' + esc(segment.translation || '') + '</span></button>';
      var change = changeLabel(segment);
      return '<tr class="' + (isActive ? 'is-active' : '') + '" data-cat-row="' + index + '" data-cat-segment-id="' + esc(segment.segment_id || '') + '" data-cat-confirmed="' + (segment.confirmed ? '1' : '0') + '" data-yaku-cat-state="' + esc(state) + '">' +
        '<td class="cat-col-no"><span class="cat-card-label">行番号・状態</span>' + row + '<span class="cat-state cat-state-' + esc(state) + '">' + esc(stateLabel(state)) + '</span>' + (change ? '<span class="cat-change-badge cat-change-' + esc(changeGroup(segment)) + '">' + esc(change) + '</span>' : '') + '</td>' +
        '<td class="cat-col-loc"><span class="cat-card-label">場所</span><span class="cat-location-main">' + esc(segment.location || '本文') + '</span><span class="cat-location-kind">' + esc(kind) + '</span>' + (origin ? '<span class="cat-origin">' + esc(origin) + '</span>' : '') + '<span class="cat-ops">' + ops + '</span></td>' +
        '<td class="cat-source"><span class="cat-card-label">原文</span>' + (isActive ? '<span class="cat-source-text">' + esc(segment.source) + '</span>' : '<button type="button" class="cat-row-activate" data-cat-activate="' + index + '"><span class="cat-source-text">' + esc(segment.source) + '</span></button>') + '</td>' +
        '<td class="cat-target"><span class="cat-card-label">訳文</span>' + target + '</td></tr>';
    }).join('');
    el('cat-candidates').hidden = false;
    if (current) candidates(Number(current.index)); else { el('cat-candidate-count').textContent = '0'; el('cat-candidates-list').innerHTML = '<p class="muted">表示できる行がありません。</p>'; }
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
    if (previousProjectId && previousProjectId !== String(project.id || '')) { activeSegmentId = ''; activeIndex = -1; revisionComparison = null; currentFilter = 'actionable'; currentLocation = 'all'; currentChange = 'all'; }
    if (outputScope && (outputScope.id !== String(project.id || '') || outputScope.revision !== revision())) clearOutputDisplay();
    dirty.clear(); candidateSeq++;
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
    el('cat-draft-warning').hidden = true;
    el('cat-output-help').textContent = draft ? '作成するファイルは確認作業用です。完成版・外部公表可能資料ではありません。ファイル名と文書内にDRAFTを表示します。' : '';
    el('cat-export').textContent = isFile ? (project.document_format === 'docx' && wordReady ? '確認用Word DRAFT（外部配布不可）を作る' : project.document_format === 'docx' ? '確認済み訳文をコピー' : '確認用Excel DRAFT（外部配布不可）を作る') : '確認済み訳文をコピー';
    el('cat-export-blocked').textContent = outputGuidance();
    saveStatus('保存済み', false); setBusy(false);
    status((project.file_name || '資料') + '・訳あり' + project.translated + '行・残り' + project.remaining + '行');
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
      if (file.size > YakuCommon.maxUploadBytes) return Promise.reject(new Error('ファイルサイズが上限を超えています。'));
      var key = [file.name, file.size, file.lastModified].join(':');
      if (uploaded && uploaded.key === key) return Promise.resolve({ file_handle: uploaded.handle });
      return YakuCommon.upload('/api/upload', file).then(function (data) { if (!data.file_handle) throw new Error('ファイルを安全に取り込めませんでした。'); uploaded = { key: key, handle: data.file_handle }; return { file_handle: data.file_handle }; });
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
        saveStatus('保存できませんでした。赤い行を確認してください。', true);
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
      requestScope = currentScope(); if (!requestScope) throw new Error('作業が開かれていません。');
      setBusy(true); if (message) status(message); return post(action, body || {}, true, requestScope);
    }).then(function (data) {
      if (!scopeIsCurrent(requestScope, true) || !data || (data.id && String(data.id) !== requestScope.id)) { setBusy(false); return null; }
      render(data); return data;
    }).catch(function (error) { setBusy(false); status(error.message, true); return null; });
  }

  function startJobHtml(html, context) {
    el('cat-job').innerHTML = html; var node = el('cat-job').querySelector('[data-yaku-job-id]'); if (!node) throw new Error('処理を開始できませんでした。');
    context = context || {}; context.token = ++jobSerial; jobContext = context; pollJob(node.getAttribute('data-yaku-job-id'), context.token);
  }
  function pollJob(id, token) {
    window.clearTimeout(jobTimer);
    YakuCommon.json('/api/jobs/' + encodeURIComponent(id)).then(function (data) {
      if (!jobContext || jobContext.token !== token) return;
      el('cat-job').innerHTML = '<div class="job-loading"><div class="job-phase">' + esc(data.label || data.phase || '処理中') + '</div><div class="job-progress-line"><span class="job-progress-bar" style="width:' + (Number(data.progress) || 0) + '%"></span></div></div>';
      if (['done','completed_with_warnings'].indexOf(data.mode) >= 0) { finishJob(id, token); return; }
      if (['error','failed','cancelled'].indexOf(data.mode) >= 0) { setBusy(false); status(data.detail || '処理を完了できませんでした。', true); return; }
      jobTimer = window.setTimeout(function () { pollJob(id, token); }, 1000);
    }).catch(function (error) { if (!jobContext || jobContext.token !== token) return; setBusy(false); status(error.message, true); });
  }
  function finishJob(jobId, token) {
    var context = jobContext;
    if (!context || context.token !== token) return Promise.resolve();
    jobContext = null; el('cat-job').innerHTML = '';
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
    return flush().then(function () { glossaryScope = currentScope(); if (!glossaryScope) throw new Error('作業が開かれていません。'); setBusy(true); status('用語集を適用しています…'); return post('glossary', {}, true, glossaryScope); }).then(function (data) {
      if (!scopeIsCurrent(glossaryScope, true) || !data || String(data.id || '') !== glossaryScope.id) throw new Error('表示中の作業が変わったため、翻訳を中止しました。');
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
      jobScope = currentScope(); if (!jobScope) throw new Error('作業が開かれていません。');
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
        status('確認できませんでした。赤く表示された検査結果を直してください。', true);
        inspectorTab = 'qc'; renderInspector();
        window.setTimeout(function () { var same = document.querySelector('[data-cat-input="' + index + '"]'); YakuCommon.focus(same); }, 0);
        return data;
      }
      window.setTimeout(function () { focusAfter(index); }, 0);
      return data;
    });
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
    el('cat-candidate-count').textContent = '…'; el('cat-terms-list').innerHTML = '<p class="muted">用語を探しています…</p>'; el('cat-candidates-list').innerHTML = '<p class="muted">翻訳例を探しています…</p>';
    YakuCommon.post('/api/cat/candidates', { id: requestScope.id, index: index }).then(function (data) {
      if (seq !== candidateSeq || !scopeIsCurrent(requestScope, true) || Number(activeIndex) !== Number(index)) return;
      var terms = data.terms || [], items = data.segment_matches || [], panel = el('cat-candidates'); panel.hidden = false;
      el('cat-candidate-count').textContent = String(terms.length + items.length);
      el('cat-terms-list').innerHTML = terms.length ? terms.map(function (item) {
        var allowed = (item.allowed_targets || []).filter(Boolean), forbidden = (item.forbidden_targets || []).filter(Boolean);
        var isLegacy = item.kind === 'glossary';
        var termLabel = isLegacy ? '参考用語（機械チェック対象外）' : '登録用語';
        var scopeLabel = isLegacy ? '旧用語集（参考表示）' : (item.scope === 'project' ? 'この資料だけ' : '今後の資料でも使用');
        return '<article class="cat-candidate-card cat-term-card"><div class="cat-candidate-meta"><span class="cat-cand-tag">' + esc(termLabel) + '</span><span>' + esc(item.source_name || '用語集') + '</span><span>' + esc(scopeLabel) + '</span></div>' +
          '<div><strong>原文の用語</strong><p class="cat-cand-src">' + esc(item.source) + '</p></div><div><strong>推奨訳</strong><p class="cat-cand-tgt">' + esc(item.translation || item.target) + '</p></div>' +
          (allowed.length ? '<p class="muted">許容する別訳: ' + esc(allowed.join('、')) + '</p>' : '') + (forbidden.length ? '<p class="muted">使用しない訳: ' + esc(forbidden.join('、')) + '</p>' : '') +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-term-insert="' + esc(item.translation || item.target) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">カーソル位置へ用語を挿入</button>' +
          (!isLegacy ? '<button type="button" class="secondary-button" data-cat-term-edit data-cat-index="' + index + '" data-cat-term-id="' + esc(item.term_id || '') + '" data-cat-term-version="' + Number(item.term_version || 0) + '" data-cat-term-source="' + esc(item.source || '') + '" data-cat-term-target="' + esc(item.translation || item.target || '') + '" data-cat-term-allowed="' + esc(allowed.join('|')) + '" data-cat-term-forbidden="' + esc(forbidden.join('|')) + '" data-cat-term-scope="' + esc(item.scope || 'project') + '">用語を修正</button><button type="button" class="secondary-button" data-cat-term-deactivate="' + esc(item.term_id || '') + '" data-cat-index="' + index + '">この用語を使わない</button>' : '') + '</div></article>';
      }).join('') : '<p class="muted">この行に登録済みの用語はありません。</p>';
      el('cat-candidates-list').innerHTML = items.length ? items.map(function (item, itemIndex) {
        var label = item.kind === 'memory' ? 'この端末で確認した訳' : item.kind === 'prior' ? '前回版' : '過去の翻訳例';
        var material = item.source_name || item.database || '資料名なし';
        var place = Number(item.page) > 0 ? ('ページ ' + Number(item.page)) : 'ページ情報なし';
        var location = item.location ? String(item.location) : '文書内の場所情報なし';
        var ratio = Number(item.score != null ? item.score : (item.source_match_ratio != null ? item.source_match_ratio : item.ratio)) || 0;
        var match = item.kind === 'prior' ? (item.exact ? '前回と原文が同じ' : '前回から原文に変更あり') : (ratio >= .999 || item.exact ? '原文全文一致' : ('原文一致度 ' + Math.round(ratio * 100) + '%'));
        var matchedTerms = Array.isArray(item.matched_terms) ? item.matched_terms.filter(Boolean) : [];
        var term = matchedTerms.length ? ('・一致した語: ' + matchedTerms.join('、')) : '・一致した語: なし';
        var translation = item.translation != null ? item.translation : item.target;
        var number = itemIndex + 1;
        var saved = item.saved ? ('・確認日: ' + String(item.saved)) : '';
        var deleteButton = item.kind === 'memory' ? '<button type="button" class="secondary-button" data-cat-tm-delete="' + esc(item.reference_id || '') + '" data-cat-index="' + index + '">翻訳メモリから非表示にする</button>' : '';
        return '<article class="cat-candidate-card"><span class="cat-candidate-number">' + number + '</span><span class="cat-candidate-shortcut"><kbd>Ctrl</kbd>+<kbd>' + number + '</kbd></span><div class="cat-candidate-meta"><span class="cat-cand-tag">' + esc(label) + '</span><span>' + esc(material) + '</span>' + (location ? '<span>' + esc(location) + '</span>' : '') + (place ? '<span>' + esc(place) + '</span>' : '') + '</div>' +
          '<div><strong>原文</strong><p class="cat-cand-src">' + esc(item.source) + '</p></div><div><strong>訳文</strong><p class="cat-cand-tgt">' + esc(translation) + '</p></div>' +
          '<p class="muted">' + esc(match + term + saved) + '。原文一致率は訳文の品質や承認を示しません。</p>' +
          '<div class="cat-row-actions"><button type="button" class="secondary-button" data-cat-insert="' + esc(translation) + '" data-cat-reference-id="' + esc(item.reference_id || '') + '" data-cat-project-id="' + esc(requestScope.id) + '" data-cat-index="' + index + '">' + number + ' この翻訳例から挿入</button>' + deleteButton + '</div></article>';
      }).join('') : '<p class="muted">この行に利用できる翻訳例はありません。</p>';
    }).catch(function () { if (seq === candidateSeq) { el('cat-candidate-count').textContent = '0'; el('cat-terms-list').innerHTML = '<p class="muted">用語を読み込めませんでした。</p>'; el('cat-candidates-list').innerHTML = '<p class="muted">翻訳例を読み込めませんでした。</p>'; } });
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
    if (!referenceId) { status('この翻訳例は現在利用できません。候補を読み直してください。', true); return Promise.resolve(); }
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope();
      if (!requestScope || requestScope.id !== buttonProjectId) throw new Error('表示中の作業が変わったため、挿入を中止しました。');
      setBusy(true); status('翻訳例を挿入して保存しています…');
      return post('segment', { index: index, text: translation, reference_id: referenceId }, true, requestScope);
    }).then(function (data) {
      if (!scopeIsCurrent(requestScope, true) || !data || String(data.id || '') !== requestScope.id) { setBusy(false); return; }
      render(data); status('翻訳例を挿入しました。内容を確認し、必要なら編集してください。');
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
      requestScope = currentScope(); if (!requestScope) throw new Error('作業が開かれていません。');
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
    if (!window.confirm('この用語を今後の候補と機械チェックで使わないようにしますか？既に確認した訳文は変更しません。')) return Promise.resolve();
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
      el('cat-term-exception-dialog').close(); if (scopeIsCurrent(requestScope, true)) { render(data); status('この行だけ用語例外を記録しました。確認済みにする操作で、もう一度機械チェックします。'); }
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function deleteMemory(button) {
    if (!window.confirm('この翻訳メモリ候補を今後の候補から非表示にしますか？既に使った行の記録は残ります。')) return Promise.resolve();
    var requestScope=currentScope(), index=Number(button.getAttribute('data-cat-index'));
    if(!requestScope)return Promise.resolve(); setBusy(true); status('翻訳メモリ候補を非表示にしています…');
    return post('tm-delete',{index:index,reference_id:button.getAttribute('data-cat-tm-delete')||''},true,requestScope).then(function(){setBusy(false);status('翻訳メモリ候補を非表示にしました。');candidates(index);}).catch(function(error){setBusy(false);status(error.message,true);});
  }
  function exportProject() {
    var requestScope = null;
    return flush().then(function () { requestScope = currentScope(); if (!requestScope) throw new Error('作業が開かれていません。'); setBusy(true); status('出力しています…'); return post('export', {}, true, requestScope); }).then(function (data) {
      if (!project || String(project.id || '') !== requestScope.id) { setBusy(false); return; }
      setBusy(false); outputScope = requestScope;
      if (data.text) { el('cat-text-output').hidden = false; el('cat-text-output').setAttribute('data-cat-output-project', requestScope.id); el('cat-text-output-value').value = data.text; return YakuCommon.copyText(data.text, el('cat-text-output-value'), el('cat-status')); }
      el('cat-output-row').hidden = false; el('cat-output-row').setAttribute('data-cat-output-project', requestScope.id); el('cat-output-name').textContent = data.output_name || data.output_path; el('cat-draft-warning').hidden = false; el('cat-draft-warning').textContent = '確認用DRAFTを作成しました。完成版ではありません。社外配布しないでください。'; YakuCommon.focus(el('cat-draft-warning'));
    }).catch(function (error) { setBusy(false); status(error.message, true); });
  }

  function outputModeLabel(mode) {
    if (mode === 'word_draft') return '確認用Word DRAFTを作成します';
    if (mode === 'excel_draft') return '確認用Excel DRAFTを作成します';
    if (mode === 'copy_text') return '確認済み訳文をコピーします';
    return '現在は出力できません';
  }
  function openExportPreflight() {
    var requestScope = null;
    return flush().then(function () {
      requestScope = currentScope(); if (!requestScope) throw new Error('作業が開かれていません。');
      setBusy(true); status('出力条件を確認しています…'); return post('preflight', {}, true, requestScope);
    }).then(function (data) {
      setBusy(false);
      if (!scopeIsCurrent(requestScope, true) || !data || String(data.project_id || '') !== requestScope.id || Number(data.revision) !== requestScope.revision) throw new Error('表示中の作業が変わったため、出力前の確認を中止しました。');
      preflightScope = requestScope;
      var mode = String(data.mode || 'blocked'), blockers = Array.isArray(data.blockers) ? data.blockers : [], warnings = Array.isArray(data.warnings) ? data.warnings : [];
      if (data.eligible && blockers.length) { warnings = warnings.concat(blockers); blockers = []; }
      el('cat-export-mode').textContent = outputModeLabel(mode);
      el('cat-export-name').textContent = data.output_name ? ('出力名: ' + data.output_name) : '';
      el('cat-export-checks').innerHTML = blockers.map(function (item) { return '<div class="cat-preflight-item is-blocked">' + esc(item.message || item.code || '出力条件を満たしていません。') + '</div>'; }).join('') + warnings.map(function (item) { return '<div class="cat-preflight-item">' + esc(item.message || item.code || item) + '</div>'; }).join('') + (!blockers.length ? '<div class="cat-preflight-item is-ready">確認済みの内容を出力できます。</div>' : '');
      el('cat-export-notice').textContent = data.draft_notice || '作成するファイルは確認用DRAFTです。完成版ではなく、社外配布できません。';
      el('cat-export-notice').hidden = mode === 'copy_text' || mode === 'blocked';
      el('cat-export-confirm').disabled = !data.eligible || mode === 'blocked';
      el('cat-export-confirm').textContent = mode === 'copy_text' ? '訳文をコピー' : 'DRAFTを作成';
      var dialog = el('cat-export-dialog'); dialog.returnValue = 'cancel'; dialog.showModal();
    }).catch(function (error) { setBusy(false); preflightScope = null; status(error.message, true); });
  }

  function goToNextQc() {
    if (!project) return Promise.resolve();
    var all = project.segments || [], after = all.find(function (segment) { return Number(segment.index) > Number(activeIndex) && segmentHasQc(segment); });
    var target = after || all.find(segmentHasQc);
    if (!target) { status('数値・単位などの機械チェックで問題は見つかりません。表現の適切さはご自身で確認してください。'); return Promise.resolve(); }
    currentFilter = 'qc'; currentLocation = 'all'; inspectorTab = 'qc';
    return activateIndex(Number(target.index), true);
  }

  function bind() {
    document.querySelectorAll('[data-cat-source-show]').forEach(function (button) { button.addEventListener('click', function () { showStart(button.getAttribute('data-cat-source-show')); }); });
    document.querySelectorAll('[data-cat-open]').forEach(function (button) { button.addEventListener('click', function () { openSource(button.getAttribute('data-cat-open'), 'auto'); }); });
    document.querySelectorAll('[data-cat-direction]').forEach(function (button) { button.addEventListener('click', function () { el('cat-direction-choice').hidden = true; if (pendingDirection) pendingDirection(button.getAttribute('data-cat-direction')); }); });
    el('cat-file-input').addEventListener('change', function () { uploaded = null; el('cat-file-name').textContent = this.files.length ? this.files[0].name : '.docx / .xlsx / .xlsm'; });
    bindFileDrop(el('cat-drop'), el('cat-file-input'));
    el('cat-prior-open').addEventListener('click', function () { var epoch = ++viewEpoch; setBusy(true); post('from-prior-version', { prior_ja: el('cat-prior-ja').value, prior_en: el('cat-prior-en').value, current_ja: el('cat-current-ja').value, document_name: el('cat-prior-name').value }, false, null).then(function (data) { if (epoch === viewEpoch) render(data, true); }).catch(function (error) { if (epoch !== viewEpoch) return; setBusy(false); status(error.message, true); }); });
    el('cat-align-open').addEventListener('click', function () { var epoch = viewEpoch; setBusy(true); YakuCommon.postText('/api/cat/align', { source_text: el('cat-align-source').value, target_text: el('cat-align-target').value, file_name: el('cat-align-name').value }).then(function (html) { startJobHtml(html, { type: 'align', name: el('cat-align-name').value, viewEpoch: epoch }); }).catch(function (error) { setBusy(false); status(error.message, true); }); });
    el('cat-switch-project').addEventListener('click', function () { if (busy) return; flush().then(showPicker).catch(function (error) { status(error.message, true); }); });
    el('cat-translate').addEventListener('click', translate); el('cat-export').addEventListener('click', openExportPreflight);
    document.addEventListener('click', function (event) {
      var button = event.target.closest('button'); if (!button) return;
      if (busy && (button.hasAttribute('data-cat-confirm') || button.hasAttribute('data-cat-merge') || button.hasAttribute('data-cat-split') || button.hasAttribute('data-cat-glossary') || button.hasAttribute('data-cat-insert') || button.hasAttribute('data-cat-term-open') || button.hasAttribute('data-cat-term-insert') || button.hasAttribute('data-cat-term-edit') || button.hasAttribute('data-cat-term-deactivate') || button.hasAttribute('data-cat-term-exception') || button.hasAttribute('data-cat-tm-delete') || button.hasAttribute('data-cat-shorten') || button.hasAttribute('data-cat-accept-revision') || button.hasAttribute('data-cat-revert-revision'))) { status('処理中です。完了してからもう一度お試しください。'); return; }
      if (button.hasAttribute('data-cat-activate')) return activateIndex(Number(button.getAttribute('data-cat-activate')), true);
      if (button.hasAttribute('data-cat-filter')) { currentFilter = button.getAttribute('data-cat-filter') || 'actionable'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-location')) { currentLocation = button.getAttribute('data-cat-location') || 'all'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-change')) { currentChange = button.getAttribute('data-cat-change') || 'all'; return redrawAfterFlush(); }
      if (button.hasAttribute('data-cat-inspector')) { inspectorTab = button.getAttribute('data-cat-inspector') || 'candidates'; renderInspector(); return; }
      if (button.hasAttribute('data-cat-resume')) return resume(button.getAttribute('data-cat-resume'));
      if (button.hasAttribute('data-cat-confirm')) return confirmRow(Number(button.getAttribute('data-cat-confirm')));
      if (button.hasAttribute('data-cat-merge')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('結合すると、対象行の訳文が消えます。結合しますか？')) return; return mutate('merge', { index: Number(button.getAttribute('data-cat-merge')) }, '行を結合しています…'); }
      if (button.hasAttribute('data-cat-split')) { if (button.getAttribute('data-cat-loss') === '1' && !window.confirm('解除すると、この行の訳文が消えます。解除しますか？')) return; return mutate('split', { index: Number(button.getAttribute('data-cat-split')) }, '結合を解除しています…'); }
      if (button.hasAttribute('data-cat-glossary')) return post('glossary-add', { id: project.id, index: Number(button.getAttribute('data-cat-glossary')) }).then(function (data) { status(data.message); });
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
      var note = event.target.closest('.cat-target').querySelector('.cat-example-trace');
      if (note) note.textContent = note.textContent.replace('その後編集なし', 'その後編集あり');
      saveStatus('変更を保存していません', false); el('cat-export').disabled = true; clearOutputDisplay();
      if (!el('cat-draft-warning').hidden) el('cat-draft-warning').textContent = '作成するファイルは確認用DRAFTです。完成版ではなく、社外配布できません。';
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
      var form = event.target.closest('[data-cat-revise]'); if (form) { event.preventDefault(); if (busy) { status('処理中です。完了してからもう一度お試しください。'); return; } revise(form); }
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
      if (busy) { status('処理中は翻訳例を挿入できません。完了してからもう一度お試しください。'); return; }
      var picks = document.querySelectorAll('#cat-candidates-list [data-cat-insert]');
      var pick = picks[Number(event.key) - 1]; if (pick) insertReference(pick);
    });
    el('cat-search').addEventListener('input', redrawAfterFlush);
    document.querySelector('[data-cat-term-cancel]').addEventListener('click', function () { el('cat-term-dialog').close(); });
    document.querySelector('[data-cat-term-exception-cancel]').addEventListener('click', function () { el('cat-term-exception-dialog').close(); });
    el('cat-next-qc').addEventListener('click', goToNextQc);
    el('cat-copy-again').addEventListener('click', function () { YakuCommon.copyText(el('cat-text-output-value').value, el('cat-text-output-value'), el('cat-status')); });
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
  function start() {
    YakuCommon.start(); YakuCommon.onReady(function (value) { ready = value; setBusy(busy); }); bind(); loadRecent();
    var wanted = new URLSearchParams(location.search).get('project'); if (wanted) resume(wanted); else showPicker();
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
