// Owned literal-127.0.0.1 Anthropic Messages HTTP integration; no API or private config reads.
// node tests/product/anthropic_mock.mjs <compiled src/anthropic_http_test_root.zig test binary>
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { isDeepStrictEqual } from 'node:util';

if (!process.argv[2] || process.platform !== 'linux') {
  console.error('Usage: node tests/product/anthropic_mock.mjs <Linux Zig test binary>');
  process.exit(2);
}
const home = mkdtempSync(`${tmpdir()}/thin-anthropic-local-`);
const sockets = new Set();
const counts = new Map();
const failures = new Set();
const expected = new Map([
  ['replay', 3], ['multi', 3], ['error401', 1], ['error429', 1], ['error500', 1],
  ['error404', 1], ['error-sse', 1], ['max_tokens', 1], ['pause_turn', 1],
  ['context_limit', 1], ['missing-stop', 1], ['malformed-delta', 1], ['invalid-json', 1],
  ['unsupported-block', 1], ['server-tool', 1], ['redirect', 1], ['timeout', 1], ['cancel', 1],
]);
let targetHits = 0, child, watchdog, interrupted = false;
// Only fixed labels are ever reported; never log caught assertion/request/body data.
function check(ok, label) { if (!ok) throw new Error(label); }
const same = (a, b, label) => check(isDeepStrictEqual(a, b), label);
const frame = value => `event: ${value.type}\r\ndata: ${JSON.stringify(value)}\r\n\r\n`;
const start = () => frame({ type: 'message_start', message: {
  id: 'msg_actual', type: 'message', role: 'assistant', model: 'fixture-model', content: [],
  stop_reason: null, stop_sequence: null,
  usage: { input_tokens: 10, cache_creation_input_tokens: 2, cache_read_input_tokens: 3, output_tokens: 0 },
} });
const blockStart = (index, content_block) => frame({ type: 'content_block_start', index, content_block });
const delta = (index, delta) => frame({ type: 'content_block_delta', index, delta });
const blockStop = index => frame({ type: 'content_block_stop', index });
// Current native responses include these nullable metadata fields even without container tools.
const finish = reason => frame({ type: 'message_delta', delta: { stop_reason: reason, stop_sequence: null, stop_details: null, container: null }, usage: { output_tokens: 4 } }) + frame({ type: 'message_stop' });
const nativePrefix = [
  { type: 'thinking', thinking: 'local plan', signature: 'fixture-signature-A+B/==' },
  { type: 'redacted_thinking', data: 'opaque-native-A+B/==' },
  { type: 'text', text: '你' },
];
const tool = (second = false) => ({ type: 'tool_use', id: second ? 'call_second' : 'call_actual', name: 'lookup', input: { q: second ? 'second' : '你' } });
function toolBlocks(multi = false) {
  let s = blockStart(0, { type: 'thinking', thinking: '', signature: '' }) +
    delta(0, { type: 'thinking_delta', thinking: 'local ' }) + delta(0, { type: 'thinking_delta', thinking: 'plan' }) +
    delta(0, { type: 'signature_delta', signature: 'replaced-fixture' }) + delta(0, { type: 'signature_delta', signature: 'fixture-signature-A+B/==' }) + blockStop(0) +
    blockStart(1, nativePrefix[1]) + blockStop(1) +
    blockStart(2, { type: 'text', text: '' }) + delta(2, { type: 'text_delta', text: '你' }) + blockStop(2);
  for (let n = 0; n < (multi ? 2 : 1); n++) {
    const index = n + 3, native = tool(n === 1);
    s += blockStart(index, { ...native, input: {} }) +
      delta(index, { type: 'input_json_delta', partial_json: '{"q":' }) +
      delta(index, { type: 'input_json_delta', partial_json: JSON.stringify(native.input.q) + '}' }) + blockStop(index);
  }
  return s;
}
function textStream() {
  return start() + blockStart(0, { type: 'text', text: '' }) + delta(0, { type: 'text_delta', text: 'done' }) + blockStop(0) + finish('end_turn');
}
function send(res, body, fragmented = false) {
  res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' });
  if (!fragmented) return res.end(body);
  const bytes = Buffer.from(body);
  let offset = 0;
  // One byte per tick guarantees splits inside UTF8, CRLF, JSON, signature and partial_json.
  const timer = setInterval(() => {
    if (offset === bytes.length) { clearInterval(timer); res.end(); }
    else res.write(bytes.subarray(offset, ++offset));
  }, 1);
  res.once('close', () => clearInterval(timer));
}
function checkWire(req, body, scenario, count) {
  check(req.method === 'POST', 'method');
  check(req.headers['x-api-key'] === 'fake-local-key', 'api-key');
  check(req.headers.authorization === undefined, 'authorization-forbidden');
  check(req.headers['anthropic-version'] === '2023-06-01', 'version');
  check(req.headers['user-agent'] === 'thin', 'user-agent');
  check(body.model === 'fixture-model' && body.stream === true && body.max_tokens === 128, 'model-stream-budget');
  check(body.system === 'fixed fixture system', 'separate-system');
  check(Array.isArray(body.messages) && !body.messages.some(m => m.role === 'system'), 'messages');
  same(body.tools, [{ name: 'lookup', description: 'Local fixture only', input_schema: {
    type: 'object', properties: { q: { type: 'string' } }, required: ['q'], additionalProperties: false,
  } }], 'tool-schema');
  const replay = scenario === 'replay' || scenario === 'multi';
  if (replay && count > 1) {
    const multi = scenario === 'multi';
    check(body.messages.length === 3, 'adjacent-result-group');
    const assistant = body.messages[1];
    check(assistant.role === 'assistant', 'assistant-role');
    same(assistant.content, [...nativePrefix, tool(), ...(multi ? [tool(true)] : [])], 'exact-native-replay');
    const result = body.messages[2];
    check(result.role === 'user' && result.content.length === (multi ? 2 : 1), 'user-tool-results');
    result.content.forEach((r, i) => {
      check(r.type === 'tool_result' && r.tool_use_id === (i ? 'call_second' : 'call_actual'), 'tool-result-id');
      // Anthropic permits either a string or a text-block array for tool_result content.
      check(r.content === (i ? 'second result' : 'fixture result') || isDeepStrictEqual(r.content, [{ type: 'text', text: i ? 'second result' : 'fixture result' }]), 'tool-result-content');
      check(i ? r.is_error === true : r.is_error === false || r.is_error === undefined, 'tool-result-error');
    });
    if (count === 3) same(body.tool_choice, { type: 'none' }, 'summary-tool-choice');
  }
}
const server = http.createServer(async (req, res) => {
  // Count all traffic, including accidental fallback and retry, before parsing bodies.
  if (req.url === '/redirect-target') { targetHits++; res.writeHead(500); res.end(); return; }
  const match = /^\/([a-z0-9_-]+)\/messages$/.exec(req.url ?? '');
  const scenario = match?.[1];
  if (!expected.has(scenario)) { failures.add('unexpected-route'); res.writeHead(400); res.end(); return; }
  const count = (counts.get(scenario) ?? 0) + 1;
  counts.set(scenario, count);
  try {
    let size = 0; const chunks = [];
    for await (const chunk of req) {
      size += chunk.length;
      check(size <= 65536, 'request-bound');
      chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    checkWire(req, body, scenario, count);
    if (scenario.startsWith('error') && scenario !== 'error-sse') {
      const status = Number(scenario.slice(5));
      const type = { 401: 'authentication_error', 429: 'rate_limit_error', 500: 'api_error', 404: 'not_found_error' }[status];
      res.writeHead(status, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ type: 'error', error: { type, message: 'local fixture error' } })); return;
    }
    if (scenario === 'redirect') {
      res.writeHead(307, { location: `http://127.0.0.1:${server.address().port}/redirect-target` }); res.end(); return;
    }
    if (scenario === 'timeout' || scenario === 'cancel') {
      res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write(start()); return;
    }
    if (scenario === 'replay' || scenario === 'multi') {
      send(res, count === 1 ? start() + toolBlocks(scenario === 'multi') + finish('tool_use') : textStream(), count === 1); return;
    }
    if (scenario === 'error-sse') {
      send(res, start() + frame({ type: 'error', error: { type: 'api_error', message: 'local fixture failure' } })); return;
    }
    if (scenario === 'unsupported-block' || scenario === 'server-tool') {
      const block = scenario === 'server-tool' ? { type: 'server_tool_use', id: 'server_call', name: 'web_search', input: {} } : { type: 'unknown_future_block', data: 'fixture' };
      send(res, start() + blockStart(0, block) + blockStop(0) + finish('end_turn')); return;
    }
    if (scenario === 'malformed-delta') {
      send(res, start() + blockStart(0, { ...tool(), input: {} }) + delta(0, { type: 'input_json_delta', partial_json: 42 }) + blockStop(0) + finish('tool_use')); return;
    }
    if (scenario === 'invalid-json') {
      send(res, start() + blockStart(0, { ...tool(), input: {} }) + delta(0, { type: 'input_json_delta', partial_json: '{"q":' }) + blockStop(0) + finish('tool_use')); return;
    }
    if (scenario === 'missing-stop') {
      send(res, start() + toolBlocks() + frame({ type: 'message_delta', delta: { stop_reason: 'tool_use', stop_sequence: null }, usage: { output_tokens: 4 } })); return;
    }
    send(res, start() + toolBlocks() + finish(scenario === 'context_limit' ? 'model_context_window_exceeded' : scenario));
  } catch {
    failures.add(`wire-or-handler:${scenario}`);
    if (!res.headersSent) res.writeHead(400);
    res.end();
  }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
server.on('clientError', (_error, socket) => socket.destroy());
function stop() { interrupted = true; child?.kill('SIGKILL'); for (const s of sockets) s.destroy(); }
process.once('SIGINT', stop);
process.once('SIGTERM', stop);
let exitCode = 1;
try {
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  child = spawn(resolve(process.argv[2]), [], {
    cwd: home,
    env: { PATH: '/usr/bin:/bin', HOME: home, XDG_CONFIG_HOME: home, XDG_CACHE_HOME: home, TMPDIR: home,
      LANG: 'C.UTF-8', THIN_FAKE_KEY: 'fake-local-key', THIN_ANTHROPIC_FIXTURE_URL: `http://127.0.0.1:${server.address().port}` },
    // Zig assertion operands can include native replay. Suppress child output entirely.
    stdio: ['ignore', 'ignore', 'ignore'],
  });
  watchdog = setTimeout(stop, 45000);
  const code = await new Promise(resolve => { child.once('error', () => resolve(null)); child.once('close', code => resolve(code)); });
  if (code !== 0) failures.add('test-binary-failed');
  if (interrupted) failures.add('interrupted-or-deadline');
  if (targetHits !== 0) failures.add('redirect-target-contacted');
  for (const [scenario, wanted] of expected) if ((counts.get(scenario) ?? 0) !== wanted) failures.add(`request-count:${scenario}`);
  if (failures.size) console.error(`Anthropic loopback FAIL: ${[...failures].join(', ')}`);
  else { console.log(`Anthropic loopback PASS: ${expected.size} scenarios, ${[...expected.values()].reduce((a, b) => a + b, 0)} POSTs, redirect target 0`); exitCode = 0; }
} catch { console.error('Anthropic loopback FAIL: runner'); }
finally {
  clearTimeout(watchdog);
  child?.kill('SIGKILL');
  for (const socket of sockets) socket.destroy();
  await new Promise(resolve => server.close(resolve));
  rmSync(home, { recursive: true, force: true });
  process.removeListener('SIGINT', stop);
  process.removeListener('SIGTERM', stop);
}
process.exitCode = exitCode;
