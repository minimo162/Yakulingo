(function () {
  'use strict';
  function start() {
    YakuCommon.start();
    var preferred = document.getElementById('open-quick');
    if (preferred) preferred.focus();
    /* 「次回からすぐ使う設定がオフです」の帯は外した（2026-08-12）。
       自動起動を既定オフにしたので、オフは想定どおりの状態であって、
       毎回知らせる不具合ではない。入れたい人は「起動とショートカット」から入れる。 */
    loadResume();
  }

  /* 途中の資料があるなら、開始画面から1回で戻れるようにする。
     これが無いと「資料翻訳」→一覧→該当カードで毎回2回押すことになる。 */
  function loadResume() {
    var box = document.getElementById('home-resume');
    var list = document.getElementById('home-resume-list');
    if (!box || !list) return;
    YakuCommon.post('/api/cat/recent', {}).then(function (data) {
      /* 出すのは直近1件だけ。3件並べると「文字を大きく」したときに
         主要な2つの入口が画面外へ出る（1240x800で103px はみ出した）。
         残りは資料翻訳の一覧にそのまま並んでいる。 */
      var all = (data && data.projects ? data.projects : []);
      var items = all.slice(0, 1);
      if (!items.length) return;
      list.innerHTML = items.map(function (item) {
        var remaining = Math.max(0, Number(item.total) - Number(item.confirmed));
        return '<a class="home-resume-card" href="/cat?project=' + encodeURIComponent(item.id) + '">' +
          '<strong>' + YakuCommon.escape(item.file_name || '名称未設定の資料') + '</strong>' +
          '<span>' + (remaining ? 'あと ' + remaining + ' 行を確認します' : 'すべて確認済みです') + '</span>' +
          '<span class="home-resume-action">続きを開く</span></a>';
      }).join('');
      if (all.length > 1) {
        list.innerHTML += '<a class="home-resume-more" href="/cat">ほかに保存した作業が ' + (all.length - 1) + ' 件あります</a>';
      }
      box.hidden = false;
    }).catch(function () {
      // 続きが読めなくても、下の2つの入口はそのまま使える。
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
