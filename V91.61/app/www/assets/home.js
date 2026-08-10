(function () {
  'use strict';
  function start() {
    YakuCommon.start();
    var preferred = document.getElementById('open-quick');
    if (preferred) preferred.focus();
    var banner = document.getElementById('background-disabled-banner');
    YakuCommon.json('/api/desktop/preferences').then(function (data) {
      if (banner && data && data.available !== false && data.tutorial_completed === true && data.startup_enabled === false) banner.hidden = false;
    }).catch(function () {
      // 起動設定を取得できなくても、翻訳の開始画面はそのまま利用できる。
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
