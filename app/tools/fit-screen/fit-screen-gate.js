'use strict';
/*
  収まりの見える化を、本物の cat.html / cat.js を headless Chromium で開いて
  確かめる運転席（tools/cat-screen/cat-screen-gate.js の --width-preview と
  同じ形。既存の総合門は肥大化させず、専用の小ドライバとして新設する）。

  判定はしない。判定は呼び出し側の PowerShell が行う（ps1 judges / JS driver
  observes の decisions）。ここでやることは3つだけ:
    1. 本物の cat.html / cat.js / cat-workspace.css / styles.css / common.js /
       quick.js を、その場のローカル HTTP で配る
    2. /api/* は決め打ちの応答を返し、来た要求（本文）を記録する
    3. 実際に開く・押す。出た DOM と、飛んだ要求の中身を JSON で書き出す

  使い方:
    node fit-screen-gate.js <wwwDir> <payloadJsonPath> <outJsonPath> [viewport] [mode]

  payloadJson は { main: <project>, perf: <project> } の形。
  viewport は "1912x987"（既定）か "1380x900"。
  mode は "full"（既定。main一式＋perfの速度検証まで全部）か
       "filter"（main の絞り込み・行の印だけ。狭い窓での再確認用に軽くする）。

  CoD審査 2026-08-18 REWORK-1 で足した題材:
    - perf: 300行「右に何も無い」行＋1行「シートの最終内容列そのもの」の行。
      前者は自動spillの上限（layout.lastContentColumn）が効いているかを
      初回描画の所要時間で見る。後者は、その上限が「最終内容列そのものの
      セルを無限の余白で収まると誤判定させない」ことを見る。
    - main の index=11: 訳がまだ空の行。segmentFitRiskInfo が訳の有無で
      門を閉じているかを見る（原文だけなら明らかにはみ出す長さにしてある）。
*/
const fs = require('fs');
const http = require('http');
const path = require('path');
const { chromium } = require('playwright');

const wwwDir = process.argv[2];
const payloadJsonPath = process.argv[3];
const outputPath = process.argv[4];
const viewportArg = String(process.argv[5] || '1912x987');
const mode = String(process.argv[6] || 'full');
const viewportParts = viewportArg.split('x');
const viewport = { width: Number(viewportParts[0]) || 1912, height: Number(viewportParts[1]) || 987 };

const payloadJson = fs.readFileSync(payloadJsonPath, 'utf8');
const payload = JSON.parse(payloadJson);
const mainProject = payload.main;
const perfProject = payload.perf;
const mainProjectJson = JSON.stringify(mainProject);
const perfProjectJson = perfProject ? JSON.stringify(perfProject) : '';

/* 絞り込みの釦（data-cat-filter）は #cat-editor-toolbar の中にあり、premium の
   作業画面では premium-ui.css がこの帯を display:none にする。利用者は上部の
   「詳細ツール」（#premium-tools）で開いてから触る。その道すがらをなぞる。
   （旧ドライバは button.hidden を力技で外して押していたが、隠れているのは
   hidden 属性ではなく祖先の display:none なので効かず、30秒の時間切れになって
   いた。2026-08-23 実測。） */
async function openTools(page) {
  const needOpen = await page.evaluate(function () {
    var invoker = document.getElementById('premium-tools');
    return !document.body.classList.contains('premium-tools-open') && !!invoker && !invoker.hidden;
  });
  if (!needOpen) return;
  await page.click('#premium-tools');
  await page.waitForFunction(function () {
    var toolbar = document.getElementById('cat-editor-toolbar');
    return document.body.classList.contains('premium-tools-open') &&
      !!toolbar && toolbar.getClientRects().length > 0;
  }, null, { timeout: 10000 });
}

/* 詳細ツールを開いているあいだは、帯の外に半透明の幕（premium-ui.css の
   body.premium-tools-open::after）が降りて、帯の外の釦を押せなくなる。
   絞り込みを押し終えたら Esc で閉じて、画面の本体へ手を戻す。 */
async function closeTools(page) {
  const isOpen = await page.evaluate(function () {
    return document.body.classList.contains('premium-tools-open');
  });
  if (!isOpen) return;
  await page.keyboard.press('Escape');
  await page.waitForFunction(function () {
    return !document.body.classList.contains('premium-tools-open');
  }, null, { timeout: 10000 });
}

/* Premium places low-frequency row tools behind 「この行の詳細」. The
   legacy fit-screen driver opens that disclosure before using the preserved
   delegated buttons; this exercises the same user path without making the
   product show a permanent tool strip. */
async function openRowDetails(page) {

  let details = page.locator('#premium-row-details');
  if (!(await details.count())) {
    await page.waitForSelector('#premium-row-details', { state: 'attached', timeout: 10000 });
    details = page.locator('#premium-row-details');
  }
  const open = await details.evaluate(function (node) { return !!node.open; });
  if (!open) await details.locator(':scope > summary').click();
  await page.waitForFunction(function () {
    var node = document.getElementById('premium-row-details');
    var preview = document.getElementById('cat-preview-open');
    return !!node && node.open && !!preview && preview.getClientRects().length > 0 && getComputedStyle(preview).display !== 'none';
  }, null, { timeout: 10000 });
}

const types = {
  '.js': 'application/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.html': 'text/html; charset=utf-8'
};

const publicationCalls = [];

function readBody(req) {
  return new Promise(function (resolve) {
    let data = '';
    req.on('data', function (c) { data += c; });
    req.on('end', function () { resolve(data); });
  });
}

const server = http.createServer(async function (req, res) {
  const url = new URL(req.url, 'http://127.0.0.1');
  const p = url.pathname;
  if (p === '/cat' || p === '/') {
    let html = fs.readFileSync(path.join(wwwDir, 'cat.html'), 'utf8');
    html = html.replace(/__YAKU_SESSION_TOKEN__/g, 'fit-test-token')
      .replace(/__YAKU_MAX_UPLOAD_BYTES__/g, '52428800')
      .replace(/__YAKU_MAX_BATCH_CHARS__/g, '4000')
      .replace(/__YAKU_AMOUNT_NOTATION__/g, 'oku')
      .replace(/__YAKU_TOUR__/g, '0')
      .replace(/__YAKU_IMPORT__/g, '0')
      .replace(/__YAKU_VIEW__/g, '')
      /* previewOutputFont() の配線先。実測値の再現（下の canvas 計測）と
         同じ書体にする。 */
      .replace(/__YAKU_OUTPUT_FONT__/g, 'Arial')
      .replace(/__YAKU_OUTPUT_FONT_JP__/g, 'MS Pゴシック');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(html);
    return;
  }
  if (p.startsWith('/assets/')) {
    const file = path.join(wwwDir, p.replace(/^\//, ''));
    if (fs.existsSync(file)) {
      res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream' });
      res.end(fs.readFileSync(file));
      return;
    }
    res.writeHead(404); res.end('not found'); return;
  }
  const body = await readBody(req);
  let parsed = null;
  try { parsed = body ? JSON.parse(body) : null; } catch (_) { parsed = null; }
  res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
  if (p === '/api/ready-state') { res.end(JSON.stringify({ canTranslate: true, label: 'ready', class: 'ok' })); return; }
  if (p === '/api/cat/recent') { res.end(JSON.stringify({ projects: [] })); return; }
  if (p === '/api/cat/resume') {
    const wanted = parsed ? String(parsed.project_id || '') : '';
    if (perfProject && wanted === String(perfProject.id || '')) { res.end(perfProjectJson); return; }
    res.end(mainProjectJson);
    return;
  }
  if (p === '/api/cat/publication-candidates') {
    publicationCalls.push(parsed);
    res.end(JSON.stringify({ job_id: 'fit-job-' + publicationCalls.length }));
    return;
  }
  if (p.indexOf('/api/jobs/') === 0) {
    /* 正確さの検証は候補の中身までは要らない（見るのは max_chars の配線）。
       候補0件でも「収まりません」の状態行が出るだけで、押した事実は残る。 */
    res.end(JSON.stringify({ mode: 'done', application_status: 'current', candidate_set: { candidate_set_id: 'cs-1', dependency_fingerprint: 'fp-1', candidates: [] } }));
    return;
  }
  res.end('{}');
});

/* 絞り込み・行の印を読む。1912x987・1380x900の両方の窓で同じ手順を回すため
   関数にする（MINOR-6d）。 */
async function readFilterAndBadges(page) {
  await openTools(page);
  const filterBefore = await page.evaluate(function () {
    var button = document.querySelector('[data-cat-filter="fit"]');
    var count = document.querySelector('[data-cat-count="fit"]');
    return { hidden: !button || button.hidden, visible: !!(button && button.getClientRects().length > 0), count: count ? count.textContent : '' };
  });
  const badges = await page.evaluate(function () {
    return Array.from(document.querySelectorAll('.cat-fit-risk-badge')).map(function (badge) {
      var row = badge.closest('tr[data-cat-row]');
      return { row: row ? Number(row.getAttribute('data-cat-row')) : -1, title: badge.getAttribute('title') || '' };
    });
  });
  /* hidden を外す旧手当ては削除した。詳細ツールを開いているので、釦は
     利用者と同じ条件で見えている。隠れたままなら、それは製品側の問題として
     そのまま時間切れに落とす（緑偽装の禁止）。 */
  await page.click('[data-cat-filter="fit"]');
  await page.waitForTimeout(250);
  const filterAfter = await page.evaluate(function () {
    var button = document.querySelector('[data-cat-filter="fit"]');
    return {
      pressed: button ? button.getAttribute('aria-pressed') : '',
      rows: Array.from(document.querySelectorAll('#cat-grid-body tr[data-cat-row]')).map(function (tr) { return Number(tr.getAttribute('data-cat-row')); })
    };
  });
  await page.click('[data-cat-filter="all"]');
  await page.waitForTimeout(200);
  await closeTools(page);
  return { filterBefore: filterBefore, badges: badges, filterAfter: filterAfter };
}

(async function () {
  const out = { errors: [], console: [], publicationCalls: [], viewport: viewport, mode: mode };
  let browser = null;
  try {
    await new Promise(function (resolve) { server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch();
    const page = await browser.newPage({ viewport: viewport });
    page.on('pageerror', function (error) { out.errors.push(String((error && error.message) || error)); });
    page.on('console', function (message) { if (message.type() === 'error') out.console.push(message.text()); });
    await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(mainProject.id), { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('#cat-grid-body tr[data-cat-row]', { timeout: 20000 });

    if (mode === 'filter') {
      // 狭い窓の再確認（MINOR-6d）。絞り込み・行の印だけを見る、軽い経路。
      const filterResult = await readFilterAndBadges(page);
      out.fitFilterBefore = filterResult.filterBefore;
      out.fitBadges = filterResult.badges;
      out.fitFilterAfter = filterResult.filterAfter;
      out.publicationCalls = publicationCalls;
    } else {
      // ---------------------------------------------------- プレビューの印（自動spill）
      await openRowDetails(page);
      await page.click('#cat-preview-open');
      await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
      /* セルの組み立ては資料を読み込み終えた render() のあとに走る。起動直後の
         決め打ち待ちではまだ空で、あとの押す手順だけが通る非対称な赤になって
         いた（2026-08-23 実測）。V9212 の運転席と同じく、出るまで待つ。 */
      await page.waitForFunction(function () {
        return document.querySelectorAll('#cat-preview-body .cat-preview-cell').length > 0;
      }, null, { timeout: 20000 });
      await page.waitForTimeout(250);
      out.previewCells = await page.evaluate(function () {
        return Array.from(document.querySelectorAll('#cat-preview-body .cat-preview-cell')).map(function (cell) {
          return {
            index: Number(cell.getAttribute('data-cat-preview-index')),
            overflowRisk: cell.classList.contains('is-overflow-risk'),
            ariaLabel: cell.getAttribute('aria-label') || '',
            title: cell.getAttribute('title') || ''
          };
        });
      });

      // ------------------------------------------------- 文字目標（実測3通り＋フォールバック）
      /* previewSide=target が既定なので、配置つきのセルは data-cat-placement-edit
         を持つ。押すと配置ダイアログが直接開く。 */
      async function runPublicationFromPreviewCell(index) {
        await page.click('#cat-preview-body .cat-preview-cell[data-cat-preview-index="' + index + '"]');
        await page.waitForSelector('#cat-placement-dialog[open]', { timeout: 10000 });
        await page.click('#cat-placement-edit');
        await page.click('#cat-publication-open');
        await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
        const before = publicationCalls.length;
        await page.click('#cat-publication-generate');
        // publicationCalls はNode側配列。ブラウザ側からは見えないので、要求が
        // サーバへ届くまで素直に待つ（ポーリング）。
        const deadline = Date.now() + 10000;
        while (publicationCalls.length <= before && Date.now() < deadline) { await page.waitForTimeout(50); }
        const note = await page.evaluate(function () { var n = document.getElementById('cat-publication-maxchars-note'); return n ? n.textContent : ''; });
        await page.evaluate(function () {
          document.getElementById('cat-publication-dialog').close();
          document.getElementById('cat-placement-dialog').close();
        });
        return { requestBody: publicationCalls[publicationCalls.length - 1] || null, note: note };
      }
      /* 実測の期待値を、cat.js の実装と同じ式で独立に出す（呼び出さない・覗かない）。
         previewOutputFont() は「"Arial", Calibri, Arial, sans-serif」を組む
         （direction=to_en・設定値=Arial のとき）。列幅の式（幅*7+5、24px下限）は
         仕様として固定されているので、テスト側が用意した既知の列幅から出す。
         8..99へのクランプ・生の値・basisもここで同じ式で再現する
         （REWORK-1 MAJOR-3/4: below-min／measured／above-maxの3通りを見る）。 */
      async function computeOracle(text, columnWidths) {
        return await page.evaluate(function (args) {
          var ctx = document.createElement('canvas').getContext('2d');
          ctx.font = '14.7px "Arial", Calibri, Arial, sans-serif';
          var textWidth = ctx.measureText(args.text).width;
          var displayWidth = args.columnWidths.reduce(function (sum, w) { return sum + Math.max(24, Math.round(w * 7 + 5)); }, 0);
          var raw = Math.floor(args.text.length * Math.max(0, displayWidth - 8) / textWidth);
          var basis = raw < 8 ? 'below-min' : (raw > 99 ? 'above-max' : 'measured');
          return { textWidth: textWidth, displayWidth: displayWidth, raw: raw, basis: basis, expectedMaxChars: Math.min(99, Math.max(8, raw)) };
        }, { text: text, columnWidths: columnWidths });
      }
      function segmentText(index) {
        var segment = (mainProject.segments || []).find(function (s) { return Number(s.index) === index; });
        return String((segment && segment.translation) || '');
      }
      const aboveIndex = 8, normalIndex = 12, belowIndex = 13, fallbackIndex = 9;
      out.measuredAbove = await runPublicationFromPreviewCell(aboveIndex);
      out.oracleAbove = await computeOracle(segmentText(aboveIndex), [1, 50, 50]);
      out.measuredNormal = await runPublicationFromPreviewCell(normalIndex);
      out.oracleNormal = await computeOracle(segmentText(normalIndex), [1, 50]);
      out.measuredBelow = await runPublicationFromPreviewCell(belowIndex);
      out.oracleBelow = await computeOracle(segmentText(belowIndex), [1]);
      out.fallback = await runPublicationFromPreviewCell(fallbackIndex);
      out.fallbackExpected = Math.max(20, Math.floor(segmentText(fallbackIndex).length * 0.8));

      await page.evaluate(function () { document.getElementById('cat-preview-dialog').close(); });

      // -------------------------------------------------------------- 絞り込み・行の印
      const filterResult = await readFilterAndBadges(page);
      out.fitFilterBefore = filterResult.filterBefore;
      out.fitBadges = filterResult.badges;
      out.fitFilterAfter = filterResult.filterAfter;

      // -------------------------------------------------------------- 行の1クリック導線
      /* index=7 の行（scenario "row-action"）を選び、選択行リボンにボタンが
         出るか・押すと配置ダイアログ＋公開候補の両方が開くかを見る。
         選び方はキーボード（Alt+↑/↓）。premium の表は選択中の行だけを描くため、
         ほかの行の訳文欄は DOM にはあっても display:none で、focus を当てても
         選択は動かない（2026-08-23 実測）。絞り込みを触ったあとは選択行が
         0行目とは限らないので、いまの選択を読みながら目的の行まで歩く。 */
      async function activeRowNow() {
        return await page.evaluate(function () {
          var tr = document.querySelector('#cat-grid-body tr.is-active');
          return tr ? Number(tr.getAttribute('data-cat-row')) : -1;
        });
      }
      async function gotoRow(target) {
        for (var guard = 0; guard < 40; guard++) {
          const current = await activeRowNow();
          if (current === target) { await page.waitForTimeout(150); return; }
          await page.keyboard.down('Alt'); await page.keyboard.press(current < target ? 'ArrowDown' : 'ArrowUp'); await page.keyboard.up('Alt');
          await page.waitForFunction(function (pair) {
            var tr = document.querySelector('#cat-grid-body tr.is-active');
            return !!tr && Number(tr.getAttribute('data-cat-row')) !== pair[0];
          }, [current, target], { timeout: 10000 });
          await page.waitForTimeout(100);
        }
        throw new Error('row ' + target + ' not reached');
      }
      await gotoRow(7);
      out.rowActionButton = await page.evaluate(function () {
        var button = document.querySelector('[data-cat-fit-candidates="7"]');
        return { exists: !!button, visible: !!(button && button.getClientRects().length > 0) };
      });
      // 訳が空の行（index=11）には出ないことも、同じ選択→観察の手順で見る。
      await gotoRow(11);
      out.untranslatedRowActionButton = await page.evaluate(function () {
        return !!document.querySelector('[data-cat-fit-candidates="11"]');
      });
      await gotoRow(7);
      await page.waitForTimeout(200);
      await openRowDetails(page);
      await page.click('[data-cat-fit-candidates="7"]');
      await page.waitForSelector('#cat-placement-dialog[open]', { timeout: 10000 });
      await page.waitForSelector('#cat-publication-dialog[open]', { timeout: 10000 });
      out.rowActionOpened = await page.evaluate(function () {
        return {
          placementOpen: !!document.getElementById('cat-placement-dialog').open,
          publicationOpen: !!document.getElementById('cat-publication-dialog').open,
          placementIndex: document.getElementById('cat-placement-index').value
        };
      });
      await page.evaluate(function () {
        document.getElementById('cat-publication-dialog').close();
        document.getElementById('cat-placement-dialog').close();
      });

      out.publicationCalls = publicationCalls;

      // ---------------------------------------------------- perf: 最終内容列の上限
      if (perfProject) {
        const t0 = Date.now();
        await page.goto('http://127.0.0.1:' + server.address().port + '/cat?project=' + encodeURIComponent(perfProject.id), { waitUntil: 'domcontentloaded' });
        /* premium の表は選択中の行だけを描く（ほかの行は display:none）。
           「見える」を待つと永遠に来ないので、描き切ったことの合図としては
           最終行が DOM に載ることを見る（attached）。 */
        await page.waitForSelector('#cat-grid-body tr[data-cat-row="300"]', { state: 'attached', timeout: 30000 });
        const t1 = Date.now();
        out.perfFirstRenderMs = t1 - t0;
        // 右端（最終内容列そのもの、行番号300）の印を体裁プレビューで見る。
        await openRowDetails(page);
        await page.click('#cat-preview-open');
        await page.waitForSelector('#cat-preview-dialog[open]', { timeout: 10000 });
        await page.waitForFunction(function () {
          return document.querySelectorAll('#cat-preview-body .cat-preview-cell').length > 0;
        }, null, { timeout: 20000 });
        await page.waitForTimeout(250);
        out.perfPreviewCells = await page.evaluate(function () {
          return Array.from(document.querySelectorAll('#cat-preview-body .cat-preview-cell')).map(function (cell) {
            return { index: Number(cell.getAttribute('data-cat-preview-index')), overflowRisk: cell.classList.contains('is-overflow-risk') };
          });
        });
        await page.evaluate(function () { document.getElementById('cat-preview-dialog').close(); });
      }
    }
  } catch (error) {
    out.fatal = String((error && error.stack) || error);
  } finally {
    if (browser) await browser.close().catch(function () {});
    await new Promise(function (resolve) { server.close(resolve); });
    fs.writeFileSync(outputPath, JSON.stringify(out, null, 1), 'utf8');
  }
  if (out.errors.length || out.console.length || out.fatal) process.exitCode = 1;
})();
