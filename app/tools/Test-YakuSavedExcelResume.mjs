import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const app = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const js = fs.readFileSync(path.join(app, 'www', 'assets', 'cat.js'), 'utf8');

function functionBody(name) {
  const marker = `function ${name}(`;
  const start = js.indexOf(marker);
  assert.notEqual(start, -1, `${name} is missing`);
  const open = js.indexOf('{', start);
  let depth = 1;
  for (let index = open + 1; index < js.length; index += 1) {
    if (js[index] === '{') depth += 1;
    if (js[index] === '}' && --depth === 0) return js.slice(open + 1, index);
  }
  throw new Error(`${name} has an unbalanced body`);
}

const render = functionBody('render');
const loadProject = functionBody('resume');
assert.match(render, /project\s*=\s*data/, 'saved project is not adopted');
assert.match(render, /renderRows\(\)/, 'saved project rows are not rendered');
assert.doesNotMatch(render, /renderInspector|cat-inspector-pane/, 'removed inspector still blocks row restore');
assert.match(loadProject, /post\('resume'/, 'saved-project load does not use the resume endpoint');
assert.match(loadProject, /render\(data/, 'saved-project load does not enter the row renderer');
assert.doesNotMatch(js, /function\s+renderInspector\s*\(/, 'removed inspector renderer remains');

console.log('ok - saved Excel resume renders rows without retired DOM');
