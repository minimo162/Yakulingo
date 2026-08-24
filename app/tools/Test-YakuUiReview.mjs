import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const reviewPath = path.join(app, 'www', 'assets', 'ui-review.css');
const premiumPath = path.join(app, 'www', 'assets', 'premium-ui.css');
const reviewBytes = fs.readFileSync(reviewPath);
const review = reviewBytes.toString('utf8');
const premium = fs.readFileSync(premiumPath, 'utf8');

assert.deepEqual(Array.from(reviewBytes.subarray(0, 3)), [0xEF, 0xBB, 0xBF], 'UI_REVIEW_CSS_BOM_MISSING');
assert.match(review, /focus-visible[\s\S]*outline:\s*3px solid var\(--yaku-ui-focus\)/, 'UI_REVIEW_FOCUS_RING_MISSING');
assert.match(review, /@media\s*\(max-width:\s*820px\)[\s\S]*safe-area-inset-bottom/, 'UI_REVIEW_MOBILE_SAFE_AREA_MISSING');
assert.match(review, /@media\s*\(prefers-reduced-motion:\s*reduce\)/, 'UI_REVIEW_REDUCED_MOTION_MISSING');
assert.match(review, /@media\s*\(forced-colors:\s*active\)/, 'UI_REVIEW_FORCED_COLORS_MISSING');
assert.doesNotMatch(review + premium, /(palette|premium-fit|cat-fit|inspector|publication|placement)/i, 'RETIRED_EXCEL_OR_PALETTE_STYLE_REMAINS');
assert.equal((review.match(/{/g) || []).length, (review.match(/}/g) || []).length, 'UI_REVIEW_CSS_BRACES_UNBALANCED');
assert.equal((premium.match(/{/g) || []).length, (premium.match(/}/g) || []).length, 'PREMIUM_CSS_BRACES_UNBALANCED');
assert.doesNotMatch(review, /url\(\s*['"]?https?:/i, 'UI_REVIEW_REMOTE_ASSET_NOT_ALLOWED');

console.log('ok - UI review contracts');
