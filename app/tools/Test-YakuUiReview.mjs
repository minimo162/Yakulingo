import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const toolsDir = path.dirname(fileURLToPath(import.meta.url));
const appDir = path.resolve(toolsDir, '..');
const commonPath = path.join(appDir, 'www', 'assets', 'common.js');
const premiumCssPath = path.join(appDir, 'www', 'assets', 'premium-ui.css');
const premiumUiPath = path.join(appDir, 'www', 'assets', 'premium-ui.js');
const reviewCssPath = path.join(appDir, 'www', 'assets', 'ui-review.css');
const eolBaselinePath = path.join(appDir, 'tools', 'eol-baseline.txt');

const common = fs.readFileSync(commonPath, 'utf8');
const premiumCss = fs.readFileSync(premiumCssPath, 'utf8');
const premiumUi = fs.readFileSync(premiumUiPath, 'utf8');
const cssBytes = fs.readFileSync(reviewCssPath);
const css = cssBytes.toString('utf8');
const eolBaseline = fs.readFileSync(eolBaselinePath, 'utf8');

function mustMatch(text, pattern, code) {
  assert.match(text, pattern, code);
}

mustMatch(common, /function ensureUiReviewStyles\(\)/, 'UI_REVIEW_LOADER_MISSING');
mustMatch(common, /link\[data-yaku-ui-review\]/, 'UI_REVIEW_DUPLICATE_GUARD_MISSING');
mustMatch(common, /\/assets\/ui-review\.css\?v=20260822c/, 'UI_REVIEW_VERSIONED_STYLESHEET_MISSING');
mustMatch(common, /document\.head\.appendChild\(link\)/, 'UI_REVIEW_STYLESHEET_APPEND_MISSING');
assert.doesNotThrow(() => new Function(common), 'UI_REVIEW_COMMON_JAVASCRIPT_INVALID');

assert.deepEqual(Array.from(cssBytes.subarray(0, 3)), [0xEF, 0xBB, 0xBF], 'UI_REVIEW_CSS_BOM_MISSING');
assert.equal(cssBytes.includes(Buffer.from('\r\n')), false, 'UI_REVIEW_CSS_EOL_NOT_LF');
assert.equal(cssBytes.includes(Buffer.from('\n')), true, 'UI_REVIEW_CSS_EOL_MISSING');
mustMatch(eolBaseline, /^www\/assets\/ui-review\.css\tlf\r?$/m, 'UI_REVIEW_EOL_BASELINE_MISSING');
mustMatch(
  premiumCss,
  /:root\s*\{[^{}]*--premium-sidebar:\s*206px;/,
  'UI_REVIEW_BASE_SIDEBAR_WIDTH_MISSING'
);
mustMatch(
  premiumCss,
  /@media\s*\(max-width:\s*1260px\)\s*\{\s*:root\s*\{\s*--premium-sidebar:\s*208px;\s*\}/,
  'UI_REVIEW_RESPONSIVE_SIDEBAR_WIDTH_MISSING'
);
mustMatch(
  premiumUi,
  /<header class="premium-combined-heading">[\s\S]*?<h1>文章もExcelも、ひとつの画面で。<\/h1>/,
  'UI_REVIEW_START_H1_MISSING'
);

const startHeadingMatch = css.match(/body\.premium-cat \.premium-combined-heading\s*\{([^}]*)\}/);
assert.ok(startHeadingMatch, 'UI_REVIEW_START_HEADING_RULE_MISSING');
const startHeadingRule = startHeadingMatch[1];
mustMatch(startHeadingRule, /position:\s*absolute/, 'UI_REVIEW_START_HEADING_NOT_VISUALLY_HIDDEN');
mustMatch(startHeadingRule, /width:\s*1px/, 'UI_REVIEW_START_HEADING_WIDTH_NOT_COLLAPSED');
mustMatch(startHeadingRule, /height:\s*1px/, 'UI_REVIEW_START_HEADING_HEIGHT_NOT_COLLAPSED');
mustMatch(startHeadingRule, /clip:\s*rect\(0,\s*0,\s*0,\s*0\)/, 'UI_REVIEW_START_HEADING_CLIP_MISSING');
mustMatch(startHeadingRule, /clip-path:\s*inset\(50%\)/, 'UI_REVIEW_START_HEADING_CLIP_PATH_MISSING');
mustMatch(startHeadingRule, /white-space:\s*nowrap/, 'UI_REVIEW_START_HEADING_NOWRAP_MISSING');
assert.doesNotMatch(startHeadingRule, /display:\s*none/, 'UI_REVIEW_START_H1_REMOVED_FROM_ACCESSIBILITY_TREE');

const chatLabelMatch = css.match(/body\.premium-cat \.premium-combined-chat-live \.palette-label\s*\{([^}]*)\}/);
assert.ok(chatLabelMatch, 'UI_REVIEW_CHAT_LABEL_RULE_MISSING');
mustMatch(chatLabelMatch[1], /clip-path:\s*inset\(50%\)/, 'UI_REVIEW_CHAT_LABEL_CLIP_PATH_MISSING');
assert.doesNotMatch(css, /--premium-sidebar\s*:/, 'UI_REVIEW_SIDEBAR_OVERRIDE_PRESENT');

const contracts = [
  [/focus-visible[\s\S]*outline:\s*3px solid var\(--yaku-ui-focus\)/, 'UI_REVIEW_FOCUS_RING_MISSING'],
  [/premium-top-actions\s*>\s*a\[href="\/cat\?view=work"\][\s\S]*display:\s*none/, 'UI_REVIEW_DUPLICATE_WORK_LINK_VISIBLE'],
  [/premium-brand small[\s\S]*premium-nav-label[\s\S]*premium-nav-item small[\s\S]*display:\s*none/, 'UI_REVIEW_SIDEBAR_HELPER_COPY_VISIBLE'],
  [/premium-combined-panel\s*>\s*header \.premium-panel-number[\s\S]*premium-combined-panel\s*>\s*header \.premium-eyebrow[\s\S]*premium-combined-panel\s*>\s*header p[\s\S]*display:\s*none/, 'UI_REVIEW_START_DECORATION_VISIBLE'],
  [/premium-combined-chat[\s\S]*background:\s*var\(--premium-surface\)/, 'UI_REVIEW_CHAT_CARD_NOT_NEUTRAL'],
  [/premium-combined-excel[\s\S]*background:\s*var\(--premium-surface\)/, 'UI_REVIEW_EXCEL_CARD_NOT_NEUTRAL'],
  [/premium-combined-excel \.premium-excel-mark[\s\S]*premium-combined-excel \.premium-drop-tags[\s\S]*display:\s*none/, 'UI_REVIEW_EXCEL_DECORATION_VISIBLE'],
  [/palette-result:empty\s*\+\s*\.palette-footer[\s\S]*display:\s*none/, 'UI_REVIEW_EMPTY_CHAT_FOOTER_VISIBLE'],
  [/premium-combined-excel-options\s*>\s*section[\s\S]*border:\s*0[\s\S]*background:\s*transparent/, 'UI_REVIEW_NESTED_OPTION_CARDS_PRESENT'],
  [/premium-combined-excel-options p[\s\S]*display:\s*none/, 'UI_REVIEW_PAST_TRANSLATION_HELPER_COPY_VISIBLE'],
  [/premium-work-list-head \.premium-eyebrow[\s\S]*display:\s*none/, 'UI_REVIEW_WORKLIST_EYEBROW_VISIBLE'],
  [/premium-work-metrics[\s\S]*grid-template-columns:\s*repeat\(2,\s*minmax\(0,\s*1fr\)\)/, 'UI_REVIEW_WORK_METRICS_NOT_REDUCED'],
  [/premium-work-metrics\s*>\s*div:nth-child\(3\)[\s\S]*display:\s*none/, 'UI_REVIEW_PERCENT_TILE_VISIBLE'],
  [/premium-work-progress[\s\S]*height:\s*2px/, 'UI_REVIEW_PROGRESS_LINE_NOT_QUIET'],
  [/premium-fit-panel\s*>\s*header p[\s\S]*display:\s*none/, 'UI_REVIEW_REDUNDANT_FIT_COPY_VISIBLE'],
  [/@media\s*\(max-width:\s*1120px\)[\s\S]*premium-combined-grid[\s\S]*grid-template-columns:\s*minmax\(0,\s*1fr\)/, 'UI_REVIEW_MID_WIDTH_STACK_MISSING'],
  [/@media\s*\(max-width:\s*820px\)[\s\S]*--yaku-ui-mobile-nav-height:\s*140px/, 'UI_REVIEW_MOBILE_RECOVERY_SPACE_MISSING'],
  [/@media\s*\(max-width:\s*820px\)[\s\S]*premium-sidebar[\s\S]*display:\s*flex\s*!important/, 'UI_REVIEW_MOBILE_NAV_NOT_RESTORED'],
  [/@media\s*\(max-width:\s*820px\)[\s\S]*premium-sidebar\s*>\s*:not\(\.premium-nav\):not\(\.premium-sidebar-bottom\)[\s\S]*display:\s*none\s*!important/, 'UI_REVIEW_MOBILE_COPILOT_STRIP_PRUNED'],
  [/premium-sidebar\s+\.premium-sidebar-bottom[\s\S]*order:\s*-1[\s\S]*display:\s*block\s*!important/, 'UI_REVIEW_MOBILE_COPILOT_STRIP_MISSING'],
  [/premium-sidebar\s+#premium-copilot-slot[\s\S]*display:\s*flex/, 'UI_REVIEW_MOBILE_COPILOT_CONTROLS_HIDDEN'],
  [/premium-sidebar-bottom\s+\.status-detail:not\(\[hidden\]\)[\s\S]*-webkit-line-clamp:\s*2/, 'UI_REVIEW_MOBILE_COPILOT_DETAIL_MISSING'],
  [/premium-sidebar-bottom\s+\.link-button[\s\S]*min-height:\s*36px/, 'UI_REVIEW_MOBILE_COPILOT_ACTIONS_MISSING'],
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
