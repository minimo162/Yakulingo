(function () {
  'use strict';

  var PREMIUM_FLAG = 'data-yaku-premium-ready';
  var premiumState = {
    recent: [],
    catFilter: 'issues',
    lastQuickSource: '',
    lastQuickArchived: '',
    quickLength: 'brief',
    quickTone: 'business',
    quickToneRequested: false,
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

  function logoMarkup() {
    return '<span class="premium-logo" aria-hidden="true">Y</span>' +
      '<span><strong>YakuLingo</strong><small>レイアウトを守る翻訳</small></span>';
  }
  function navMarkup(active) {
    var items = [
      { key: 'excel', href: '/cat', icon: 'XLS', title: 'Excel翻訳', note: 'セル幅に合わせる' },
      { key: 'quick', href: '/palette', icon: '↗', title: 'クイック翻訳', note: '1文ずつすぐに' },
      { key: 'past', href: '/cat?import=1', icon: '↔', title: '過去訳', note: '確認済みを再利用' },
      { key: 'work', href: '/cat?view=work', icon: '◴', title: '作業一覧', note: '保存済みの作業' }
    ];
    return items.map(function (item) {
      return '<a class="premium-nav-item' + (active === item.key ? ' is-active' : '') + '" href="' + item.href + '" data-premium-nav="' + item.key + '">' +
        '<span class="premium-nav-icon">' + item.icon + '</span><span><strong>' + item.title + '</strong><small>' + item.note + '</small></span></a>';
    }).join('');
  }
  function buildSidebar(active) {
    var sidebar = create('aside', 'premium-sidebar');
    sidebar.innerHTML =
      '<a class="premium-brand" href="/cat">' + logoMarkup() + '</a>' +
      '<p class="premium-nav-label">メニュー</p><nav class="premium-nav">' + navMarkup(active) + '</nav>' +
      '<div class="premium-sidebar-rule"></div>' +
      '<div class="premium-recent-heading"><span>最近の作業</span><span id="premium-recent-count">0件</span></div>' +
      '<div id="premium-sidebar-recent" class="premium-sidebar-recent"><p class="premium-sidebar-loading">読み込んでいます…</p></div>' +
      '<div class="premium-sidebar-bottom"><div id="premium-copilot-slot"></div></div>';
    return sidebar;
  }
  function buildTopbar() {
    var topbar = create('header', 'premium-topbar');
    topbar.innerHTML =
      '<div class="premium-topbar-left"><span id="premium-top-product" class="premium-top-product"></span><span class="premium-top-separator"></span>' +
      '<strong id="premium-top-context" class="premium-top-context"></strong></div>' +
      '<div class="premium-top-actions"><a href="/cat?view=work">作業一覧</a>' +
      '<button id="premium-translate" type="button" class="premium-top-action" hidden>未訳を翻訳</button>' +
      '<button id="premium-qa" type="button" class="premium-top-action" hidden>点検結果</button>' +
      '<button id="premium-tools" type="button" class="premium-top-text-button" hidden>詳細ツール</button>' +
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
    if (status) {
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
    var app = create('div', 'premium-app');
    var sidebar = buildSidebar(active);
    var main = create('div', 'premium-main');
    var topbar = buildTopbar();
    root.parentNode.insertBefore(app, root);
    app.appendChild(sidebar);
    app.appendChild(main);
    main.appendChild(topbar);
    main.appendChild(root);
    var legacyHero = one('.hero,.palette-header', root);
    if (legacyHero) legacyHero.classList.add('premium-legacy-hero');
    moveCopilotControls(sidebar);
    return { app: app, sidebar: sidebar, main: main, topbar: topbar };
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
  function fetchRecent() {
    if (!(window.YakuCommon && YakuCommon.post)) return Promise.resolve([]);
    return YakuCommon.post('/api/cat/recent', {}).then(function (data) {
      premiumState.recent = normalizeRecent(data);
      renderSidebarRecent();
      renderWorkCards();
      return premiumState.recent;
    }).catch(function () {
      premiumState.recent = [];
      renderSidebarRecent();
      renderWorkCards();
      return [];
    });
  }
  function recentMeta(item) {
    if (item.source === 'align') {
      return '過去訳の対応確認 ・ ' + (item.remaining ? 'あと' + item.remaining + '行' : '確認完了');
    }
    var direction = item.direction === 'to_jp' ? '英語 → 日本語' : '日本語 → 英語';
    return direction + ' ・ ' + (item.remaining ? 'あと' + item.remaining + '行' : '確認完了');
  }
  function renderSidebarRecent() {
    var host = el('premium-sidebar-recent');
    var count = el('premium-recent-count');
    if (!host) return;
    var rows = premiumState.recent.slice(0, 3);
    if (count) count.textContent = rows.length + '件';
    if (!rows.length) {
      host.innerHTML = '<p class="premium-sidebar-empty">保存済みの作業はまだありません。</p>';
      return;
    }
    host.innerHTML = rows.map(function (item) {
      return '<a class="premium-recent-item" href="/cat?project=' + encodeURIComponent(item.id) + '"><strong title="' + escapeHtml(item.fileName) + '">' +
        escapeHtml(item.fileName) + '</strong><span>' + escapeHtml(recentMeta(item)) + '</span><i><b style="width:' + item.percent + '%"></b></i></a>';
    }).join('');
  }

  /* Excel start and saved work ------------------------------------------- */
  function visualStepsMarkup() {
    return '<div class="premium-start-visual">' +
      '<div class="premium-visual-step"><span class="premium-step-number">1</span><strong>セル幅を読む</strong>' +
      '<div class="premium-mini-sheet"><span></span><span></span><span class="is-source">長期的な信頼性</span><span class="is-over">Long-Term Reliability…</span><span></span><span></span></div></div>' +
      '<span class="premium-flow-arrow">›</span>' +
      '<div class="premium-visual-step"><span class="premium-step-number">2</span><strong>意味を保って短く</strong>' +
      '<div class="premium-compare"><p class="is-long">Long-Term Reliability Assurance</p><p class="is-short">Long-Term Reliability</p></div></div>' +
      '<span class="premium-flow-arrow">›</span>' +
      '<div class="premium-visual-step is-result"><span class="premium-step-number">3</span><strong>収まる訳だけ反映</strong>' +
      '<div class="premium-result-cell"><span>✓ 収まりました</span><b>Long-Term Reliability</b><small>2px余り・基準訳は保持</small></div></div></div>';
  }
  function buildCatStart(picker) {
    if (!picker || el('premium-cat-start')) return;
    var start = create('section', 'premium-cat-start');
    start.id = 'premium-cat-start';
    start.innerHTML =
      '<header class="premium-start-heading"><div><span class="premium-eyebrow">Excelレイアウト翻訳</span><h1>セル幅に合わせて、短く正確に。</h1>' +
      '<p>Excelを読み込み、収まりにくいセルを仕上げます。以前に確認した日英PDFの訳も、過去訳として次の資料で再利用できます。</p></div></header>' +
      '<div class="premium-start-grid"><section class="premium-start-primary">' + visualStepsMarkup() +
      '<div id="premium-file-drop" class="premium-file-drop" role="group" aria-label="Excelファイルを選ぶ、またはドロップする">' +
      '<div class="premium-excel-mark">X</div><div class="premium-drop-copy"><strong>Excelをここに置く</strong>' +
      '<span>列幅・結合セル・右側の空きセルを読み取り、収まる長さで翻訳します。</span>' +
      '<div class="premium-drop-tags"><i>列幅を測定</i><i>短訳を生成</i><i>超過だけ確認</i></div></div>' +
      '<div class="premium-drop-actions"><button id="premium-file-select" type="button">Excelを選ぶ</button><small>.xlsx / .xlsm</small></div>' +
      '<input id="premium-file-input" type="file" accept=".xlsx,.xlsm" hidden></div></section>' +
      '<aside class="premium-start-aside"><section><h2>翻訳方向</h2><div id="premium-direction-switch" class="premium-direction-switch" role="group" aria-label="翻訳方向">' +
      '<button type="button" class="is-active" aria-pressed="true" data-direction="to_en">日本語 → 英語</button><button type="button" aria-pressed="false" data-direction="to_jp">英語 → 日本語</button></div></section>' +
      '<section><h2>確認済みの過去訳を再利用</h2><p>日本語PDFと英語PDFを突き合わせ、確認した訳を登録すると、次の作業の候補に出ます。</p><button id="premium-reference-open" type="button" class="premium-secondary-action">過去訳を登録</button></section>' +
      '<section><h2>読み込み後</h2><div class="premium-outcome-row"><span>収まり済み</span><i><b style="width:82%"></b></i><strong>優先表示</strong></div>' +
      '<div class="premium-outcome-row is-alert"><span>要調整</span><i><b style="width:20%"></b></i><strong>数セル</strong></div></section></aside></div>';
    picker.appendChild(start);

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
    var reference = el('premium-reference-open');
    if (reference) reference.addEventListener('click', function () {
      var original = el('cat-open-align-entry');
      if (original) original.click();
    });
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
      showToast('作業を削除しました。');
    }).catch(function (error) { showToast(error && error.message ? error.message : '削除できませんでした。', 'error'); });
  }

  /* Focused Excel work surface ------------------------------------------- */
  function ensureWorkspaceUi() {
    var workspace = el('cat-workspace');
    if (!workspace) return;
    if (!el('premium-work-summary')) {
      var summary = create('section', 'premium-work-summary');
      summary.id = 'premium-work-summary';
      summary.innerHTML = '<div class="premium-summary-title"><h1>セル幅に合わせて、短く正確に仕上げる</h1><p id="premium-summary-context"></p></div>' +
        '<div class="premium-summary-progress"><div><strong><span id="premium-fit-count">0</span> / <span id="premium-total-count">0</span>セルが収まりました</strong><span id="premium-fit-percent">0%</span></div><i><b id="premium-fit-progress"></b></i></div>' +
        '<div class="premium-summary-stats"><div class="is-done"><b id="premium-fit-done">0</b><span>収まり済み</span></div><div class="is-alert"><b id="premium-fit-left">0</b><span>要調整</span></div><div><b id="premium-untranslated">0</b><span>未翻訳</span></div></div>';
      workspace.insertBefore(summary, workspace.firstChild);
      ['cat-output-help', 'cat-output-reason', 'cat-export-blocked', 'cat-mask-notice'].forEach(function (id) {
        var node = el(id);
        if (node) summary.appendChild(node);
      });
    }
    if (!el('premium-fit-panel')) {
      var panel = create('aside', 'premium-fit-panel');
      panel.id = 'premium-fit-panel';
      panel.innerHTML = '<header><h2>セル一覧</h2><p>調整が必要なセルを優先</p></header><div id="premium-fit-filter" class="premium-fit-filter">' +
        '<button type="button" class="is-active" data-premium-filter="issues">要調整</button><button type="button" data-premium-filter="fit">収まり済み</button><button type="button" data-premium-filter="all">すべて</button></div>' +
        '<div id="premium-fit-list" class="premium-fit-list"></div>';
      var editorLayout = el('cat-editor-layout');
      workspace.insertBefore(panel, editorLayout || workspace.lastChild);
      all('[data-premium-filter]', panel).forEach(function (button) {
        button.addEventListener('click', function () {
          premiumState.catFilter = button.getAttribute('data-premium-filter') || 'issues';
          all('[data-premium-filter]', panel).forEach(function (item) { item.classList.toggle('is-active', item === button); });
          var originalKey = premiumState.catFilter === 'issues' ? 'fit' : 'all';
          var original = one('[data-cat-filter="' + originalKey + '"]');
          if (original) original.click();
          window.setTimeout(refreshWorkspaceUi, 80);
        });
      });
    }
    var editorPane = el('cat-editor-pane');
    var gridWrap = el('cat-grid-wrap');
    if (editorPane && gridWrap && !el('premium-editor-intro')) {
      var intro = create('div', 'premium-editor-intro');
      intro.id = 'premium-editor-intro';
      intro.innerHTML = '<div><span id="premium-active-cell">セル</span><strong id="premium-active-location"></strong></div><em id="premium-editor-risk" class="premium-editor-risk"></em>';
      editorPane.insertBefore(intro, gridWrap);
      var actions = create('div', 'premium-row-actions');
      actions.id = 'premium-row-actions';
      editorPane.insertBefore(actions, gridWrap);
    }
    moveRowActions();
    forcePreviewRail();
  }
  function removeExcelWorkspaceUi() {
    var workspace = el('cat-workspace');
    var editorLayout = el('cat-editor-layout');
    var summary = el('premium-work-summary');
    ['cat-output-help', 'cat-output-reason', 'cat-export-blocked', 'cat-mask-notice'].forEach(function (id) {
      var node = el(id);
      if (node && summary && summary.contains(node) && workspace) {
        workspace.insertBefore(node, editorLayout || workspace.firstChild);
      }
    });
    var actions = el('cat-segment-actions');
    var legacyActions = el('cat-actions');
    if (actions && legacyActions && actions.parentNode !== legacyActions) legacyActions.appendChild(actions);
    ['premium-work-summary', 'premium-fit-panel', 'premium-editor-intro', 'premium-row-actions'].forEach(function (id) {
      var node = el(id);
      if (node && node.parentNode) node.parentNode.removeChild(node);
    });
  }
  function moveRowActions() {
    var host = el('premium-row-actions');
    var actions = el('cat-segment-actions');
    if (host && actions && actions.parentNode !== host) host.appendChild(actions);
  }
  function forcePreviewRail() {
    var dock = el('cat-preview-dock');
    if (!dock) return;
    if (dock.hidden) {
      var toggle = el('cat-preview-dock-toggle');
      if (toggle) toggle.click();
    }
    var preview = one('[data-cat-inspector="preview"]');
    if (preview && preview.getAttribute('aria-selected') !== 'true') preview.click();
  }
  function rowModel(row) {
    var input = one('textarea[data-cat-input]', row);
    var location = textOf(one('.cat-location-main', row)) || textOf(one('.cat-col-loc', row));
    var source = textOf(one('.cat-source-text', row));
    var target = input ? String(input.value || '').trim() : '';
    var risk = !!one('.cat-fit-risk-badge,[data-cat-fit-candidates]', row);
    var reviewed = row.getAttribute('data-cat-confirmed') === '1';
    var index = row.getAttribute('data-cat-row') || '';
    var riskLabel = textOf(one('.cat-fit-risk-badge', row)) || (risk ? '要調整' : reviewed ? '確認済み' : '収まり済み');
    return { row: row, index: index, location: location, source: source, target: target, risk: risk, reviewed: reviewed, riskLabel: riskLabel };
  }
  function renderFitRows() {
    var host = el('premium-fit-list');
    if (!host) return;
    var models = all('#cat-grid-body [data-cat-row]').map(rowModel);
    var filtered = models.filter(function (model) {
      if (premiumState.catFilter === 'issues') return model.risk;
      if (premiumState.catFilter === 'fit') return !model.risk && !!model.target;
      return true;
    });
    if (!filtered.length) {
      var totalRiskNode = one('[data-cat-count="fit"]');
      var totalRisk = totalRiskNode ? Number(totalRiskNode.textContent || 0) : 0;
      host.innerHTML = '<div class="premium-fit-empty">' + (premiumState.catFilter === 'issues' && totalRisk ? '要調整セルを表示しています…' : '該当するセルはありません。') + '</div>';
      return;
    }
    host.innerHTML = filtered.map(function (model) {
      var width = model.risk ? 100 : 92;
      return '<button type="button" class="premium-fit-row' + (model.row.classList.contains('is-active') ? ' is-active' : '') + (model.risk ? ' is-risk' : '') + '" data-premium-row="' + escapeHtml(model.index) + '">' +
        '<span class="premium-fit-row-main"><small>' + escapeHtml(model.location) + '</small><strong>' + escapeHtml(model.source || '原文なし') + '</strong><em>' + escapeHtml(model.target || '未翻訳') + '</em></span>' +
        '<span class="premium-fit-row-state">' + escapeHtml(model.riskLabel) + '</span><i><b style="width:' + width + '%"></b></i></button>';
    }).join('');
  }
  function refreshWorkspaceUi() {
    if (!document.body.classList.contains('premium-mode-workspace')) return;
    ensureWorkspaceUi();
    moveRowActions();
    var totalNode = one('[data-cat-count="all"]');
    var riskNode = one('[data-cat-count="fit"]');
    var total = totalNode ? Number(totalNode.textContent || 0) : all('#cat-grid-body [data-cat-row]').length;
    var risk = riskNode ? Number(riskNode.textContent || 0) : all('#cat-grid-body .cat-fit-risk-badge').length;
    var untranslated = 0;
    all('#cat-grid-body textarea[data-cat-input]').forEach(function (input) { if (!String(input.value || '').trim()) untranslated++; });
    var fit = Math.max(0, total - risk - untranslated);
    var percent = total ? Math.round(100 * fit / total) : 0;
    if (el('premium-fit-count')) el('premium-fit-count').textContent = fit;
    if (el('premium-total-count')) el('premium-total-count').textContent = total;
    if (el('premium-fit-percent')) el('premium-fit-percent').textContent = percent + '%';
    if (el('premium-fit-progress')) el('premium-fit-progress').style.width = percent + '%';
    if (el('premium-fit-done')) el('premium-fit-done').textContent = fit;
    if (el('premium-fit-left')) el('premium-fit-left').textContent = risk;
    if (el('premium-untranslated')) el('premium-untranslated').textContent = untranslated;
    var title = textOf(el('cat-toolbar-title'));
    var direction = textOf(el('cat-toolbar-direction'));
    if (el('premium-summary-context')) el('premium-summary-context').textContent = [title, direction].filter(Boolean).join(' ・ ');
    var active = one('#cat-grid-body tr.is-active');
    if (active) {
      var model = rowModel(active);
      var cell = model.location.match(/(?:^|[,!\s])([A-Z]{1,3}\d+)$/i);
      if (el('premium-active-cell')) el('premium-active-cell').textContent = cell ? cell[1].toUpperCase() : ((Number(model.index) + 1) + '行目');
      if (el('premium-active-location')) el('premium-active-location').textContent = model.location || '選択中のセル';
      var riskBadge = el('premium-editor-risk');
      if (riskBadge) {
        riskBadge.textContent = model.risk ? '要調整' : '収まり済み';
        riskBadge.classList.toggle('is-fit', !model.risk);
      }
    }
    renderFitRows();
    syncTopActionStates();
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
        proxy.textContent = /未訳はありません/.test(textOf(original)) ? '翻訳済み' : pair[2];
      } else {
        proxy.textContent = textOf(original) || pair[2];
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
    if (!isWorkspace) {
      cancelPremiumRowWait();
      closeTools();
    }
    document.body.classList.toggle('premium-mode-workspace', !!isWorkspace && !isAlignmentWorkspace);
    document.body.classList.toggle('premium-mode-align-workspace', !!isAlignmentWorkspace);
    document.body.classList.toggle('premium-mode-worklist', !isWorkspace && workMode);
    document.body.classList.toggle('premium-mode-excel-start', !isWorkspace && !workMode && !importMode);
    document.body.classList.toggle('premium-mode-import', !!importMode);
    syncToolsExpanded();
    var start = el('premium-cat-start');
    var work = el('premium-work-list');
    if (start) start.hidden = !!isWorkspace || workMode || importMode;
    if (work) work.hidden = !!isWorkspace || !workMode || importMode;
    if (isWorkspace && !isAlignmentWorkspace) {
      setActiveNav('excel');
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
    } else {
      setActiveNav('excel');
      setTopbar('Excel翻訳', 'セル幅に合わせる', {});
      document.title = 'Excel翻訳 - YakuLingo';
    }
  }
  function setupCat() {
    var shell = one('main.shell');
    if (!shell || document.body.hasAttribute(PREMIUM_FLAG)) return;
    document.body.setAttribute(PREMIUM_FLAG, '1');
    mountPremiumFrame(shell, 'excel', 'premium-cat');
    var picker = el('cat-picker');
    buildCatStart(picker);
    buildWorkList(picker);
    fetchRecent();
    setupTopActionProxies();

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
    window.addEventListener('popstate', cancelPremiumRowWait);

    var refresh = debounce(function () { syncCatMode(); refreshWorkspaceUi(); renderWorkCards(); }, 90);
    /* Observe only legacy application nodes. Observing #cat-workspace also sees
       the premium summary/list mutations produced by refreshWorkspaceUi(),
       causing a self-sustaining redraw loop. */
    [el('cat-grid-body'), el('cat-editor-toolbar')].forEach(function (node) {
      if (node) new MutationObserver(refresh).observe(node, { childList: true, subtree: true, attributes: true, characterData: true });
    });
    var resumeList = el('cat-resume-list');
    if (resumeList) new MutationObserver(function () { window.setTimeout(fetchRecent, 70); }).observe(resumeList, { childList: true, subtree: true });
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
    if (premiumState.quickLength === 'brief' && !mainLooksBrief && !premiumState.quickBriefApplied && alternate) {
      premiumState.quickBriefApplied = true;
      alternate.click();
      return;
    }
    if (premiumState.quickLength === 'full' && mainLooksBrief && alternate) {
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
    chat.innerHTML = '<header class="premium-quick-head"><div><h1>クイック翻訳</h1><p>1文ずつ、用途に合う簡潔な訳を返します。</p></div>' +
      '<div class="premium-current-preset"><span id="premium-length-label">簡潔</span><i>×</i><span id="premium-tone-label">ビジネス</span></div></header>' +
      '<div class="premium-quick-thread"><div id="premium-quick-history"></div><div id="premium-current-source" class="premium-current-source" hidden></div>' +
      '<div id="premium-live-result" class="premium-live-result"></div></div><div id="premium-quick-composer" class="premium-quick-composer"></div>';
    var rail = create('aside', 'premium-quick-rail');
    rail.innerHTML = '<section><h2>よく使う入力</h2><p>押すと入力欄へ入ります。</p><div class="premium-quick-prompts">' +
      ['前期比で増加しました', '今後の成長に向けた取り組み', '製品の主な特長', 'グローバルな供給体制'].map(function (text) {
        return '<button type="button" data-premium-prompt="' + escapeHtml(text) + '">' + escapeHtml(text) + '</button>';
      }).join('') + '</div></section>' +
      '<section><h2>今回の設定</h2><div class="premium-setting-row"><span>翻訳方向</span><strong id="premium-quick-direction">自動判定</strong></div>' +
      '<div class="premium-setting-row"><span>長さ</span><strong id="premium-quick-length">簡潔</strong></div><div class="premium-setting-row"><span>文体</span><strong id="premium-quick-tone">ビジネス</strong></div><div id="premium-context-host"></div></section>' +
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
      toolbar.innerHTML = '<span class="premium-control-label">長さ</span><div id="premium-length-mode" class="premium-segmented"><button type="button" class="is-active" data-length="brief">簡潔</button><button type="button" data-length="full">標準</button></div>' +
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
        premiumState.quickLength = button.getAttribute('data-length') || 'brief';
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
    setTopbar('クイック翻訳', '1文ずつすぐに', { 'premium-new-chat': true });
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
    document.title = 'クイック翻訳 - YakuLingo';
    fetchRecent();
  }

  onReady(function () {
    if (document.body.classList.contains('app-cat')) setupCat();
    else if (document.body.classList.contains('app-palette')) setupPalette();
  });
})();
