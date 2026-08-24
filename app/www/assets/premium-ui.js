(function () {
  'use strict';

  var PREMIUM_FLAG = 'data-yaku-premium-ready';
  var premiumState = {
    recent: [],
    recentStatus: 'loading',
    recentError: '',
    recentRetrying: false,
    catFilter: 'untranslated',
    catFilterTouched: false,
    catInspectorInitialized: false,
    lastQuickSource: '',
    lastQuickArchived: '',
    quickLength: 'full',
    quickTone: 'business',
    quickToneRequested: false,
    // 利用者が長さを触るまで、結果欄の描画のたびの取り直しで
    // 勝手に主札と添え札を入れ替えない(無言スワップの防止)。
    // 一度触ったら選択は次の翻訳以降も維持する。
    quickLengthTouched: false,
    quickBriefApplied: false,
    quickActionBusy: false,
    toolsInvoker: null,
    initialWorkMode: (function () { try { return new URLSearchParams(window.location.search).get('view') === 'work'; } catch (_) { return false; } })(),
    initialImport: (function () {
      try {
        var params = new URLSearchParams(window.location.search);
        var meta = document.querySelector('meta[name="yaku-import"]');
        return params.get('import') === '1' || !!(meta && meta.getAttribute('content') === '1');
      } catch (_) { return false; }
    })(),
    toastTimer: null
  };
  var premiumRowWait = null;

  function el(id) { return document.getElementById(id); }
  function one(selector, root) { return (root || document).querySelector(selector); }
  function all(selector, root) { return Array.prototype.slice.call((root || document).querySelectorAll(selector)); }
  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
    });
  }
  function create(tag, className, html) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (html != null) node.innerHTML = html;
    return node;
  }
  function onReady(callback) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', callback);
    else callback();
  }
  function debounce(callback, wait) {
    var timer = null;
    return function () {
      var args = arguments;
      window.clearTimeout(timer);
      timer = window.setTimeout(function () { callback.apply(null, args); }, wait || 80);
    };
  }
  function randomKey() {
    if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID().replace(/-/g, '');
    return Date.now().toString(36) + Math.random().toString(36).slice(2) + Math.random().toString(36).slice(2);
  }
  function textOf(node) {
    if (!node) return '';
    return String(node.value != null ? node.value : node.textContent || '').trim();
  }
  function reducedMotion() {
    try { return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches); }
    catch (_) { return false; }
  }

  function showToast(message, kind) {
    var toast = el('premium-toast');
    if (!toast) {
      toast = create('div', 'premium-toast');
      toast.id = 'premium-toast';
      toast.setAttribute('role', 'status');
      toast.setAttribute('aria-live', 'polite');
      document.body.appendChild(toast);
    }
    toast.textContent = String(message || '');
    toast.classList.remove('is-error', 'is-warning');
    if (kind === 'error') toast.classList.add('is-error');
    if (kind === 'warning') toast.classList.add('is-warning');
    toast.classList.add('is-showing');
    window.clearTimeout(premiumState.toastTimer);
    premiumState.toastTimer = window.setTimeout(function () { toast.classList.remove('is-showing'); }, 2200);
  }

  function syncToolsExpanded() {
    var workspace = el('cat-workspace');
    var toolbar = el('cat-editor-toolbar');
    var active = document.body.classList.contains('premium-cat') &&
      (document.body.classList.contains('premium-mode-workspace') || document.body.classList.contains('premium-mode-align-workspace')) &&
      !!(workspace && !workspace.hidden && toolbar);
    var expanded = document.body.classList.contains('premium-tools-open') ? 'true' : 'false';
    ['premium-tools'].forEach(function (id) {
      var node = el(id);
      if (!node) return;
      if (!active) {
        node.removeAttribute('aria-controls');
        node.removeAttribute('aria-expanded');
        return;
      }
      node.setAttribute('aria-controls', 'cat-editor-toolbar');
      node.setAttribute('aria-expanded', expanded);
    });
  }

  function focusFirstTool() {
    var toolbar = el('cat-editor-toolbar');
    if (!toolbar) return;
    var first = one('button:not([hidden]):not([disabled]),input:not([hidden]):not([disabled]),select:not([hidden]):not([disabled]),textarea:not([hidden]):not([disabled]),summary', toolbar);
    if (!first) return;
    try { first.focus({ preventScroll: true }); } catch (_) { first.focus(); }
  }

  function openTools(invoker) {
    premiumState.toolsInvoker = invoker || null;
    document.body.classList.add('premium-tools-open');
    syncToolsExpanded();
    var toolbar = el('cat-editor-toolbar');
    if (toolbar) toolbar.scrollTop = 0;
    focusFirstTool();
  }

  function closeTools() {
    var wasOpen = document.body.classList.contains('premium-tools-open');
    var toolbar = el('cat-editor-toolbar');
    var active = document.activeElement;
    var shouldRestore = wasOpen && !!(toolbar && active && toolbar.contains(active));
    var invoker = premiumState.toolsInvoker;
    document.body.classList.remove('premium-tools-open');
    syncToolsExpanded();
    premiumState.toolsInvoker = null;
    if (shouldRestore && invoker && document.contains(invoker) && !invoker.hidden && !invoker.disabled) {
      try { invoker.focus({ preventScroll: true }); } catch (_) { invoker.focus(); }
    }
  }

  function buildTopbar() {
    var topbar = create('header', 'premium-topbar');
    topbar.innerHTML =
      '<div class="premium-topbar-left"><span id="premium-top-product" class="premium-top-product"></span><span class="premium-top-separator"></span>' +
      '<strong id="premium-top-context" class="premium-top-context"></strong></div>' +
      '<div class="premium-top-actions"><a href="/cat?view=work" data-premium-nav="work">作業一覧</a>' +
      '<button id="premium-translate" type="button" class="premium-top-action" hidden>未訳を翻訳</button>' +
      '<button id="premium-qa" type="button" class="premium-top-action" hidden>点検結果</button>' +
      '<button id="premium-tools" type="button" class="premium-top-text-button" hidden>その他</button>' +
      '<button id="premium-export" type="button" class="premium-top-action premium-primary-action" hidden>Excelを書き出す</button>' +
      '<button id="premium-new-chat" type="button" class="premium-top-action" hidden>＋ 新しい会話</button></div>';
    return topbar;
  }
  function setTopbar(product, context, options) {
    options = options || {};
    if (el('premium-top-product')) el('premium-top-product').textContent = product || '';
    if (el('premium-top-context')) el('premium-top-context').textContent = context || '';
    ['premium-translate', 'premium-qa', 'premium-tools', 'premium-export', 'premium-new-chat'].forEach(function (id) {
      var node = el(id);
      if (node) node.hidden = !options[id];
    });
  }
  function setActiveNav(key) {
    all('[data-premium-nav]').forEach(function (node) {
      node.classList.toggle('is-active', node.getAttribute('data-premium-nav') === key);
    });
  }
  function moveCopilotControls(sidebar) {
    var slot = one('#premium-copilot-slot', sidebar);
    if (!slot) return;
    var status = el('copilot-status');
    var detail = el('copilot-status-detail');
    var open = el('copilot-window-open');
    var retry = el('copilot-prepare-retry');
    if (status && !status.closest('#premium-copilot-slot')) {
      var row = create('div', 'premium-copilot-status');
      row.appendChild(status);
      slot.appendChild(row);
    }
    if (detail) slot.appendChild(detail);
    if (open) slot.appendChild(open);
    if (retry) slot.appendChild(retry);
  }
  function mountPremiumFrame(root, active, bodyClass) {
    document.body.classList.add('premium-ui', bodyClass);
    var app = el('premium-app');
    var main = one('.premium-main', app || document);
    var topbar = el('premium-topbar');
    if (!app || !main || !topbar) {
      app = create('div', 'premium-app');
      main = create('div', 'premium-main');
      topbar = buildTopbar();
      root.parentNode.insertBefore(app, root);
      app.appendChild(main);
      main.appendChild(topbar);
      main.appendChild(root);
    }
    moveCopilotControls(app);
    return { app: app, main: main, topbar: topbar };
  }

  function normalizeRecent(data) {
    return (data && data.projects || []).map(function (item) {
      var total = Math.max(0, Number(item.total || 0));
      var confirmed = Math.max(0, Number(item.confirmed || 0));
      var remaining = Math.max(0, total - confirmed);
      return {
        id: String(item.id || ''),
        source: String(item.source || ''),
        fileName: String(item.file_name || item.display_name || '名称未設定'),
        direction: String(item.direction || ''),
        revision: Number(item.revision || 0),
        total: total,
        confirmed: confirmed,
        remaining: remaining,
        saved: String(item.saved || ''),
        percent: total ? Math.round(100 * confirmed / total) : 0
      };
    });
  }
  function adoptRecent(data) {
    var error = data && data.error;
    premiumState.recentStatus = error ? 'error' : 'ready';
    premiumState.recentError = error && error.message ? String(error.message) : '';
    premiumState.recentRetrying = false;
    premiumState.recent = normalizeRecent(data);
    renderSidebarRecent();
    renderWorkCards();
    return premiumState.recent;
  }
  function fetchRecent() {
    if (!(window.YakuCommon && YakuCommon.post)) return Promise.resolve([]);
    return YakuCommon.post('/api/cat/recent', {}).then(function (data) {
      return adoptRecent(data);
    }).catch(function () {
      return adoptRecent({ projects: [], error: { message: '最近の作業を読み込めませんでした。' } });
    });
  }
  function adoptCatRecentSnapshot(data) {
    if (data && typeof data === 'object') return adoptRecent(data);
    if (window.YakuCat && typeof YakuCat.getRecentSnapshot === 'function') {
      var snapshot = YakuCat.getRecentSnapshot();
      if (snapshot) return adoptRecent(snapshot);
    }
    return premiumState.recent;
  }
  function retryCatRecent() {
    if (premiumState.recentRetrying || !(window.YakuCat && typeof YakuCat.refreshRecent === 'function')) return;
    premiumState.recentRetrying = true;
    renderSidebarRecent();
    renderWorkCards();
    Promise.resolve(YakuCat.refreshRecent()).then(function () {
      premiumState.recentRetrying = false;
      renderSidebarRecent();
      renderWorkCards();
    }, function () {
      premiumState.recentRetrying = false;
      renderSidebarRecent();
      renderWorkCards();
    });
  }
  function recentErrorMarkup() {
    var retry = premiumState.recentRetrying ? '読み込み中…' : '再読み込み';
    return '<div class="premium-recent-error" data-premium-recent-error role="alert"><strong>最近の作業を読み込めません</strong><span>' + escapeHtml(premiumState.recentError || '通信を確認して、もう一度お試しください。') + '</span><button type="button" data-premium-recent-retry>' + retry + '</button></div>';
  }
  function bindRecentRetry(host) {
    var button = host && host.querySelector('[data-premium-recent-retry]');
    if (button) { button.disabled = premiumState.recentRetrying; button.addEventListener('click', retryCatRecent); }
  }
  function recentMeta(item) {
    if (item.source === 'align') {
      return '過去訳の対応確認 ・ ' + (item.remaining ? 'あと' + item.remaining + '行' : '確認完了');
    }
    var direction = item.direction === 'to_jp' ? '英語 → 日本語' : '日本語 → 英語';
    return direction + ' ・ ' + (item.remaining ? 'あと' + item.remaining + '行' : '確認完了');
  }
  function renderSidebarRecent() {
    var hosts = [el('premium-sidebar-recent'), el('premium-start-recent-list')].filter(Boolean);
    var count = el('premium-recent-count');
    if (!hosts.length) return;
    if (premiumState.recentStatus === 'error') {
      if (count) count.textContent = '読込失敗';
      hosts.forEach(function (host) { host.innerHTML = recentErrorMarkup(); bindRecentRetry(host); });
      return;
    }
    var rows = premiumState.recent.slice(0, 3);
    if (count) count.textContent = rows.length + '件';
    if (!rows.length) {
      hosts.forEach(function (host) { host.innerHTML = '<p class="premium-sidebar-empty">保存済みの作業はまだありません。</p>'; });
      return;
    }
    var markup = rows.map(function (item) {
      return '<a class="premium-recent-item" href="/cat?project=' + encodeURIComponent(item.id) + '"><strong title="' + escapeHtml(item.fileName) + '">' +
        escapeHtml(item.fileName) + '</strong><span>' + escapeHtml(recentMeta(item)) + '</span><i><b style="width:' + item.percent + '%"></b></i></a>';
    }).join('');
    hosts.forEach(function (host) { host.innerHTML = markup; });
  }

  /* Excel start and saved work ------------------------------------------- */
  function buildCatStart(picker) {
    var start = el('premium-cat-start');
    if (!picker || !start || start.getAttribute('data-bound') === '1') return;
    start.setAttribute('data-bound', '1');

    var direction = 'to_en';
    all('#premium-direction-switch button').forEach(function (button) {
      button.addEventListener('click', function () {
        all('#premium-direction-switch button').forEach(function (item) {
          item.classList.toggle('is-active', item === button);
          item.setAttribute('aria-pressed', item === button ? 'true' : 'false');
        });
        button.classList.add('is-active');
        direction = button.getAttribute('data-direction') || 'to_en';
      });
    });
    var fileInput = el('premium-file-input');
    var fileSelect = el('premium-file-select');
    var drop = el('premium-file-drop');
    function choose() { if (fileInput) { fileInput.value = ''; fileInput.click(); } }
    if (fileSelect) fileSelect.addEventListener('click', choose);
    if (drop) {
      ['dragenter', 'dragover'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.add('is-dragging'); }); });
      ['dragleave', 'drop'].forEach(function (name) { drop.addEventListener(name, function (event) { event.preventDefault(); drop.classList.remove('is-dragging'); }); });
      drop.addEventListener('drop', function (event) {
        var file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0];
        if (file) openExcelFile(file, direction);
      });
    }
    if (fileInput) fileInput.addEventListener('change', function () { if (this.files && this.files[0]) openExcelFile(this.files[0], direction); });
  }
  function openExcelFile(file, direction) {
    if (!file) return;
    if (Number(file.size || 0) <= 0) {
      showToast('空のファイルは読み込めません。', 'warning');
      return;
    }
    if (!/\.(xlsx|xlsm)$/i.test(String(file.name || ''))) {
      showToast('Excelファイル（.xlsx / .xlsm）を選んでください。', 'warning');
      return;
    }
    var max = window.YakuCommon && Number(YakuCommon.maxUploadBytes || 0);
    if (max > 0 && file.size > max) {
      showToast('ファイルが大きすぎます。資料を分けてからお試しください。', 'error');
      return;
    }
    if (!(window.YakuCommon && YakuCommon.upload && YakuCommon.post)) {
      showToast('ファイルを読み込む準備ができていません。', 'error');
      return;
    }
    document.body.classList.add('premium-file-busy');
    var button = el('premium-file-select');
    if (button) button.textContent = '読み込んでいます…';
    YakuCommon.upload('/api/upload', file).then(function (data) {
      if (!data || !data.file_handle) throw new Error('ファイルを読み込めませんでした。');
      return YakuCommon.post('/api/cat/open', { file_handle: data.file_handle, direction_intent: direction || 'to_en' });
    }).then(function (project) {
      if (!project || !project.id) throw new Error('翻訳作業を作れませんでした。');
      window.location.assign('/cat?project=' + encodeURIComponent(project.id));
    }).catch(function (error) {
      document.body.classList.remove('premium-file-busy');
      if (button) button.textContent = 'Excelを選ぶ';
      showToast(error && error.message ? error.message : 'Excelを読み込めませんでした。', 'error');
    });
  }
  function buildWorkList(picker) {
    if (!picker || el('premium-work-list')) return;
    var view = create('section', 'premium-work-list');
    view.id = 'premium-work-list';
    view.innerHTML = '<header class="premium-work-list-head"><div><span class="premium-eyebrow">保存済みの作業</span><h1>作業一覧</h1>' +
      '<p>Excel翻訳と過去訳の対応確認を、保存したところから再開できます。</p></div><button id="premium-new-excel" type="button">新しいExcelを開く</button></header>' +
      '<div id="premium-work-cards" class="premium-work-cards"></div>';
    picker.appendChild(view);
    var newExcel = el('premium-new-excel');
    if (newExcel) newExcel.addEventListener('click', function () { window.location.assign('/cat'); });
  }
  function renderWorkCards() {
    var host = el('premium-work-cards');
    if (!host) return;
    if (premiumState.recentStatus === 'error') {
      host.innerHTML = recentErrorMarkup();
      bindRecentRetry(host);
      return;
    }
    var rows = premiumState.recent;
    if (!rows.length) {
      host.innerHTML = '<div class="premium-work-empty"><strong>保存済みの作業はまだありません。</strong><p>Excel翻訳や過去訳の対応確認を始めると、途中経過がここに自動保存されます。</p></div>';
      return;
    }
    host.innerHTML = rows.map(function (item) {
      var direction = item.direction === 'to_jp' ? '英語 → 日本語' : '日本語 → 英語';
      var isAlignment = item.source === 'align';
      var icon = isAlignment ? '↔' : 'XLS';
      var description = isAlignment ? '過去訳の対応確認' : direction;
      var sourceMeta = isAlignment ? '<small class="premium-work-card-meta">' + escapeHtml(recentMeta(item)) + '</small>' : '';
      var openLabel = isAlignment ? '過去訳の対応確認を再開' : (item.remaining ? '続きから開く' : '開く');
      return '<article class="premium-work-card" data-work-id="' + escapeHtml(item.id) + '"><header><span class="premium-work-file-icon">' + icon + '</span><div><h2 title="' + escapeHtml(item.fileName) + '">' + escapeHtml(item.fileName) + '</h2>' +
        '<p>' + escapeHtml(description) + '</p>' + sourceMeta + '</div></header><div class="premium-work-metrics"><div><b>' + item.confirmed + ' / ' + item.total + '</b><span>確認済み</span></div>' +
        '<div><b>' + item.remaining + '</b><span>残り</span></div><div><b>' + item.percent + '%</b><span>進捗</span></div></div>' +
        '<div class="premium-work-progress"><i style="width:' + item.percent + '%"></i></div><footer><button type="button" data-work-delete="' + escapeHtml(item.id) + '">削除</button>' +
        '<a href="/cat?project=' + encodeURIComponent(item.id) + '">' + openLabel + '</a></footer></article>';
    }).join('');
    all('[data-work-delete]', host).forEach(function (button) {
      button.addEventListener('click', function () { deleteSavedWork(button.getAttribute('data-work-delete')); });
    });
  }
  function deleteSavedWork(id) {
    var item = premiumState.recent.filter(function (row) { return row.id === id; })[0];
    var confirmMessage = item && item.source === 'align'
      ? '「' + item.fileName + '」の過去訳の対応確認を削除します。元のPDFは削除しません。'
      : item ? '「' + item.fileName + '」の途中保存を削除します。元のExcelは削除しません。' : '';
    if (!item || !window.confirm(confirmMessage)) return;
    if (!(window.YakuCommon && YakuCommon.post)) return;
    YakuCommon.post('/api/cat/delete', {
      id: id,
      expected_revision: item.revision,
      memory_policy: 'retain_tm',
      client_id: YakuCommon.clientId ? YakuCommon.clientId() : '',
      idempotency_key: randomKey()
    }).then(function () {
      premiumState.recent = premiumState.recent.filter(function (row) { return row.id !== id; });
      renderSidebarRecent();
      renderWorkCards();
      if (window.YakuCat && typeof YakuCat.refreshRecent === 'function') YakuCat.refreshRecent();
      showToast('作業を削除しました。');
    }).catch(function (error) { showToast(error && error.message ? error.message : '削除できませんでした。', 'error'); });
  }

  /* Focused Excel work surface ------------------------------------------- */
  function ensureWorkspaceUi() {
    var workspace = el('cat-workspace');
    var panel = el('premium-cell-list-pane');
    if (!workspace || !panel) return;
    if (panel.getAttribute('data-bound') !== '1') {
      panel.setAttribute('data-bound', '1');
      all('[data-premium-filter]', panel).forEach(function (button) {
        button.addEventListener('click', function () {
          premiumState.catFilterTouched = true;
          premiumState.catFilter = button.getAttribute('data-premium-filter') || 'untranslated';
          syncPremiumFilterUi();
          renderFitRows();
        });
      });
    }
    moveRowActions();
    preparePremiumRowActions();
  }

  function removeExcelWorkspaceUi() {
    var actions = el('cat-segment-actions');
    var legacyActions = el('cat-actions');
    if (actions && legacyActions && actions.parentNode !== legacyActions) legacyActions.appendChild(actions);
  }

  function moveRowActions() {
    var host = el('premium-row-actions'), actions = el('cat-segment-actions');
    if (host && actions && actions.parentNode !== host) host.appendChild(actions);
  }
  function preparePremiumRowActions() {
    var host = el('premium-row-actions'), actions = el('cat-segment-actions');
    if (!host || !actions) return;
    var primary = one('.premium-row-primary', host), disclosure = one('.premium-row-details', host), detailContent;
    if (!primary) { primary = create('div', 'premium-row-primary'); host.appendChild(primary); }
    if (!disclosure) { disclosure = create('details', 'premium-row-details'); disclosure.id = 'premium-row-details'; disclosure.innerHTML = '<summary>この行の詳細</summary><div class="premium-row-details-content"></div>'; host.appendChild(disclosure); }
    detailContent = one('.premium-row-details-content', disclosure);
    var row = one('#cat-grid-body tr.is-active'), model = row ? rowModel(row) : null;
    var nodes = Array.prototype.slice.call(actions.children).filter(function (node) { return node !== primary && node !== disclosure && !node.classList.contains('cat-segment-actions-dynamic'); });
    var dynamic = one(':scope > .cat-segment-actions-dynamic', actions);
    if (dynamic) nodes = nodes.concat(Array.prototype.slice.call(dynamic.children).filter(function (node) { return !node.classList.contains('sr-only'); }));
    if (!nodes.length && (primary.children.length || detailContent.children.length)) { host.hidden = !row || actions.hidden; return; }
    var signature = (model ? model.index : '') + '|' + nodes.map(function (node) { return node.outerHTML; }).join('|') + '|' + (model ? model.canonical : '');
    if (host.getAttribute('data-premium-action-signature') === signature) return;
    host.setAttribute('data-premium-action-signature', signature);
    primary.innerHTML = ''; detailContent.innerHTML = '';
    var primaryNodes = nodes.filter(function (node) { return node.hasAttribute('data-cat-confirm') || node.hasAttribute('data-cat-unconfirm') || node.getAttribute('data-cat-inspector') === 'qc' || node.hasAttribute('data-cat-placement-edit'); });
    var detailNodes = nodes.filter(function (node) { return primaryNodes.indexOf(node) < 0; });
    primaryNodes.forEach(function (node) {
      var label = one('.cat-segment-button-label', node);
      if (node.hasAttribute('data-cat-confirm')) {
        var canConfirm = !model || String(model.target || '').trim().length > 0;
        if (label) label.textContent = canConfirm ? 'この行を確認して次へ' : '訳文を入力してから確認';
        node.disabled = !canConfirm;
        node.title = canConfirm ? 'この行を確認済みにする（Ctrl+Enter）' : '先に「未訳を翻訳」または「この行だけ訳す」で訳文を入れてください。';
        node.setAttribute('aria-label', canConfirm ? 'この行を確認して次へ' : '訳文を入力してから確認');
      }
      else if (node.hasAttribute('data-cat-unconfirm')) { if (label) label.textContent = '確認を取り消す'; }
      else if (node.getAttribute('data-cat-inspector') === 'qc') { if (label) label.textContent = '指摘を見る'; }
      else if (node.hasAttribute('data-cat-placement-edit')) {
        if (label) label.textContent = 'Excel表示を確認';
        node.hidden = !model || (!model.risk && !model.warning);
      }
      primary.appendChild(node);
    });
    detailNodes.forEach(function (node) { detailContent.appendChild(node); });
    if (model && model.canonical && model.canonical !== model.target) {
      var canonical = create('p', 'premium-canonical-detail'); canonical.innerHTML = '<strong>基準訳</strong><span>' + escapeHtml(model.canonical) + '</span>'; detailContent.insertBefore(canonical, detailContent.firstChild);
    }
    disclosure.hidden = !detailNodes.length && !(model && model.canonical && model.canonical !== model.target);
    host.hidden = !row || actions.hidden;
  }
  function runPremiumOutputAction() {
    var models = premiumModels(), saveFailed = models.some(function (model) { return model.saveFailed; });
    if (!saveFailed) return runPremiumStage('export');
    var api = window.YakuCat;
    if (api && typeof api.resave === 'function') {
      return Promise.resolve(api.resave()).then(function () { refreshWorkspaceUi(); }, function () { refreshWorkspaceUi(); });
    }
    return runPremiumStage('export');
  }
  function runPremiumStage(stage) {
    if (stage === 'translate') { var translate = el('cat-translate'); if (translate && !translate.disabled) translate.click(); return; }
    if (stage === 'export') { var exportButton = el('cat-export'); if (exportButton && !exportButton.disabled) exportButton.click(); else stage = 'review'; }
    if (stage !== 'review') return;
    premiumState.catFilter = 'review';
    premiumState.catFilterTouched = true;
    var button = one('[data-premium-filter="' + premiumState.catFilter + '"]'); if (button) button.click();
    var filter = one('[data-cat-filter="all"]'); if (filter) filter.click();
    window.setTimeout(function () { var first = one('#premium-cell-list .premium-cell-row'); if (first) first.click(); }, 60);
  }
  function bindStageActions() {
    all('[data-premium-stage]').forEach(function (button) { if (button.getAttribute('data-bound') === '1') return; button.setAttribute('data-bound', '1'); button.addEventListener('click', function () { if (!button.disabled) runPremiumStage(button.getAttribute('data-premium-stage')); }); });
    var summary = el('premium-output-summary-open');
    if (summary && summary.getAttribute('data-bound') !== '1') { summary.setAttribute('data-bound', '1'); summary.addEventListener('click', function () { runPremiumOutputAction(); }); }
  }
  function premiumModels() {
    var domModels = all('#cat-grid-body [data-cat-row]').map(rowModel), snapshot = window.YakuCat && typeof window.YakuCat.getPremiumSnapshot === 'function' ? window.YakuCat.getPremiumSnapshot() : [];
    if (!Array.isArray(snapshot) || !snapshot.length) return domModels;
    var domByIndex = {};
    domModels.forEach(function (model) { domByIndex[String(model.index)] = model; });
    return snapshot.map(function (model) {
      var current = domByIndex[String(model.index)];
      if (current) return current;
      model.row = null;
      return model;
    });
  }
  function rowModel(row) {
    var input = one('textarea[data-cat-input]', row), location = textOf(one('.cat-location-main', row)) || textOf(one('.cat-col-loc', row)), source = textOf(one('.cat-source-text', row)), target = input ? String(input.value || '').trim() : '';
    var variant = row.getAttribute('data-cat-publication-variant') === '1', effective = variant ? String(row.getAttribute('data-cat-effective-value') || target).trim() : target;
    var canonical = String(row.getAttribute('data-cat-canonical-translation') || '').trim(), risk = !!one('.cat-fit-risk-badge,[data-cat-fit-candidates]', row), reviewed = row.getAttribute('data-cat-confirmed') === '1', index = row.getAttribute('data-cat-row') || '', state = row.getAttribute('data-yaku-cat-state') || '';
    var warning = row.getAttribute('data-cat-qc-warning') === '1', saveFailed = row.classList.contains('cat-unsaved') || row.classList.contains('cat-dirty') || row.getAttribute('data-cat-save-failed') === '1', qcError = row.getAttribute('data-cat-blocking') === '1' && !!one('.premium-inline-findings,.cat-qc-findings', row);
    var blocking = row.getAttribute('data-cat-blocking') === '1' || !effective || saveFailed, stale = state === 'stale', recommended = !blocking && (row.getAttribute('data-cat-recommended') === '1' || warning || risk || !reviewed);
    var reason = !effective ? '未翻訳' : saveFailed ? '保存失敗' : qcError ? '点検エラー' : stale ? '再点検' : risk ? '収まり要確認' : warning ? '指摘あり' : !reviewed ? '未確認' : '収まり見込み';
    return { row: row, index: index, location: location, source: source, target: effective, canonical: canonical, risk: risk, reviewed: reviewed, warning: warning, blocking: blocking, saveFailed: saveFailed, qcError: qcError, stale: stale, recommended: recommended, reason: reason };
  }
  function fitRowStatus(model) {
    if (!model) return '';
    if (model.blocking) {
      /* 原文・訳文の「未翻訳」と、出力を止める理由を同じ短語で
         並べると、何を直すべきか分からない。空欄だけは状態を一段
         具体化し、他のブロッカーは既存の理由を保つ。 */
      return !String(model.target || '').trim() ? '未翻訳（出力を止めます）' : (model.reason || '要対応');
    }
    return model.risk ? '収まり要確認' : '収まり見込み';
  }
  function syncPremiumFilterUi() {
    var panel = el('premium-cell-list-pane');
    if (!panel) return;
    all('[data-premium-filter]', panel).forEach(function (button) {
      var active = button.getAttribute('data-premium-filter') === premiumState.catFilter;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-pressed', active ? 'true' : 'false');
    });
  }
  function renderFitRows() {
    syncPremiumFilterUi();
    var host = el('premium-cell-list');
    if (!host) return;
    var models = premiumModels();
    var untranslated = models.filter(function (model) { return !model.target; }).length;
    var review = models.filter(function (model) { return !!model.target && (model.blocking || model.recommended); }).length;
    if (el('premium-filter-untranslated')) el('premium-filter-untranslated').textContent = untranslated;
    if (el('premium-filter-review')) el('premium-filter-review').textContent = review;
    if (el('premium-filter-all')) el('premium-filter-all').textContent = models.length;
    if (el('premium-cell-list-count')) el('premium-cell-list-count').textContent = models.length + '件';

    var filtered = models.filter(function (model) {
      if (premiumState.catFilter === 'untranslated') return !model.target;
      if (premiumState.catFilter === 'review') return !!model.target && (model.blocking || model.recommended);
      return true;
    });
    if (!filtered.length && premiumState.catFilter === 'untranslated') {
      premiumState.catFilter = review > 0 ? 'review' : 'all';
      syncPremiumFilterUi();
      return renderFitRows();
    }
    if (!filtered.length) {
      host.innerHTML = '<p class="premium-cell-empty">' + (premiumState.catFilter === 'review' ? '要確認のセルはありません。' : '該当するセルはありません。') + '</p>';
      return;
    }
    host.innerHTML = filtered.map(function (model) {
      var status = !model.target ? '未訳' : model.blocking || model.recommended ? '要確認' : model.reviewed ? '確認済み' : '下訳';
      var active = !!(model.row && model.row.classList.contains('is-active'));
      var label = [model.location, model.source || '原文なし', model.target || '未訳', status].join(' / ');
      return '<button type="button" role="option" aria-selected="' + (active ? 'true' : 'false') + '" class="premium-cell-row' + (active ? ' is-active' : '') + '" data-premium-row="' + escapeHtml(model.index) + '" aria-label="' + escapeHtml(label) + '">' +
        '<span class="premium-cell-location">' + escapeHtml(model.location || ((Number(model.index) + 1) + '行目')) + '</span>' +
        '<strong>' + escapeHtml(model.source || '原文なし') + '</strong>' +
        '<span class="premium-cell-target">' + escapeHtml(model.target || '訳文なし') + '</span>' +
        '<em class="premium-cell-state is-' + (status === '未訳' ? 'untranslated' : status === '要確認' ? 'review' : status === '確認済み' ? 'reviewed' : 'draft') + '">' + status + '</em></button>';
    }).join('');
  }

  function updatePremiumStageState(total, counts, reviewed, untranslated) {
    var exportButton = el('cat-export');
    var status = el('premium-export-status');
    if (!status) return;
    if (!exportButton) status.textContent = '出力条件を確認中';
    else if (counts.saveFailed > 0) status.textContent = '保存失敗 ' + counts.saveFailed + '件';
    else if (untranslated > 0) status.textContent = '未訳 ' + untranslated + '件のため出力できません';
    else if (counts.qc > 0 || counts.stale > 0) status.textContent = '未解決エラー ' + (counts.qc + counts.stale) + '件';
    else if (counts.recommended > 0) status.textContent = '要確認 ' + counts.recommended + '件（出力可能）';
    else status.textContent = exportButton.disabled ? '出力条件を確認してください' : '出力できます';
  }

  function refreshWorkspaceUi() {
    if (!document.body.classList.contains('premium-mode-workspace')) return;
    ensureWorkspaceUi(); moveRowActions();
    var models = premiumModels(), totalNode = one('[data-cat-count="all"]'), total = totalNode ? Number(totalNode.textContent || 0) : models.length;
    var reviewed = models.filter(function (model) { return model.reviewed; }).length, untranslated = models.filter(function (model) { return !model.target; }).length;
    var counts = { blockers: models.filter(function (model) { return model.blocking; }).length, recommended: models.filter(function (model) { return model.recommended; }).length, untranslated: untranslated, qc: models.filter(function (model) { return model.qcError; }).length, stale: models.filter(function (model) { return model.stale; }).length, saveFailed: models.filter(function (model) { return model.saveFailed; }).length };
    if (!premiumState.catFilterTouched) premiumState.catFilter = untranslated > 0 ? 'untranslated' : counts.recommended > 0 ? 'review' : 'all';
    if (el('premium-fit-count')) el('premium-fit-count').textContent = reviewed; if (el('premium-total-count')) el('premium-total-count').textContent = total; if (el('premium-fit-percent')) el('premium-fit-percent').textContent = (total ? Math.round(100 * reviewed / total) : 0) + '%'; if (el('premium-fit-progress')) el('premium-fit-progress').style.width = (total ? Math.round(100 * reviewed / total) : 0) + '%'; if (el('premium-fit-done')) el('premium-fit-done').textContent = reviewed; if (el('premium-fit-left')) el('premium-fit-left').textContent = counts.blockers; if (el('premium-recommended-count')) el('premium-recommended-count').textContent = counts.recommended; if (el('premium-untranslated')) el('premium-untranslated').textContent = untranslated;
    if (el('premium-fit-blockers')) el('premium-fit-blockers').textContent = counts.blockers; if (el('premium-fit-recommended')) el('premium-fit-recommended').textContent = counts.recommended; if (el('premium-fit-all')) el('premium-fit-all').textContent = total;
    var title = textOf(el('cat-toolbar-title')), direction = textOf(el('cat-toolbar-direction')); if (el('premium-summary-context')) el('premium-summary-context').textContent = [title, direction].filter(Boolean).join(' ・ ');
    var active = one('#cat-grid-body tr.is-active'); if (active) { var model = rowModel(active), cell = model.location.match(/(?:^|[,!\s])([A-Z]{1,3}\d+)$/i); if (el('premium-active-cell')) el('premium-active-cell').textContent = cell ? cell[1].toUpperCase() : ((Number(model.index) + 1) + '行目'); if (el('premium-active-location')) el('premium-active-location').textContent = model.location || '選択中のセル'; var riskBadge = el('premium-editor-risk'); if (riskBadge) { riskBadge.textContent = fitRowStatus(model); riskBadge.classList.toggle('is-fit', !model.blocking && !model.risk); riskBadge.classList.toggle('is-risk', !!model.risk); } }
    updatePremiumStageState(total, counts, reviewed, untranslated); preparePremiumRowActions(); renderFitRows(); syncTopActionStates();
  }
  function cancelPremiumRowWait() {
    if (!premiumRowWait) return;
    premiumRowWait.observer.disconnect();
    window.clearTimeout(premiumRowWait.timer);
    premiumRowWait = null;
  }
  function premiumViewIdentity() {
    var project = '';
    try { project = new URLSearchParams(window.location.search).get('project') || ''; } catch (_) {}
    var workspace = el('cat-workspace');
    var title = textOf(el('cat-toolbar-title'));
    var direction = textOf(el('cat-toolbar-direction'));
    return [window.location.pathname, project, document.body.getAttribute('data-cat-view') || '',
      workspace && !workspace.hidden ? 'workspace' : 'hidden', title, direction].join('|');
  }
  function waitForPremiumRow(index) {
    cancelPremiumRowWait();
    var workspace = el('cat-workspace');
    if (!workspace) return;
    var identity = premiumViewIdentity();
    var requestedInput = null;
    function inspect() {
      if (premiumViewIdentity() !== identity) {
        cancelPremiumRowWait();
        return true;
      }
      var row = one('#cat-grid-body [data-cat-row="' + index + '"]');
      var input = row && one('textarea[data-cat-input]', row);
      if (!row || !input) return false;
      if (!row.classList.contains('is-active')) {
        if (requestedInput !== input) {
          requestedInput = input;
          input.dispatchEvent(new Event('focusin', { bubbles: true }));
        }
        return false;
      }
      cancelPremiumRowWait();
      input.focus();
      row.scrollIntoView({ block: 'center', behavior: reducedMotion() ? 'auto' : 'smooth' });
      return true;
    }
    var observer = new MutationObserver(inspect);
    premiumRowWait = {
      observer: observer,
      identity: identity,
      /* The observer is the success path; this is only a route/error teardown
         guard so a failed import cannot leave an observer forever. */
      timer: window.setTimeout(cancelPremiumRowWait, 30000)
    };
    observer.observe(workspace, { childList: true, subtree: true, attributes: true });
    inspect();
  }
  function openPremiumRow(index) {
    var row = one('#cat-grid-body [data-cat-row="' + index + '"]');
    if (!row) {
      var allFilter = one('[data-cat-filter="all"]');
      if (allFilter) allFilter.click();
      waitForPremiumRow(index);
      return;
    }
    var input = one('textarea[data-cat-input]', row);
    if (!input) {
      waitForPremiumRow(index);
      return;
    }
    if (!row.classList.contains('is-active')) {
      waitForPremiumRow(index);
      return;
    }
    cancelPremiumRowWait();
    if (input) {
      input.focus();
      row.scrollIntoView({ block: 'center', behavior: reducedMotion() ? 'auto' : 'smooth' });
    }
  }
  function setupTopActionProxies() {
    function bind(proxyId, originalId) {
      var proxy = el(proxyId);
      if (!proxy || proxy.getAttribute('data-bound') === '1') return;
      proxy.setAttribute('data-bound', '1');
      proxy.addEventListener('click', function () {
        var original = el(originalId);
        if (original && !original.disabled) original.click();
      });
    }
    bind('premium-translate', 'cat-translate');
    bind('premium-qa', 'cat-qa-open');
    bind('premium-export', 'cat-export');
    var tools = el('premium-tools');
    if (tools && tools.getAttribute('data-bound') !== '1') {
      tools.setAttribute('data-bound', '1');
      tools.addEventListener('click', function () {
        if (document.body.classList.contains('premium-tools-open')) closeTools();
        else openTools(tools);
      });
    }
  }
  function syncTopActionStates() {
    var pairs = [
      ['premium-translate', 'cat-translate', '未訳を翻訳'],
      ['premium-qa', 'cat-qa-open', '点検結果'],
      ['premium-export', 'cat-export', 'Excelを書き出す']
    ];
    pairs.forEach(function (pair) {
      var proxy = el(pair[0]);
      var original = el(pair[1]);
      if (!proxy || !original) return;
      proxy.disabled = !!original.disabled;
      proxy.hidden = !!original.hidden;
      if (pair[0] === 'premium-export') {
        var originalText = textOf(original);
        proxy.textContent = /Word/.test(originalText) ? 'Wordを書き出す' : /コピー/.test(originalText) ? '訳文をコピー' : 'Excelを書き出す';
      } else if (pair[0] === 'premium-translate') {
        var untranslatedCount = premiumModels().filter(function (model) { return !String(model.target || '').trim(); }).length;
        proxy.textContent = untranslatedCount > 0 ? '未訳' + untranslatedCount + '件を翻訳' : /未訳はありません/.test(textOf(original)) ? '翻訳済み' : pair[2];
      } else {
        var reviewCount = premiumModels().filter(function (model) { return !!model.target && (model.blocking || model.recommended); }).length;
        proxy.textContent = reviewCount > 0 ? '要確認 ' + reviewCount + '件' : '要確認なし';
        proxy.classList.toggle('cat-qa-has-blockers', original.classList.contains('cat-qa-has-blockers'));
      }
    });
  }

  function syncCatMode() {
    var workspace = el('cat-workspace');
    var isWorkspace = document.body.getAttribute('data-cat-view') === 'workspace' && workspace && !workspace.hidden;
    var isAlignmentWorkspace = isWorkspace && document.body.getAttribute('data-cat-source') === 'align';
    var workMode = (function () {
      try { return new URLSearchParams(window.location.search).get('view') === 'work'; }
      catch (_) { return premiumState.initialWorkMode; }
    })();
    var importMode = premiumState.initialImport && !isWorkspace && !workMode &&
      !!(el('cat-source-align') && !el('cat-source-align').hidden);
    var combinedStart = !isWorkspace && !workMode && !importMode;
    if (!isWorkspace) {
      cancelPremiumRowWait();
      closeTools();
    }
    document.body.classList.toggle('premium-mode-workspace', !!isWorkspace && !isAlignmentWorkspace);
    document.body.classList.toggle('premium-mode-align-workspace', !!isAlignmentWorkspace);
    document.body.classList.toggle('premium-mode-worklist', !isWorkspace && workMode);
    document.body.classList.toggle('premium-mode-combined-start', !!combinedStart);
    document.body.classList.remove('premium-mode-excel-start');
    document.body.classList.toggle('premium-mode-import', !!importMode);
    syncToolsExpanded();
    var start = el('premium-cat-start');
    var work = el('premium-work-list');
    if (start) start.hidden = !!isWorkspace || workMode || importMode;
    if (work) work.hidden = !!isWorkspace || !workMode || importMode;
    if (isWorkspace && !isAlignmentWorkspace) {
      setActiveNav('translate');
      setTopbar('Excelレイアウト翻訳', textOf(el('cat-toolbar-title')) || 'Excel翻訳', {
        'premium-translate': true, 'premium-qa': true, 'premium-tools': true, 'premium-export': true
      });
      document.title = 'Excel翻訳 - YakuLingo';
      ensureWorkspaceUi();
      setupTopActionProxies();
      window.setTimeout(refreshWorkspaceUi, 0);
    } else if (isAlignmentWorkspace) {
      removeExcelWorkspaceUi();
      setActiveNav('past');
      setTopbar('過去訳', '過去訳の対応確認', { 'premium-tools': true });
      document.title = '過去訳の対応確認 - YakuLingo';
    } else if (importMode) {
      setActiveNav('past');
      setTopbar('過去訳', '確認済みの対訳を再利用', {});
      document.title = '過去訳 - YakuLingo';
    } else if (workMode) {
      setActiveNav('work');
      setTopbar('作業一覧', '保存済みの作業', {});
      document.title = '作業一覧 - YakuLingo';
      renderWorkCards();
    } else if (combinedStart) {
      setActiveNav('translate');
      setTopbar('Excelレイアウト翻訳', 'Excelを翻訳', {});
      document.title = 'Excelを翻訳 - YakuLingo';
    }
  }
  function interceptCatStartNavigation(event) {
    if (event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.shiftKey || event.altKey || event.metaKey) return;
    var link = event.target.closest ? event.target.closest('[data-premium-nav]') : null;
    if (!link || document.body.getAttribute('data-cat-view') !== 'start') return;
    var target = link.getAttribute('target');
    if ((target && target !== '_self') || link.hasAttribute('download')) return;
    var key = link.getAttribute('data-premium-nav');
    if (key !== 'translate' && key !== 'work') return;
    if (!(window.YakuCat && typeof YakuCat.navigateStart === 'function')) return;
    if (YakuCat.navigateStart(key === 'work' ? 'work' : 'translate')) event.preventDefault();
  }
  function setupCat() {
    var shell = el('excel-app');
    if (!shell || document.body.hasAttribute(PREMIUM_FLAG)) return;
    document.body.setAttribute(PREMIUM_FLAG, '1');
    mountPremiumFrame(shell, 'translate', 'premium-cat');
    var picker = el('cat-picker');
    buildCatStart(picker);
    buildWorkList(picker);
    window.addEventListener('yaku-cat-recent', function (event) { adoptCatRecentSnapshot(event && event.detail); });
    adoptCatRecentSnapshot();
    setupTopActionProxies();

    document.addEventListener('click', interceptCatStartNavigation);
    document.addEventListener('click', function (event) {
      var row = event.target.closest('[data-premium-row]');
      if (row) { openPremiumRow(row.getAttribute('data-premium-row')); return; }
      if (document.body.classList.contains('premium-tools-open') && !event.target.closest('#cat-editor-toolbar,#premium-tools')) {
        closeTools();
      }
    });
    document.addEventListener('keydown', function (event) {
      if (event.key === 'Escape') {
        closeTools();
      }
    });
    window.addEventListener('pagehide', cancelPremiumRowWait);
    window.addEventListener('popstate', function () { cancelPremiumRowWait(); syncCatMode(); });
    window.addEventListener('yaku-cat-rows-rendered', function () { refreshWorkspaceUi(); });

    var refresh = debounce(function () { syncCatMode(); refreshWorkspaceUi(); renderWorkCards(); }, 90);
    /* Observe only legacy application nodes. Observing #cat-workspace also sees
       the premium summary/list mutations produced by refreshWorkspaceUi(),
       causing a self-sustaining redraw loop. */
    [el('cat-grid-body'), el('cat-editor-toolbar')].forEach(function (node) {
      if (node) new MutationObserver(refresh).observe(node, { childList: true, subtree: true, attributes: true, characterData: true });
    });
    var resumeList = el('cat-resume-list');
    if (resumeList) new MutationObserver(function () { window.setTimeout(adoptCatRecentSnapshot, 0); }).observe(resumeList, { childList: true, subtree: true });
    new MutationObserver(syncCatMode).observe(document.body, { attributes: true, attributeFilter: ['data-cat-view', 'data-cat-source'] });
    syncCatMode();
  }

  /* Quick translation ----------------------------------------------------- */
  function quickArchiveMarkup(source, translation) {
    return '<article class="premium-archived-turn"><div class="premium-user-bubble">' + escapeHtml(source) + '</div>' +
      '<div class="premium-answer-turn"><span class="premium-answer-avatar">Y</span><div><strong>' + escapeHtml(translation) + '</strong>' +
      '<button type="button" class="premium-result-link" data-premium-copy="' + escapeHtml(translation) + '">コピー</button></div></div></article>';
  }
  function currentQuickTranslation() {
    var main = one('#palette-result [data-yaku-main-text]');
    if (main) return textOf(main);
    var instant = one('#palette-tm-candidate .translation');
    return textOf(instant);
  }
  function archivePreviousQuick() {
    var history = el('premium-quick-history');
    var source = premiumState.lastQuickSource;
    var translation = currentQuickTranslation();
    if (!history || !source || !translation || source === premiumState.lastQuickArchived) return;
    history.insertAdjacentHTML('beforeend', quickArchiveMarkup(source, translation));
    premiumState.lastQuickArchived = source;
  }
  function applyQuickPreferences() {
    var result = el('palette-result');
    if (!result || !one('[data-yaku-main-card]', result) || one('.job-loading,.alert', result)) return;
    if (premiumState.quickTone === 'polite' && !premiumState.quickToneRequested && !premiumState.quickActionBusy) {
      var chip = one('#palette-chips [data-yaku-chip="revise"]');
      if (chip && !chip.disabled && !el('palette-chips').hidden) {
        premiumState.quickToneRequested = true;
        premiumState.quickActionBusy = true;
        window.setTimeout(function () { chip.click(); premiumState.quickActionBusy = false; }, 0);
        return;
      }
    }
    var kind = textOf(one('[data-yaku-main-kind]', result));
    var mainLooksBrief = /短|簡潔/.test(kind);
    var alternate = one('.result-alt[data-yaku-swap]', result);
    if (premiumState.quickLengthTouched && premiumState.quickLength === 'brief' && !mainLooksBrief && !premiumState.quickBriefApplied && alternate) {
      premiumState.quickBriefApplied = true;
      alternate.click();
      return;
    }
    if (premiumState.quickLengthTouched && premiumState.quickLength === 'full' && mainLooksBrief && alternate) {
      premiumState.quickBriefApplied = false;
      alternate.click();
    }
  }
  function resetQuickRequest(source) {
    archivePreviousQuick();
    premiumState.lastQuickSource = source;
    premiumState.quickToneRequested = false;
    premiumState.quickBriefApplied = false;
    premiumState.quickActionBusy = false;
    var current = el('premium-current-source');
    if (current) { current.textContent = source; current.hidden = !source; }
  }
  function buildQuickLayout(main) {
    if (!main || el('premium-quick-layout')) return;
    var form = el('palette-form');
    var result = el('palette-result');
    var instant = el('palette-instant');
    var chips = el('palette-chips');
    var directionNote = el('palette-direction');
    var footer = one('.palette-footer');
    var contextField = one('.palette-context-field');
    var fineprint = one('.palette-fineprint');

    var layout = create('div', 'premium-quick-layout');
    layout.id = 'premium-quick-layout';
    var chat = create('section', 'premium-quick-chat');
    chat.innerHTML = '<header class="premium-quick-head"><div><h1>チャット翻訳</h1><p>文章を貼ってすぐ訳します。用途に合う簡潔な訳を返します。</p></div>' +
      '<div class="premium-current-preset"><span id="premium-length-label">標準</span><i>×</i><span id="premium-tone-label">ビジネス</span></div></header>' +
      '<div class="premium-quick-thread"><div id="premium-quick-history"></div><div id="premium-current-source" class="premium-current-source" hidden></div>' +
      '<div id="premium-live-result" class="premium-live-result"></div></div><div id="premium-quick-composer" class="premium-quick-composer"></div>';
    var rail = create('aside', 'premium-quick-rail');
    rail.innerHTML = '<section><h2>よく使う入力</h2><p>押すと入力欄へ入ります。</p><div class="premium-quick-prompts">' +
      ['前期比で増加しました', '今後の成長に向けた取り組み', '製品の主な特長', 'グローバルな供給体制'].map(function (text) {
        return '<button type="button" data-premium-prompt="' + escapeHtml(text) + '">' + escapeHtml(text) + '</button>';
      }).join('') + '</div></section>' +
      '<section><h2>今回の設定</h2><div class="premium-setting-row"><span>翻訳方向</span><strong id="premium-quick-direction">自動判定</strong></div>' +
      '<div class="premium-setting-row"><span>長さ</span><strong id="premium-quick-length">標準</strong></div><div class="premium-setting-row"><span>文体</span><strong id="premium-quick-tone">ビジネス</strong></div><div id="premium-context-host"></div></section>' +
      '<section class="premium-quick-transfer"><h2>Excelで仕上げる</h2><p>この文をセル幅に合わせる作業へ引き継ぎます。</p><button id="premium-quick-handoff" type="button">Excel翻訳へ</button></section>';
    layout.appendChild(chat);
    layout.appendChild(rail);
    main.appendChild(layout);

    var live = el('premium-live-result');
    [fineprint, directionNote, instant, chips, result, footer].forEach(function (node) { if (node && live) live.appendChild(node); });
    var composer = el('premium-quick-composer');
    if (form && composer) { form.classList.add('premium-palette-form'); composer.appendChild(form); }
    if (contextField && el('premium-context-host')) el('premium-context-host').appendChild(contextField);

    var directionRow = one('.palette-direction-row', form);
    if (form && directionRow) {
      var toolbar = create('div', 'premium-compose-toolbar');
      toolbar.innerHTML = '<span class="premium-control-label">長さ</span><div id="premium-length-mode" class="premium-segmented"><button type="button" data-length="brief">簡潔</button><button type="button" class="is-active" data-length="full">標準</button></div>' +
        '<span class="premium-control-label">文体</span><div id="premium-tone-mode" class="premium-segmented"><button type="button" class="is-active" data-tone="business">ビジネス</button><button type="button" data-tone="polite">丁寧</button></div>' +
        '<span class="premium-compose-hint">Enterで送信・Shift+Enterで改行</span>';
      form.insertBefore(toolbar, directionRow);
    }
    var input = el('palette-input');
    if (input) { input.placeholder = '翻訳したい文を入力…'; input.rows = 3; }
    var handoff = el('palette-handoff');
    var handoffProxy = el('premium-quick-handoff');
    if (handoffProxy && handoff) {
      handoffProxy.disabled = handoff.disabled;
      handoffProxy.addEventListener('click', function () { if (!handoff.disabled) handoff.click(); });
      new MutationObserver(function () { handoffProxy.disabled = handoff.disabled; }).observe(handoff, { attributes: true });
    }
    all('[data-premium-prompt]').forEach(function (button) {
      button.addEventListener('click', function () {
        if (!input) return;
        input.value = button.getAttribute('data-premium-prompt') || '';
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.focus();
      });
    });
    all('[data-length]').forEach(function (button) {
      button.addEventListener('click', function () {
        premiumState.quickLength = button.getAttribute('data-length') || 'full';
        premiumState.quickLengthTouched = true;
        all('[data-length]').forEach(function (item) { item.classList.toggle('is-active', item === button); });
        var label = premiumState.quickLength === 'brief' ? '簡潔' : '標準';
        if (el('premium-length-label')) el('premium-length-label').textContent = label;
        if (el('premium-quick-length')) el('premium-quick-length').textContent = label;
        premiumState.quickBriefApplied = false;
        applyQuickPreferences();
      });
    });
    all('[data-tone]').forEach(function (button) {
      button.addEventListener('click', function () {
        premiumState.quickTone = button.getAttribute('data-tone') || 'business';
        all('[data-tone]').forEach(function (item) { item.classList.toggle('is-active', item === button); });
        var label = premiumState.quickTone === 'polite' ? '丁寧' : 'ビジネス';
        if (el('premium-tone-label')) el('premium-tone-label').textContent = label;
        if (el('premium-quick-tone')) el('premium-quick-tone').textContent = label;
      });
    });
    var direction = el('palette-direction-select');
    function updateDirectionLabel() {
      var label = !direction || !direction.value ? '自動判定' : direction.value === 'to_jp' ? '英語 → 日本語' : '日本語 → 英語';
      if (el('premium-quick-direction')) el('premium-quick-direction').textContent = label;
    }
    if (direction) direction.addEventListener('change', updateDirectionLabel);
    updateDirectionLabel();

    function captureRequest() {
      window.setTimeout(function () {
        var source = input ? String(input.value || '').trim() : '';
        if (source) resetQuickRequest(source);
      }, 0);
    }
    if (form) form.addEventListener('submit', function () {
      var source = input ? String(input.value || '').trim() : '';
      if (source) resetQuickRequest(source);
    }, true);
    if (input) {
      input.addEventListener('paste', captureRequest, true);
      input.addEventListener('input', function () { if (!input.value.trim() && el('premium-current-source')) el('premium-current-source').hidden = true; });
    }
    if (result) {
      new MutationObserver(function () {
        window.setTimeout(applyQuickPreferences, 0);
      }).observe(result, { childList: true, subtree: true, characterData: true });
    }
    document.addEventListener('click', function (event) {
      var copy = event.target.closest('[data-premium-copy]');
      if (copy && window.YakuCommon && YakuCommon.copyText) {
        YakuCommon.copyText(copy.getAttribute('data-premium-copy') || '').then(function () { showToast('訳文をコピーしました。'); });
      }
    });
  }
  function setupQuickTopbar() {
    setTopbar('チャット翻訳', '文章を貼ってすぐ訳す', { 'premium-new-chat': true });
    var button = el('premium-new-chat');
    if (button && button.getAttribute('data-bound') !== '1') {
      button.setAttribute('data-bound', '1');
      button.addEventListener('click', function () {
        archivePreviousQuick();
        document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }));
        premiumState.lastQuickSource = '';
        premiumState.lastQuickArchived = '';
        if (el('premium-current-source')) { el('premium-current-source').textContent = ''; el('premium-current-source').hidden = true; }
        if (el('premium-quick-history')) el('premium-quick-history').innerHTML = '';
        showToast('新しい会話を始めました。');
      });
    }
  }
  function setupPalette() {
    var shell = one('.palette-shell');
    if (!shell || document.body.hasAttribute(PREMIUM_FLAG)) return;
    document.body.setAttribute(PREMIUM_FLAG, '1');
    mountPremiumFrame(shell, 'quick', 'premium-palette');
    var main = one('.palette-main', shell);
    buildQuickLayout(main);
    setupQuickTopbar();
    setActiveNav('quick');
    document.title = 'チャット翻訳 - YakuLingo';
    fetchRecent();
  }

  onReady(function () {
    try {
      if (document.body.classList.contains('app-cat')) setupCat();
      else if (document.body.classList.contains('app-palette')) setupPalette();
    } catch (error) {
      /* Reveal the legacy route when a Premium enhancement cannot mount. */
      console.error('Premium UI setup failed', error);
    } finally {
      document.body.classList.remove('premium-booting');
    }
  });
})();
