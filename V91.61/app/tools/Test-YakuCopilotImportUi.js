'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const catPath = path.join(root, 'www', 'assets', 'cat.js');
const pagePath = path.join(root, 'www', 'cat.html');
const stylesPath = path.join(root, 'www', 'assets', 'styles.css');
const catSource = fs.readFileSync(catPath, 'utf8').replace(/^\uFEFF/, '');
const pageSource = fs.readFileSync(pagePath, 'utf8').replace(/^\uFEFF/, '');
const stylesSource = fs.readFileSync(stylesPath, 'utf8').replace(/^\uFEFF/, '');

function sliceFunction(name, nextName) {
  const start = catSource.indexOf('  function ' + name + '(');
  const end = catSource.indexOf('  ' + nextName, start);
  assert.notEqual(start, -1, name + ' must remain in cat.js');
  assert.notEqual(end, -1, nextName + ' must remain after ' + name);
  return catSource.slice(start, end).trim();
}
const openSource = sliceFunction('openSource', 'function resume');

const events = [];
const sandbox = {
  Promise,
  setTimeout,
  clearTimeout,
  source() {
    events.push('source');
    return Promise.resolve({ file_handle: 'test-handle' });
  },
  setBusy(value) { events.push('busy:' + value); },
  setFileLoading(value) { events.push('loading:' + value); },
  status(value) { events.push('status:' + value); },
  post() { events.push('post'); return Promise.resolve({ id: 'project-1' }); },
  render() { events.push('render'); },
  handleDirection() { return false; },
  viewEpoch: 0,
  pendingDirection: null
};
vm.createContext(sandbox);
vm.runInContext('var viewEpoch = 0; var pendingDirection = null; ' + openSource + '; this.openSource = openSource;', sandbox, { filename: catPath });

(async () => {
  await sandbox.openSource('file', 'auto', { name: 'sample.xlsx' });
  assert.equal(events[0], 'loading:true', 'file loading indicator starts before the upload');
  assert.ok(events.indexOf('source') > events.indexOf('loading:true'), 'upload begins after the visible loading state');
  assert.equal(events.filter(value => value === 'loading:false').length, 1, 'success clears the file loading state');

  events.length = 0;
  sandbox.source = function () {
    events.push('source');
    return Promise.reject(new Error('read failed'));
  };
  await sandbox.openSource('file', 'auto', { name: 'broken.xlsx' });
  assert.equal(events[0], 'loading:true', 'error path also starts the visible loading state');
  assert.equal(events.filter(value => value === 'loading:false').length, 1, 'error clears the file loading state');
  assert.match(pageSource, /id="cat-file-loading"[^>]*role="status"/, 'page has a visible file-loading status region');
  assert.match(pageSource, /id="cat-file-loading"[^>]*aria-live="polite"/, 'file-loading status is announced politely');
  assert.match(stylesSource, /\.status-detail[^\r\n]*overflow-wrap\s*:\s*anywhere|overflow-wrap\s*:\s*anywhere[^\r\n]*\.status-detail/, 'Copilot detail wraps long text');
  console.log('PASS Test-YakuCopilotImportUi');
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
