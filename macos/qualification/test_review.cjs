const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const code = fs.readFileSync(__dirname + '/september8_review.js', 'utf8');
const origin = 'https://process-miner-74014979.hub.europe-west3.gcp.keboola.com';
function context({password = false, selected = true, host = origin, response, visibility = 'visible'} = {}) {
  const calls = [];
  const document = {
    visibilityState: visibility,
    querySelector: () => password ? {} : null,
    querySelectorAll: () => selected ? [{textContent: 'cap-01a0801f-21f6-7072-974c-4066a1e50a98'}] : [],
  };
  Object.defineProperty(document, 'cookie', {get() { throw Error('cookie access forbidden'); }});
  const ctx = vm.createContext({window: {}, document,
    location: {origin: host, hash: '#/area/process-mining/process/__unassigned__/governance'},
    URL, AbortController, setTimeout, clearTimeout, TextDecoder, Uint8Array,
    fetch: async (url, options) => { calls.push({url, options}); return response; },
  });
  return {ctx, calls};
}
test('password, wrong origin and wrong capture stop before a request', () => {
  for (const options of [{password: true}, {host: 'https://wrong.example'}, {selected: false}]) {
    const {ctx, calls} = context(options);
    assert.throws(() => vm.runInContext(code, ctx), /STOP/);
    assert.equal(calls.length, 0);
  }
});
test('login HTML never qualifies as JSON/media and never triggers retry', async () => {
  const {ctx, calls} = context({response: {status: 200, headers: new Headers({'Content-Type': 'text/html'}), body: {}}});
  vm.runInContext(code, ctx);
  await assert.rejects(ctx.window.jazzSeptember8Qualification.retrieve(), /STOP/);
  await assert.rejects(ctx.window.jazzSeptember8Qualification.retrieve(), /no automatic retry/);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.method, 'GET');
  assert.equal(calls[0].options.credentials, 'same-origin');
  assert.equal(calls[0].options.redirect, 'error');
  assert.equal(calls[0].options.cache, 'no-store');
});
test('oversize stream is cancelled and media requests never begin', async () => {
  let cancelled = false;
  const {ctx, calls} = context({response: {status: 200, headers: new Headers({'Content-Type': 'application/json'}),
    body: {getReader: () => ({read: async () => ({done: false, value: new Uint8Array(1048577)}), cancel: async () => { cancelled = true; }})}}});
  vm.runInContext(code, ctx);
  await assert.rejects(ctx.window.jazzSeptember8Qualification.retrieve(), /response limit/);
  assert.equal(cancelled, true); assert.equal(calls.length, 1);
});
test('hidden review cannot be mistaken for visible playback', async () => {
  const {ctx, calls} = context({visibility: 'hidden'}); vm.runInContext(code, ctx);
  await assert.rejects(ctx.window.jazzSeptember8Qualification.observePlayback(), /visible review tab/);
  assert.equal(calls.length, 0);
});
test('unverified media cannot be saved or observed as playback', async () => {
  const {ctx, calls} = context(); vm.runInContext(code, ctx);
  assert.throws(() => ctx.window.jazzSeptember8Qualification.save(0), /verified media/);
  await assert.rejects(ctx.window.jazzSeptember8Qualification.observePlayback(), /verify server bytes/);
  assert.equal(calls.length, 0);
});
