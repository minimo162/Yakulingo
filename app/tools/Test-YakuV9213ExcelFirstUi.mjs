import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, '..');
const cat = fs.readFileSync(path.join(app, 'www', 'cat.html'), 'utf8');
const quick = fs.readFileSync(path.join(app, 'www', 'quick.html'), 'utf8');
const quickJs = fs.readFileSync(path.join(app, 'www', 'assets', 'quick-page.js'), 'utf8');
const premiumJs = fs.readFileSync(path.join(app, 'www', 'assets', 'premium-ui.js'), 'utf8');
const premiumCss = fs.readFileSync(path.join(app, 'www', 'assets', 'premium-ui.css'), 'utf8');
const server = fs.readFileSync(path.join(app, 'src', 'Server.ps1'), 'utf8');
const design = fs.readFileSync(path.join(app, 'DESIGN.md'), 'utf8');

const failures = [];
const expect = (condition, message) => { if (!condition) failures.push(message); };
const count = (text, pattern) => (text.match(pattern) || []).length;

expect(count(cat, /id="premium-file-input"/g) === 1, 'Excel start must expose exactly one file input');
expect(cat.includes('<h1 id="premium-start-title">Excelを翻訳</h1>'), 'Excel start heading is missing');
expect(cat.includes('href="/quick">文章を翻訳</a>'), 'Excel header must link to quick translation');
expect(!cat.includes('id="quick-input"') && !cat.includes('/assets/quick.js'), 'Quick translation must not be embedded in Excel');
for (const legacy of ['class="shell"', 'class="hero"', 'class="tab-panel"', 'id="cat-doc-dialog"', 'id="cat-preview-dock"', 'id="cat-inspector-toggle"']) {
  expect(!cat.includes(legacy), `Legacy Excel surface remains: ${legacy}`);
}
expect(count(cat, /id="premium-cell-list-pane"/g) === 1, 'The cell list must be unique');
expect(cat.includes('id="premium-row-actions"'), 'Selected-cell actions must remain explicit');
expect(cat.includes('id="cat-preview-dialog"'), 'Excel display confirmation dialog must remain available');

expect(quick.includes('href="/quick" aria-current="page">文章を翻訳</a>'), 'Quick mode must be independently selected');
expect(quick.includes('id="quick-page-input"') && quick.includes('id="quick-page-output"'), 'Quick mode must have source and target panes');
expect(quick.includes('id="quick-page-submit"') && quick.includes('id="quick-page-copy"'), 'Quick translate and copy actions are missing');
expect(!quick.includes('premium-file-input') && !quick.includes('翻訳メモリ') && !quick.includes('点検一覧') && !quick.includes('最近の作業'), 'Quick mode must not carry Excel project state');
expect(quickJs.includes("'/api/palette/translate'") && quickJs.includes('YakuCommon.post(path,body)'), 'Quick mode must reuse the isolated transient backend');
expect(/ctrlKey\|\|[a-zA-Z]+\.metaKey/.test(quickJs), 'Quick mode must support Ctrl/Cmd+Enter');
expect(quickJs.includes("YakuCommon.post('/api/cancel-translation'"), 'Quick mode must support cancellation');

expect(server.includes("$path -in @('/', '/cat')"), 'Excel route must remain the default');
expect(server.includes("$path -in @('/quick', '/palette')"), 'Quick route and palette compatibility route must be separate');
expect(server.includes("PageName 'quick.html'"), 'Quick route must render quick.html');
expect(premiumJs.includes("var shell = el('excel-app')"), 'Premium Excel must bind to the explicit Excel root');
expect(!premiumJs.includes('function forcePreviewRail') && !premiumJs.includes('premium-legacy-hero'), 'Legacy mounting and forced inspector code must be removed');
expect(premiumCss.includes('@media(max-width:1200px)') || premiumCss.includes('@media (max-width: 1200px)'), '1200px mode switch contract is missing');
expect(design.includes('two first-class responsibilities'), 'Translation pivot intent is undocumented');

if (failures.length) {
  failures.forEach((failure) => console.error(`not ok - ${failure}`));
  process.exit(1);
}
console.log('ok - Excel-first and isolated quick translation contract');
