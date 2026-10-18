// Owned HTTP CONNECT + destination TLS only. Never print bodies/headers/keys.
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, existsSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
if (!process.argv[2] || process.platform !== 'linux') throw Error('Usage: node proxy_mock.mjs <Zig test binary>');
const home = mkdtempSync(join(tmpdir(), 'thin-proxy-'));
const sockets = new Set(), servers = [], counts = new Map(), failures = [];
let child, watchdog, connects = 0, rejectedProxyRequests = 0, tlsTunnels = 0, handshakes = 0, interrupted = false;
const marker = join(home, 'delta-observed');
const track = s => { sockets.add(s); s.on('error', () => {}); s.once('close', () => sockets.delete(s)); return s; };
const fail = label => { if (failures.length < 16) failures.push(label); };
const kill = () => { if (child?.pid && child.exitCode === null && child.signalCode === null) { try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; } } };
const interrupt = () => { interrupted = true; kill(); for (const s of sockets) s.destroy(); };
process.on('SIGINT', interrupt); process.on('SIGTERM', interrupt);
async function listen(server) {
  servers.push(server); server.on('connection', track);
  await new Promise((ok, no) => { server.once('error', no); server.listen(0, '127.0.0.1', ok); });
  return server.address().port;
}
const frame = o => `data: ${JSON.stringify(o)}\n\n`;
const chat = (delta, finish_reason = null) => frame({ choices: [{ index: 0, delta, finish_reason }] });
const chatTail = () => chat({}, 'stop') + 'data: [DONE]\n\n';
function stream(protocol) {
  if (protocol === 'responses') return [frame({ type: 'response.output_item.added', output_index: 0, item: { id: 'msg_fixture', type: 'message', role: 'assistant' } }) + frame({ type: 'response.output_text.delta', output_index: 0, item_id: 'msg_fixture', delta: 'ok' }), frame({ type: 'response.completed', response: { status: 'completed', output: [{ id: 'msg_fixture', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'ok' }] }], usage: { input_tokens: 10, output_tokens: 2 } } })];
  if (protocol === 'anthropic') return [frame({ type: 'message_start', message: { id: 'msg_fixture', type: 'message', role: 'assistant', model: 'raw/id', content: [], stop_reason: null, usage: { input_tokens: 10, output_tokens: 0 } } }) + frame({ type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }) + frame({ type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'ok' } }), frame({ type: 'content_block_stop', index: 0 }) + frame({ type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 2 } }) + frame({ type: 'message_stop' })];
  return [chat({ content: 'ok' }), chatTail()];
}
function handler(req, res) {
  req.on('error', () => {}); res.on('error', () => {});
  const chunks = []; let size = 0;
  req.on('data', b => { size += b.length; if (size > 65536) { fail('body bound'); req.destroy(); } else chunks.push(b); });
  req.on('end', () => {
    let scenario = 'invalid';
    try {
      const m = /^\/([a-z-]+)\/(chat\/completions|responses|messages|systemone)$/.exec(req.url);
      assert(m); scenario = m[1];
      counts.set(scenario, (counts.get(scenario) ?? 0) + 1);
      assert.equal(req.method, 'POST');
      const body = JSON.parse(Buffer.concat(chunks));
      const native = m[2] === 'systemone', anthropic = m[2] === 'messages', judge = scenario.startsWith('judge-');
      assert.equal(req.headers['content-type'], 'application/json');
      if (anthropic) { assert.equal(req.headers['x-api-key'] === 'fake-proxy-key', true); assert.equal(req.headers['anthropic-version'], '2023-06-01'); }
      else assert.equal(req.headers.authorization === 'Bearer fake-proxy-key', true);
      assert.equal(body.model, native || judge ? 'jev' : 'raw/id');
      assert.equal(Boolean(req.socket.encrypted), !['alias-direct', 'decision-direct', 'judge-direct'].includes(scenario));
      if (native) {
        assert(body.questions.write && typeof body.state === 'string');
        res.writeHead(200, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ answers: { write: { type: 'noul', noul: 0.95 } }, usage: { input_tokens: 3, output_tokens: 1 } })); return;
      }
      assert.equal(body.stream, true);
      if (judge) {
        assert(!body.tools || body.tools.length === 0);
        res.writeHead(200, { 'content-type': 'text/event-stream' });
        res.end(chat({ content: '{"write":true}' }) + chatTail()); return;
      }
      assert(Array.isArray(body.tools) && body.tools.length === 1);
      assert.equal(req.headers.accept, 'text/event-stream');
      const protocol = anthropic ? 'anthropic' : m[2] === 'responses' ? 'responses' : 'chat';
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      res.flushHeaders();
      if (scenario === 'disconnect' || scenario === 'timeout') {
        res.write(chat({ tool_calls: [{ index: 0, id: 'call_partial', type: 'function', function: { name: 'lookup', arguments: '{' } }] }));
        if (scenario === 'disconnect') setTimeout(() => res.destroy(), 60).unref();
        return;
      }
      if (scenario === 'cancel') { res.write(chat({ content: 'arrived' })); return; }
      const [first, tail] = stream(protocol);
      res.write(first);
      if (scenario === 'chat' && counts.get(scenario) === 1) {
        // Tail is impossible until the *client sink* observed the first delta.
        const start = Date.now();
        const timer = setInterval(() => {
          if (existsSync(marker)) { clearInterval(timer); ++handshakes; res.end(tail); }
          else if (Date.now() - start > 3000 || res.destroyed) { clearInterval(timer); fail('streaming handshake missing'); res.destroy(); }
        }, 5);
        timer.unref(); res.once('close', () => clearInterval(timer));
      } else res.end(tail);
    } catch { fail(`wire-${scenario}`); res.writeHead(500); res.end(); }
  });
}
try {
  watchdog = setTimeout(() => { fail('watchdog'); interrupt(); }, 90000);
  const httpPort = await listen(http.createServer(handler));
  const cert = join(home, 'ca.pem'), key = join(home, 'key.pem'), wrongCert = join(home, 'wrong.pem');
  for (const [c, k] of [[cert, key], [wrongCert, join(home, 'wrong-key.pem')]]) execFileSync('/usr/bin/openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1', '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1', '-keyout', k, '-out', c], { env: { PATH: '/usr/bin:/bin', HOME: home, LANG: 'C' }, stdio: 'ignore', timeout: 10000 });
  const tls = https.createServer({ key: readFileSync(key), cert: readFileSync(cert) }, handler);
  tls.on('tlsClientError', () => {});
  const tlsPort = await listen(tls);
  const proxy = http.createServer((req, res) => {
    // HTTP targets use standard absolute-form forwarding, not CONNECT/TLS.
    // This owned negative proves the listed alias reaches the proxy, not origin.
    if (req.url === `http://127.0.0.1:${httpPort}/alias-direct/chat/completions`) ++rejectedProxyRequests;
    else fail('unowned-forward-proxy');
    req.resume(); res.writeHead(403); res.end();
  });
  proxy.on('connect', (req, downstream, head) => {
    ++connects;
    if (req.headers.authorization || req.headers['proxy-authorization']) fail('CONNECT-auth');
    if (req.url === `127.0.0.1:${httpPort}`) { ++rejectedProxyRequests; downstream.end('HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n'); return; }
    if (req.url !== `127.0.0.1:${tlsPort}` && req.url !== `localhost:${tlsPort}`) { fail('unowned-CONNECT'); downstream.destroy(); return; }
    const upstream = track(net.connect({ host: '127.0.0.1', port: tlsPort }));
    upstream.once('connect', () => {
      downstream.write('HTTP/1.1 200 Connection Established\r\n\r\n');
      let prefix = Buffer.alloc(0);
      const inspect = b => {
        prefix = Buffer.concat([prefix, b]);
        if (prefix.length < 3) return;
        downstream.off('data', inspect);
        if (prefix[0] !== 0x16 || prefix[1] !== 0x03) { fail('non-TLS-tunnel'); downstream.destroy(); upstream.destroy(); return; }
        ++tlsTunnels; upstream.write(prefix); downstream.pipe(upstream); upstream.pipe(downstream);
      };
      downstream.on('data', inspect); if (head.length) inspect(head);
    });
    downstream.once('close', () => upstream.destroy()); upstream.once('close', () => downstream.destroy());
  });
  const proxyPort = await listen(proxy);
  // Reserve an owned closed port for deterministic connection refusal.
  const down = net.createServer(); await new Promise(ok => down.listen(0, '127.0.0.1', ok));
  const downPort = down.address().port; await new Promise(ok => down.close(ok));
  child = spawn(resolve(process.argv[2]), [], { detached: true, stdio: ['ignore', 'inherit', 'inherit'], env: {
    PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', HOME: home,
    THIN_PROXY_HTTP: `http://127.0.0.1:${httpPort}`, THIN_PROXY_HTTPS: `https://127.0.0.1:${tlsPort}`,
    THIN_PROXY_MISMATCH: `https://localhost:${tlsPort}`, THIN_PROXY_PORT: String(proxyPort), THIN_PROXY_DOWN_PORT: String(downPort),
    THIN_PROXY_CA: cert, THIN_PROXY_WRONG_CA: wrongCert, THIN_PROXY_DELTA_MARKER: marker,
  } });
  const code = await new Promise((ok, no) => { child.once('error', no); child.once('close', (code, signal) => ok(signal ? 1 : code)); });
  child = undefined; // Already reaped: never signal its cached PID/PGID.
  console.log('proxy fixture counts:', JSON.stringify(Object.fromEntries([...counts].sort())), JSON.stringify({ connects, rejectedProxyRequests, tlsTunnels, handshakes, failures: failures.length }));
  const expected = { 'alias-direct': 1, anthropic: 2, chat: 2, 'decision-direct': 1, 'decision-listed': 1, 'judge-direct': 1, 'judge-listed': 1, disconnect: 1, responses: 2, timeout: 1, cancel: 1 };
  assert.deepEqual(Object.fromEntries([...counts].sort()), Object.fromEntries(Object.entries(expected).sort()), 'origin requests exactly once, negative TLS/down zero HTTP');
  assert.equal(connects, 13); // 6 normal + 2 TLS negatives + 3 partial + 2 decision backends; HTTP alias uses forward form.
  assert.equal(rejectedProxyRequests, 1); assert.equal(tlsTunnels, 13); assert.equal(handshakes, 1);
  assert.deepEqual(failures, []); assert.equal(interrupted, false); assert.equal(code, 0);
} finally {
  clearTimeout(watchdog); kill();
  for (const s of sockets) s.destroy();
  await Promise.all(servers.map(s => new Promise(ok => s.close(ok))));
  rmSync(home, { recursive: true, force: true });
  process.removeListener('SIGINT', interrupt); process.removeListener('SIGTERM', interrupt);
}
