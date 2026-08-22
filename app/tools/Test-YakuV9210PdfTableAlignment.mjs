/*
 * V9210: coordinate-based table reconstruction for PDF past-translation input.
 *
 * This is intentionally a browser test: pdf-extract.js is a browser ES module
 * and its public surface must be exercised as shipped.  Exit 3 means the gate
 * could not be measured because Playwright or its Chromium binary is missing.
 */
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const assetRoot = path.resolve(repoRoot, 'app/www/assets');

let playwright;
try {
  playwright = require(require.resolve('playwright', { paths: [repoRoot] }));
} catch (error) {
  console.log('UNMEASURED: Playwright is unavailable (' + String(error && error.message || error) + ')');
  process.exit(3);
}

let chromiumPath = '';
try { chromiumPath = playwright.chromium.executablePath(); } catch (_) {}
if (!chromiumPath || !fs.existsSync(chromiumPath)) {
  console.log('UNMEASURED: Chromium executable is unavailable.');
  process.exit(3);
}

function item(text, x, y, width, height = 8.3) {
  return { text, x, y, width: width || Math.max(12, text.length * 5), height };
}

function makeColumnMajorFallbackText(title, period, header, dataRows, footer) {
  const columns = header.map(function (heading, index) {
    return [heading].concat(dataRows.map(function (row) { return row[index]; })).join('\n');
  });
  return [title, period].concat(columns, [footer]).join('\n');
}

function makeTablePage(title, period, header, dataRows, footer, yValues, titleY, bodyHeight) {
  const x = [39.015750885009766, 175.07875061035156, 245.94483947753906, 316.81103515625, 382.0078430175781];
  const items = [item(title, 42.015750885009766, titleY, 298.9, 20), item(period, 40.015750885009766, yValues[1], 132, 9)];
  items.push(item(header[0], x[0], yValues[2], 34), item(header[1], x[1], yValues[2], 34), item(header[2], x[2], yValues[2], 34), item(header[3], x[3], yValues[2], 40), item(header[4], x[4], yValues[2], 48));
  for (let r = 0; r < dataRows.length; r++) {
    const y = yValues[3 + r];
    const row = dataRows[r];
    items.push(item(row[0], x[0], y, 120, bodyHeight), item(row[1], x[1], y, 30, bodyHeight), item(row[2], x[2], y, 30, bodyHeight), item(row[3], x[3], y, 30, bodyHeight), item(row[4], x[4], y, 320, bodyHeight));
  }
  items.push(item(footer, 40.015750885009766, yValues[7], 200, 9));
  return { text: makeColumnMajorFallbackText(title, period, header, dataRows, footer), textItems: items };
}

const ja = makeTablePage(
  '第1四半期 営業実績（社内向け）',
  '対象期間：2026年度 第1四半期',
  ['指標', '実績', '計画', '進捗率', 'コメント'],
  [
    ['売上高（百万円）', '1,210', '1,200', '101%', '自動車部門は主要顧客の増産により計画を上回りました。'],
    ['営業利益（百万円）', '132', '125', '106%', '調達価格の安定により利益率が改善しました。'],
    ['サービス売上（百万円）', '286', '270', '106%', 'サービス売上は保守契約の更新により増加しました。'],
    ['新規案件（件）', '18', '18', '100%', '重点顧客への提案活動を継続します。']
  ],
  '社内確認用。数値は2026年5月12日時点。',
  [51.9761962890625, 100.42138671875, 127.63601684570312, 155.98239135742188, 207.00601196289062, 258.0296630859375, 309.05328369140625, 375.37408447265625],
  51.9761962890625,
  8.2705078125
);

const en = makeTablePage(
  'Q1 Sales Results (Internal Use)',
  'Period: FY2026 First Quarter',
  ['Metric', 'Actual', 'Plan', 'Progress', 'Comments'],
  [
    ['Net sales (JPY million)', '1,210', '1,200', '101%', 'The automotive business exceeded plan due to higher production by key customers.'],
    ['Operating profit (JPY million)', '132', '125', '106%', 'The profit margin improved as procurement prices stabilized.'],
    ['Service revenue (JPY million)', '286', '270', '106%', 'Service revenue increased due to maintenance contract renewals.'],
    ['New opportunities', '18', '18', '100%', 'We will continue proposal activities for priority customers.']
  ],
  'For internal review. Figures as of May 12, 2026.',
  [48.11614990234375, 98.68438720703125, 125.99551391601562, 154.34188842773438, 205.36550903320312, 256.38916015625, 307.41278076171875, 373.6370849609375],
  48.11614990234375,
  9.936492919921875
);

function jitterTableBody(page, bodyYs) {
  const offsets = [2, -2, 1, -1];
  return {
    text: page.text,
    textItems: page.textItems.map(function (entry) {
      const row = bodyYs.findIndex(function (y) { return Math.abs(entry.y - y) < 0.01; });
      if (row < 0) return { ...entry };
      return { ...entry, x: entry.x + offsets[row] };
    })
  };
}

const jaJitter = jitterTableBody(ja, [155.98239135742188, 207.00601196289062, 258.0296630859375, 309.05328369140625]);
const enJitter = jitterTableBody(en, [154.34188842773438, 205.36550903320312, 256.38916015625, 307.41278076171875]);

const fragmentPage = { text: en.text, textItems: en.textItems.map(function (entry) { return { ...entry }; }) };
const fragmentIndex = fragmentPage.textItems.findIndex(function (entry) {
  return entry.text === 'The automotive business exceeded plan due to higher production by key customers.';
});
if (fragmentIndex >= 0) {
  const fragmentY = fragmentPage.textItems[fragmentIndex].y;
  fragmentPage.textItems.splice(fragmentIndex, 1,
    item('The', 382.0078430175781, fragmentY, 16, 9.936492919921875),
    item('automotive', 385, fragmentY, 52, 9.936492919921875),
    item('business', 388, fragmentY, 42, 9.936492919921875),
    item('exceeded plan', 391, fragmentY, 70, 9.936492919921875),
    item('due to higher production by key customers.', 392, fragmentY, 210, 9.936492919921875)
  );
}

const proseRows = [
  ['Left paragraph one has enough text to be prose.', 'Right paragraph one has enough text to be prose.'],
  ['Left paragraph two remains in the first column.', 'Right paragraph two remains in the second column.'],
  ['Left paragraph three is not a table cell.', 'Right paragraph three is not a table cell.'],
  ['Left paragraph four closes the first column.', 'Right paragraph four closes the second column.']
];
const prose = {
  text: proseRows.map(row => row.join('    ')).join('\n'),
  textItems: proseRows.flatMap((row, index) => [item(row[0], 40, 60 + index * 30, 280, 10), item(row[1], 500, 60 + index * 30, 280, 10)])
};

// Mixed-page prose uses the outer table anchors so the existing whole-page
// column detector still has two columns to reconstruct after the table guard
// returns null.
const mixedProse = {
  text: proseRows.map(row => row[0]).concat(proseRows.map(row => row[1])).join('\n'),
  textItems: [
    item('Left paragraph one has enough', 60, 430, 95, 10), item('text to be prose.', 66, 430, 80, 10), item(proseRows[0][1], 420, 430, 180, 10),
    item(proseRows[1][0], 60, 460, 180, 10), item(proseRows[1][1], 420, 460, 180, 10),
    item(proseRows[2][0], 80, 490, 180, 10), item(proseRows[2][1], 440, 490, 180, 10),
    item(proseRows[3][0], 80, 520, 180, 10), item(proseRows[3][1], 440, 520, 180, 10)
  ]
};
const mixed = {
  text: ja.text + '\n' + mixedProse.text,
  textItems: ja.textItems.concat(mixedProse.textItems)
};

const singleColumnProse = {
  text: proseRows.map(row => row.join(' ')).join('\n'),
  textItems: proseRows.map((row, index) => item(row.join(' '), 40, 430 + index * 30, 520, 10))
};
const singleColumnWithTable = {
  text: ja.text + '\n' + singleColumnProse.text,
  textItems: ja.textItems.concat(singleColumnProse.textItems)
};

// The marker is present only in page.text.  A successful reconstruction must
// fail the 80% guard and return the original fallback, preserving it.
const fallbackMarker = 'FALLBACK_ONLY_MARKER_' + 'x'.repeat(600);
const fallbackPage = { text: ja.text + '\n' + fallbackMarker, textItems: ja.textItems.map(function (entry) { return { ...entry }; }) };

const gapRows = [100, 120, 140, 500, 520, 540].map(function (y, index) {
  return ['Gap row ' + (index + 1), String(index + 1), String((index + 1) * 10)];
});
const gapItems = [100, 120, 140, 500, 520, 540].flatMap(function (y, index) {
  return [item(gapRows[index][0], 40, y, 100, 8.3), item(gapRows[index][1], 200, y, 30, 8.3), item(gapRows[index][2], 360, y, 40, 8.3)];
});
const gapFallbackMarker = 'GAP_FALLBACK_ONLY';
const gapPage = {
  text: gapRows.map(row => row.join('  ')).concat([gapFallbackMarker]).join('\n'),
  textItems: gapItems
};

const multiRegionRows = [100, 120, 140, 180, 200, 220].map(function (y, index) {
  return ['Region row ' + (index + 1), String(index + 1), String((index + 1) * 10)];
});
const multiRegionItems = [100, 120, 140, 180, 200, 220].flatMap(function (y, index) {
  return [item(multiRegionRows[index][0], 40, y, 100, 8.3), item(multiRegionRows[index][1], 200, y, 30, 8.3), item(multiRegionRows[index][2], 360, y, 40, 8.3)];
});
multiRegionItems.push(item('separated region marker', 40, 160, 150, 8.3));
const multiRegionMarker = 'MULTI_REGION_FALLBACK_ONLY';
const multiRegionPage = {
  text: multiRegionRows.slice(0, 3).map(row => row.join('  ')).concat(['separated region marker'], multiRegionRows.slice(3).map(row => row.join('  ')), [multiRegionMarker]).join('\n'),
  textItems: multiRegionItems
};

const continuationFallbackText = [
  '第1四半期 営業実績（社内向け）',
  '対象期間：2026年度 第1四半期',
  '指標  実績  計画  進捗率  コメント',
  '売上高（百万円）  1,210  1,200  101%  自動車部門は主要顧客の増産により計画を上回りました。',
  '営業利益（百万円）  132  125  106%  調達価格の安定により利益率が改善しました。',
  'サービス売上（百万円）  286  270  106%  サービス売上は保守契約の更新により増加しました。',
  '新規案件（件）  18  18  100%  重点顧客への提案活動を継続します。 （注記の続き）',
  '社内確認用。数値は2026年5月12日時点。'
].join('\n');
const continuationPage = {
  text: continuationFallbackText,
  textItems: ja.textItems.concat([item('（注記の続き）', 382.0078430175781, 319.5, 100, 8.2705078125)])
};
const continuationFragmentsPage = {
  text: continuationFallbackText,
  textItems: ja.textItems.concat([
    item('（注記の', 382.0078430175781, 319.5, 45, 8.2705078125),
    item('続き）', 390, 319.5, 32, 8.2705078125)
  ])
};

function withoutWhitespace(value) { return String(value || '').replace(/\s/g, ''); }

const server = http.createServer((request, response) => {
  const requestPath = decodeURIComponent(String(request.url || '/').split('?')[0]);
  if (requestPath === '/' || requestPath === '/test.html') {
    response.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    response.end('<!doctype html><meta charset="utf-8"><title>pdf table test</title>');
    return;
  }
  if (!requestPath.startsWith('/assets/')) {
    response.writeHead(404); response.end(); return;
  }
  const relative = requestPath.slice('/assets/'.length).split(String.fromCharCode(92)).join('/');
  const target = path.resolve(assetRoot, relative);
  if (!target.startsWith(assetRoot + path.sep) || !fs.existsSync(target)) {
    response.writeHead(404); response.end(); return;
  }
  const type = target.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'application/octet-stream';
  response.writeHead(200, { 'Content-Type': type });
  fs.createReadStream(target).pipe(response);
});

function checkPage(actual, fixture, label, expectedRows) {
  const lines = String(actual || '').split(/\r?\n/).filter(line => line.trim());
  const failures = [];
  if (lines.length !== 8) failures.push(label + ': expected 8 logical lines, got ' + lines.length);
  for (let i = 0; i < expectedRows.length; i++) {
    const row = lines[i] || '';
    let cursor = 0;
    for (const cell of expectedRows[i]) {
      const position = row.indexOf(cell, cursor);
      if (position < 0) {
        failures.push(label + ': row ' + (i + 1) + ' is missing or misordered cell ' + cell);
      } else {
        cursor = position + cell.length;
      }
    }
  }
  if (withoutWhitespace(actual).length < withoutWhitespace(fixture.text).length * 0.8) failures.push(label + ': character yield fell below 80%');
  if (!lines.slice(2, 7).every(line => line.includes('  '))) failures.push(label + ': table cells are not separated by multiple spaces');
  return failures;
}

let browser;
let serverStarted = false;
try {
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  serverStarted = true;
  browser = await playwright.chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto('http://127.0.0.1:' + server.address().port + '/test.html', { waitUntil: 'domcontentloaded' });
  const actual = await page.evaluate(async ({ jaPage, enPage, jaJitterPage, enJitterPage, fragmentPage, prosePage, mixedPage, singleColumnPage, fallbackPage, gapPage, multiRegionPage, continuationPage, continuationFragmentsPage }) => {
    const module = await import('/assets/pdf-extract.js');
    return {
      ja: module.yakuPageTextByColumns(jaPage),
      en: module.yakuPageTextByColumns(enPage),
      jaJitter: module.yakuPageTextByColumns(jaJitterPage),
      enJitter: module.yakuPageTextByColumns(enJitterPage),
      fragment: module.yakuPageTextByColumns(fragmentPage),
      prose: module.yakuPageTextByColumns(prosePage),
      mixed: module.yakuPageTextByColumns(mixedPage),
      singleColumn: module.yakuPageTextByColumns(singleColumnPage),
      fallback: module.yakuPageTextByColumns(fallbackPage),
      gap: module.yakuPageTextByColumns(gapPage),
      multiRegion: module.yakuPageTextByColumns(multiRegionPage),
      continuation: module.yakuPageTextByColumns(continuationPage),
      continuationFragments: module.yakuPageTextByColumns(continuationFragmentsPage)
    };
  }, { jaPage: ja, enPage: en, jaJitterPage: jaJitter, enJitterPage: enJitter, fragmentPage: fragmentPage, prosePage: prose, mixedPage: mixed, singleColumnPage: singleColumnWithTable, fallbackPage: fallbackPage, gapPage: gapPage, multiRegionPage: multiRegionPage, continuationPage: continuationPage, continuationFragmentsPage: continuationFragmentsPage });

  const failures = [];
  const jaRows = [
    ['第1四半期 営業実績（社内向け）'], ['対象期間：2026年度 第1四半期'], ['指標', '実績', '計画', '進捗率', 'コメント'],
    ['売上高（百万円）', '1,210', '1,200', '101%', '自動車部門は主要顧客の増産により計画を上回りました。'],
    ['営業利益（百万円）', '132', '125', '106%', '調達価格の安定により利益率が改善しました。'],
    ['サービス売上（百万円）', '286', '270', '106%', 'サービス売上は保守契約の更新により増加しました。'],
    ['新規案件（件）', '18', '18', '100%', '重点顧客への提案活動を継続します。'], ['社内確認用。数値は2026年5月12日時点。']
  ];
  const enRows = [
    ['Q1 Sales Results (Internal Use)'], ['Period: FY2026 First Quarter'], ['Metric', 'Actual', 'Plan', 'Progress', 'Comments'],
    ['Net sales (JPY million)', '1,210', '1,200', '101%', 'The automotive business exceeded plan due to higher production by key customers.'],
    ['Operating profit (JPY million)', '132', '125', '106%', 'The profit margin improved as procurement prices stabilized.'],
    ['Service revenue (JPY million)', '286', '270', '106%', 'Service revenue increased due to maintenance contract renewals.'],
    ['New opportunities', '18', '18', '100%', 'We will continue proposal activities for priority customers.'], ['For internal review. Figures as of May 12, 2026.']
  ];
  failures.push(...checkPage(actual.ja, ja, 'Japanese table', jaRows));
  failures.push(...checkPage(actual.en, en, 'English table', enRows));
  failures.push(...checkPage(actual.jaJitter, ja, 'Japanese table with x jitter', jaRows));
  failures.push(...checkPage(actual.enJitter, en, 'English table with x jitter', enRows));
  failures.push(...checkPage(actual.fragment, en, 'English table with same-anchor fragments', enRows));
  const proseLines = String(actual.prose || '').split(/\r?\n/).filter(line => line.trim());
  if (proseLines.length !== 8) failures.push('two-column prose: expected the existing 8 column lines, got ' + proseLines.length);
  if (String(actual.prose).indexOf('Left paragraph four') > String(actual.prose).indexOf('Right paragraph one')) failures.push('two-column prose: reconstruction is not column-major');
  if (withoutWhitespace(actual.prose).length < withoutWhitespace(prose.text).length * 0.8) failures.push('two-column prose: character yield fell below 80%');
  if (String(actual.mixed).indexOf('Left paragraph two') > String(actual.mixed).indexOf('Right paragraph one')) failures.push('mixed page: table detection interleaved two-column prose rows');
  if (String(actual.mixed).indexOf('Left paragraph one') < 0 || String(actual.mixed).indexOf('Right paragraph two') < 0) failures.push('mixed page: prose outside table was lost');
  const singleColumnRows = String(actual.singleColumn).split(/\r?\n/).filter(line => line.trim());
  const singleColumnSales = singleColumnRows.filter(line => line.includes('売上高（百万円）'))[0] || '';
  if (!singleColumnSales.includes('1,210') || !singleColumnSales.includes('  ')) failures.push('single-column prose plus table: valid table was not kept eligible');
  if (!String(actual.fallback).includes(fallbackMarker)) failures.push('80% fallback: marker present only in fallback text was lost');
  if (String(actual.gap) !== gapPage.text || !String(actual.gap).includes(gapFallbackMarker)) failures.push('body-gap continuity: separated numeric regions did not return the exact fallback');
  if (String(actual.multiRegion) !== multiRegionPage.text || !String(actual.multiRegion).includes(multiRegionMarker)) failures.push('multiple numeric regions: non-geometry separator was not kept in the exact fallback');
  const continuationLines = String(actual.continuation).split(/\r?\n/).filter(line => line.trim());
  if (String(actual.continuation) !== continuationPage.text || continuationLines.length !== 8) failures.push('wrapped continuation: immediate final-column continuation did not return the exact 8-line fallback');
  const continuationFragmentLines = String(actual.continuationFragments).split(/\r?\n/).filter(line => line.trim());
  if (String(actual.continuationFragments) !== continuationFragmentsPage.text || continuationFragmentLines.length !== 8) failures.push('wrapped continuation fragments: split final-column continuation did not return the exact 8-line fallback');
  if (failures.length) {
    console.error('FAIL ' + failures.length + ' assertion(s)');
    for (const failure of failures) console.error('  ' + failure);
    process.exitCode = 1;
  } else {
    console.log('PASS PDF table alignment: JA/EN 8 rows, numeric body cells, prose fallback, and character yield.');
  }
} catch (error) {
  // A missing executable is an unmeasured gate, not a product failure.
  if (!browser || /executable|browserType\.launch|browser.*not found|ENOENT/i.test(String(error && error.message || error))) {
    console.log('UNMEASURED: Chromium could not be launched (' + String(error && error.message || error) + ')');
    process.exitCode = 3;
  } else {
    console.error('FAIL PDF table alignment test: ' + String(error && error.stack || error));
    process.exitCode = 1;
  }
} finally {
  try { if (browser) await browser.close(); } catch (_) {}
  if (serverStarted) await new Promise(resolve => server.close(resolve));
}
