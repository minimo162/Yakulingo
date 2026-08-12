(function () {
  'use strict';

  /* 2026-08-12: 4画面をめくらせる仕掛けを外した。初回の案内は本物の画面の上で
     行う（tour.js）。ここに残すのは、起動とショートカットの設定だけ。
     設定は「この設定で始める」を押したときにだけ保存する。押すまでパソコンの
     設定は変えない、という約束をコードでも守る。 */

  var applying = false;
  var form;
  var confirmButton;
  var responseBox;
  var startupInput;
  var desktopInput;

  function setResponse(message, warnings, isError) {
    responseBox.textContent = '';
    var main = document.createElement('p');
    main.textContent = message;
    responseBox.appendChild(main);
    (warnings || []).forEach(function (warning) {
      var item = document.createElement('p');
      item.textContent = String(warning);
      responseBox.appendChild(item);
    });
    responseBox.classList.toggle('is-error', !!isError);
    responseBox.hidden = false;
  }

  function loadPreferences() {
    YakuCommon.json('/api/desktop/preferences').then(function (data) {
      if (!data || data.available === false) return;
      if (typeof data.startup_enabled === 'boolean') startupInput.checked = data.startup_enabled;
      if (typeof data.desktop_shortcut === 'boolean') desktopInput.checked = data.desktop_shortcut;
    }).catch(function () {
      // 読取失敗だけでは外部設定を変更しない。既定の見た目のままにする。
    });
  }

  function applyPreferences(event) {
    event.preventDefault();
    if (applying) return;
    applying = true;
    confirmButton.disabled = true;
    confirmButton.textContent = '設定しています…';
    setResponse('設定を確認しています。', [], false);
    YakuCommon.post('/api/desktop/preferences', {
      startup_enabled: !!startupInput.checked,
      desktop_shortcut: !!desktopInput.checked
    }).then(function (data) {
      if (!data || data.available === false) throw new Error((data && data.message) || 'この環境では起動設定を変更できません。');
      startupInput.checked = !!data.startup_enabled;
      desktopInput.checked = !!data.desktop_shortcut;
      YakuCommon.notifyDesktopShell('desktop-preferences-changed');
      setResponse(data.message || '起動とショートカットの設定を保存しました。', data.warnings || [], false);
      startupInput.disabled = true;
      desktopInput.disabled = true;
      confirmButton.hidden = true;
      responseBox.focus();
    }).catch(function (error) {
      applying = false;
      confirmButton.disabled = false;
      confirmButton.textContent = 'この設定で始める';
      /* 設定に失敗しても翻訳は使える。ここで出口を塞ぐと詰んでしまう
         （同名のショートカットが既にある職場では実際に起きる）。 */
      setResponse(YakuCommon.plainError(error && error.message ? error.message : error)
        + ' 設定は変更できませんでしたが、翻訳はこのままお使いいただけます。', [], true);
      responseBox.focus();
    });
  }

  function start() {
    form = document.getElementById('tutorial-preferences');
    confirmButton = document.getElementById('tutorial-confirm');
    responseBox = document.getElementById('tutorial-setting-response');
    startupInput = document.getElementById('startup-enabled');
    desktopInput = document.getElementById('desktop-shortcut');
    if (!form) return;
    form.addEventListener('submit', applyPreferences);
    loadPreferences();
    if (window.location.hash === '#settings') {
      var heading = document.getElementById('tutorial-settings-title');
      if (heading) heading.scrollIntoView({ block: 'start' });
    }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
