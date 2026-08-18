'use strict';

/*
 * Regression test for the CAT start-screen drop path.
 *
 * The browser code is deliberately evaluated from cat.js rather than copied
 * into this test: a tiny DOM/event harness supplies only the dependencies of
 * bindFileDrop, source, openSource, and the existing desktop handoff event.
 * This keeps the test runnable with the stock Node.js installation and still
 * exercises the production functions.
 */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const catPath = path.join(__dirname, '..', 'www', 'assets', 'cat.js');
const catSource = fs.readFileSync(catPath, 'utf8').replace(/^\uFEFF/, '');

function functionSlice(name, nextName) {
  const start = catSource.indexOf('  function ' + name + '(');
  const end = catSource.indexOf('  ' + nextName, start);
  assert.notEqual(start, -1, `${name} must remain in cat.js`);
  assert.notEqual(end, -1, `${nextName} must remain after ${name}`);
  return catSource.slice(start, end).trim();
}

const sourceFunction = functionSlice('source', 'function openSource');
const openSourceFunction = functionSlice('openSource', 'function resume').replace(
  /^(function openSource\([^\n]+\) \{\n)/,
  '$1    __openSourceCalls += 1;\n'
);
const bindFileDropFunction = functionSlice('bindFileDrop', 'var filterSeq');
const bindInstantFunction = functionSlice('bindInstant', 'function start');

class FakeNode {
  constructor() {
    this.listeners = new Map();
    this.classList = { add() {}, remove() {} };
    this.value = '';
    this.files = [];
  }

  addEventListener(name, handler) {
    const handlers = this.listeners.get(name) || [];
    handlers.push(handler);
    this.listeners.set(name, handlers);
  }

  dispatch(name, event) {
    const handlers = this.listeners.get(name);
    assert.ok(handlers && handlers.length, `drop handler for ${name} must be registered`);
    let result;
    for (const handler of handlers) result = handler(event);
    return result;
  }
}

const drop = new FakeNode();
const input = new FakeNode();
const uploadFiles = [];
const posts = [];
const rendered = [];
let directionRetry = null;
let uploaded = null;
let viewEpoch = 0;
let pendingDirection = null;

const sandbox = {
  console,
  Promise,
  setTimeout,
  clearTimeout,
  uploaded,
  viewEpoch,
  pendingDirection,
  YakuCommon: {
    maxUploadBytes: 10 * 1024 * 1024,
    upload(_url, file) {
      uploadFiles.push(file);
      return Promise.resolve({ file_handle: 'handle-1' });
    }
  },
  el(id) {
    assert.equal(id, 'cat-file-input');
    return input;
  },
  setBusy() {},
  setFileLoading() {},
  status() {},
  render(data) { rendered.push(data); },
  post(action, body) {
    posts.push({ action, body });
    if (posts.length === 1) {
      return Promise.reject({
        status: 409,
        data: { code: 'DIRECTION_CONFIRMATION_REQUIRED', error: 'choose direction' }
      });
    }
    return Promise.resolve({ id: 'project-1' });
  },
  handleDirection(error, retry) {
    if (error.status !== 409 || !error.data || error.data.code !== 'DIRECTION_CONFIRMATION_REQUIRED') return false;
    directionRetry = retry;
    return true;
  }
};

vm.createContext(sandbox);
vm.runInContext(`
  var uploaded = null;
  var viewEpoch = 0;
  var pendingDirection = null;
  var __openSourceCalls = 0;
  ${sourceFunction}
  ${openSourceFunction}
  ${bindFileDropFunction}
  this.bindFileDrop = bindFileDrop;
  this.openSource = openSource;
`, sandbox, { filename: catPath });

/* DesktopIntegration has historically dispatched yaku-instant-handoff with
 * detail.filePath.  Keep this as a real event dispatch: the assertion below
 * must observe the normalized path at the single openSource('file') route,
 * rather than merely finding the event name in source text. */
const handoffInput = new FakeNode();
const handoffWindow = {
  listeners: new Map(),
  addEventListener(name, handler) {
    const handlers = this.listeners.get(name) || [];
    handlers.push(handler);
    this.listeners.set(name, handlers);
  },
  dispatch(name, event) {
    const handlers = this.listeners.get(name) || [];
    for (const handler of handlers) handler(event);
  }
};
const handoffSandbox = {
  console,
  window: handoffWindow,
  __handoffInput: handoffInput
};
vm.createContext(handoffSandbox);
vm.runInContext(`
  var directFilePath = '';
  var __handoffCalls = [];
  var __pickerCalls = 0;
  var __status = {};
  function el(id) {
    if (id === 'cat-file-input') return __handoffInput;
    if (id === 'cat-workspace') return { hidden: true };
    throw new Error('unexpected element: ' + id);
  }
  function showPicker() { directFilePath = ''; __pickerCalls += 1; }
  function status(message, isError) { __status = { message: message, error: !!isError }; }
  function openSource(mode, intent) { __handoffCalls.push({ mode: mode, intent: intent, path: directFilePath }); }
  ${bindInstantFunction}
  this.bindInstant = bindInstant;
`, handoffSandbox, { filename: catPath });
handoffSandbox.bindInstant();

const file = { name: 'sample.docx', size: 42, lastModified: 1234 };
sandbox.bindFileDrop(drop, input);
let prevented = 0;
let stopped = 0;
drop.dispatch('drop', {
  dataTransfer: { files: [file] },
  preventDefault() { prevented += 1; },
  stopPropagation() { stopped += 1; }
});

function tick() {
  return new Promise(resolve => setImmediate(resolve));
}

(async () => {
  handoffWindow.dispatch('yaku-instant-handoff', {
    detail: { filePath: '  "C:\\Users\\yuuki\\Desktop\\desktop.docx"  ' }
  });
  await tick();
  assert.equal(handoffSandbox.__pickerCalls, 1, 'desktop file handoff returns to the single picker once');
  assert.equal(handoffSandbox.__handoffCalls.length, 1, 'desktop filePath reaches openSource file route once');
  assert.equal(handoffSandbox.__handoffCalls[0].mode, 'file', 'desktop filePath selects the file route');
  assert.equal(handoffSandbox.__handoffCalls[0].intent, 'auto', 'desktop filePath keeps automatic direction intent');
  assert.equal(handoffSandbox.__handoffCalls[0].path, 'C:\\Users\\yuuki\\Desktop\\desktop.docx', 'desktop filePath is normalized before the route');
  assert.equal(handoffInput.value, '', 'desktop file handoff clears the browser file input');
  handoffWindow.dispatch('yaku-instant-handoff', {
    detail: { filePath: 'C:\\bad' + String.fromCharCode(0) + '\\path.docx' }
  });
  await tick();
  assert.equal(handoffSandbox.__handoffCalls.length, 1, 'invalid desktop path does not open a second route');
  assert.equal(handoffSandbox.__status.error, true, 'invalid desktop path is rejected before transport');

  await tick();
  await tick();
  assert.equal(prevented, 1, 'one drop must be handled once');
  assert.equal(stopped, 1, 'the drop must not bubble into another upload handler');
  assert.equal(sandbox.__openSourceCalls, 1, 'one drop must invoke openSource exactly once');
  assert.equal(posts.length, 1, 'one drop must start exactly one open request before direction confirmation');
  assert.equal(uploadFiles.length, 1, 'one drop must upload exactly once');
  assert.strictEqual(uploadFiles[0], file, 'the dropped File object must be passed directly to upload');
  assert.ok(directionRetry, 'direction confirmation must retain a retry callback');

  await directionRetry('to_en');
  await tick();
  await tick();
  assert.equal(sandbox.__openSourceCalls, 2, 'direction confirmation must add only its one intentional retry');
  assert.equal(posts.length, 2, 'direction confirmation must retry the open request once');
  assert.equal(posts[1].body.direction_intent, 'to_en', 'the retry must use the chosen direction');
  assert.equal(posts[1].body.file_handle, 'handle-1', 'the retry must reuse the uploaded file handle');
  assert.equal(uploadFiles.length, 1, 'direction retry must not upload the same File again');
  assert.equal(rendered.length, 1, 'the successful retry must render one project');
  console.log('PASS Test-CatFileDrop');
})().catch(error => {
  console.error(error.stack || error);
  process.exitCode = 1;
});
