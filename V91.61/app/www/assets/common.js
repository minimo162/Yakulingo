(function () {
  'use strict';

  function ensureUiReviewStyles() {
    if (document.querySelector('link[data-yaku-ui-review]')) return;
    var link = document.createElement('link');
    link.rel = 'stylesheet';
    link.href = '/assets/ui-review.css?v=20260822a';
    link.setAttribute('data-yaku-ui-review', '');
    document.head.appendChild(link);
  }
  ensureUiReviewStyles();

  function meta(name) {
    var node = document.querySelector('meta[name="' + name + '"]');
    return node ? node.getAttribute('content') || '' : '';
  }

  var sessionToken = meta('yaku-session');
  var ready = false;
  var readyTimer = null;
  var readyListeners = [];
  var uiClientId = '';
  var uiPresenceTimer = null;

  try {
    uiClientId = sessionStorage.getItem('yaku-ui-client-id') || '';
    if (!/^[a-f0-9]{32}$/.test(uiClientId)) {
      var bytes = new Uint8Array(16);
      crypto.getRandomValues(bytes);
      uiClientId = Array.prototype.map.call(bytes, function (value) { return value.toString(16).padStart(2, '0'); }).join('');
      sessionStorage.setItem('yaku-ui-client-id', uiClientId);
    }
  } catch (_) {}

  function plainError(value) {
    var raw = String(value || '').trim();
    if (!raw) return '処理を完了できませんでした。';
    if (/^\s*</.test(raw)) {
      var box = document.createElement('div');
      box.innerHTML = raw;
      raw = (box.textContent || box.innerText || '').trim();
    }
    try {
      var parsed = JSON.parse(raw);
      if (parsed && parsed.error) return String(parsed.error);
    } catch (_) {}
    return raw.replace(/^\s*(Error|Exception)\s*:\s*/i, '').trim();
  }

  function request(url, options) {
    options = options || {};
    options.headers = options.headers || {};
    if (sessionToken) options.headers['X-Yaku-Session'] = sessionToken;
    return fetch(url, options).then(function (response) {
      if (response.ok) return response;
      return response.text().then(function (body) {
        var error = new Error(plainError(body) || ('HTTP ' + response.status));
        error.status = response.status;
        error.body = body;
        try { error.data = JSON.parse(body); } catch (_) {}
        throw error;
      });
    });
  }

  function json(url, options) {
    return request(url, options).then(function (response) { return response.json(); });
  }

  function post(url, body) {
    return json(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
  }

  function postText(url, body) {
    return request(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    }).then(function (response) { return response.text(); });
  }

  function upload(url, file) {
    return request(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream', 'X-Yaku-File-Name': encodeURIComponent(file.name || 'upload.bin') },
      body: file
    }).then(function (response) { return response.json(); });
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (ch) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[ch];
    });
  }

  function reducedMotion() {
    return !!(window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  function focusAndReveal(node) {
    if (!node) return;
    node.focus();
    node.scrollIntoView({ behavior: reducedMotion() ? 'auto' : 'smooth', block: 'center' });
  }

  /* detail には「EdgeのCopilot画面でログインが済んでいるかご確認ください」のような
     利用者が実際に取るべき行動が入っている。label だけ出していたので一度も見えていなかった。
     ただし準備完了時の detail はURLなので出さない。 */
  function setStatus(label, klass, detail) {
    var root = document.getElementById('copilot-status');
    if (!root) return;
    var html = '<span class="status-dot ' + escapeHtml(klass || 'idle') + '"></span><span>' + escapeHtml(label || '') + '</span>';
    root.innerHTML = html;
    var hint = document.getElementById('copilot-status-detail');
    if (hint) {
      hint.textContent = detail || '';
      hint.hidden = !detail;
    }
  }

  function readableDetail(data) {
    if (!data || data.canTranslate) return '';
    var detail = String(data.detail || '').trim();
    if (!detail) return '';
    /* 英語のまま、あるいはURLや内部の記録は出さない。 */
    if (/^https?:/i.test(detail)) return '';
    if (!/[ぁ-んァ-ヶ一-龥]/.test(detail)) return '';
    return detail;
  }

  /* 準備完了時に1回だけ外枠へ知らせる。専用Edgeは通常時には完全非表示だが、
     起動直後に利用者が別のアプリへ移っている場合もあるので、窓を奪わない条件は残す。 */
  var readyAnnounced = false;
  var startedAt = Date.now();

  /* 「Copilotの準備をやり直す」は、放っておいても直らないと分かっている
     状態でだけ出す。timeout=15分待っても終わらない、error=起動に失敗、
     stale=心拍が60秒止まった、not-started=まだ一度も準備が始まっていない、
     not-ready=Watch-YakuCopilotReadinessがCDP連続失敗で降格した状態
     （D2-2）。not-ready の detail は「『Copilotの準備をやり直す』を押して
     ください」と明示に案内するのに、以前はボタン表示条件に入っておらず、
     しかも心拍自体は生きているので updated_at が新鮮で stale にも落ちず、
     ボタンが永久に出なかった（R3-1）。
     login・loading・busy・working はいずれ自然に進むか、別の案内（サインイン等）
     が既に detail に出ているので、ここには含めない。 */
  var RETRY_MODES = { timeout: true, error: true, stale: true, 'not-started': true, 'not-ready': true };

  function updatePrepareRetryButton(data) {
    var button = document.getElementById('copilot-prepare-retry');
    if (!button) return;
    var mode = data && data.mode ? String(data.mode) : '';
    var show = !!RETRY_MODES[mode];
    button.hidden = !show;
    /* R2-2: 以前はここで「Copilot画面を開く」を隠していた（排他表示）。詰まって
       いる場面ほど利用者に残る操作が0になっていたため、押せる操作が消える
       排他表示はやめる。折り返し対策はラベルを短くする側で行う
       （「Copilotの準備をやり直す」→「準備し直す」）。 */
    if (!show) return;
    if (button.dataset.busy === '1') return;
    button.disabled = false;
    button.textContent = '準備し直す';
  }

  function announceReady(data) {
    ready = !!(data && data.canTranslate);
    if (ready && !readyAnnounced) {
      readyAnnounced = true;
    }
    setStatus(data && data.label ? data.label : (ready ? 'Copilot：準備完了' : '準備しています'), data && data.class ? data.class : (ready ? 'ok' : 'warn'), readableDetail(data));
    updatePrepareRetryButton(data);
    readyListeners.forEach(function (listener) { try { listener(ready, data || {}); } catch (_) {} });
  }

  function pollReady() {
    window.clearTimeout(readyTimer);
    json('/api/ready-state').then(function (data) {
      announceReady(data);
      readyTimer = window.setTimeout(pollReady, ready ? 5000 : 1500);
    }).catch(function () {
      ready = false;
      setStatus('つながるのを待っています', 'warn', '');
      readyTimer = window.setTimeout(pollReady, 2500);
    });
  }

  function onReady(listener) {
    readyListeners.push(listener);
    listener(ready, {});
  }

  /* 独自の「文字を大きく」は廃止した（2026-08-11）。本文は既に 17px、原文と訳文は
     19.04px で、市販CATの編集画面（MateCat 18px）より大きい。拡大したいときは
     Edge の Ctrl+スクロールが使える。独自に持つと、器の高さが変わるたびに
     ツールバーが3段になる・絞り込みが枠に切られる、といった破綻を各画面で
     個別に面倒みることになり、実際に何度も壊した。 */

  function copyText(text, target, status) {
    function fallback() {
      if (target) { target.hidden = false; target.value = text; focusAndReveal(target); target.select(); }
      if (status) status.textContent = 'コピーできませんでした。全文を選択したので、Ctrl+Cでコピーしてください。';
      return false;
    }
    if (!(navigator.clipboard && navigator.clipboard.writeText)) return Promise.resolve(fallback());
    return navigator.clipboard.writeText(text).then(function () {
      if (status) status.textContent = 'コピーしました。';
      return true;
    }, fallback);
  }

  function decodeBase64(value) {
    var binary = atob(value || '');
    var bytes = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return new TextDecoder('utf-8').decode(bytes);
  }

  function bindCopilotWindowButton() {
    var button = document.getElementById('copilot-window-open');
    if (!button) return;
    button.addEventListener('click', function () {
      if (button.disabled) return;
      button.disabled = true;
      button.textContent = '開いています…';
      post('/api/copilot/window', { action: 'show' }).catch(function (error) {
        setStatus('Copilot画面を開けませんでした', 'warn', plainError(error && error.message ? error.message : error));
      }).then(function () {
        button.disabled = false;
        button.textContent = 'Copilot画面を開く';
      });
    });
  }

  function bindCopilotPrepareRetryButton() {
    var button = document.getElementById('copilot-prepare-retry');
    if (!button) return;
    button.addEventListener('click', function () {
      if (button.disabled) return;
      button.disabled = true;
      button.dataset.busy = '1';
      button.textContent = 'やり直し中…';
      post('/api/copilot/prepare', {}).catch(function (error) {
        setStatus('準備をやり直せませんでした', 'warn', plainError(error && error.message ? error.message : error));
      }).then(function () {
        button.dataset.busy = '0';
        button.disabled = false;
        button.textContent = '準備し直す';
        /* すぐにポーリングを1回走らせる。次の /api/ready-state で mode が
           変われば updatePrepareRetryButton が自動でボタンを隠す。 */
        pollReady();
      });
    });
  }

  function reportUiPresence(state, keepalive) {
    if (!uiClientId) return Promise.resolve();
    return request('/api/ui/presence', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ client_id: uiClientId, state: state }),
      keepalive: !!keepalive
    }).catch(function () {});
  }

  function startUiPresence() {
    reportUiPresence('open', false);
    window.clearInterval(uiPresenceTimer);
    uiPresenceTimer = window.setInterval(function () { reportUiPresence('open', false); }, 15000);
  }

  /* 画面を一つにしたので、同じページで cat.js と quick.js の両方が start() を
     呼ぶ。2回呼んで問い合わせを二重に流さない。 */
  var started = false;
  function start() {
    if (started) return;
    started = true;
    pollReady();
  }

  function translationIsRunning() {
    try {
      return !!((window.YakuInstant && window.YakuInstant.isBusy && window.YakuInstant.isBusy()) ||
        (window.YakuCat && window.YakuCat.isBusy && window.YakuCat.isBusy()));
    } catch (_) { return false; }
  }

  /* YakuLingoタブの×はYakuLingo全体の終了操作になる。通常時は確認を出さず、
     Copilotとの往復やファイル書き出しの途中だけブラウザー標準の確認を出す。 */
  window.addEventListener('beforeunload', function (event) {
    if (!translationIsRunning()) return;
    event.preventDefault();
    event.returnValue = '';
  });
  window.addEventListener('pagehide', function () {
    window.clearInterval(uiPresenceTimer);
    reportUiPresence('closing', true);
  });

  bindCopilotWindowButton();
  bindCopilotPrepareRetryButton();
  startUiPresence();

  window.YakuCommon = {
    request: request, json: json, post: post, postText: postText, upload: upload,
    escape: escapeHtml, plainError: plainError, focus: focusAndReveal,
    reducedMotion: reducedMotion, onReady: onReady, isReady: function () { return ready; },
    copyText: copyText, decodeBase64: decodeBase64, start: start,
    clientId: function () { return uiClientId; },
    translationIsRunning: translationIsRunning,
    maxUploadBytes: Number(meta('yaku-file-max-bytes')) || 50 * 1024 * 1024
  };
})();
