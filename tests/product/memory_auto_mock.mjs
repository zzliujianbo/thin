// Owned-loopback CLI acceptance for automatic memory. Never loads user state.
import assert from 'node:assert/strict';
import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const bin = resolve(process.argv[2]);
const root = await mkdtemp(join(tmpdir(), 'thin-memory-http-'));
const home = join(root, 'home'), project = join(root, 'project'), failureProject = join(root, 'failure-project'), cancelProject = join(root, 'cancel-project');
const KEY = 'owned-loopback-memory-fixture-key';
const FIRST = 'I prefer concise explanations in code reviews.';
const FACT = 'Prefers concise explanations in code reviews.';
const ANSWER = 'memory-primary-answer';
const exists = p => access(p).then(() => true, () => false);
const requests = {primary: 0, helper: 0};
const sockets = new Set();
let active, fixtureFailed = false, answerBeforeHelper = 0, fragmentedHelpers = 0;

function reply(res, content, helper, bad = false) {
  res.writeHead(200, {'content-type': 'text/event-stream'});
  let wireBytes = 0;
  const event = x => {
    const frame = `data: ${JSON.stringify(x)}\n\n`;
    wireBytes += Buffer.byteLength(frame);
    return res.write(frame);
  };
  if (helper && !bad) {
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
const server = http.createServer(async (req, res) => {
  try {
    const current = active;
    assert(current, 'request without owned child');
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
    assert(requests.primary <= 7 && requests.helper <= 5, 'request count bound');
    if (!helper) {
      assert(!JSON.stringify(body.messages).includes(KEY), 'known key entered initial or task-local primary memory');
      assert(body.messages.some(m => m.role === 'user' && m.content === current.prompt), 'primary accepted prompt missing');
      if (current.expectFact) {
        assert(JSON.stringify(body.messages).includes(FACT), 'latest project memory absent from actual primary request');
        assert(JSON.stringify(body.messages).includes('Latest Memory reference'), 'task-local reference missing');
      }
      if (current.interruptAt === 'primary') {
        // Primary request arrived but is unanswered: deliver SIGINT to the owned
        // child and never reply, so only real in-flight cancellation is exercised.
        // The request is left unanswered on purpose: the client cancels and closes
        // the socket, so no server-side disconnect can race the signal.
        current.interrupted = true;
        current.signalInterrupt();
        return;
      }
      reply(res, ANSWER, false);
      current.primaryStopped = true;
      return;
    }
    assert(!body.tools?.length, 'extractor must not receive tools');
    const material = JSON.parse(body.messages.findLast(m => m.role === 'user').content);
    assert.equal(material.sources.length, 1, 'assistant output must not become source');
    assert.equal(material.sources[0].kind, 'user');
    assert.equal(material.sources[0].text, current.prompt);
    assert(!JSON.stringify(material).includes(KEY), 'known credential entered material');
    assert(!JSON.stringify(material.sources).includes(ANSWER), 'assistant guess entered sources');
    if (current.interruptAt === 'helper') {
      // The primary round is already fully stopped when the auxiliary request
      // arrives; cancel only the auxiliary and never answer it. The terminal
      // state is auxiliary-interrupted, not a pretended helper response.
      assert(current.primaryStopped, 'helper interrupt requires a fully stopped primary round');
      current.interrupted = true;
      current.signalInterrupt();
      return;
    }
    // Keep the auxiliary request open briefly. Synchronous pre-settle Memory
    // must prevent the primary answer and process completion from appearing yet.
    await new Promise(resolve => setTimeout(resolve, 50));
    const items = current.prompt === FIRST ? [{category: 'preferences', topic: 'review-style', content: FACT,
      source_id: material.sources[0].id, quote: 'prefer concise explanations', expected_version: null, expires_at_ms: null}] : [];
    current.helperResponded = true;
    reply(res, current.bad ? '{' : JSON.stringify({items}), true, current.bad);
  } catch {
    fixtureFailed = true;
    if (!res.headersSent) res.writeHead(500);
    res.end('owned memory fixture failed');
  }
});
server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });

async function run(cwd, prompt, {expectFact = false, expectHelper = true, bad = false, interruptAt, expectExit = 0, expectAuxInterrupted = false, args} = {}) {
  active = {prompt, expectFact, expectHelper: expectHelper && !args, bad, interruptAt, expectExit,
    answerSeen: false, helperResponded: false, primaryStopped: false, interrupted: false,
    answerBeforeHelperObserved: false, signalInterrupt: null};
  const env = {PATH: '/usr/bin:/bin', HOME: home, LANG: 'C.UTF-8', TERM: 'xterm-256color'};
  const child = spawn(bin, args ?? ['--print', prompt, '--no-log'], {cwd, env, detached: true, stdio: ['ignore', 'pipe', 'pipe']});
  let owned = true, size = 0, expired = false, rejectPending;
  const stdout = [], stderr = [];
  const kill = signal => { if (owned && child.pid) { try { process.kill(-child.pid, signal); } catch {} } };
  // The fixture triggers interrupts only after the server has received the real
  // request, never from a timer. The owned child leads its own group.
  active.signalInterrupt = () => kill('SIGINT');
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
    // An auxiliarily canceled finalization is a distinct terminal state: the
    // primary answer may legitimately appear without any helper response.
    if (active.answerSeen && active.expectHelper && !active.helperResponded && !active.interrupted && !active.answerBeforeHelperObserved) {
      active.answerBeforeHelperObserved = true;
      answerBeforeHelper++;
    }
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
    assert(!expired, 'owned memory CLI did not finish before its bound');
    assert.equal(code, expectExit, `owned memory CLI exit mismatch (${interruptAt ?? 'normal'})`);
    assert(!fixtureFailed, 'owned memory HTTP assertion failed');
    const out = Buffer.concat(stdout).toString('utf8'), err = Buffer.concat(stderr).toString('utf8');
    assert(!out.includes(KEY) && !err.includes(KEY), 'credential leaked to local output');
    if (!args) {
      if (expectExit === 0) assert(out.includes(ANSWER), 'primary success lost to auxiliary failure');
      else assert(!out.includes(ANSWER), 'canceled primary printed an answer');
    }
    if (expectAuxInterrupted) assert(err.includes('auxiliary Memory finalization did not succeed'), 'auxiliary cancellation was not reported');
    assert(!await exists(join(cwd, '.thin/sessions')), 'no-log created session records');
    assert(!await exists(join(cwd, '.thin/logs')), 'legacy logs created');
  } finally {
    clearTimeout(timer); clearTimeout(escalator); kill('SIGKILL');
    active = null;
  }
}
async function assertNoJobs(cwd) {
  assert(!await exists(join(cwd, '.thin/memory/jobs')), 'retired Memory jobs directory recreated');
  assert(!await exists(join(cwd, '.thin/memory/jobs-owner')), 'retired Memory worker lease recreated');
  assert(!await exists(join(cwd, '.thin/mem-jobs')), 'legacy Memory jobs directory retained');
  assert(!await exists(join(cwd, '.thin/mem-jobs-owner')), 'legacy Memory worker lease retained');
}

try {
  await mkdir(home); await mkdir(project); await mkdir(failureProject); await mkdir(cancelProject); await mkdir(join(home, '.thin'));
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
  const saved = await readFile(join(project, '.thin/memory/preferences-review-style.md'), 'utf8');
  assert(saved.includes(FACT) && !saved.includes(KEY));
  await assertNoJobs(project);
  assert.equal(await readFile(config, 'utf8'), original, 'active snapshot rewrote declaration');
  await run(project, 'Use my concise code review preference.', {expectFact: true});
  assert.deepEqual(requests, {primary: 2, helper: 2});
  declaration.memory = {auto: false};
  await writeFile(config, JSON.stringify(declaration));
  await run(project, 'Explain concise code reviews again.', {expectFact: true, expectHelper: false});
  assert.deepEqual(requests, {primary: 3, helper: 2}); // Off still retrieves locally.
  await assertNoJobs(project);
  delete declaration.memory;
  await writeFile(config, JSON.stringify(declaration));
  // A local legacy core is not automatic evidence and must not bypass the
  // known-key guard by being frozen into the initial primary prefix.
  await mkdir(join(failureProject, '.thin/mem'), {recursive: true, mode: 0o700});
  await writeFile(join(failureProject, '.thin/mem/core.md'), `Legacy private core ${KEY}`, {mode: 0o600});
  const failedPrompt = 'I prefer careful explanations of code changes.';
  await run(failureProject, failedPrompt, {bad: true});
  assert.deepEqual(requests, {primary: 4, helper: 3});
  await assertNoJobs(failureProject);
  await run(failureProject, failedPrompt, {bad: true});
  assert.deepEqual(requests, {primary: 5, helper: 4}); // A new explicit task gets one fresh finalization attempt.
  await assertNoJobs(failureProject);
  // Auxiliary interrupt: the primary round is already fully stopped when the
  // helper request arrives, so only Memory is canceled. The primary answer must
  // survive with exit 0, an auxiliary warning, and no durable entry or retry.
  await run(cancelProject, FIRST, {interruptAt: 'helper', expectAuxInterrupted: true});
  assert.deepEqual(requests, {primary: 6, helper: 5});
  assert(!await exists(join(cancelProject, '.thin/memory/preferences-review-style.md')), 'canceled auxiliary wrote durable memory');
  await assertNoJobs(cancelProject);
  // Primary interrupt: the primary request is unanswered, so the task itself is
  // canceled (130) and the auxiliary is never entered for a second attempt.
  await run(cancelProject, FIRST, {interruptAt: 'primary', expectExit: 130});
  assert.deepEqual(requests, {primary: 7, helper: 5});
  assert(!await exists(join(cancelProject, '.thin/memory/preferences-review-style.md')), 'canceled primary wrote durable memory');
  await assertNoJobs(cancelProject);
  assert.equal(answerBeforeHelper, 0);
  assert.equal(fragmentedHelpers, 2);
  await writeFile(join(root, 'evidence.json'), JSON.stringify({requests, answerBeforeHelper, fragmentedHelpers,
    defaultOn: true, offRetainsRetrieval: true, noLog: true, synchronousPreSettle: true,
    noDurableJobs: true, oneAttemptPerExplicitTask: true,
    auxiliaryInterruptKeepsPrimarySuccess: true, primaryInterruptKeepsCanceledExit: true,
    noAuxiliaryReplayAfterInterrupt: true,
    wireBudgetIndependentOfDecodedJson: true}, null, 2) + '\n');
  console.log('PASS memory CLI synchronous pre-settle source/save/retrieve/Off/no-log/no-jobs/interrupt primary=7 helper=5');
} finally {
  for (const socket of sockets) socket.destroy();
  if (server.listening) await new Promise(resolve => server.close(resolve));
  // Keep only owned fixture evidence, including failures; no user paths read.
  console.log(`MEMORY_OWNED_FIXTURE_ROOT=${root}`);
}
