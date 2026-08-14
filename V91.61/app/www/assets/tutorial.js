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
  var desktopInput;
  var replayLink;
  var homeLink;
  var firstRun = true;

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
      firstRun = data.tutorial_completed === false;
      if (replayLink) replayLink.hidden = firstRun;
      if (homeLink) homeLink.hidden = firstRun;
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
      startup_enabled: false,
      desktop_shortcut: !!desktopInput.checked
    }).then(function (data) {
      if (!data || data.available === false) throw new Error((data && data.message) || 'この環境では起動設定を変更できません。');
      desktopInput.checked = !!data.desktop_shortcut;
      YakuCommon.notifyDesktopShell('desktop-preferences-changed');
      setResponse(data.message || '起動とショートカットの設定を保存しました。', data.warnings || [], false);
      desktopInput.disabled = true;
      confirmButton.hidden = true;
      responseBox.focus();
      /* 初回の主ボタンは「始める」と書いてあるので、保存完了後は本物の翻訳画面へ
         進める。以前は同じ説明ページに残り、下端の「開始画面へ」をもう一度押さないと
         始められず、実画面上の案内も再生されなかった。再訪時の設定変更では勝手に
         画面を移動しない。 */
      if (firstRun) {
        setResponse('設定を保存しました。翻訳画面を開きます。', data.warnings || [], false);
        window.setTimeout(function () { window.location.assign('/cat?tour=1'); }, 450);
      }
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
    desktopInput = document.getElementById('desktop-shortcut');
    replayLink = document.getElementById('tutorial-replay');
    homeLink = document.getElementById('tutorial-home');
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
