import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, '..');
const html = fs.readFileSync(path.join(app, 'www', 'cat.html'), 'utf8');
const js = fs.readFileSync(path.join(app, 'www', 'assets', 'premium-ui.js'), 'utf8');
const css = fs.readFileSync(path.join(app, 'www', 'assets', 'premium-ui.css'), 'utf8');
const design = fs.readFileSync(path.join(app, 'DESIGN.md'), 'utf8');

const failures = [];
function expect(condition, message) { if (!condition) failures.push(message); }
function count(text, pattern) { return (text.match(pattern) || []).length; }

expect(count(html, /id="premium-file-input"/g) === 1, 'Excel start must expose exactly one primary file input');
expect(html.includes('<h1 id="premium-start-title">Excelを翻訳</h1>'), 'Excel-first start heading is missing');
expect(html.includes('Excelファイルをここにドロップ'), 'Excel drop instruction is missing');
expect(!html.includes('/assets/palette.js') && !html.includes('/assets/palette.css'), 'Palette UI must not be embedded in the Excel route');
expect(!html.includes('文章もExcelも、ひとつの画面で'), 'Combined text/Excel message must be removed');

expect(html.includes('id="premium-cell-list-pane"'), 'The single cell list must be explicit in cat.html');
expect(html.includes('data-premium-filter="untranslated"'), 'Untranslated filter is missing');
expect(html.includes('data-premium-filter="review"'), 'Review filter is missing');
expect(html.includes('data-premium-filter="all"'), 'All filter is missing');
expect(html.includes('id="premium-row-actions"'), 'Selected-cell action region must be explicit in cat.html');
expect(html.includes('id="premium-export"'), 'The single visible Excel export proxy is missing');

expect(!js.includes('3ステップで仕上げる'), 'Explanatory three-step navigation must not be generated');
expect(!js.includes('確認するセル'), 'A second permanent confirmation list must not be generated');
expect(!js.includes("create('section', 'premium-cat-start')"), 'The start DOM must not be reconstructed in JavaScript');
expect(js.includes("premiumState.catFilter = untranslated > 0 ? 'untranslated'"), 'Cell filter must follow live workbook state');
expect(js.includes("label.textContent = 'Excel表示を確認'"), 'A flagged cell must expose Excel display confirmation');

expect(css.includes('grid-template-columns: minmax(300px, 34%) minmax(0,1fr)'), 'Desktop workspace must use the two-pane layout');
expect(css.includes('@media (max-width: 1260px)'), 'The 1200px responsive contract is missing');
expect(css.includes('#cat-preview-dock:not([hidden])'), 'Preview must remain conditional rather than permanent');
expect(design.includes('YakuLingo is an Excel-first translation tool'), 'Product intent was not updated');

if (failures.length) {
  failures.forEach((failure) => console.error(`not ok - ${failure}`));
  process.exit(1);
}
console.log('ok - Excel-first UI contract');
