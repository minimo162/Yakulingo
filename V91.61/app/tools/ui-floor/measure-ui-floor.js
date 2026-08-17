'use strict';
/*
 * measure-ui-floor.js -- 画面の「床」を機械で測る。
 *
 * 床は4つ。どれか1つでも割れたら赤にする。
 *   1. pageerror   : JS の未捕捉例外が 0 件
 *   2. contrast    : 文字が乗っている要素の前景/背景コントラストが 4.5:1 以上
 *   3. label       : ラベルが1行に収まる（折り返さない・切り取られない）
 *   4. overflow    : documentElement.scrollWidth <= clientWidth
 *
 * 実機の窓幅は約 1380px（CLAUDE.md）。既定を 1380x900 にしてあるのはそのため。
 * 1440px で測ると @media (max-width: 1400px) に当たらず、実機と違う結果になる。
 *
 * 使い方:
 *   node measure-ui-floor.js --url http://127.0.0.1:18790/ --out report.json
 *   node measure-ui-floor.js --url ... --inject contrast   (門が発火するかを見る)
 *
 * 終了コード: 0=違反なし / 2=違反あり / 1=装置自身の失敗
 */

const fs = require('fs');
const path = require('path');

// ---- playwright の在り処 -------------------------------------------------
// このリポジトリに node_modules は無い。実在する場所を順に試し、
// 見つからなければ「装置の失敗(1)」として、探した場所をすべて表示する。
function loadPlaywright() {
  const candidates = [];
  if (process.env.YAKULINGO_PLAYWRIGHT_DIR) candidates.push(process.env.YAKULINGO_PLAYWRIGHT_DIR);
  // __dirname から上へ順に見る。node_modules は自分のリポジトリの中とは限らない。
  let dir = __dirname;
  for (let depth = 0; depth < 8; depth++) {
    candidates.push(path.join(dir, 'node_modules'));
    const outputsRoot = path.join(dir, 'outputs');
    try {
      for (const entry of fs.readdirSync(outputsRoot)) {
        const child = path.join(outputsRoot, entry);
        try {
          for (const sub of fs.readdirSync(child)) {
            candidates.push(path.join(child, sub, 'node_modules'));
          }
        } catch (e) { /* not a directory */ }
      }
    } catch (e) { /* outputs may not exist here */ }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  const tried = [];
  for (const dir of candidates) {
    const target = path.join(dir, 'playwright');
    tried.push(target);
    try {
      if (fs.existsSync(target)) return require(target);
    } catch (e) { /* keep looking */ }
  }
  try { return require('playwright'); } catch (e) { /* fall through */ }
  const err = new Error('playwright が見つかりません。探した場所:\n' + tried.join('\n'));
  err.yakuToolFailure = true;
  throw err;
}

// ---- 引数 ---------------------------------------------------------------
function parseArgs(argv) {
  const out = {
    url: '',
    width: 1380,
    height: 900,
    out: '',
    fixture: '',
    inject: 'none',
    states: 'landing,workspace',
    screenshotDir: '',
    minContrast: 4.5,
    maxLabelChars: 40,
    timeout: 120000,
    dump: false,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith('--')) continue;
    const key = a.slice(2);
    const value = argv[i + 1];
    switch (key) {
      case 'url': out.url = value; i++; break;
      case 'width': out.width = parseInt(value, 10); i++; break;
      case 'height': out.height = parseInt(value, 10); i++; break;
      case 'out': out.out = value; i++; break;
      case 'fixture': out.fixture = value; i++; break;
      case 'inject': out.inject = value; i++; break;
      case 'states': out.states = value; i++; break;
      case 'screenshot-dir': out.screenshotDir = value; i++; break;
      case 'min-contrast': out.minContrast = parseFloat(value); i++; break;
      case 'max-label-chars': out.maxLabelChars = parseInt(value, 10); i++; break;
      case 'timeout': out.timeout = parseInt(value, 10); i++; break;
      case 'dump': out.dump = true; break;
      default: break;
    }
  }
  return out;
}

// ---- ページの中で走る測定本体 -------------------------------------------
// 注意: この関数は文字列としてブラウザへ渡される。外側の変数を参照しないこと。
function pageProbe(options) {
  const MIN_CONTRAST = options.minContrast;
  const MAX_LABEL_CHARS = options.maxLabelChars;

  // 色の正規化。oklch / color-mix / currentColor など、getComputedStyle が
  // 何を返しても canvas の fillStyle が sRGB へ畳んでくれる。自前の
  // パーサを書くと書式を1つ落とした瞬間に「黒地に黒」を見逃す。
  const cv = document.createElement('canvas');
  cv.width = 1; cv.height = 1;
  const cx = cv.getContext('2d');
  const colorCache = new Map();
  function toRGBA(str) {
    const s = String(str || '').trim();
    if (!s) return { r: 0, g: 0, b: 0, a: 0, unknown: true };
    if (colorCache.has(s)) return colorCache.get(s);
    let result;
    try {
      cx.fillStyle = '#010203';
      cx.fillStyle = s;
      const normalized = String(cx.fillStyle);
      if (normalized === '#010203' && s.replace(/\s/g, '').toLowerCase() !== '#010203') {
        result = { r: 0, g: 0, b: 0, a: 0, unknown: true };
      } else if (normalized.charAt(0) === '#') {
        result = {
          r: parseInt(normalized.substr(1, 2), 16),
          g: parseInt(normalized.substr(3, 2), 16),
          b: parseInt(normalized.substr(5, 2), 16),
          a: 1,
          unknown: false,
        };
      } else {
        const m = normalized.match(/rgba?\(([^)]+)\)/);
        if (!m) {
          result = { r: 0, g: 0, b: 0, a: 0, unknown: true };
        } else {
          const parts = m[1].split(',').map(function (x) { return parseFloat(x); });
          result = {
            r: parts[0], g: parts[1], b: parts[2],
            a: parts.length > 3 ? parts[3] : 1,
            unknown: false,
          };
        }
      }
    } catch (e) {
      result = { r: 0, g: 0, b: 0, a: 0, unknown: true };
    }
    colorCache.set(s, result);
    return result;
  }

  function over(top, bottom) {
    const a = top.a + bottom.a * (1 - top.a);
    if (a <= 0) return { r: 0, g: 0, b: 0, a: 0 };
    return {
      r: (top.r * top.a + bottom.r * bottom.a * (1 - top.a)) / a,
      g: (top.g * top.a + bottom.g * bottom.a * (1 - top.a)) / a,
      b: (top.b * top.a + bottom.b * bottom.a * (1 - top.a)) / a,
      a: a,
    };
  }

  function channel(v) {
    const c = v / 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  }
  function luminance(c) {
    return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
  }
  function contrast(fg, bg) {
    const l1 = luminance(fg);
    const l2 = luminance(bg);
    const hi = Math.max(l1, l2);
    const lo = Math.min(l1, l2);
    return (hi + 0.05) / (lo + 0.05);
  }

  function cssPath(el) {
    const parts = [];
    let node = el;
    while (node && node.nodeType === 1 && parts.length < 6) {
      let seg = node.tagName.toLowerCase();
      if (node.id) { seg += '#' + node.id; parts.unshift(seg); break; }
      const cls = String(node.getAttribute('class') || '').trim().split(/\s+/).filter(Boolean).slice(0, 2);
      if (cls.length) seg += '.' + cls.join('.');
      parts.unshift(seg);
      node = node.parentElement;
    }
    return parts.join(' > ');
  }

  // 背景は「実際に塗られている色」を祖先まで辿って合成する。
  // 途中に background-image があれば、その要素より下は当てにならないので
  // unknownImage を立てて別枠で報告する（勝手に白と決めない）。
  function resolveBackground(el) {
    const layers = [];
    let node = el;
    let imageAncestor = '';
    while (node) {
      const cs = getComputedStyle(node);
      const bg = toRGBA(cs.backgroundColor);
      const img = cs.backgroundImage;
      if (img && img !== 'none' && !imageAncestor) imageAncestor = cssPath(node);
      const nodeOpacity = parseFloat(cs.opacity);
      const eff = isNaN(nodeOpacity) ? 1 : nodeOpacity;
      if (bg.a > 0) layers.push({ r: bg.r, g: bg.g, b: bg.b, a: bg.a * eff });
      if (bg.a >= 1 && eff >= 1) break;
      node = node.parentElement;
    }
    let result = { r: 255, g: 255, b: 255, a: 1 };
    const canvasColor = toRGBA(getComputedStyle(document.documentElement).backgroundColor);
    if (canvasColor.a >= 1) result = { r: canvasColor.r, g: canvasColor.g, b: canvasColor.b, a: 1 };
    for (let i = layers.length - 1; i >= 0; i--) result = over(layers[i], result);
    return { color: result, imageAncestor: imageAncestor };
  }

  function cumulativeOpacity(el) {
    let node = el;
    let acc = 1;
    while (node) {
      const o = parseFloat(getComputedStyle(node).opacity);
      if (!isNaN(o)) acc *= o;
      node = node.parentElement;
    }
    return acc;
  }

  function isHiddenForA11y(el) {
    let node = el;
    while (node && node.nodeType === 1) {
      if (node.hasAttribute && node.hasAttribute('hidden')) return true;
      if (node.getAttribute && node.getAttribute('aria-hidden') === 'true') return true;
      node = node.parentElement;
    }
    return false;
  }

  function isScreenReaderOnly(el) {
    let node = el;
    while (node && node.nodeType === 1) {
      const cs = getComputedStyle(node);
      // sr-only の定番: 1x1 に潰して clip する
      if (cs.clip && cs.clip !== 'auto') return true;
      if (cs.clipPath && cs.clipPath !== 'none' && cs.clipPath.indexOf('inset(50%') === 0) return true;
      const r = node.getBoundingClientRect();
      if (r.width <= 1 && r.height <= 1) return true;
      node = node.parentElement;
    }
    return false;
  }

  function visible(el) {
    // 閉じた <details> の中身は、getBoundingClientRect も offsetParent も
    // 「見えている」と答える（実測: rect 124x24 / offsetParent 非 null）。
    // 頼れるのは checkVisibility だけ。これを入れる前は、閉じた
    // 「そのほかの操作」の中のボタンを折り返し違反として4件誤報していた。
    if (typeof el.checkVisibility === 'function') {
      const ok = el.checkVisibility({
        checkOpacity: true,
        checkVisibilityCSS: true,
        contentVisibilityAuto: true,
        opacityProperty: true,
        visibilityProperty: true,
      });
      if (!ok) return false;
    } else {
      const cs = getComputedStyle(el);
      if (cs.display === 'none' || cs.visibility === 'hidden' || cs.visibility === 'collapse') return false;
      if (cumulativeOpacity(el) <= 0.01) return false;
    }
    const r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    if (isHiddenForA11y(el)) return false;
    return true;
  }

  const SKIP_TAGS = { SCRIPT: 1, STYLE: 1, TITLE: 1, NOSCRIPT: 1, HEAD: 1, META: 1, LINK: 1, OPTION: 1, TEMPLATE: 1, BR: 1, HR: 1 };

  function ownText(el) {
    let text = '';
    for (const node of el.childNodes) {
      if (node.nodeType === 3) text += node.nodeValue;
    }
    return text.replace(/\s+/g, ' ').trim();
  }

  // ---- 1. コントラスト ---------------------------------------------------
  const contrastViolations = [];
  const contrastSkipped = [];
  const contrastAll = [];
  const textElements = [];
  let contrastChecked = 0;
  let worst = null;
  const all = document.querySelectorAll('*');
  for (const el of all) {
    if (SKIP_TAGS[el.tagName]) continue;
    const text = ownText(el);
    if (!text) continue;
    if (!visible(el)) continue;
    if (isScreenReaderOnly(el)) continue;
    textElements.push(el);
    const cs = getComputedStyle(el);
    const fgRaw = toRGBA(cs.color);
    if (fgRaw.unknown) { contrastSkipped.push({ selector: cssPath(el), reason: 'color-unresolved', value: cs.color }); continue; }
    const bg = resolveBackground(el);
    if (bg.imageAncestor) {
      contrastSkipped.push({ selector: cssPath(el), reason: 'background-image', at: bg.imageAncestor, text: text.slice(0, 40) });
      continue;
    }
    const fgAlpha = fgRaw.a * cumulativeOpacity(el);
    const fg = over({ r: fgRaw.r, g: fgRaw.g, b: fgRaw.b, a: fgAlpha }, bg.color);
    const ratio = contrast(fg, bg.color);
    contrastChecked++;
    const fontSize = parseFloat(cs.fontSize);
    const weight = parseInt(cs.fontWeight, 10) || 400;
    const large = fontSize >= 24 || (fontSize >= 18.66 && weight >= 700);
    const record = {
      selector: cssPath(el),
      text: text.slice(0, 60),
      ratio: Math.round(ratio * 100) / 100,
      color: cs.color,
      background: 'rgb(' + Math.round(bg.color.r) + ', ' + Math.round(bg.color.g) + ', ' + Math.round(bg.color.b) + ')',
      fontSizePx: Math.round(fontSize * 10) / 10,
      fontWeight: weight,
      largeText: large,
    };
    if (!worst || ratio < worst.ratio) worst = record;
    if (options.dump) contrastAll.push(record);
    if (ratio + 0.005 < MIN_CONTRAST) contrastViolations.push(record);
  }

  // 入力欄の文字と、薄くしがちな placeholder。text ノードとして取れないので
  // 別に測る。ここを外すと「原文・訳文を検索」「例:固定費」のような、
  // 画面に確かに見えている文字が1つも測られない。
  const FORM_SKIP_TYPE = { hidden: 1, file: 1, checkbox: 1, radio: 1, range: 1, color: 1, image: 1, submit: 1, button: 1, reset: 1 };
  for (const el of document.querySelectorAll('input, textarea, select')) {
    if (!visible(el)) continue;
    if (isScreenReaderOnly(el)) continue;
    const type = String(el.type || '').toLowerCase();
    if (FORM_SKIP_TYPE[type]) continue;
    const bg = resolveBackground(el);
    if (bg.imageAncestor) {
      contrastSkipped.push({ selector: cssPath(el), reason: 'background-image', at: bg.imageAncestor, text: '(form control)' });
      continue;
    }
    const opacity = cumulativeOpacity(el);
    const csEl = getComputedStyle(el);
    const probes = [];
    const value = String(el.value === undefined || el.value === null ? '' : el.value);
    if (el.tagName === 'SELECT' || value.length > 0) {
      probes.push({ kind: 'value', color: csEl.color, text: (value || String(el.tagName)).slice(0, 40) });
    }
    if (el.placeholder && value.length === 0) {
      let phColor = '';
      try { phColor = getComputedStyle(el, '::placeholder').color; } catch (e) { phColor = ''; }
      if (phColor) probes.push({ kind: 'placeholder', color: phColor, text: String(el.placeholder).slice(0, 40) });
    }
    for (const probe of probes) {
      const raw = toRGBA(probe.color);
      if (raw.unknown) { contrastSkipped.push({ selector: cssPath(el), reason: 'color-unresolved', value: probe.color }); continue; }
      const fgC = over({ r: raw.r, g: raw.g, b: raw.b, a: raw.a * opacity }, bg.color);
      const ratioC = contrast(fgC, bg.color);
      contrastChecked++;
      const rec = {
        selector: cssPath(el),
        text: probe.text,
        kind: probe.kind,
        ratio: Math.round(ratioC * 100) / 100,
        color: probe.color,
        background: 'rgb(' + Math.round(bg.color.r) + ', ' + Math.round(bg.color.g) + ', ' + Math.round(bg.color.b) + ')',
        fontSizePx: Math.round(parseFloat(csEl.fontSize) * 10) / 10,
        fontWeight: parseInt(csEl.fontWeight, 10) || 400,
        largeText: false,
      };
      if (!worst || ratioC < worst.ratio) worst = rec;
      if (options.dump) contrastAll.push(rec);
      if (ratioC + 0.005 < MIN_CONTRAST) contrastViolations.push(rec);
    }
  }

  // ---- 2. ラベルの折り返し / 切り取り ------------------------------------
  const LABEL_SELECTOR = [
    'nav a', 'nav button', 'button', 'summary', 'th', 'legend', 'label',
    '[role="tab"]', '[data-cat-filter]', '[data-cat-inspector]', '[data-cat-direction]',
    '.status', '.start-kind', '.version-label', '.brand', 'dt', '.chip', '.badge',
  ].join(', ');
  const labelViolations = [];
  let labelsChecked = 0;
  const labelSeen = new Set();
  for (const el of document.querySelectorAll(LABEL_SELECTOR)) {
    if (labelSeen.has(el)) continue;
    labelSeen.add(el);
    const text = (el.textContent || '').replace(/\s+/g, ' ').trim();
    if (!text || text.length > MAX_LABEL_CHARS) continue;
    if (!visible(el)) continue;
    if (isScreenReaderOnly(el)) continue;
    labelsChecked++;
    // 行数は「文字の描画矩形の縦の帯」を数える。padding や中の <span> に
    // 影響されない。件数バッジのように同じ行に別要素があっても1本に数える。
    const bands = [];
    let inlineWidth = 0;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    let node;
    while ((node = walker.nextNode())) {
      if (!String(node.nodeValue || '').trim()) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width <= 0 || rect.height <= 0) continue;
        inlineWidth += rect.width;
        const mid = rect.top + rect.height / 2;
        let found = false;
        for (const band of bands) {
          if (Math.abs(band - mid) < Math.max(4, rect.height * 0.6)) { found = true; break; }
        }
        if (!found) bands.push(mid);
      }
      range.detach && range.detach();
    }
    const rect = el.getBoundingClientRect();
    if (bands.length > 1) {
      // 「何px 足りないか」まで出す。幅を詰めた変更を戻すとき、これが無いと
      // また当て推量になる（CLAUDE.md「いちばん長いラベルの実測幅を出す」）。
      const cs2 = getComputedStyle(el);
      const padding = parseFloat(cs2.paddingLeft) + parseFloat(cs2.paddingRight)
        + parseFloat(cs2.borderLeftWidth) + parseFloat(cs2.borderRightWidth);
      labelViolations.push({
        selector: cssPath(el), text: text.slice(0, 60), reason: 'wrapped',
        lines: bands.length,
        widthPx: Math.round(rect.width),
        heightPx: Math.round(rect.height),
        textWidthPx: Math.round(inlineWidth),
        needWidthPx: Math.round(inlineWidth + padding),
      });
    }
  }

  // 切り取りは「ラベル」だけを見ても捕まらない。実際の抜けは
  // <button> の中の <strong>/<span> 側で起きていた（ツールバーの資料名と
  // 訳す向き）。文字が乗っている要素すべてに対して、横に溢れて隠れて
  // いないかを見る。
  const CLIP_OVERFLOW = { hidden: 1, clip: 1, auto: 1, scroll: 1 };
  for (const el of textElements) {
    const cs = getComputedStyle(el);
    if (!CLIP_OVERFLOW[cs.overflowX]) continue;
    if (el.scrollWidth <= el.clientWidth + 1) continue;
    // scrollWidth と clientWidth の差だけで断じない。差の正体が中の部品の
    // 余白だと、文字は1画も欠けていないのに赤になる（実測: 行番号の列で
    // 90px/95px と出たが、「未翻訳」は最後まで描かれていた）。
    // 実際に切れているかは、文字そのものの描画矩形が枠の右端を越えたかで見る。
    const box = el.getBoundingClientRect();
    const clientRight = box.left + el.clientLeft + el.clientWidth - el.scrollLeft;
    let cutPx = 0;
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, null);
    let node;
    while ((node = walker.nextNode())) {
      if (!String(node.nodeValue || '').trim()) continue;
      const parent = node.parentElement;
      if (parent && !visible(parent)) continue;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width <= 0 || rect.height <= 0) continue;
        const beyond = rect.right - clientRight;
        if (beyond > cutPx) cutPx = beyond;
      }
    }
    if (cutPx <= 0.5) continue;
    const text = (el.textContent || '').replace(/\s+/g, ' ').trim();
    labelViolations.push({
      selector: cssPath(el),
      text: text.slice(0, 60),
      reason: 'clipped',
      widthPx: Math.round(el.clientWidth),
      neededPx: Math.round(el.scrollWidth),
      cutPx: Math.round(cutPx),
      ellipsis: (cs.textOverflow === 'ellipsis'),
    });
  }

  // ---- 3. 横スクロール ---------------------------------------------------
  const docEl = document.documentElement;
  const overflow = {
    scrollWidth: docEl.scrollWidth,
    clientWidth: docEl.clientWidth,
    overflowPx: docEl.scrollWidth - docEl.clientWidth,
  };
  const overflowViolations = [];
  if (overflow.overflowPx > 0) {
    const offenders = [];
    for (const el of all) {
      if (SKIP_TAGS[el.tagName]) continue;
      if (!visible(el)) continue;
      const r = el.getBoundingClientRect();
      if (r.right > docEl.clientWidth + 1) {
        offenders.push({ selector: cssPath(el), right: Math.round(r.right), width: Math.round(r.width) });
      }
    }
    offenders.sort(function (a, b) { return b.right - a.right; });
    overflowViolations.push({
      reason: 'document-scrolls-horizontally',
      scrollWidth: overflow.scrollWidth,
      clientWidth: overflow.clientWidth,
      overflowPx: overflow.overflowPx,
      offenders: offenders.slice(0, 8),
    });
  }

  return {
    contrast: {
      checked: contrastChecked,
      threshold: MIN_CONTRAST,
      violations: contrastViolations.sort(function (a, b) { return a.ratio - b.ratio; }),
      worst: worst,
      skipped: contrastSkipped,
      all: contrastAll,
    },
    label: { checked: labelsChecked, textElements: textElements.length, violations: labelViolations },
    overflow: { metrics: overflow, violations: overflowViolations },
  };
}

// ---- 故意に床を割る（門が発火するかを確かめる） --------------------------
// 本番の css も html も書き換えない。開いたページの DOM にだけ足す。
function injectFault(kind) {
  const host = document.createElement('div');
  host.id = 'yaku-ui-floor-injected';
  if (kind === 'contrast') {
    host.style.cssText = 'background:#ffffff;color:#f2f2f2;font-size:14px;padding:4px;position:relative;z-index:0;';
    host.textContent = '床を割るための低コントラスト文字';
    document.body.appendChild(host);
    return 'contrast';
  }
  if (kind === 'label') {
    // CLAUDE.md の実例をそのまま使う。この語は 119px 要るのに 65px しか
    // 与えられておらず、実機で3行に折り返していた。
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.style.cssText = 'width:65px;white-space:normal;overflow:visible;font-size:14px;';
    btn.textContent = '点検で気になる点';
    host.appendChild(btn);
    document.body.appendChild(host);
    return 'label';
  }
  if (kind === 'clip') {
    const span = document.createElement('span');
    span.style.cssText = 'display:inline-block;width:40px;overflow:hidden;white-space:nowrap;font-size:14px;background:#fff;color:#000;';
    span.textContent = '点検で気になる点';
    host.appendChild(span);
    document.body.appendChild(host);
    return 'clip';
  }
  if (kind === 'overflow') {
    host.style.cssText = 'position:absolute;left:0;top:0;width:' +
      (document.documentElement.clientWidth + 400) + 'px;height:8px;background:#123456;';
    document.body.appendChild(host);
    return 'overflow';
  }
  if (kind === 'pageerror') {
    setTimeout(function () { throw new Error('YAKU_UI_FLOOR_INJECTED_ERROR'); }, 0);
    return 'pageerror';
  }
  return 'none';
}

// ---- 状態を作る ----------------------------------------------------------
async function gotoLanding(page, opt) {
  await page.goto(opt.url, { waitUntil: 'domcontentloaded', timeout: 30000 });
  // networkidle は使わない。この画面は状態の問い合わせを回し続けるので
  // 永久に idle にならない（実測: 30秒で timeout）。
  await page.waitForSelector('#cat-picker', { state: 'visible', timeout: 30000 });
  await page.waitForTimeout(1500);
  // 使い捨てのデータ置き場で開くと、初回の吹き出しが必ず出る。暗い覆いが
  // 画面全体に掛かるので、そのまま測ると「普段の画面」ではなくなる。閉じる。
  const skip = await page.$('.yaku-tour-skip');
  if (skip) {
    await skip.click();
    await page.waitForTimeout(1000);
  }
}

async function gotoWorkspace(page, opt) {
  await gotoLanding(page, opt);
  if (!opt.fixture) throw Object.assign(new Error('workspace 状態には --fixture が要る'), { yakuToolFailure: true });
  await page.setInputFiles('#cat-file-input', opt.fixture);
  // 訳す向きを自動で決められないときだけ聞いてくる。出たら英訳を選ぶ。
  const deadline = Date.now() + opt.timeout;
  while (Date.now() < deadline) {
    const workspaceShown = await page.evaluate(function () {
      const w = document.getElementById('cat-workspace');
      return !!(w && !w.hidden);
    });
    if (workspaceShown) break;
    const askShown = await page.evaluate(function () {
      const f = document.getElementById('cat-direction-choice');
      return !!(f && !f.hidden);
    });
    if (askShown) {
      await page.click('[data-cat-direction="to_en"]');
    }
    await page.waitForTimeout(500);
  }
  const ok = await page.evaluate(function () {
    const w = document.getElementById('cat-workspace');
    return !!(w && !w.hidden);
  });
  if (!ok) {
    // 失敗の説明を立てる前に、画面が実際に何を出しているかを読む。
    const seen = await page.evaluate(function () {
      function t(id) { const e = document.getElementById(id); return e ? (e.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 300) : '(no element)'; }
      const ask = document.getElementById('cat-direction-choice');
      return {
        status: t('cat-status'),
        job: t('cat-job'),
        quickJob: t('quick-job'),
        directionAsk: !!(ask && !ask.hidden),
        pickerHidden: (document.getElementById('cat-picker') || {}).hidden,
      };
    });
    throw Object.assign(new Error('workspace が開かなかった: ' + JSON.stringify(seen)), { yakuToolFailure: true });
  }
  await page.waitForSelector('#cat-grid-body tr', { timeout: 30000 });
  await page.waitForTimeout(2000);
}

const STATE_BUILDERS = { landing: gotoLanding, workspace: gotoWorkspace };

async function main() {
  const opt = parseArgs(process.argv);
  if (!opt.url) {
    console.error('--url が要る');
    process.exit(1);
  }
  const { chromium } = loadPlaywright();
  const browser = await chromium.launch({ headless: true });
  const report = {
    url: opt.url,
    viewport: { width: opt.width, height: opt.height },
    inject: opt.inject,
    minContrast: opt.minContrast,
    measuredAt: new Date().toISOString(),
    states: [],
    totals: { pageerror: 0, contrast: 0, label: 0, overflow: 0 },
    ok: true,
  };
  try {
    for (const name of opt.states.split(',').map(function (s) { return s.trim(); }).filter(Boolean)) {
      const builder = STATE_BUILDERS[name];
      if (!builder) throw Object.assign(new Error('知らない状態: ' + name), { yakuToolFailure: true });
      const ctx = await browser.newContext({
        viewport: { width: opt.width, height: opt.height },
        deviceScaleFactor: 1,
      });
      const page = await ctx.newPage();
      const pageErrors = [];
      page.on('pageerror', function (e) { pageErrors.push(String((e && e.message) || e)); });
      const stateResult = { state: name, pageerror: { violations: [] } };
      try {
        await builder(page, opt);
        if (opt.inject && opt.inject !== 'none') {
          await page.evaluate(injectFault, opt.inject);
          await page.waitForTimeout(600);
        }
        const probe = await page.evaluate(pageProbe, {
          minContrast: opt.minContrast,
          maxLabelChars: opt.maxLabelChars,
          dump: opt.dump,
        });
        Object.assign(stateResult, probe);
        if (opt.screenshotDir) {
          const shot = path.join(opt.screenshotDir, name + '-' + opt.inject + '.png');
          await page.screenshot({ path: shot });
          stateResult.screenshot = shot;
        }
      } finally {
        stateResult.pageerror.violations = pageErrors.slice();
        await ctx.close();
      }
      report.states.push(stateResult);
    }
  } catch (e) {
    await browser.close();
    console.error(String((e && e.stack) || e));
    process.exit(1);
    return;
  }
  await browser.close();

  for (const s of report.states) {
    report.totals.pageerror += s.pageerror.violations.length;
    report.totals.contrast += (s.contrast ? s.contrast.violations.length : 0);
    report.totals.label += (s.label ? s.label.violations.length : 0);
    report.totals.overflow += (s.overflow ? s.overflow.violations.length : 0);
  }
  report.ok = (report.totals.pageerror + report.totals.contrast + report.totals.label + report.totals.overflow) === 0;

  const json = JSON.stringify(report, null, 2);
  if (opt.out) fs.writeFileSync(opt.out, json, 'utf8');
  else process.stdout.write(json + '\n');
  process.exit(report.ok ? 0 : 2);
}

main().catch(function (e) {
  console.error(String((e && e.stack) || e));
  process.exit(1);
});
