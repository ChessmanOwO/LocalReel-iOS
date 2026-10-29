// Run with Node 18+: node Tests/check-capture.cjs
// This validates the exact injected JavaScript, not an iOS/WebKit runtime.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../Shared/VideoResolver.swift'), 'utf8');
const script = source.match(/static let captureScript = #"""\n([\s\S]*?)\n    """#/)[1];
const tick = () => new Promise(resolve => setTimeout(resolve, 30));
let body = '{"video_url":"https://cdn.example/video.mp4"}';
let contentType = 'application/json';
let xhrSent = 0;
class XHR {
  constructor() { this.callbacks = []; this.responseType = ''; }
  addEventListener(name, callback) { this.callbacks.push(callback); }
  send() { xhrSent++; for (const callback of this.callbacks) callback(); }
}
const window = {fetch: async () => new Response(body, {headers: {'content-type': contentType}})};
const context = vm.createContext({window, XMLHttpRequest: XHR, TextDecoder, Number});
vm.runInContext(script, context);
(async () => {
  // Chunked/unknown content length is common: it must be read without requiring a play click.
  const response = await window.fetch('https://www.instagram.com/');
  assert.equal(await response.text(), body, 'page fetch remains readable');
  await tick();
  assert.equal(window.__localreelPayloads.length, 1);
  await window.fetch('https://www.instagram.com/'); await tick();
  assert.equal(window.__localreelPayloads.length, 1, 'deduplicates payloads');
  body = 'video_url' + 'x'.repeat(2_000_001);
  await window.fetch('https://www.instagram.com/'); await tick();
  assert.equal(window.__localreelPayloads.length, 1, 'rejects oversized streamed response');
  body = 'not video metadata';
  await window.fetch('https://www.instagram.com/'); await tick();
  assert.equal(window.__localreelPayloads.length, 1, 'ignores noise');
  contentType = 'video/mp4'; body = 'video_url binary';
  await window.fetch('https://www.instagram.com/'); await tick();
  assert.equal(window.__localreelPayloads.length, 1, 'does not copy video response bodies');
  for (let i = 0; i < 10; i++) {
    const xhr = new XHR(); xhr.responseText = JSON.stringify({playAddr: `https://cdn.example/${i}.mp4`}); xhr.send();
  }
  assert.equal(xhrSent, 10, 'does not block original XHR');
  assert.equal(window.__localreelPayloads.length, 6, 'bounded payload count');
  const copy = window.__localreelPayloads; copy.length = 0;
  assert.equal(window.__localreelPayloads.length, 6, 'snapshot does not mutate private buffer');
  assert.ok(!/\.play\s*\(/.test(script), 'does not invoke playback');
  const root = path.join(__dirname, '..');
  const ui = fs.readFileSync(path.join(root, 'App/ContentView.swift'), 'utf8');
  assert.ok(!ui.includes('SourceBrowser(') && !ui.includes('Mở trang nguồn'));
  assert.ok(fs.readFileSync(path.join(root, 'App/AppModel.swift'), 'utf8').includes('resolver.resolveAutomatically(initial.sourceURL)'));
  assert.ok(fs.readFileSync(path.join(root, 'ShareExtension/ShareViewController.swift'), 'utf8').includes('VideoResolver().resolveAutomatically(source)'));
  console.log('PASS: 13 capture and automatic-flow assertions; JavaScript/Node only, NOT an iOS build or live-source test.');
})().catch(error => { console.error(error); process.exitCode = 1; });
