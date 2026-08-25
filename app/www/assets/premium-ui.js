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
      '<nav class="translation-mode-nav" aria-label="翻訳モード">' +
      '<a href="/quick">テキスト翻訳</a><a href="/cat" aria-current="page">Excel翻訳</a></nav>' +
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
    var hosts = [el('premium-start-recent-list')].filter(Boolean);
    if (!hosts.length) return;
    if (premiumState.recentStatus === 'error') {
      hosts.forEach(function (host) { host.innerHTML = recentErrorMarkup(); bindRecentRetry(host); });
      return;
    }
    var rows = premiumState.recent.slice(0, 3);
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
    moveRowActions(); preparePremiumRowActions();
    var sx=el('premium-summary-export');if(sx&&sx.getAttribute('data-bound')!=='1'){sx.setAttribute('data-bound','1');sx.addEventListener('click',function(){var b=el('cat-export');if(b&&!b.disabled){b.click();return}var api=window.YakuCat;if(api&&typeof api.explainOutput==='function')api.explainOutput()})}
    var su=el('premium-summary-unresolved');if(su&&su.getAttribute('data-bound')!=='1'){su.setAttribute('data-bound','1');su.addEventListener('click',function(){premiumState.catFilterTouched=true;premiumState.catFilter='untranslated';renderFitRows();var pane=el('premium-cell-list-pane');if(pane)pane.scrollIntoView({block:'start'})})}
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
    var primaryNodes = nodes.filter(function (node) { return node.hasAttribute('data-cat-confirm') || node.hasAttribute('data-cat-unconfirm'); });
    var detailNodes = nodes.filter(function (node) { return primaryNodes.indexOf(node) < 0; });
    if(model&&!one('[data-premium-quick-handoff]',primary)){var q=create('button','secondary-button');q.type='button';q.setAttribute('data-premium-quick-handoff','1');q.textContent='文章翻訳で補う';q.addEventListener('click',function(){var x={index:model.index,source:model.source,location:model.location,cell:model.location,return_url:location.pathname+location.search};try{sessionStorage.setItem('yakuQuickHandoff',JSON.stringify(x))}catch(_){}location.assign('/quick?from=excel')});primary.appendChild(q)}
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
    var effective = target;
    var canonical = String(row.getAttribute('data-cat-canonical-translation') || '').trim(), reviewed = row.getAttribute('data-cat-confirmed') === '1', index = row.getAttribute('data-cat-row') || '', state = row.getAttribute('data-yaku-cat-state') || '';
    var warning = row.getAttribute('data-cat-qc-warning') === '1', saveFailed = row.classList.contains('cat-unsaved') || row.classList.contains('cat-dirty') || row.getAttribute('data-cat-save-failed') === '1', qcError = row.getAttribute('data-cat-blocking') === '1' && !!one('.premium-inline-findings,.cat-qc-findings', row);
    var blocking = row.getAttribute('data-cat-blocking') === '1' || !effective || saveFailed, stale = state === 'stale', recommended = !blocking && (row.getAttribute('data-cat-recommended') === '1' || warning || !reviewed);
    var reason = !effective ? '未翻訳' : saveFailed ? '保存失敗' : qcError ? '点検エラー' : stale ? '再点検' : warning ? '指摘あり' : !reviewed ? '未確認' : '確認済み';
    return { row: row, index: index, location: location, source: source, target: effective, canonical: canonical, reviewed: reviewed, warning: warning, blocking: blocking, saveFailed: saveFailed, qcError: qcError, stale: stale, recommended: recommended, reason: reason };
  }
  function fitRowStatus(model) {
    if (!model) return '';
    if (model.blocking) {
      /* 原文・訳文の「未翻訳」と、出力を止める理由を同じ短語で
         並べると、何を直すべきか分からない。空欄だけは状態を一段
         具体化し、他のブロッカーは既存の理由を保つ。 */
      return !String(model.target || '').trim() ? '未翻訳（出力を止めます）' : (model.reason || '要対応');
    }
    return model.reviewed ? '確認済み' : '未確認';
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
    var applied=models.filter(function(m){return!!m.target}).length;if(el('premium-applied-count'))el('premium-applied-count').textContent=applied+'件';if(el('premium-unresolved-count'))el('premium-unresolved-count').textContent=untranslated+'件';if(el('premium-conflict-count'))el('premium-conflict-count').textContent=counts.recommended+'件';if(el('premium-apply-context'))el('premium-apply-context').textContent=untranslated?'確定済み対訳がないセルは日本語のままです。必要なセルだけ文章翻訳で補えます。':'未訳はありません。要確認だけ確認してExcelを作れます。';var usb=el('premium-summary-unresolved');if(usb)usb.textContent='未訳・競合'+(untranslated+counts.recommended)+'件を見る';
    if (!premiumState.catFilterTouched) premiumState.catFilter = untranslated > 0 ? 'untranslated' : counts.recommended > 0 ? 'review' : 'all';
    var active = one('#cat-grid-body tr.is-active'); if (active) { var model = rowModel(active), cell = model.location.match(/(?:^|[,!\s])([A-Z]{1,3}\d+)$/i); if (el('premium-active-cell')) el('premium-active-cell').textContent = cell ? cell[1].toUpperCase() : ((Number(model.index) + 1) + '行目'); if (el('premium-active-location')) el('premium-active-location').textContent = model.location || '選択中のセル'; var stateBadge = el('premium-editor-risk'); if (stateBadge) { stateBadge.textContent = fitRowStatus(model); stateBadge.classList.toggle('is-fit', !model.blocking && model.reviewed); stateBadge.classList.toggle('is-risk', !!model.blocking); } }
    updatePremiumStageState(total, counts, reviewed, untranslated); preparePremiumRowActions(); renderFitRows(); syncTopActionStates(); consumeQuickReturn();
  }
  function consumeQuickReturn(){var r='';try{r=sessionStorage.getItem('yakuQuickReturn')||''}catch(_){}if(!r)return;var d;try{d=JSON.parse(r)}catch(_){try{sessionStorage.removeItem('yakuQuickReturn')}catch(__){}return}var row=one('#cat-grid-body [data-cat-row="'+String(d.index||'')+'"]'),i=row&&one('textarea[data-cat-input]',row);if(!i)return;i.value=String(d.translation||'');i.dispatchEvent(new Event('input',{bubbles:true}));i.dispatchEvent(new Event('change',{bubbles:true}));try{sessionStorage.removeItem('yakuQuickReturn')}catch(_){}showToast('文章翻訳の訳文をExcel作業へ戻しました。')}
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
    new MutationObserver(syncCatMode).observe(document.body, { attributes: true, attributeFilter: ['data-cat-view', 'data-cat-source'] });
    syncCatMode();
  }

  onReady(function () {
    try {
      if (document.body.classList.contains('app-cat')) setupCat();
    } catch (error) {
      /* Reveal the legacy route when a Premium enhancement cannot mount. */
      console.error('Premium UI setup failed', error);
    } finally {
      document.body.classList.remove('premium-booting');
    }
  });
})();
