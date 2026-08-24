import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const app = path.resolve(here, '..');
const read = (...parts) => fs.readFileSync(path.join(app, ...parts), 'utf8');
const cat = read('www', 'cat.html');
const quick = read('www', 'quick.html');
const quickJs = read('www', 'assets', 'quick-page.js');
const premiumJs = read('www', 'assets', 'premium-ui.js');
const server = read('src', 'Server.ps1');
const failures = [];
const expect = (condition, message) => { if (!condition) failures.push(message); };

// #129 revoked the old Excel-first root contract. Keep the still-supported
// separation between transient text translation and saved Excel work.
expect(server.includes("$path -in @('/', '/quick', '/palette')"), 'root must serve text translation');
expect(server.includes("$path -eq '/cat'"), 'Excel must remain on /cat');
expect(quick.includes('id="quick-page-input"') && quick.includes('id="quick-page-output"'), 'text source/target panes are missing');
expect(quickJs.includes("'/api/palette/translate'"), 'transient text backend is not isolated');
expect(cat.includes('id="premium-file-input"'), 'Excel file input is missing');
expect(cat.includes('id="premium-apply-summary"'), 'confirmed bilingual reapply summary is missing');
expect(cat.includes('id="premium-unresolved-count"'), 'unresolved-cell summary is missing');
expect(cat.includes('id="cat-export"'), 'Excel export is missing');
for (const removed of ['cat-preview-dialog', 'cat-inspector', 'cat-placement', 'cat-publication', 'premium-fit-panel']) {
  expect(!cat.includes(removed), `retired Excel surface remains: ${removed}`);
  expect(!premiumJs.includes(removed), `retired Excel behavior remains: ${removed}`);
}

if (failures.length) {
  failures.forEach((failure) => console.error(`not ok - ${failure}`));
  process.exit(1);
}
console.log('ok - text-first and limited Excel contract');
