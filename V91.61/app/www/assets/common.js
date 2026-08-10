(function () {
  'use strict';

  function meta(name) {
    var node = document.querySelector('meta[name="' + name + '"]');
    return node ? node.getAttribute('content') || '' : '';
  }

  var sessionToken = meta('yaku-session');
  var ready = false;
  var readyTimer = null;
  var readyListeners = [];
  var desktopPreferenceMessageQueue = Promise.resolve();

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

  function setStatus(label, klass) {
    var root = document.getElementById('copilot-status');
    if (!root) return;
    root.innerHTML = '<span class="status-dot ' + escapeHtml(klass || 'idle') + '"></span><span>' + escapeHtml(label || '') + '</span>';
  }

  function announceReady(data) {
    ready = !!(data && data.canTranslate);
    setStatus(data && data.label ? data.label : (ready ? '準備完了' : '準備中'), data && data.class ? data.class : (ready ? 'ok' : 'warn'));
    readyListeners.forEach(function (listener) { try { listener(ready, data || {}); } catch (_) {} });
  }

  function pollReady() {
    window.clearTimeout(readyTimer);
    json('/api/ready-state').then(function (data) {
      announceReady(data);
      readyTimer = window.setTimeout(pollReady, ready ? 5000 : 1500);
    }).catch(function () {
      ready = false;
      setStatus('接続を確認中', 'warn');
      readyTimer = window.setTimeout(pollReady, 2500);
    });
  }

  function onReady(listener) {
    readyListeners.push(listener);
    listener(ready, {});
  }

  function applyTextSize(large) {
    document.documentElement.setAttribute('data-yaku-text-size', large ? 'large' : 'normal');
    var button = document.getElementById('text-size-toggle');
    if (button) {
      button.setAttribute('aria-pressed', large ? 'true' : 'false');
      button.textContent = large ? '文字を標準に戻す' : '文字を大きく';
    }
    try { localStorage.setItem('yaku-text-size', large ? 'large' : 'normal'); } catch (_) {}
  }

  function bindTextSize() {
    var large = false;
    try { large = localStorage.getItem('yaku-text-size') === 'large'; } catch (_) {}
    applyTextSize(large);
    var button = document.getElementById('text-size-toggle');
    if (button) button.addEventListener('click', function () { applyTextSize(button.getAttribute('aria-pressed') !== 'true'); });
  }

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

  function notifyDesktopShell(type) {
    if (type !== 'desktop-preferences-changed' && type !== 'desktop-preferences-error') return;
    try {
      if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === 'function') {
        window.chrome.webview.postMessage({ type: type });
      }
    } catch (_) {}
  }

  function applyStartupPreferenceFromShell(enabled) {
    return json('/api/desktop/preferences').then(function (current) {
      if (!current || current.available === false || typeof current.desktop_shortcut !== 'boolean') {
        throw new Error('DESKTOP_PREFERENCES_UNAVAILABLE');
      }
      return post('/api/desktop/preferences', {
        startup_enabled: enabled,
        desktop_shortcut: current.desktop_shortcut
      });
    }).then(function (updated) {
      if (!updated || updated.available === false) throw new Error('DESKTOP_PREFERENCES_UPDATE_FAILED');
      notifyDesktopShell('desktop-preferences-changed');
    }).catch(function () {
      notifyDesktopShell('desktop-preferences-error');
    });
  }

  function bindDesktopShellMessages() {
    if (!(window.chrome && window.chrome.webview && typeof window.chrome.webview.addEventListener === 'function')) return;
    window.chrome.webview.addEventListener('message', function (event) {
      var data = event && event.data;
      if (!data || typeof data !== 'object' || Array.isArray(data)) return;
      var keys = Object.keys(data).sort().join(',');
      if (keys !== 'enabled,type' || data.type !== 'set-startup-enabled' || typeof data.enabled !== 'boolean') return;
      var enabled = data.enabled;
      desktopPreferenceMessageQueue = desktopPreferenceMessageQueue.then(function () {
        return applyStartupPreferenceFromShell(enabled);
      }, function () {
        return applyStartupPreferenceFromShell(enabled);
      });
    });
  }

  function start() {
    bindTextSize();
    pollReady();
  }

  bindDesktopShellMessages();

  window.YakuCommon = {
    request: request, json: json, post: post, postText: postText, upload: upload,
    escape: escapeHtml, plainError: plainError, focus: focusAndReveal,
    reducedMotion: reducedMotion, onReady: onReady, isReady: function () { return ready; },
    copyText: copyText, decodeBase64: decodeBase64, start: start,
    notifyDesktopShell: notifyDesktopShell,
    maxUploadBytes: Number(meta('yaku-file-max-bytes')) || 50 * 1024 * 1024
  };
})();
