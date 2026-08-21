import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(toolsDir, '..');
const commonPath = path.join(appDir, 'www', 'assets', 'common.js');
const reviewCssPath = path.join(appDir, 'www', 'assets', 'ui-review.css');

const common = fs.readFileSync(commonPath, 'utf8');
const css = fs.readFileSync(reviewCssPath, 'utf8');

function mustMatch(text, pattern, code) {
  assert.match(text, pattern, code);
}

mustMatch(common, /function ensureUiReviewStyles\(\)/, 'UI_REVIEW_LOADER_MISSING');
mustMatch(common, /link\[data-yaku-ui-review\]/, 'UI_REVIEW_DUPLICATE_GUARD_MISSING');
mustMatch(common, /\/assets\/ui-review\.css\?v=20260822a/, 'UI_REVIEW_VERSIONED_STYLESHEET_MISSING');
mustMatch(common, /document\.head\.appendChild\(link\)/, 'UI_REVIEW_STYLESHEET_APPEND_MISSING');
assert.doesNotThrow(() => new Function(common), 'UI_REVIEW_COMMON_JAVASCRIPT_INVALID');

const contracts = [
  [/focus-visible[\s\S]*outline:\s*3px solid var\(--yaku-ui-focus\)/, 'UI_REVIEW_FOCUS_RING_MISSING'],
  [/premium-top-actions\s*>\s*a\[href="\/cat\?view=work"\][\s\S]*display:\s*none/, 'UI_REVIEW_DUPLICATE_WORK_LINK_VISIBLE'],
  [/premium-combined-chat[\s\S]*background:\s*var\(--premium-surface\)/, 'UI_REVIEW_CHAT_CARD_NOT_NEUTRAL'],
  [/premium-combined-excel[\s\S]*background:\s*var\(--premium-surface\)/, 'UI_REVIEW_EXCEL_CARD_NOT_NEUTRAL'],
  [/@media\s*\(max-width:\s*1120px\)[\s\S]*premium-combined-grid[\s\S]*grid-template-columns:\s*minmax\(0,\s*1fr\)/, 'UI_REVIEW_MID_WIDTH_STACK_MISSING'],
  [/@media\s*\(max-width:\s*820px\)[\s\S]*premium-sidebar[\s\S]*display:\s*block\s*!important/, 'UI_REVIEW_MOBILE_NAV_NOT_RESTORED'],
  [/@media\s*\(max-width:\s*820px\)[\s\S]*premium-sidebar\s*>\s*:not\(\.premium-nav\)[\s\S]*display:\s*none\s*!important/, 'UI_REVIEW_MOBILE_NAV_CHROME_NOT_PRUNED'],
  [/premium-sidebar\s+\.premium-nav[\s\S]*grid-template-columns:\s*repeat\(3,\s*minmax\(0,\s*1fr\)\)/, 'UI_REVIEW_MOBILE_NAV_NOT_THREE_WAY'],
  [/safe-area-inset-bottom/, 'UI_REVIEW_SAFE_AREA_MISSING'],
  [/@media\s*\(prefers-reduced-motion:\s*reduce\)/, 'UI_REVIEW_REDUCED_MOTION_MISSING'],
  [/@media\s*\(forced-colors:\s*active\)/, 'UI_REVIEW_FORCED_COLORS_MISSING']
];

for (const [pattern, code] of contracts) mustMatch(css, pattern, code);

assert.equal((css.match(/{/g) || []).length, (css.match(/}/g) || []).length, 'UI_REVIEW_CSS_BRACES_UNBALANCED');
assert.doesNotMatch(css, /url\(\s*['"]?https?:/i, 'UI_REVIEW_REMOTE_ASSET_NOT_ALLOWED');
assert.doesNotMatch(css, /@media\s*\(max-width:\s*820px\)\s*\{\s*body\.premium-ui\s*\{\s*padding-bottom:/, 'UI_REVIEW_MOBILE_BODY_PADDING_DUPLICATED');

console.log('YakuLingo UI review contracts: PASS');
