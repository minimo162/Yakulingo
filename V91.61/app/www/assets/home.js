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
    loadResume();
  }

  /* 途中の資料があるなら、開始画面から1回で戻れるようにする。
     これが無いと「資料翻訳」→一覧→該当カードで毎回2回押すことになる。 */
  function loadResume() {
    var box = document.getElementById('home-resume');
    var list = document.getElementById('home-resume-list');
    if (!box || !list) return;
    YakuCommon.post('/api/cat/recent', {}).then(function (data) {
      var items = (data && data.projects ? data.projects : []).slice(0, 3);
      if (!items.length) return;
      list.innerHTML = items.map(function (item) {
        var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
        return '<a class="home-resume-card" href="/cat?project=' + encodeURIComponent(item.id) + '">' +
          '<strong>' + YakuCommon.escape(item.file_name || '名称未設定の資料') + '</strong>' +
          '<span>' + (remaining ? 'あと ' + remaining + ' 行を確認します' : 'すべて確認済みです') + '</span>' +
          '<span class="home-resume-action">続きを開く</span></a>';
      }).join('');
      box.hidden = false;
    }).catch(function () {
      // 続きが読めなくても、下の2つの入口はそのまま使える。
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
