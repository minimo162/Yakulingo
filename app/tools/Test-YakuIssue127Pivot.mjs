import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const read = (...parts) => fs.readFileSync(path.join(app, ...parts), 'utf8');
const server = read('src', 'Server.ps1');
const cat = read('www', 'cat.html');
const catJs = read('www', 'assets', 'cat.js');
const quickJs = read('www', 'assets', 'quick-page.js');
const premiumJs = read('www', 'assets', 'premium-ui.js');
const design = read('DESIGN.md');
const failures = [];
const check = (value, message) => { if (!value) failures.push(message); };

// Contracts from #127 that were not revoked by the #129 text-first pivot.
check(server.includes("$path -eq '/api/cat/align-files'"), 'bilingual alignment endpoint is missing');
check(server.includes('Get-YakuFileTextBlocks'), 'bilingual file extraction is missing');
check(server.includes("@('revise','shorten','shorter','rephrase','heading','table')"), 'explicit rewrite allow-list changed');
check(cat.includes('id="cat-open-align-entry"'), 'bilingual import entry is missing');
check(cat.includes('id="premium-apply-summary"'), 'confirmed reapply summary is missing');
check(catJs.includes("'/api/cat/align-files'"), 'alignment client is not wired');
check(quickJs.includes('yakuQuickHandoff') && premiumJs.includes('consumeQuickReturn'), 'text/Excel handoff is missing');
check(!premiumJs.includes('column_width') && !premiumJs.includes('font_size'), 'layout metadata leaks into text translation');
check(design.includes('trust boundary') || design.includes('trust boundaries'), 'trust-boundary ownership is undocumented');

// Display-context optimization was explicitly withdrawn by #129.
check(!quickJs.includes('display_context'), 'withdrawn display context returned to text translation');
check(!server.includes("payload['display_context']"), 'server still consumes withdrawn display context');

if (failures.length) {
  failures.forEach((failure) => console.error(`not ok - ${failure}`));
  process.exit(1);
}
console.log('ok - retained Issue #127 contracts');
