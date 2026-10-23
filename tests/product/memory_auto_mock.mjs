// Owned-loopback CLI acceptance for automatic memory. Never loads user state.
import assert from 'node:assert/strict';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, readdir, stat, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const bin = resolve(process.argv[2]);
const root = await mkdtemp(join(tmpdir(), 'thin-memory-http-'));
const home = join(root, 'home'), project = join(root, 'project'), failureProject = join(root, 'failure-project');
const KEY = 'owned-loopback-memory-fixture-key';
const FIRST = 'I prefer concise explanations in code reviews.';
const FACT = 'Prefers concise explanations in code reviews.';
const ANSWER = 'memory-primary-answer';
const exists = p => access(p).then(() => true, () => false);
const requests = {primary: 0, helper: 0};
const sockets = new Set();
let active, fixtureFailed = false, answerBeforeHelper = 0, fragmentedHelpers = 0;

function reply(res, content, helper) {
  res.writeHead(200, {'content-type': 'text/event-stream'});
  let wireBytes = 0;
  const event = x => {
    const frame = `data: ${JSON.stringify(x)}\n\n`;
    wireBytes += Buffer.byteLength(frame);
    return res.write(frame);
  };
  if (helper && !active.bad) {
    // Legal empty reasoning deltas have no logical output tokens, but still
    // carry SSE/JSON framing. A small valid extraction must survive a stream
    // whose wire size exceeds the independent 32KiB decoded-JSON hard bound.
    assert(Buffer.byteLength(content) < 32768);
    for (let i = 0; i < 800; i++) event({choices: [{index: 0,
      delta: {reasoning_content: ''}, finish_reason: null}]});
    assert(wireBytes > 32768 && wireBytes < 256 * 1024);
    fragmentedHelpers++;
  }
  event({choices: [{index: 0, delta: {content}, finish_reason: null}]});
  event({choices: [{index: 0, delta: {}, finish_reason: 'stop'}], usage: {
    prompt_tokens: helper ? 300 : 1200, completion_tokens: helper ? 33 : 34,
    total_tokens: helper ? 333 : 1234,
  }});
  res.end('data: [DONE]\n\n');
}
async function waitFor(predicate) {
  const end = Date.now() + 3000;
  while (!predicate()) {
    assert(Date.now() < end, 'headless primary answer was held behind auxiliary drain');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}
const server = http.createServer(async (req, res) => {
  try {
    assert(active, 'request without owned child');
    assert.equal(req.url, '/v1/chat/completions');
    assert.equal(req.headers.authorization, `Bearer ${KEY}`);
    let bytes = 0, data = '';
    for await (const chunk of req) {
      bytes += chunk.length;
      assert(bytes <= 1024 * 1024, 'request byte bound');
      data += chunk;
    }
    const body = JSON.parse(data);
    const helper = body.messages.some(m => m.role === 'system' && typeof m.content === 'string' && m.content.startsWith('Extract only durable, reusable knowledge'));
    requests[helper ? 'helper' : 'primary']++;
    assert(requests.primary <= 5 && requests.helper <= 3, 'request count bound');
    if (!helper) {
      assert(!JSON.stringify(body.messages).includes(KEY), 'known key entered initial or task-local primary memory');
      assert(body.messages.some(m => m.role === 'user' && m.content === active.prompt), 'primary accepted prompt missing');
      if (active.expectFact) {
        assert(JSON.stringify(body.messages).includes(FACT), 'latest project memory absent from actual primary request');
        assert(JSON.stringify(body.messages).includes('Latest Memory reference'), 'task-local reference missing');
      }
      reply(res, ANSWER, false);
      return;
    }
    assert(!body.tools?.length, 'extractor must not receive tools');
    const material = JSON.parse(body.messages.findLast(m => m.role === 'user').content);
    assert.equal(material.sources.length, 1, 'assistant output must not become source');
    assert.equal(material.sources[0].kind, 'user');
    assert.equal(material.sources[0].text, active.prompt);
    assert(!JSON.stringify(material).includes(KEY), 'known credential entered material');
    assert(!JSON.stringify(material.sources).includes(ANSWER), 'assistant guess entered sources');
    // Deliberately withhold the helper response until stdout has the primary
    // answer. A drain-before-print regression must time out, not appear green.
    await waitFor(() => active.answerSeen);
    answerBeforeHelper++;
    const items = active.prompt === FIRST ? [{category: 'preferences', topic: 'review-style', content: FACT,
      source_id: material.sources[0].id, quote: 'prefer concise explanations', expected_version: null, expires_at_ms: null}] : [];
    reply(res, active.bad ? '{' : JSON.stringify({items}), true);
  } catch {
    fixtureFailed = true;
    if (!res.headersSent) res.writeHead(500);
    res.end('owned memory fixture failed');
  }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });

async function run(cwd, prompt, {expectFact = false, bad = false, args} = {}) {
  active = {prompt, expectFact, bad, answerSeen: false};
  const env = {PATH: '/usr/bin:/bin', HOME: home, LANG: 'C.UTF-8', TERM: 'xterm-256color'};
  const child = spawn(bin, args ?? ['--print', prompt, '--no-log'], {cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe']});
  let owned = true, size = 0, expired = false, rejectPending;
  const stdout = [], stderr = [];
  const kill = signal => { if (owned && child.pid) { try { process.kill(-child.pid, signal); } catch {} } };
  const timer = setTimeout(() => { expired = true; kill('SIGTERM'); }, 15000);
  const escalator = setTimeout(() => {
    kill('SIGKILL'); child.stdout.destroy(); child.stderr.destroy();
    rejectPending?.(new Error('owned memory child failed bounded shutdown'));
  }, 18000);
  child.stdout.on('data', chunk => {
    size += chunk.length;
    if (size > 256 * 1024) { expired = true; kill('SIGTERM'); return; }
    stdout.push(chunk);
    active.answerSeen = Buffer.concat(stdout).toString('utf8').includes(ANSWER);
  });
  child.stderr.on('data', chunk => {
    size += chunk.length;
    if (size > 256 * 1024) { expired = true; kill('SIGTERM'); return; }
    stderr.push(chunk);
  });
  child.once('exit', () => { owned = false; });
  try {
    const code = await new Promise((resolve, reject) => {
      rejectPending = reject;
      child.once('error', reject); child.once('close', resolve);
    });
    assert(!expired && code === 0, 'owned memory CLI exit failure');
    assert(!fixtureFailed, 'owned memory HTTP assertion failed');
    const out = Buffer.concat(stdout).toString('utf8'), err = Buffer.concat(stderr).toString('utf8');
    assert(!out.includes(KEY) && !err.includes(KEY), 'credential leaked to local output');
    if (!args) assert(out.includes(ANSWER), 'primary success lost to auxiliary failure');
    assert(!await exists(join(cwd, '.thin/sessions')), 'no-log created session records');
    assert(!await exists(join(cwd, '.thin/logs')), 'legacy logs created');
  } finally {
    clearTimeout(timer); clearTimeout(escalator); kill('SIGKILL');
    active = null;
  }
}
async function jobs(cwd) {
  const directory = join(cwd, '.thin/mem-jobs');
  assert.equal((await stat(directory)).mode & 0o777, 0o700);
  const result = [];
  for (const name of await readdir(directory)) {
    assert(/^[a-f0-9]{64}\.json$/.test(name), 'unexpected outbox file');
    const path = join(directory, name);
    assert.equal((await stat(path)).mode & 0o777, 0o600);
    const raw = await readFile(path, 'utf8');
    assert(!raw.includes(KEY), 'known credential persisted');
    result.push(JSON.parse(raw));
  }
  return result;
}

try {
  await mkdir(home); await mkdir(project); await mkdir(failureProject); await mkdir(join(home, '.thin'));
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const declaration = {llm: {default: 'owned/memory-fixture', providers: {owned: {
    base_url: `http://127.0.0.1:${server.address().port}/v1`, api_key: KEY,
    models: {'memory-fixture': {protocol: 'chat', context_tokens: 32768}},
  }}}, limits: {low_price_input: false,
    request_timeout_ms: 5000, task_timeout_ms: 15000}};
  const config = join(home, '.thin/config.json');
  const original = JSON.stringify(declaration);
  await writeFile(config, original, {mode: 0o600}); // Auto memory omitted: default On.
  await run(project, '', {args: ['--version']});
  assert.deepEqual(requests, {primary: 0, helper: 0});
  assert(!await exists(join(project, '.thin')), 'startup-only command touched project memory');
  await run(project, FIRST);
  assert.deepEqual(requests, {primary: 1, helper: 1});
  const saved = await readFile(join(project, '.thin/mem/preferences-review-style.md'), 'utf8');
  assert(saved.includes(FACT) && !saved.includes(KEY));
  assert((await jobs(project)).every(job => job.state === 'done' && job.material === null));
  assert.equal(await readFile(config, 'utf8'), original, 'active snapshot rewrote declaration');
  await run(project, 'Use my concise code review preference.', {expectFact: true});
  assert.deepEqual(requests, {primary: 2, helper: 2});
  declaration.memory = {auto: false};
  await writeFile(config, JSON.stringify(declaration));
  await run(project, 'Explain concise code reviews again.', {expectFact: true});
  assert.deepEqual(requests, {primary: 3, helper: 2}); // Off still retrieves locally.
  assert((await jobs(project)).every(job => job.state === 'done' && job.material === null));
  delete declaration.memory;
  await writeFile(config, JSON.stringify(declaration));
  // A local legacy core is not automatic evidence and must not bypass the
  // known-key guard by being frozen into the initial primary prefix.
  await mkdir(join(failureProject, '.thin/mem'), {recursive: true, mode: 0o700});
  await writeFile(join(failureProject, '.thin/mem/core.md'), `Legacy private core ${KEY}`, {mode: 0o600});
  const failedPrompt = 'I prefer careful explanations of code changes.';
  await run(failureProject, failedPrompt, {bad: true});
  assert.deepEqual(requests, {primary: 4, helper: 3});
  const uncertain = await jobs(failureProject);
  assert.equal(uncertain.length, 1);
  assert.equal(uncertain[0].state, 'uncertain');
  assert(uncertain[0].material.sources.length === 1);
  await run(failureProject, failedPrompt, {bad: true});
  assert.deepEqual(requests, {primary: 5, helper: 3}); // No automatic paid replay.
  assert.equal((await jobs(failureProject))[0].state, 'uncertain');
  assert.equal(answerBeforeHelper, 3);
  assert.equal(fragmentedHelpers, 2);
  await writeFile(join(root, 'evidence.json'), JSON.stringify({requests, answerBeforeHelper, fragmentedHelpers,
    defaultOn: true, offRetainsRetrieval: true, noLog: true, uncertainNotReplayed: true,
    wireBudgetIndependentOfDecodedJson: true}, null, 2) + '\n');
  console.log('PASS memory CLI default-On source/save/retrieve/Off/no-log/headless-drain/uncertain-no-replay primary=5 helper=3');
} finally {
  for (const socket of sockets) socket.destroy();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  // Keep only owned fixture evidence, including failures; no user paths read.
  console.log(`MEMORY_OWNED_FIXTURE_ROOT=${root}`);
}
