// PDF からテキストを取り出す共通部品。
//
// PDF取り込みで共通に使うため、ブラウザ側の部品として独立させている。
// 写すと、段組みの判定のような測って決めた実装が2つに分かれて必ず食い違う。
//
// 動かすには CSP に 'wasm-unsafe-eval' が要る。取り込みで開いた画面
//（?import=1）だけがそれを受け取る。
import init, { LiteParse } from '/assets/vendor/liteparse/liteparse_wasm.js';
export { LiteParse };

let wasmReady = null;

async function reportEnvironment() {
  const csp = await fetch(location.pathname + location.search, { method: 'GET' })
    .then(function (r) { return r.headers.get('content-security-policy') || '(なし)'; })
    .catch(function () { return '(取得できず)'; });
  const build = (document.querySelector('meta[name="yaku-build"]') || {}).content || '(不明)';
  return { csp: csp, build: build, wasmOk: /wasm-unsafe-eval/.test(csp) };
}

export function ensureWasm() {
  // 初期化は実測 369ms。押されるまで走らせない（起動を遅くしないため）。
  //
  // .wasm を自分で取得してバイト列で渡す。init() に任せると取得と
  // コンパイルのどちらで失敗したか分からず、原因の切り分けができない。
  if (!wasmReady) {
    wasmReady = (async function () {
      const url = '/assets/vendor/liteparse/liteparse_wasm_bg.wasm';
      let res;
      try { res = await fetch(url); }
      catch (e) { throw new Error('WASM を取得できません: ' + url + ' (' + e.message + ')'); }
      if (!res.ok) throw new Error('WASM を取得できません: ' + url + ' (HTTP ' + res.status + ')');
      const buf = await res.arrayBuffer();
      if (buf.byteLength < 1000000) throw new Error('WASM のサイズが不正です: ' + buf.byteLength + ' bytes');
      try {
        await init({ module_or_path: buf });
      } catch (e) {
        // CSP に 'wasm-unsafe-eval' が無いとここで落ちる。原因を名指しする。
        const msg = (e && e.message) ? e.message : String(e);
        if (/unsafe-eval|Content Security Policy/i.test(msg)) {
          // この画面が実際に受け取った CSP を添える。推測せずに切り分けられるようにする。
          const env = await reportEnvironment();
          throw new Error(
            'WebAssembly がブラウザの制限で実行できません。\n' +
            'この画面が受け取った CSP: ' + env.csp + '\n' +
            'アプリの版: ' + env.build + '\n' +
            (env.wasmOk
              ? 'CSP には wasm-unsafe-eval が入っています。ブラウザが対応していない可能性があります（Edge 97 以降が必要）。'
              : 'CSP に wasm-unsafe-eval がありません。古い版が動いているか、以前に開いた画面が残っています。'
                + ' Ctrl+Shift+R で再読み込みするか、アプリを再起動してください。') +
            '\n(' + msg + ')');
        }
        throw new Error('WASM を初期化できません: ' + msg);
      }
    })();
    // 失敗を握りつぶすと次回も同じ Promise を返してしまう。捨てて作り直せるようにする。
    wasmReady.catch(function () { wasmReady = null; });
  }
  return wasmReady;
}

export function yakuPageTextByColumns(page) {
  const items = (page.textItems || []).filter(function (t) { return t && t.text && t.text.trim(); });
  const fallback = page.text || page.markdown || '';
  if (items.length < 8) return fallback;
  let minX = Infinity, maxX = -Infinity, hSum = 0;
  for (const t of items) {
    const x = Number(t.x) || 0, w = Number(t.width) || 0;
    if (x < minX) minX = x;
    if (x + w > maxX) maxX = x + w;
    hSum += Number(t.height) || 0;
  }
  const width = maxX - minX;
  if (!isFinite(width) || width <= 0) return fallback;
  const lineHeight = (hSum / items.length) || 10;

  // x 方向を細かい升目に落とし、何個の文字片が載っているかを数える。
  const BINS = 240;
  const occ = new Array(BINS).fill(0);
  for (const t of items) {
    const x = Number(t.x) || 0, w = Number(t.width) || 0;
    let a = Math.floor((x - minX) / width * BINS);
    let b = Math.ceil((x + w - minX) / width * BINS);
    if (a < 0) a = 0;
    if (b > BINS - 1) b = BINS - 1;
    for (let i = a; i <= b; i++) occ[i]++;
  }
  // 段をまたぐ見出しが1本あるだけで谷が埋まる。完全な空白ではなく
  // 「ほとんど載っていない」を谷とみなす。
  const peak = Math.max.apply(null, occ);
  const floorLevel = Math.max(1, Math.floor(peak * 0.04));
  const minGap = Math.max(4, Math.round(BINS * 0.022));

  const bands = [];
  let start = null;
  for (let i = 0; i < BINS; i++) {
    if (occ[i] > floorLevel) {
      if (start === null) start = i;
      continue;
    }
    let j = i;
    while (j < BINS && occ[j] <= floorLevel) j++;
    if (start !== null && (j - i) >= minGap) { bands.push([start, i - 1]); start = null; }
    i = j - 1;
  }
  if (start !== null) bands.push([start, BINS - 1]);

  // 1段なら今までと同じ。刻まれすぎたときは表の可能性が高いので触らない。
  if (bands.length < 2 || bands.length > 5) return fallback;

  const edges = bands.map(function (b) {
    return { lo: minX + (b[0] / BINS) * width, hi: minX + ((b[1] + 1) / BINS) * width, items: [] };
  });
  for (const t of items) {
    const cx = (Number(t.x) || 0) + (Number(t.width) || 0) / 2;
    let band = edges[0];
    for (const e of edges) { if (cx >= e.lo && cx <= e.hi) { band = e; break; } }
    band.items.push(t);
  }

  // 表と段組みを見分ける。
  //
  // 行の揃い方では見分けられない。段組みの本文も左右の行は同じ高さに並ぶ
  // （2026-08-07 に一度これで誤り、統合報告書まで表と判定した）。
  // 見分けるのは中身のほうである。
  //   表      セルが短い。「現金及び預金」「1,001,379」
  //   段組み  1行が文の一部で長い
  // 表を段として割ると科目と金額が別の行になり、行が意味を失う。
  // 決算短信は大半が表なので、誤ると既に取れていたものを壊す。
  const cellLens = [];
  let numericCells = 0;
  for (const e of edges) {
    const rows = new Map();
    for (const t of e.items) {
      const key = Math.round((Number(t.y) || 0) / Math.max(1, lineHeight * 0.6));
      rows.set(key, (rows.get(key) || '') + String(t.text).trim());
    }
    for (const v of rows.values()) {
      cellLens.push(v.length);
      if (v.length && !/[ぁ-んァ-ヶ一-鿿A-Za-z]{3}/.test(v)) numericCells++;
    }
  }
  if (!cellLens.length) return fallback;
  cellLens.sort(function (a, b) { return a - b; });
  const median = cellLens[Math.floor(cellLens.length / 2)];
  // セルが短い、または数字だけの升目が多いページは表とみなして触らない。
  if (median < 12 || numericCells / cellLens.length > 0.35) return fallback;
  const out = [];
  for (const e of edges) {
    if (!e.items.length) continue;
    e.items.sort(function (a, b) {
      const dy = (Number(a.y) || 0) - (Number(b.y) || 0);
      if (Math.abs(dy) > lineHeight * 0.6) return dy;
      return (Number(a.x) || 0) - (Number(b.x) || 0);
    });
    let line = [], lastY = null;
    for (const t of e.items) {
      const y = Number(t.y) || 0;
      if (lastY !== null && Math.abs(y - lastY) > lineHeight * 0.6) { out.push(line.join(' ')); line = []; }
      line.push(String(t.text).trim());
      lastY = y;
    }
    if (line.length) out.push(line.join(' '));
  }
  const text = out.join('\n');
  // 取れ高が明らかに減ったときは信用しない。元の取り出しへ戻す。
  if (text.replace(/\s/g, '').length < fallback.replace(/\s/g, '').length * 0.8) return fallback;
  return text;
}

/* PDF のバイト列から、ページごとのテキストを取り出す。
   返すのは { pages: [{ page, text }], lowText } だけ。画像は返さない。
   lowText は「半数以上のページで文字がほとんど取れない」＝スキャンPDFの目印で、
   PowerShell 側の低抽出判定と同じ考え方（閾値200字）。 */
export async function extractPdfPages(bytes) {
  await ensureWasm();
  const lp = new LiteParse({ outputFormat: 'json', ocrEnabled: false, quiet: true });
  const parsed = await lp.parse(bytes);
  const pages = (parsed.pages || []).map(function (p, i) {
    return { page: i + 1, text: yakuPageTextByColumns(p) };
  });
  const low = pages.filter(function (p) { return String(p.text || '').length < 200; }).length;
  return { pages: pages, lowText: pages.length > 0 && low * 2 > pages.length };
}
