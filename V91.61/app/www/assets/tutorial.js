(function () {
  'use strict';

  var currentStep = 0;
  var lastStep = 3;
  var applying = false;
  var steps = [];
  var progressText;
  var progressBar;
  var backButton;
  var nextButton;
  var skipButton;
  var homeLink;
  var form;
  var confirmButton;
  var responseBox;
  var startupInput;
  var desktopInput;

  function focusHeading(step) {
    var heading = step ? step.querySelector('h1') : null;
    if (heading) heading.focus();
  }

  function showStep(index, focus) {
    if (index < 0) index = 0;
    if (index > lastStep) index = lastStep;
    currentStep = index;
    steps.forEach(function (step, stepIndex) { step.hidden = stepIndex !== currentStep; });
    progressText.textContent = String(currentStep + 1) + ' / 4';
    progressBar.style.width = String((currentStep + 1) * 25) + '%';
    backButton.hidden = currentStep === 0 || applying;
    nextButton.hidden = currentStep === lastStep;
    skipButton.hidden = currentStep === lastStep;
    homeLink.hidden = true;
    if (focus) focusHeading(steps[currentStep]);
    if (currentStep === lastStep) window.location.hash = 'settings';
    else if (window.location.hash === '#settings') history.replaceState(null, '', window.location.pathname);
  }

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
      if (!data || data.available === false || data.tutorial_completed !== true) return;
      if (typeof data.startup_enabled === 'boolean') startupInput.checked = data.startup_enabled;
      if (typeof data.desktop_shortcut === 'boolean') desktopInput.checked = data.desktop_shortcut;
    }).catch(function () {
      // 初回は既定ONを表示する。読取失敗だけでは外部設定を変更しない。
    });
  }

  function applyPreferences(event) {
    event.preventDefault();
    if (applying) return;
    applying = true;
    confirmButton.disabled = true;
    confirmButton.textContent = '設定しています…';
    backButton.hidden = true;
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
      skipButton.hidden = true;
      homeLink.hidden = false;
      homeLink.focus();
    }).catch(function (error) {
      applying = false;
      confirmButton.disabled = false;
      confirmButton.textContent = 'この設定で始める';
      backButton.hidden = false;
      /* 設定に失敗しても翻訳は使える。ここで出口を隠すと、初回起動でアプリが
         詰んでしまう（同名のショートカットが既にある職場では実際に起きる）。 */
      setResponse(YakuCommon.plainError(error && error.message ? error.message : error)
        + ' 設定は変更できませんでしたが、翻訳はこのままお使いいただけます。', [], true);
      homeLink.hidden = false;
      responseBox.focus();
    });
  }

  function start() {
    steps = Array.prototype.slice.call(document.querySelectorAll('.tutorial-step'));
    progressText = document.getElementById('tutorial-progress-text');
    progressBar = document.getElementById('tutorial-progress-bar');
    backButton = document.getElementById('tutorial-back');
    nextButton = document.getElementById('tutorial-next');
    skipButton = document.getElementById('tutorial-skip');
    homeLink = document.getElementById('tutorial-home');
    form = document.getElementById('tutorial-preferences');
    confirmButton = document.getElementById('tutorial-confirm');
    responseBox = document.getElementById('tutorial-setting-response');
    startupInput = document.getElementById('startup-enabled');
    desktopInput = document.getElementById('desktop-shortcut');

    backButton.addEventListener('click', function () { showStep(currentStep - 1, true); });
    nextButton.addEventListener('click', function () { showStep(currentStep + 1, true); });
    skipButton.addEventListener('click', function () { showStep(lastStep, true); });
    form.addEventListener('submit', applyPreferences);

    loadPreferences();
    showStep(window.location.hash === '#settings' ? lastStep : 0, true);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
