(function () {
  'use strict';

  /* 初回の案内。文章を読ませる4画面をやめ、本物の画面の上で3か所だけ吹き出しを
     出す（2026-08-12）。

     根拠は Nielsen Norman Group「Onboarding Tutorials vs. Contextual Help」。
     前置きの説明は読み飛ばされ、作業の成績も上がらず、文脈から離れた説明は
     必要なときに思い出せない。代わりに勧められているのが、必要な瞬間に、
     その操作のそばで出す助け（コーチマーク）である。

     だからここは次の3つを守る。
       - 「次へ」で読み進めさせない。実際の操作（入力する・押す）で進む
       - 一度に1つだけ。覚えさせない
       - いつでも閉じられる。閉じても翻訳はそのまま続けられる
     当たり前の操作（貼り付け・入力）は説明しない。説明するのは、押すと外部へ
     送られること、あとから開ける保存があること、の2つだけにする。 */

  /* 1つ目に「訳したい文章を貼り付けます」（本文なし）を出していたが、2026-08-13 に
     外した。理由は2つ。画面の見出しが同じ言葉で同じことを言っており、上に書いた
     「当たり前の操作は説明しない」に自分で反していた。もう1つは実害で、この吹き出しが
     すぐ下の1行を覆っていた（実測 1240x860: 吹き出し x153-402/y320-419、
     隠れた行「1行ずつ確認する画面に移ります。保存されるので、あとから続けられます。」は
     x153-846/y376-400）。押すと何が起きるかを書いた、いちばん読ませたい1行だった。 */
  var steps = [
    /* 1つ目は #quick-promote（訳案カードの「1文ずつ確認して保存する」）を指していた。
       2026-08-13 にそのカードごと外したので、指す先が無くなった。代わりに資料の
       入口を指す。起動して最初に出るのが貼り付け欄なので、「文章を貼るアプリ」だと
       思われたまま資料を取り込む道に気づかれない、という懸念に答える場所でもある。

       画面の上から順なら「送る」が先だが、送ると確認画面へ移ってしまい、そこで
       案内が途切れる（実機で確認: 3つ目を出す前にページごと入れ替わった）。
       だから資料の入口を先に置き、最後を「送る」にする。押した時点で案内は
       終わったことにする（下の finish-on-submit）。 */
    {
      target: '#cat-open-file-entry',
      title: 'Word・Excel は丸ごと取り込めます',
      body: '原本はそのままで、訳文を入れたコピーを作ります。貼り付けた文章と同じ画面で、1行ずつ確認します。',
      done: function () { return false; },
      events: ['click']
    },
    {
      target: '#quick-submit',
      title: 'ここを押すとCopilotへ送ります',
      /* 2026-08-13、利用者判断「保存しない約束は要らない」。押した先が確認画面に
         なったので、そこも言う。以前は「その場に訳案が出て、保存はしない」だった。 */
      body: '数値は送る前に伏せます。押すまでは送りません。押すと1行ずつ確認する画面に移り、保存されます。',
      done: function () { return false; },
      events: ['click']
    }
  ];

  var index = -1;
  var overlay = null;
  var callout = null;
  var cleanup = null;

  function el(id) { return document.getElementById(id); }
  function active() { return steps[index]; }

  function finish(reason) {
    detach();
    if (overlay) { overlay.remove(); overlay = null; }
    if (callout) { callout.remove(); callout = null; }
    index = -1;
    /* 終わったこと（飛ばしたことも含む）だけを記録する。起動設定には触らない。 */
    try {
      YakuCommon.post('/api/desktop/tour-complete', {}).catch(function () {});
    } catch (_) {}
    if (reason === 'done') {
      var status = el('cat-status');
      if (status) status.textContent = '案内はここまでです。使い方は右上の「使い方を見る」からもう一度見られます。';
    }
  }

  function detach() {
    if (cleanup) { cleanup(); cleanup = null; }
  }

  function place() {
    var step = active();
    if (!step) return;
    var target = document.querySelector(step.target);
    if (!target) { next(); return; }
    var r = target.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) { next(); return; }
    var pad = 6;
    overlay.style.top = (r.top - pad) + 'px';
    overlay.style.left = (r.left - pad) + 'px';
    overlay.style.width = (r.width + pad * 2) + 'px';
    overlay.style.height = (r.height + pad * 2) + 'px';
    /* 吹き出しは対象の下。下に入らないときだけ上へ回す。 */
    var below = r.bottom + 12;
    var calloutHeight = callout.getBoundingClientRect().height || 90;
    if (below + calloutHeight > window.innerHeight) below = Math.max(12, r.top - calloutHeight - 12);
    callout.style.top = below + 'px';
    callout.style.left = Math.max(12, Math.min(r.left, window.innerWidth - callout.getBoundingClientRect().width - 12)) + 'px';
  }

  function show() {
    var step = active();
    if (!step) { finish('done'); return; }
    var target = document.querySelector(step.target);
    if (!target) { next(); return; }
    /* 対象が画面の外に居たら、先に見える所へ持ってくる。place() は位置を計算する
       だけで動かさないので、前の段の操作で画面が動いていると、見えないボタンを
       指した吹き出しが画面の端で切れたまま残っていた（2026-08-13 実測、
       1240x860: 資料の入口を押すと画面が 560px 下がり、送るボタンは上へ外れ、
       吹き出しは上端で切れていた）。既に見えているときは動かさない。 */
    var box = target.getBoundingClientRect();
    if (box.top < 12 || box.bottom > window.innerHeight - 12) {
      try { target.scrollIntoView({ behavior: 'auto', block: 'center' }); } catch (_) { target.scrollIntoView(); }
    }
    callout.innerHTML = '';
    var title = document.createElement('p');
    title.className = 'yaku-tour-title';
    title.textContent = step.title;
    callout.appendChild(title);
    if (step.body) {
      var body = document.createElement('p');
      body.className = 'yaku-tour-body';
      body.textContent = step.body;
      callout.appendChild(body);
    }
    var skip = document.createElement('button');
    skip.type = 'button';
    skip.className = 'yaku-tour-skip';
    skip.textContent = '案内を閉じる';
    skip.addEventListener('click', function () { finish('skipped'); });
    callout.appendChild(skip);
    place();

    detach();
    var handler = function () {
      if (step.done(target)) { next(); }
      else if (step.events.indexOf('click') >= 0) { next(); }
    };
    step.events.forEach(function (name) { target.addEventListener(name, handler); });
    var onMove = function () { place(); };
    window.addEventListener('resize', onMove);
    window.addEventListener('scroll', onMove, true);
    cleanup = function () {
      step.events.forEach(function (name) { target.removeEventListener(name, handler); });
      window.removeEventListener('resize', onMove);
      window.removeEventListener('scroll', onMove, true);
    };
  }

  function next() {
    detach();
    index++;
    if (index >= steps.length) { finish('done'); return; }
    /* 3つ目は訳案が出るまで置き場が無い。出るまで待って続きを出す。 */
    var step = active();
    var target = document.querySelector(step.target);
    if (!target || target.getBoundingClientRect().width === 0) {
      var waiting = window.setInterval(function () {
        var later = document.querySelector(step.target);
        if (later && later.getBoundingClientRect().width > 0) { window.clearInterval(waiting); show(); }
      }, 400);
      window.setTimeout(function () { window.clearInterval(waiting); }, 600000);
      return;
    }
    show();
  }

  function start() {
    if (overlay) return;
    overlay = document.createElement('div');
    overlay.className = 'yaku-tour-spotlight';
    overlay.setAttribute('aria-hidden', 'true');
    callout = document.createElement('div');
    callout.className = 'yaku-tour-callout';
    callout.setAttribute('role', 'status');
    document.body.appendChild(overlay);
    document.body.appendChild(callout);
    /* 送ったら、どの段に居ても案内は終わり。送ると確認画面へ移るので、続きを
       出す場所が無くなる。ここで終わりを記録しないと、次に起動したときにまた
       最初から出る（実機で確認: 2つ目を押した時点でページごと入れ替わり、
       /api/desktop/tour-complete は一度も飛ばなかった）。 */
    var form = document.getElementById('quick-form');
    if (form) form.addEventListener('submit', function () { if (index >= 0) finish('done'); }, { once: true });
    index = -1;
    next();
  }

  function wanted() {
    var meta = document.querySelector('meta[name="yaku-tour"]');
    if (meta && String(meta.getAttribute('content') || '') === '1') return true;
    return new URLSearchParams(window.location.search).get('tour') === '1';
  }

  function boot() {
    if (!wanted()) return;
    /* 貼り付け欄が出てから始める。 */
    if (document.getElementById('quick-input')) { start(); return; }
    window.setTimeout(boot, 300);
  }

  window.YakuTour = { start: start };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
