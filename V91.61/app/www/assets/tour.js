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

  var steps = [
    {
      target: '#quick-input',
      title: '訳したい文章を貼り付けます',
      body: '',
      done: function (el) { return String(el.value || '').trim().length > 0; },
      events: ['input']
    },
    {
      target: '#quick-submit',
      title: 'ここを押すとCopilotへ送ります',
      /* 2026-08-13、利用者判断「保存しない約束は要らない」。押した先が確認画面に
         なったので、そこも言う。以前は「その場に訳案が出て、保存はしない」だった。 */
      body: '数値は送る前に伏せます。押すまでは送りません。押すと1行ずつ確認する画面に移り、保存されます。',
      done: function () { return false; },
      events: ['click']
    },
    {
      target: '#quick-promote',
      title: '保存すると、あとから続けられます',
      body: '1文ずつ確認して保存すると、次に開いたときに途中から進められます。',
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
