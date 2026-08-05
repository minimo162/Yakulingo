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

function ensureWasm() {
  // 初期化は実測 369ms。押されるまで走らせない（起動を遅くしないため）。
  if (!wasmReady) wasmReady = init();
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
  say($('status'), 'データベース ' + dbs.length + ' 件 / 取込済 ' + state.done_count + ' 件 / 未取込 ' + pending.length + ' 件');

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
  await ensureWasm();
  const lp = new LiteParse({ outputFormat: 'markdown', ocrEnabled: false, quiet: true });
  const counts = { ok: 0, 'low-text': 0, failed: 0 };
  for (let i = 0; i < pending.length; i++) {
    say($('progress'), (i + 1) + ' / ' + pending.length + '  ' + pending[i].source);
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
    say($('publish-result'),
      '作成しました（' + data.count + ' 件）: ' + data.path + '\n' +
      'このフォルダを共有フォルダの corpus\\ 配下へコピーし、corpus\\current.txt を "' + data.version + '" に書き換えてください。',
      'info');
  } catch (e) {
    say($('publish-result'), '作成に失敗しました: ' + e.message, 'error');
  }
}

$('scan').addEventListener('click', scan);
$('ingest').addEventListener('click', ingestAll);
$('publish').addEventListener('click', publish);
