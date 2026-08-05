// V91.61 コーパス作成（管理者用）。
//
// PDF の解析はこのページの中で WASM（LiteParse）が行う。
// ファイルの列挙・読み出し・保存は PowerShell 側が持つ。ブラウザにフォルダは触らせない。
// 解析結果はすべてローカルへ保存される。共有フォルダへは書き込まない。
import init, { LiteParse } from '/assets/vendor/liteparse/liteparse_wasm.js';

const token = document.querySelector('meta[name="yaku-session"]').getAttribute('content');
const $ = (id) => document.getElementById(id);
let wasmReady = null;
let state = null;

function api(path, options) {
  const opt = Object.assign({ headers: {} }, options || {});
  opt.headers['X-Yaku-Session'] = token;
  return fetch(path, opt);
}

async function reportEnvironment() {
  // この画面が実際に受け取った CSP と、動いているアプリの版を出す。
  // 実機で「直したはずなのに直っていない」ときの切り分けに要る。
  // 同一オリジンなので、自分自身を取り直せば応答ヘッダを読める。
  const el = $('env');
  let csp = '(取得できません)';
  let build = '(不明)';
  try {
    const res = await fetch(location.pathname, { cache: 'no-store' });
    csp = res.headers.get('Content-Security-Policy') || '(ヘッダなし)';
  } catch (e) { csp = '(取得に失敗: ' + e.message + ')'; }
  try {
    const res = await api('/api/instance');
    if (res.ok) { const d = await res.json(); build = d.build_id || '(不明)'; }
  } catch (e) { /* 版が取れなくても画面は使える */ }
  const wasmOk = /wasm-unsafe-eval/.test(csp);
  el.textContent = 'アプリの版: ' + build + '  /  WebAssembly: ' + (wasmOk ? '許可' : '不許可') + '\nCSP: ' + csp;
  el.className = wasmOk ? 'muted' : 'alert alert-warning';
  return { csp: csp, build: build, wasmOk: wasmOk };
}

function ensureWasm() {
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

function say(el, text, kind) {
  el.innerHTML = '';
  const div = document.createElement('div');
  if (kind) div.className = 'alert alert-' + kind;
  div.textContent = text;
  el.appendChild(div);
}

async function scan() {
  const root = $('source-root').value.trim();
  if (!root) { say($('status'), 'フォルダのパスを入力してください。', 'warning'); return; }
  say($('status'), '読み込み中…');
  try {
    const res = await api('/api/admin/corpus/status?root=' + encodeURIComponent(root));
    if (!res.ok) throw new Error('HTTP ' + res.status);
    state = await res.json();
  } catch (e) {
    say($('status'), '読み込みに失敗しました: ' + e.message, 'error');
    return;
  }
  if (!state.reachable) {
    say($('status'), 'フォルダが見つかりません: ' + state.source_root, 'warning');
    $('ingest-card').hidden = true;
    return;
  }
  const dbs = state.databases || [];
  const pending = state.pending || [];
  let msg = 'データベース ' + dbs.length + ' 件 / 取込済 ' + state.done_count + ' 件 / 未取込 ' + pending.length + ' 件';
  // 移動を黙って無視すると「取り込めない」ように見える。理由を書く。
  if (state.relocated > 0) msg += '\n（うち ' + state.relocated + ' 件は別のフォルダへ移されています。取り込み直すとデータベース名が更新されます）';
  if (state.stale && state.stale.length > 0) msg += '\n（原本が見当たらない項目が ' + state.stale.length + ' 件あります: ' + state.stale.slice(0, 3).join('、') + (state.stale.length > 3 ? ' ほか' : '') + '）';
  say($('status'), msg, (state.relocated > 0 || (state.stale && state.stale.length > 0)) ? 'info' : null);

  const list = document.createElement('ul');
  dbs.forEach(function (d) {
    const li = document.createElement('li');
    li.textContent = d.name + '  取込済 ' + d.done + ' 件 / 未取込 ' + d.pending + ' 件';
    list.appendChild(li);
  });
  $('databases').innerHTML = '';
  $('databases').appendChild(list);
  $('ingest-card').hidden = false;
  $('publish-card').hidden = (state.done_count <= 0);
  $('ingest').disabled = (pending.length === 0);
}

async function ingestOne(lp, item, root) {
  // 1件分。失敗しても投げ返さず status で返す。1件の失敗で全体を止めない。
  let markdown = '', pages = 0, pageChars = [], status = 'ok', note = '';
  try {
    const res = await api('/api/admin/corpus/pdf?root=' + encodeURIComponent(root) + '&id=' + encodeURIComponent(item.id));
    if (!res.ok) throw new Error('PDF を読めません (HTTP ' + res.status + ')');
    const bytes = new Uint8Array(await res.arrayBuffer());
    // OCR は必ず無効にする。有効だと tessdata を外部から取得しようとして止まる。
    const parsed = await lp.parse(bytes);
    const mdPages = (parsed.pages || []).map(function (p) { return p.markdown || ''; });
    pages = mdPages.length;
    pageChars = mdPages.map(function (m) { return m.length; });
    markdown = mdPages.map(function (m, i) { return '<!--yaku-page:' + (i + 1) + '-->\n' + m; }).join('\n\n');
  } catch (e) {
    status = 'failed';
    note = e && e.message ? e.message : String(e);
  }
  await api('/api/admin/corpus/ingest', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      id: item.id, sha256: item.sha256, database: item.database, source: item.source,
      markdown: markdown, pages: pages, page_chars: pageChars, status: status, note: note
    })
  });
  return status;
}

async function ingestAll() {
  const root = $('source-root').value.trim();
  const pending = (state && state.pending) || [];
  if (!pending.length) return;
  $('ingest').disabled = true;
  say($('progress'), 'WASM を読み込んでいます…');
  let lp;
  try {
    await ensureWasm();
    lp = new LiteParse({ outputFormat: 'markdown', ocrEnabled: false, quiet: true });
  } catch (e) {
    // 握りつぶすと「読み込んでいます…」のまま止まって見える。必ず表に出す。
    say($('progress'), e && e.message ? e.message : String(e), 'error');
    $('ingest').disabled = false;
    return;
  }
  const counts = { ok: 0, 'low-text': 0, failed: 0 };
  for (let i = 0; i < pending.length; i++) {
    say($('progress'), (i + 1) + ' / ' + pending.length + '  ' + pending[i].source
      + (pending[i].relocated ? '（' + pending[i].previous + ' から移動）' : ''));
    const st = await ingestOne(lp, pending[i], root);
    counts[st === 'failed' ? 'failed' : 'ok']++;
  }
  say($('progress'), '取り込みました。成功 ' + counts.ok + ' 件 / 失敗 ' + counts.failed + ' 件', 'info');
  await scan();
}

async function publish() {
  say($('publish-result'), '作成中…');
  try {
    const res = await api('/api/admin/corpus/publish', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
    const data = await res.json();
    if (!data.ok) throw new Error(data.error || 'unknown');
    // 手順は1つだけにする。版フォルダ名も current.txt も、こちらで用意済み。
    say($('publish-result'),
      '作成しました（' + data.count + ' 件）。\n' +
      '次の corpus フォルダを、共有フォルダ（YakuLingo起動.cmd と同じ場所）へ丸ごとコピーしてください。\n' +
      (data.corpus_dir || data.path) + '\n' +
      '共有フォルダに既に corpus がある場合は、上書き（統合）してください。current.txt も入っているので書き換えは不要です。',
      'info');
  } catch (e) {
    say($('publish-result'), '作成に失敗しました: ' + e.message, 'error');
  }
}

reportEnvironment();
$('scan').addEventListener('click', scan);
$('ingest').addEventListener('click', ingestAll);
$('publish').addEventListener('click', publish);
