#!/usr/bin/env node
// Owned-loopback product acceptance for the subagent Runtime with running-time
// bidirectional parent/child interaction (subagent-interaction contract).
// Run from the repo root: node tests/product/subagent_mock.mjs /absolute/path/thin
//
// Everything is an owned fixture: a temporary HOME/project, a literal
// 127.0.0.1 server, an inline fake key and bounded child process groups. No
// real API, no user configuration, no credentials, no installs, no network.
//
// Fixed tool surface under test (names are the contract, ids are dynamic):
//   parent: subagent, get_subagent_result, send_subagent_message, cancel_subagent
//   child : message_parent (and no memory/subagent/comm tools)
// Parent tool JSON: start {id,status}; get {id,status,messages[{message,
// requires_reply}],progress} plus the legacy terminal report/usage/detail/
// truncated fields at the same level; send/cancel return bounded receipts.
//
// Request choreography per case (root/child model requests):
//   chat-subagent-qna        R: start, get(wait)=waiting, write_file(denied),
//                               bash(denied), send(reply), get(wait)=success, answer
//                            C: ask(wait), read_file, report
//   chat-subagent-steering   R: start, get(wait=false), send(steering),
//                               get(wait)=progress, get(wait)=success, answer
//                            C: held request -> old-plan write_file skipped,
//                               steered request (paired skip result + steering
//                               in the same history) -> progress message, report
//   chat-subagent-cancel     R: start, get(wait)=waiting, cancel, answer
//                            C: ask(wait) and never answered
//   chat-legacy-false        R: start, get(wait)=success, answer
//                            C: report  (config carried the old subagent.enabled:false)
//   chat-subagent-unknown-id R: start, get(wait)=success,
//                               get/send/cancel(foreign id)=rejected, answer
//                            C: report
//   responses/anthropic-     R: start, get(wait)=success, answer
//     subagent-direct         C: report
//   child-dangerous-bash     R: start, get(wait)=success (approval proxied+denied), answer
//                            C: dangerous bash, report
//
// The fake root model never invents ids: every get/send/cancel argument is
// built from the parsed previous tool result. No hardcoded id format and no
// get-polling storm: waiting uses the blocking wait=true path, and the one
// non-blocking snapshot exists only to prove the steering-while-in-flight case.

import http from 'node:http';
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {randomUUID} from 'node:crypto';
import {mkdtemp, mkdir, writeFile, readFile, readdir, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

if (!process.argv[2] || process.platform !== 'linux') {
  console.error('usage: node tests/product/subagent_mock.mjs /absolute/path/thin');
  process.exit(2);
}
const bin = resolve(process.argv[2]);

const KEY = 'owned-loopback-subagent-fixture-key';
const PARENT_PRIVATE = 'PARENT-PRIVATE-MARKER-9c1f';
const PARENT_PROMPT = `parent-task ${PARENT_PRIVATE} keep this out of the child`;
const CHILD_TASK = 'child-task-marker inspect the probe file';
const CHILD_CONTEXT = 'child-context-marker-only-reference';
const CHILD_QUESTION = 'child-question-marker which probe value should the report use';
const PARENT_REPLY = 'parent-reply-marker use the probe value you read';
const PROGRESS_TEXT = 'child-progress-marker still inspecting the probe file';
const STEER_TASK = 'child-task-marker progress and parent steering over one file';
const STEER_TEXT = 'parent-steering-marker also confirm the probe file content';
const CANCEL_TASK = 'child-task-marker cancel while the child asks';
const CANCEL_QUESTION = 'child-question-marker waiting to be canceled by the parent';
const CHILD_REPORT = 'child final report: probe file content was read';
const ROOT_ANSWER = 'parent-final-answer-marker';
const UNKNOWN_ID_PREFIX = 'unknown-job-';
const CHILD_READ_NAME = 'read_file';
const CHILD_BASH_NAME = 'bash';
const PROBE_FILE = 'child-probe.txt';
const PROBE_CONTENT = 'child-probe-content-marker';
const SENTINEL = 'sentinel-must-survive';
const MODEL = 'subagent-fixture';
const OUTPUT_TOKENS = 256; // declared output capability, never a request cap
const ROOT_TOOLS = ['read_file', 'write_file', 'bash', 'memory',
  'subagent', 'get_subagent_result', 'send_subagent_message', 'cancel_subagent'];
const CHILD_TOOLS = ['read_file', 'write_file', 'bash', 'message_parent'];
const STATUSES = ['running', 'waiting_for_reply', 'success', 'failed', 'canceled', 'paused'];
const endpoint = {chat: '/v1/chat/completions', responses: '/v1/responses', anthropic: '/v1/messages'};
const MAX_BODY = 1024 * 1024;
const OUTPUT_BOUND = 256 * 1024;
const exists = path => access(path).then(() => true, () => false);

const sockets = new Set();
let workspace = null, server = null, url = null, active = null, fixtureFailed = false;

// ---------------------------------------------------------------------------
// Wire helpers
// ---------------------------------------------------------------------------

function readBody(req) {
  return (async () => {
    const chunks = [];
    let bytes = 0;
    for await (const chunk of req) {
      bytes += chunk.length;
      assert(bytes <= MAX_BODY, 'request byte bound');
      chunks.push(chunk);
    }
    return Buffer.concat(chunks).toString('utf8');
  })();
}

function toolNames(protocol, body) {
  const tools = Array.isArray(body.tools) ? body.tools : [];
  return tools.map(tool => protocol === 'chat' ? tool?.function?.name : tool?.name);
}

// Canonical call/result history, independent of the three wire encodings.
function toolHistory(protocol, body) {
  const calls = [], results = new Map();
  if (protocol === 'chat') {
    for (const m of body.messages ?? []) {
      for (const call of m.tool_calls ?? [])
        calls.push({id: call.id, name: call.function?.name, arguments: call.function?.arguments});
      if (m.role === 'tool') results.set(m.tool_call_id, m.content);
    }
  } else if (protocol === 'responses') {
    for (const item of body.input ?? []) {
      if (item.type === 'function_call') calls.push({id: item.call_id, name: item.name, arguments: item.arguments});
      else if (item.type === 'function_call_output') results.set(item.call_id, item.output);
    }
  } else {
    for (const m of body.messages ?? []) {
      if (!Array.isArray(m.content)) continue;
      for (const block of m.content) {
        if (block.type === 'tool_use') calls.push({id: block.id, name: block.name, arguments: JSON.stringify(block.input ?? {})});
        else if (block.type === 'tool_result') results.set(block.tool_use_id,
          Array.isArray(block.content) ? block.content.map(part => part.text ?? '').join('') : block.content);
      }
    }
  }
  return {calls, results};
}

// Only real user turns: tool results and other roles stay out.
function userTexts(protocol, body) {
  const out = [];
  const push = value => {
    if (typeof value === 'string') out.push(value);
    else if (Array.isArray(value))
      for (const part of value) if (part && typeof part.text === 'string') out.push(part.text);
  };
  if (protocol === 'chat') {
    for (const m of body.messages ?? []) if (m?.role === 'user') push(m.content);
  } else if (protocol === 'responses') {
    for (const item of body.input ?? [])
      if (item?.role === 'user' && item.type !== 'function_call_output') push(item.content);
  } else {
    for (const m of body.messages ?? [])
      if (m?.role === 'user' && Array.isArray(m.content))
        for (const block of m.content) if (block?.type === 'text') push(block.text);
  }
  return out;
}

function occurrences(text, marker) {
  return String(text).split(marker).length - 1;
}

function lastCall(history, name) {
  for (let i = history.calls.length - 1; i >= 0; i -= 1) if (history.calls[i].name === name) return history.calls[i];
  return null;
}

function callText(history, name) {
  const call = lastCall(history, name);
  assert(call, `missing ${name} call in canonical history`);
  assert(history.results.has(call.id), `missing ${name} tool result`);
  const text = history.results.get(call.id);
  assert.equal(typeof text, 'string', `${name} result must be tool text`);
  return text;
}

function callJson(history, name) {
  const text = callText(history, name);
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch {
    assert.fail(`${name} result must be a single JSON object, got ${JSON.stringify(text.slice(0, 64))}`);
  }
  assert(parsed && typeof parsed === 'object' && !Array.isArray(parsed), `${name} result must be a JSON object`);
  return parsed;
}

function assertPaired(history) {
  const ids = new Set();
  for (const call of history.calls) {
    assert(!ids.has(call.id), 'duplicate tool call id in one canonical history');
    ids.add(call.id);
    assert(history.results.has(call.id), `unpaired tool result for ${call.name}`);
  }
  for (const id of history.results.keys()) assert(ids.has(id), 'tool result without a call');
}

// start must be the immediate receipt. Extra safe metadata is allowed; only
// the required {id,status:"running"} fields are contractual.
function startResult(history) {
  const start = callJson(history, 'subagent');
  assert.equal(typeof start.id, 'string', 'start id must be a string');
  assert(start.id.length > 0 && Buffer.byteLength(start.id) <= 64, 'start id must be bounded');
  assert(!start.id.includes('\0'), 'start id must be NUL-free');
  assert.equal(start.status, 'running', 'start must report the running status');
  return start;
}

// Every get snapshot keeps the live fields; terminal fields stay at the same level.
function getResult(history) {
  const snap = callJson(history, 'get_subagent_result');
  assert.equal(typeof snap.id, 'string', 'get result must echo an id');
  assert(STATUSES.includes(snap.status), `unknown status ${snap.status}`);
  assert(Array.isArray(snap.messages), 'get result must carry a messages snapshot');
  for (const message of snap.messages) {
    assert.deepEqual(Object.keys(message).sort(), ['message', 'requires_reply'], 'message shape');
    assert.equal(typeof message.message, 'string', 'message text must be a string');
    assert(!message.message.includes('\0'), 'message text must be NUL-free');
    assert.equal(typeof message.requires_reply, 'boolean', 'requires_reply must be boolean');
  }
  assert(Object.hasOwn(snap, 'progress'), 'get result must carry a progress field');
  assert(snap.progress === null || typeof snap.progress === 'string', 'progress must be bounded text or null');
  return snap;
}

function sendReceipt(history, expectedId) {
  const receipt = callJson(history, 'send_subagent_message');
  assert(Object.keys(receipt).length > 0, 'send receipt must not be empty');
  assert(!Object.hasOwn(receipt, 'report'), 'send receipt must not carry a report');
  if (Object.hasOwn(receipt, 'id')) assert.equal(receipt.id, expectedId, 'send receipt must echo the started id');
  if (Object.hasOwn(receipt, 'delivered')) assert.equal(receipt.delivered, true, 'send receipt must confirm delivery');
  return receipt;
}

// Closed/unknown ids are explicit errors, never an empty success snapshot.
function assertRejected(label, text) {
  assert.equal(typeof text, 'string', `${label} must be tool text`);
  assert(text.length > 0 && text.length <= 2048, `${label} error text must be bounded`);
  assert(!text.includes(CHILD_REPORT), `${label} returned a child report`);
  assert(!text.includes(PARENT_REPLY), `${label} returned the parent reply`);
  let parsed = null;
  try {
    parsed = JSON.parse(text);
  } catch {}
  // Either an encoded failure snapshot (no report) or a bare error name.
  const explicit = typeof parsed === 'string'
    ? /^[A-Za-z][A-Za-z0-9_]*$/.test(parsed)
    : parsed && typeof parsed === 'object' && !Array.isArray(parsed)
      ? parsed.status === 'failed' && !parsed.report
      : /^[A-Za-z][A-Za-z0-9_]*$/.test(text);
  assert(explicit, `${label} must be an explicit error, got ${JSON.stringify(text.slice(0, 96))}`);
}

function assertTerminal(plan, snap) {
  assert.equal(snap.status, 'success', 'terminal status');
  assert.equal(snap.id, plan.childId, 'terminal snapshot id');
  assert.equal(typeof snap.report, 'string', 'terminal report must stay a string (no double encoding)');
  assert.equal(snap.report, CHILD_REPORT, 'terminal report passthrough');
  assert.equal(snap.truncated, false, 'terminal truncated flag');
  assert.equal(snap.cleanup_failed, false, 'terminal cleanup flag');
  assert.equal(snap.detail, null, 'terminal detail flag');
  assert.equal(snap.usage_scope, 'normal_and_summary_only', 'usage scope');
  assert.equal(snap.auxiliary_usage_excluded, true, 'auxiliary usage exclusion');
  const usage = snap.usage;
  assert(usage && typeof usage === 'object', 'terminal usage object');
  assert.equal(usage.normal_calls, plan.childCalls, 'normal call count');
  assert.equal(usage.summary_calls, 0, 'summary calls must stay separate');
  assert.equal(usage.normal.input_tokens, plan.childInput, 'normal input usage');
  assert.equal(usage.normal.output_tokens, plan.childOutput, 'normal output usage');
  assert.equal(usage.summary.input_tokens, null, 'summary usage must stay unknown');
}

function sendChat(res, replyValue, usage) {
  res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
  const event = value => res.write(`data: ${JSON.stringify(value)}\n\n`);
  const delta = replyValue.type === 'tool'
    ? {tool_calls: [{index: 0, id: replyValue.id, type: 'function',
        function: {name: replyValue.name, arguments: JSON.stringify(replyValue.args)}}]}
    : {content: replyValue.text};
  event({id: 'chat_subagent_fixture', choices: [{index: 0, delta, finish_reason: null}]});
  event({id: 'chat_subagent_fixture', choices: [{index: 0, delta: {},
    finish_reason: replyValue.type === 'tool' ? 'tool_calls' : 'stop'}]});
  event({id: 'chat_subagent_fixture', choices: [], usage: {
    prompt_tokens: usage.input, completion_tokens: usage.output, total_tokens: usage.input + usage.output,
    prompt_tokens_details: {cached_tokens: 0, cache_write_tokens: 0}, completion_tokens_details: {reasoning_tokens: 0},
  }});
  res.end('data: [DONE]\n\n');
}

function sendResponses(res, replyValue, usage) {
  res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});
  const output = replyValue.type === 'tool'
    ? [{id: `item_${replyValue.id}`, type: 'function_call', call_id: replyValue.id, name: replyValue.name,
        arguments: JSON.stringify(replyValue.args), status: 'completed'}]
    : [{id: 'message_subagent_fixture', type: 'message', role: 'assistant',
        content: [{type: 'output_text', text: replyValue.text}], status: 'completed'}];
  res.write(`data: ${JSON.stringify({type: 'response.completed', response: {
    id: 'response_subagent_fixture', status: 'completed', output,
    usage: {input_tokens: usage.input, output_tokens: usage.output, total_tokens: usage.input + usage.output,
      input_tokens_details: {cached_tokens: 0}, output_tokens_details: {reasoning_tokens: 0}},
  }})}\n\n`);
  res.end();
}

function sendAnthropic(res, replyValue, usage) {
  const frame = value => `event: ${value.type}\r\ndata: ${JSON.stringify(value)}\r\n\r\n`;
  res.writeHead(200, {'content-type': 'text/event-stream; charset=utf-8'});
  let body = frame({type: 'message_start', message: {id: 'msg_subagent_fixture', type: 'message', role: 'assistant',
    model: MODEL, content: [], stop_reason: null, stop_sequence: null,
    usage: {input_tokens: usage.input, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 0}}});
  if (replyValue.type === 'tool') {
    body += frame({type: 'content_block_start', index: 0,
      content_block: {type: 'tool_use', id: replyValue.id, name: replyValue.name, input: {}}});
    body += frame({type: 'content_block_delta', index: 0,
      delta: {type: 'input_json_delta', partial_json: JSON.stringify(replyValue.args)}});
  } else {
    body += frame({type: 'content_block_start', index: 0, content_block: {type: 'text', text: ''}});
    body += frame({type: 'content_block_delta', index: 0, delta: {type: 'text_delta', text: replyValue.text}});
  }
  body += frame({type: 'content_block_stop', index: 0});
  body += frame({type: 'message_delta', usage: {output_tokens: usage.output}, delta: {
    stop_reason: replyValue.type === 'tool' ? 'tool_use' : 'end_turn',
    stop_sequence: null, stop_details: null, container: null}});
  body += frame({type: 'message_stop'});
  res.end(body);
}

function sendReplies(protocol, res, value, usage) {
  if (protocol === 'chat') sendChat(res, value, usage);
  else if (protocol === 'responses') sendResponses(res, value, usage);
  else sendAnthropic(res, value, usage);
}

// ---------------------------------------------------------------------------
// Owned signals for the deterministic request barriers
// ---------------------------------------------------------------------------

function waitSignal(plan, key) {
  const existing = plan.signals.get(key);
  if (existing) return existing.promise;
  const deferred = {};
  deferred.promise = new Promise(resolveValue => { deferred.resolve = resolveValue; });
  plan.signals.set(key, deferred);
  return deferred.promise;
}

function fireSignal(plan, key) {
  const existing = plan.signals.get(key);
  if (existing) existing.resolve();
  else plan.signals.set(key, {promise: Promise.resolve(), resolve: () => {}});
}

// ---------------------------------------------------------------------------
// Per-request validation
// ---------------------------------------------------------------------------

function validateStage(plan, stage, role, body, tools, raw, history, ctx) {
  assert.equal(body.stream, true, 'all model requests must stream');
  assert.equal(body.model, MODEL, 'request model identity');
  const summary = plan.protocol === 'anthropic' ? body.tool_choice?.type === 'none' : body.tool_choice === 'none';
  assert(!summary, 'this fixture never expects a summary/compaction request');
  assert(!raw.includes('Extract only durable, reusable knowledge'), 'Memory extraction request leaked into the run');
  if (plan.protocol === 'anthropic') {
    // Messages requires the frozen declared capability; never a retired cap.
    assert.equal(body.max_tokens, OUTPUT_TOKENS, 'Anthropic must send only the declared output capability');
    assert(!Object.hasOwn(body, 'max_output_tokens'), 'retired max_output_tokens setting was sent');
    assert(!Object.hasOwn(body, 'max_completion_tokens'), 'foreign output cap was sent');
  } else {
    for (const key of ['max_tokens', 'max_completion_tokens', 'max_output_tokens'])
      assert(!Object.hasOwn(body, key), `chat/responses must not send ${key}`);
  }
  if (role === 'child') {
    assert.deepEqual([...tools].sort(), [...CHILD_TOOLS].sort(), 'child tool surface must be files/bash/message_parent only');
    assert(raw.includes(plan.childTask), 'delegated task missing from the child request');
    if (plan.childContext) assert(raw.includes(plan.childContext), 'delegated context missing from the child request');
    assert(!raw.includes(PARENT_PRIVATE), 'parent private marker entered the child request');
    assert(!raw.includes(ROOT_ANSWER), 'parent final answer entered the child request');
    assert(!raw.includes('"signature"') && !raw.includes('"encrypted_content"') && !raw.includes('PARENT-SIGNED-REASONING'),
      'signed or opaque parent reasoning entered the child request');
    for (const id of plan.parentCallIds) assert(!raw.includes(id), 'parent tool call id entered the child request');
  } else {
    assert.deepEqual([...tools].sort(), [...ROOT_TOOLS].sort(), 'root tool surface must expose the four parent tools');
    for (const id of plan.childCallIds) assert(!raw.includes(id), 'child tool call id leaked into the parent request');
  }
  assertPaired(history);
  if (stage.expectedCalls)
    assert.deepEqual(history.calls.map(call => call.name), stage.expectedCalls, 'canonical tool call sequence');
  if (stage.check) stage.check(ctx);
}

// ---------------------------------------------------------------------------
// Owned loopback server
// ---------------------------------------------------------------------------

server = http.createServer(async (req, res) => {
  try {
    const plan = active;
    assert(plan, 'request without an owned run');
    assert.equal(req.url, endpoint[plan.protocol], 'endpoint must match the declared protocol');
    if (plan.protocol === 'anthropic') {
      assert.equal(req.headers['x-api-key'], KEY, 'Anthropic key header');
      assert.equal(req.headers['anthropic-version'], '2023-06-01', 'Anthropic version header');
      assert.equal(req.headers.authorization, undefined, 'Anthropic must not send a bearer header');
    } else {
      assert.equal(req.headers.authorization, `Bearer ${KEY}`, 'bearer key header');
    }
    const raw = await readBody(req);
    const body = JSON.parse(raw);
    const tools = toolNames(plan.protocol, body);
    const history = toolHistory(plan.protocol, body);
    // Role identity comes from the fixed tool sets, never from prompt text.
    const role = tools.includes('message_parent') ? 'child' : 'root';
    assert(role === 'child' ? !tools.includes('get_subagent_result') : true, 'ambiguous request role');
    const stage = plan.stages[role][plan.seq[role]];
    assert(stage, `unexpected extra ${role} model request`);
    plan.seq[role] += 1;
    plan.requests += 1;
    plan.roleRequests[role] += 1;
    if (role === 'child') plan.childRequests += 1;
    assert(stage.usage, 'fixture stage must declare usage');
    const ctx = {
      plan, stage, role, body, raw, history,
      call(name, args) {
        const id = `${role === 'root' ? 'r' : 'c'}${++plan.callSeq}`;
        (role === 'root' ? plan.parentCallIds : plan.childCallIds).push(id);
        return {type: 'tool', id, name, args};
      },
      text(text) { return {type: 'text', text}; },
    };
    validateStage(plan, stage, role, body, tools, raw, history, ctx);
    for (const key of stage.release ?? []) fireSignal(plan, key);
    if (stage.hold) await waitSignal(plan, stage.hold);
    const value = typeof stage.reply === 'function' ? stage.reply(ctx) : stage.reply;
    assert(value && (value.type === 'tool' || value.type === 'text'), 'fixture reply shape');
    sendReplies(plan.protocol, res, value, stage.usage);
  } catch {
    fixtureFailed = true;
    if (!res.headersSent) res.writeHead(500);
    res.end('owned subagent fixture failed');
  }
});
server.on('connection', socket => {
  sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
});

// ---------------------------------------------------------------------------
// Owned CLI runs
// ---------------------------------------------------------------------------

function makePlan(spec) {
  return {
    logging: false,
    childContext: null,
    expectCleanSockets: false,
    legacySwitch: null,
    stages: {root: [], child: []},
    signals: new Map(),
    seq: {root: 0, child: 0},
    callSeq: 0,
    parentCallIds: [],
    childCallIds: [],
    requests: 0,
    roleRequests: {root: 0, child: 0},
    childRequests: 0,
    ...spec,
  };
}

async function waitForNoSockets(limitMs) {
  const deadline = Date.now() + limitMs;
  while (sockets.size > 0 && Date.now() < deadline) await new Promise(done => setTimeout(done, 10));
  return sockets.size;
}

async function run(plan) {
  const dir = join(workspace, plan.name);
  const home = join(dir, 'home'), project = join(dir, 'project');
  plan.project = project;
  plan.sentinelFile = join(project, 'sentinel-dir', 'sentinel.txt');
  await mkdir(join(home, '.thin'), {recursive: true});
  await mkdir(join(project, 'sentinel-dir'), {recursive: true});
  await writeFile(plan.sentinelFile, SENTINEL, {mode: 0o600});
  await writeFile(join(project, PROBE_FILE), `${PROBE_CONTENT}\n`, {mode: 0o600});
  const declaration = {
    memory: {auto: false},
    llm: {default: `owned/${MODEL}`, providers: {owned: {
      base_url: url, api_key: KEY,
      models: {[MODEL]: {protocol: plan.protocol, context_tokens: 32768, output_tokens: OUTPUT_TOKENS}},
    }}},
    limits: {low_price_input: false, safety_tokens: 100, request_timeout_ms: 10000, task_timeout_ms: 25000},
  };
  // Older preview builds could persist a top-level switch; the legacy case
  // proves a saved false no longer disables delegation. Default cases ship no
  // subagent key at all.
  if (plan.legacySwitch) declaration.subagent = {enabled: plan.legacySwitch.enabled};
  plan.configText = JSON.stringify(declaration);
  await writeFile(join(home, '.thin', 'config.json'), plan.configText, {mode: 0o600});

  plan.seq = {root: 0, child: 0};
  plan.signals = new Map();
  plan.callSeq = 0;
  plan.parentCallIds = [];
  plan.childCallIds = [];
  plan.requests = 0;
  plan.roleRequests = {root: 0, child: 0};
  plan.childRequests = 0;
  plan.childCalls = plan.stages.child.length;
  plan.childInput = plan.stages.child.reduce((sum, stage) => sum + stage.usage.input, 0);
  plan.childOutput = plan.stages.child.reduce((sum, stage) => sum + stage.usage.output, 0);

  active = plan;
  const args = ['--print', PARENT_PROMPT, '--no-model-auto-refresh', ...(plan.logging ? [] : ['--no-log'])];
  const child = spawn(bin, args, {
    cwd: project,
    env: {PATH: '/usr/bin:/bin', HOME: home, LANG: 'C.UTF-8', TERM: 'xterm-256color'},
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let owned = true, size = 0, expired = false;
  const out = [], err = [];
  const kill = signal => { if (owned && child.pid) { try { process.kill(-child.pid, signal); } catch {} } };
  const capture = chunks => chunk => {
    size += chunk.length;
    if (size > OUTPUT_BOUND) { expired = true; kill('SIGTERM'); return; }
    chunks.push(chunk);
  };
  const timer = setTimeout(() => { expired = true; kill('SIGTERM'); }, 30000);
  const escalator = setTimeout(() => {
    kill('SIGKILL');
    child.stdout.destroy();
    child.stderr.destroy();
  }, 33000);
  child.stdout.on('data', capture(out));
  child.stderr.on('data', capture(err));
  child.once('exit', () => { owned = false; });
  let code;
  try {
    code = await new Promise((res, rej) => { child.once('error', rej); child.once('close', value => res(value)); });
  } finally {
    clearTimeout(timer);
    clearTimeout(escalator);
    kill('SIGKILL');
    owned = false;
  }
  try {
    assert(!expired, 'owned subagent run exceeded its bounded lifetime');
    assert(!fixtureFailed, 'owned subagent HTTP assertion failed');
    if (plan.expectCleanSockets) {
      const lingering = await waitForNoSockets(1500);
      assert.equal(lingering, 0, 'child sockets stayed open after cancel/exit');
    }
    const stdout = Buffer.concat(out).toString('utf8'), stderr = Buffer.concat(err).toString('utf8');
    assert(!stdout.includes(KEY) && !stderr.includes(KEY), 'credential leaked to local output');
    assert(!stdout.includes('\x1b'), 'headless output carried terminal escapes');
    assert.equal(plan.seq.root, plan.stages.root.length, 'root model request count/choreography');
    assert.equal(plan.seq.child, plan.stages.child.length, 'child model request count/choreography');
    assert.equal(plan.requests, plan.stages.root.length + plan.stages.child.length, 'total request count');
    assert.equal(await readFile(join(home, '.thin', 'config.json'), 'utf8'), plan.configText,
      'active run rewrote the configuration declaration');
    await plan.verify({code, out: stdout, err: stderr, project, home, plan});
  } finally {
    for (const socket of sockets) socket.destroy();
    sockets.clear();
    active = null;
  }
  return {name: plan.name, protocol: plan.protocol, requests: plan.requests, child_requests: plan.childRequests};
}

// Parent-only archive: exactly one session file under the parent identity, one
// user record and one finish record; the child never becomes a session.
async function assertParentArchive(project) {
  const sessions = join(project, '.thin', 'sessions');
  const entries = (await readdir(sessions)).filter(name => name !== '.gitignore');
  const archives = entries.filter(name => name.endsWith('.jsonl'));
  assert.equal(archives.length, 1, 'exactly one parent session archive');
  const identity = /([0-9a-f]{32})/.exec(archives[0])?.[1];
  assert(identity, 'session archive carries an identity');
  for (const entry of entries) assert(entry.includes(identity), 'a child created its own session file');
  const rows = (await readFile(join(sessions, archives[0]), 'utf8')).trimEnd().split('\n')
    .filter(Boolean).map(line => JSON.parse(line));
  assert.equal(rows.filter(row => row.event === 'user').length, 1, 'child task must not become a parent user record');
  assert(rows.some(row => row.event === 'finished'), 'parent completion record missing');
  assert(!JSON.stringify(rows).includes('Subagent mode:'), 'child transcript was archived');
}

// ---------------------------------------------------------------------------
// Cases
// ---------------------------------------------------------------------------

// Chat Q&A: start/get(wait)/ask/reply/read_file/terminal in one run, plus the
// parent write_file+bash refusal while the child is uncollected and waiting.
function qnaCase() {
  const plan = makePlan({
    name: 'chat-subagent-qna', protocol: 'chat', logging: true,
    childTask: CHILD_TASK, childContext: CHILD_CONTEXT,
  });
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: CHILD_TASK, context: CHILD_CONTEXT})},
    {usage: {input: 70, output: 12},
      check: ctx => {
        const start = startResult(ctx.history);
        assert.equal(start.status, 'running', 'start must return before the child is collected');
        plan.childId = start.id;
      },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 90, output: 14},
      check: ctx => {
        const snap = getResult(ctx.history);
        assert.equal(snap.id, plan.childId, 'get must use the id from the start result');
        assert.equal(snap.status, 'waiting_for_reply', 'get(wait=true) must surface the pending question');
        assert.equal(snap.messages.length, 1, 'one unread child message');
        assert(snap.messages[0].message.includes(CHILD_QUESTION), 'child question text');
        assert.equal(snap.messages[0].requires_reply, true, 'question must request a reply');
      },
      reply: ctx => ctx.call('write_file', {path: 'sentinel-dir/sentinel.txt', content: 'PARENT-OVERWRITE'})},
    {usage: {input: 95, output: 10},
      check: ctx => {
        const text = callText(ctx.history, 'write_file');
        assert(text.includes('SubagentActive'), `parent write must be refused while a child is uncollected, got ${JSON.stringify(text.slice(0, 80))}`);
      },
      reply: ctx => ctx.call('bash', {command: `rm -rf ${plan.project}/sentinel-dir`})},
    {usage: {input: 96, output: 10},
      check: ctx => {
        const text = callText(ctx.history, 'bash');
        assert(text.includes('SubagentActive'), `parent bash must be refused while a child is uncollected, got ${JSON.stringify(text.slice(0, 80))}`);
      },
      reply: ctx => ctx.call('send_subagent_message', {id: plan.childId, message: PARENT_REPLY})},
    {usage: {input: 100, output: 10},
      check: ctx => { sendReceipt(ctx.history, plan.childId); },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 110, output: 12},
      expectedCalls: ['subagent', 'get_subagent_result', 'write_file', 'bash', 'send_subagent_message', 'get_subagent_result'],
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 120, output: 10},
      reply: ctx => ctx.call('message_parent', {message: CHILD_QUESTION, wait_for_reply: true})},
    {expectedCalls: ['message_parent'], usage: {input: 200, output: 25},
      check: ctx => {
        const text = callText(ctx.history, 'message_parent');
        assert(text.includes(PARENT_REPLY), 'the reply must be returned as this tool call result');
        assert.equal(occurrences(ctx.raw, PARENT_REPLY), 1, 'the reply must not be duplicated');
        for (const user of userTexts(plan.protocol, ctx.body))
          assert(!user.includes(PARENT_REPLY), 'the reply must not be fabricated as a user turn');
      },
      reply: ctx => ctx.call(CHILD_READ_NAME, {path: PROBE_FILE})},
    {expectedCalls: ['message_parent', 'read_file'], usage: {input: 150, output: 20},
      check: ctx => {
        const read = callText(ctx.history, CHILD_READ_NAME);
        assert(String(read).includes(PROBE_CONTENT), 'child did not receive the real read_file result');
        assert(!ctx.raw.includes(ROOT_ANSWER), 'parent answer entered the child request');
      },
      reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out, project, home}) => {
    assert.equal(code, 0, 'subagent run must exit 0');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.roleRequests.root, 7, 'qna root request count');
    assert.equal(plan.childRequests, 3, 'qna child request count');
    assert(!out.includes('Subagent mode:'), 'child mode note leaked to stdout');
    assert.equal(await readFile(plan.sentinelFile, 'utf8'), SENTINEL, 'refused parent write_file changed the sentinel');
    assert(await exists(join(project, 'sentinel-dir')), 'refused parent bash removed the sentinel directory');
    await assertParentArchive(project);
    assert.equal(await readFile(join(home, '.thin', 'config.json'), 'utf8'), plan.configText);
  };
  return plan;
}

// Steering: the child's first model request is held by the owned server until
// the parent's send_subagent_message has run, then served. This is a real
// in-flight barrier (no sleeps): the steering must enter the same child
// history as user input and the child's next request must carry it. The old
// plan that first request proposed is an unstarted write_file, so the Runtime
// safe point must skip it (paired skip result, no execution) and the owned
// sentinel must still hold its original content.
function steeringCase() {
  const STEER_OLD_CONTENT = 'STEER-OLD-PLAN-CONTENT-must-not-be-written';
  const plan = makePlan({name: 'chat-subagent-steering', protocol: 'chat', childTask: STEER_TASK, logging: true});
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: STEER_TASK})},
    {hold: 'childRequestArrived', usage: {input: 60, output: 10},
      check: ctx => {
        const start = startResult(ctx.history);
        assert.equal(start.status, 'running', 'start must return while the child request is in flight');
        plan.childId = start.id;
      },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: false})},
    {usage: {input: 70, output: 10},
      check: ctx => {
        const snap = getResult(ctx.history);
        assert.equal(snap.status, 'running', 'snapshot while the child is in a model request');
        assert.deepEqual(snap.messages, [], 'no child message before the send');
        assert(snap.progress === null || snap.progress === '', 'no child progress before the send');
      },
      reply: ctx => ctx.call('send_subagent_message', {id: plan.childId, message: STEER_TEXT})},
    {release: ['steeringSent'], usage: {input: 80, output: 10},
      check: ctx => { sendReceipt(ctx.history, plan.childId); },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {release: ['childReportAllowed'], usage: {input: 90, output: 12},
      check: ctx => {
        const snap = getResult(ctx.history);
        assert.equal(snap.status, 'running', 'first wait must return at the child progress message');
        assert.equal(snap.messages.length, 1, 'one progress message');
        assert(snap.messages[0].message.includes(PROGRESS_TEXT), 'progress message text');
        assert.equal(snap.messages[0].requires_reply, false, 'progress must not request a reply');
      },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 100, output: 14},
      expectedCalls: ['subagent', 'get_subagent_result', 'send_subagent_message', 'get_subagent_result', 'get_subagent_result'],
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 110, output: 9},
      release: ['childRequestArrived'], hold: 'steeringSent',
      check: ctx => {
        assert(!ctx.raw.includes(STEER_TEXT), 'the steering must still be in flight when this request was built');
      },
      reply: ctx => ctx.call('write_file', {path: 'sentinel-dir/sentinel.txt', content: STEER_OLD_CONTENT})},
    {expectedCalls: ['write_file'], usage: {input: 180, output: 22},
      check: ctx => {
        assert.equal(occurrences(ctx.raw, STEER_TEXT), 1, 'the parent steering must enter the child history exactly once');
        const users = userTexts(plan.protocol, ctx.body);
        assert(users.some(text => text.includes(STEER_TEXT)), 'the steering must be a user turn in the same child history');
        for (const value of ctx.history.results.values())
          assert(!String(value).includes(STEER_TEXT), 'the steering must not be faked as a tool result');
        for (const id of plan.parentCallIds) assert(!ctx.raw.includes(id), 'parent call id leaked into the child');
        // The superseded old-plan call keeps its pairing and carries a skip
        // result: the steering superseded it before it ever started.
        const skipped = callText(ctx.history, 'write_file');
        assert(skipped.includes('Skipped') && skipped.includes('steering'),
          `superseded write_file must carry a steering skip result, got ${JSON.stringify(skipped.slice(0, 96))}`);
        assert(!skipped.includes(STEER_OLD_CONTENT), 'the skip result must not carry the old-plan content');
        // Read here, at the second child request: the sentinel is untouched.
        plan.steerSentinelAtSecondRequest = readFile(plan.sentinelFile, 'utf8')
          .then(text => text, error => `unreadable:${error?.code ?? 'error'}`);
      },
      reply: ctx => ctx.call('message_parent', {message: `progress: ${PROGRESS_TEXT}`, wait_for_reply: false})},
    {expectedCalls: ['write_file', 'message_parent'], hold: 'childReportAllowed', usage: {input: 150, output: 20},
      check: ctx => {
        assert.equal(occurrences(ctx.raw, STEER_TEXT), 1, 'steering must stay exactly once in the third child request');
        assert(callText(ctx.history, 'write_file').includes('Skipped'), 'the skipped old-plan call must stay skipped');
        const progress = callText(ctx.history, 'message_parent');
        assert(progress.includes('sent'), `progress message must be acknowledged, got ${JSON.stringify(progress.slice(0, 96))}`);
        assert(!progress.includes(STEER_TEXT), 'the steering must not be consumed as the progress reply');
      },
      reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out, project}) => {
    assert.equal(code, 0, 'steering run must exit 0');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.roleRequests.root, 6, 'steering root request count');
    assert.equal(plan.childRequests, 3, 'steering child request count');
    assert(plan.steerSentinelAtSecondRequest, 'the second child request did not observe the sentinel');
    assert.equal(await plan.steerSentinelAtSecondRequest, SENTINEL,
      'the superseded old-plan write_file changed the sentinel at the second child request');
    assert.equal(await readFile(plan.sentinelFile, 'utf8'), SENTINEL, 'the skipped old-plan write_file content was written');
    await assertParentArchive(project);
  };
  return plan;
}

// Cancel: the child is deterministically already asking (the parent observed
// waiting_for_reply), then the parent cancels. The root still finishes, no
// further child request appears and the child sockets/worker are gone.
function cancelCase() {
  const plan = makePlan({
    name: 'chat-subagent-cancel', protocol: 'chat', childTask: CANCEL_TASK, expectCleanSockets: true,
  });
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: CANCEL_TASK})},
    {usage: {input: 60, output: 10},
      check: ctx => { plan.childId = startResult(ctx.history).id; },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 70, output: 10},
      check: ctx => {
        const snap = getResult(ctx.history);
        assert.equal(snap.status, 'waiting_for_reply', 'the child must be blocked on its question before cancel');
        assert(snap.messages.some(message => message.message.includes(CANCEL_QUESTION) && message.requires_reply),
          'the pending question must be visible before cancel');
      },
      reply: ctx => ctx.call('cancel_subagent', {id: plan.childId})},
    {usage: {input: 80, output: 12},
      expectedCalls: ['subagent', 'get_subagent_result', 'cancel_subagent'],
      check: ctx => {
        const receipt = callJson(ctx.history, 'cancel_subagent');
        assert.equal(receipt.id, plan.childId, 'cancel receipt id');
        assert.equal(receipt.status, 'canceled', 'cancel must return the final canceled status');
        if (Object.hasOwn(receipt, 'cleanup_failed')) assert.equal(receipt.cleanup_failed, false, 'cleanup must be confirmed');
      },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 110, output: 9},
      reply: ctx => ctx.call('message_parent', {message: CANCEL_QUESTION, wait_for_reply: true})},
  ];
  plan.verify = async ({code, out, project}) => {
    assert.equal(code, 0, 'a canceled child must not fail the accepted root task');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing after cancel');
    assert.equal(plan.roleRequests.root, 4, 'cancel root request count');
    assert.equal(plan.childRequests, 1, 'no child request may follow the cancel');
    assert(!await exists(join(project, '.thin', 'sessions')), '--no-log created session records');
  };
  return plan;
}

// Legacy compatibility: a saved preview switch (subagent.enabled:false) is
// dropped, not honored; delegation still runs and the file is not rewritten.
function legacySwitchCase() {
  const plan = makePlan({
    name: 'chat-legacy-switch-false', protocol: 'chat', childTask: CHILD_TASK, legacySwitch: {enabled: false},
  });
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: CHILD_TASK, context: CHILD_CONTEXT})},
    {usage: {input: 60, output: 10},
      check: ctx => { plan.childId = startResult(ctx.history).id; },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 70, output: 12},
      expectedCalls: ['subagent', 'get_subagent_result'],
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 150, output: 30}, reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out, project, home}) => {
    assert.equal(code, 0, 'legacy subagent.enabled:false must not break delegation');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.childRequests, 1, 'delegation must still start one child');
    assert.equal(await readFile(join(home, '.thin', 'config.json'), 'utf8'), plan.configText,
      'the dropped legacy switch was rewritten to disk');
    assert(!await exists(join(project, '.thin', 'sessions')), '--no-log created session records');
  };
  return plan;
}

// Foreign identities: an id this Service never issued must fail explicitly for
// get/send/cancel and must not start or revive a child request. A previously
// collected id may stay queryable from the App's bounded result cache, so it is
// deliberately NOT required to fail here; cross-root staleness is App-unit scope.
function unknownIdCase() {
  const plan = makePlan({name: 'chat-subagent-unknown-id', protocol: 'chat', childTask: CHILD_TASK});
  plan.foreignId = `${UNKNOWN_ID_PREFIX}${randomUUID()}`;
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: CHILD_TASK})},
    {usage: {input: 60, output: 10},
      check: ctx => {
        plan.childId = startResult(ctx.history).id;
        assert(Buffer.byteLength(plan.foreignId) <= 64, 'the foreign id must stay within the argument bound');
        assert.notEqual(plan.foreignId, plan.childId, 'the foreign id must not be the started job');
      },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 70, output: 10},
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.foreignId, wait: true})},
    {usage: {input: 80, output: 10},
      check: ctx => { assertRejected('get with a foreign id', callText(ctx.history, 'get_subagent_result')); },
      reply: ctx => ctx.call('send_subagent_message', {id: plan.foreignId, message: PARENT_REPLY})},
    {usage: {input: 90, output: 10},
      check: ctx => { assertRejected('send to a foreign id', callText(ctx.history, 'send_subagent_message')); },
      reply: ctx => ctx.call('cancel_subagent', {id: plan.foreignId})},
    {usage: {input: 100, output: 12},
      expectedCalls: ['subagent', 'get_subagent_result', 'get_subagent_result', 'send_subagent_message', 'cancel_subagent'],
      check: ctx => { assertRejected('cancel of a foreign id', callText(ctx.history, 'cancel_subagent')); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 150, output: 30}, reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out}) => {
    assert.equal(code, 0, 'foreign-id rejections must not fail the root task');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.roleRequests.root, 6, 'unknown-id root request count');
    assert.equal(plan.childRequests, 1, 'a foreign id must not start or revive a child');
  };
  return plan;
}

// Responses/Anthropic: start, real child turn, blocking get to terminal. The
// terminal JSON keeps the legacy usage/report fields at the same level, and
// only Anthropic declares the frozen output capability.
function directCase(name, protocol) {
  const plan = makePlan({name, protocol, childTask: CHILD_TASK, childContext: CHILD_CONTEXT});
  plan.stages.root = [
    {usage: {input: 41, output: 9},
      reply: ctx => ctx.call('subagent', {task: CHILD_TASK, context: CHILD_CONTEXT})},
    {usage: {input: 61, output: 11},
      check: ctx => {
        plan.childId = startResult(ctx.history).id;
        assert.equal(startResult(ctx.history).status, 'running', 'start is immediate');
      },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 71, output: 13},
      expectedCalls: ['subagent', 'get_subagent_result'],
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 150, output: 30}, reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out, project}) => {
    assert.equal(code, 0, 'subagent run must exit 0');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.roleRequests.root, 3, 'direct root request count');
    assert.equal(plan.childRequests, 1, 'direct child request count');
    assert(!await exists(join(project, '.thin', 'sessions')), '--no-log created session records');
  };
  return plan;
}

// Child approval mapping: the dangerous command is proposed by the CHILD, the
// parent get(wait=true) proxies it into the parent --print permission domain,
// the host denies it, and the owned sentinel proves nothing ran.
function childApprovalDenialCase() {
  const plan = makePlan({name: 'child-dangerous-bash-denied', protocol: 'chat', childTask: CHILD_TASK});
  plan.stages.root = [
    {usage: {input: 40, output: 8},
      reply: ctx => ctx.call('subagent', {task: CHILD_TASK, context: CHILD_CONTEXT})},
    {usage: {input: 60, output: 12},
      check: ctx => { plan.childId = startResult(ctx.history).id; },
      reply: ctx => ctx.call('get_subagent_result', {id: plan.childId, wait: true})},
    {usage: {input: 70, output: 12},
      expectedCalls: ['subagent', 'get_subagent_result'],
      check: ctx => { assertTerminal(plan, getResult(ctx.history)); },
      reply: ctx => ctx.text(ROOT_ANSWER)},
  ];
  plan.stages.child = [
    {expectedCalls: [], usage: {input: 120, output: 10},
      reply: ctx => ctx.call(CHILD_BASH_NAME, {command: `rm -rf ${plan.project}/sentinel-dir`})},
    {expectedCalls: ['bash'], usage: {input: 200, output: 25},
      check: ctx => {
        const text = callText(ctx.history, CHILD_BASH_NAME);
        assert(text.includes('Dangerous bash command was not executed'), 'child dangerous command was not denied');
        assert(text.includes('recursive delete'), 'risk classification detail missing');
        plan.denialText = text;
      },
      reply: ctx => ctx.text(CHILD_REPORT)},
  ];
  plan.verify = async ({code, out, err}) => {
    assert.equal(code, 0, 'denied child tool must not fail the accepted task');
    assert(out.includes(ROOT_ANSWER), 'parent final answer missing');
    assert.equal(plan.roleRequests.root, 3, 'approval root request count');
    assert.equal(plan.childRequests, 2, 'approval child request count');
    assert(err.includes('tool calls were denied by the host.'), 'print host denial notice missing');
    assert.equal(await readFile(plan.sentinelFile, 'utf8'), SENTINEL, 'sentinel content changed');
    assert(await exists(join(plan.project, 'sentinel-dir')), 'denied child dangerous command executed');
  };
  return plan;
}

// ---------------------------------------------------------------------------

function stop() {
  for (const socket of sockets) socket.destroy();
  if (!server.listening) return;
}

process.once('SIGINT', () => { stop(); process.exit(130); });
process.once('SIGTERM', () => { stop(); process.exit(143); });

try {
  workspace = await mkdtemp(join(tmpdir(), 'thin-subagent-owned-'));
  await new Promise((resolveValue, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolveValue); });
  url = `http://127.0.0.1:${server.address().port}/v1`;

  const cases = [
    qnaCase(), steeringCase(), cancelCase(), legacySwitchCase(), unknownIdCase(),
    directCase('responses-subagent-direct', 'responses'),
    directCase('anthropic-subagent-direct', 'anthropic'),
    childApprovalDenialCase(),
  ];
  const results = [];
  for (const plan of cases) {
    const result = await run(plan);
    results.push(result);
    console.log(`PASS ${result.name} protocol=${result.protocol} requests=${result.requests} child_requests=${result.child_requests}`);
  }
  assert(!fixtureFailed, 'owned subagent HTTP assertion failed');
  await writeFile(join(workspace, 'evidence.json'), JSON.stringify({
    cases: results,
    wires: ['chat', 'responses', 'anthropic'],
    fixedParentTools: ROOT_TOOLS,
    fixedChildTools: CHILD_TOOLS,
    dynamicIdsFromStartResult: true,
    childQuestionAnsweredByParentSend: true,
    parentWriteAndBashRefusedWhileChildUncollected: true,
    steeringDeliveredWhileChildModelRequestInFlight: true,
    progressMessageSnapshot: true,
    cancelLeavesRootCompletedAndChildExited: true,
    legacySubagentEnabledFalseStillDelegates: true,
    foreignIdsRejectedForGetSendCancel: true,
    childFreshContext: true,
    childToolLoop: true,
    encodedResultNotDoubleWrapped: true,
    childDangerousBashDeniedByPrintHost: true,
    parentOnlySessionArchive: true,
    memoryAutoOffNoAuxiliaryRequest: true,
  }, null, 2) + '\n');
  console.log('PASS subagent owned loopback acceptance: 8 cases (Q&A, steering, cancel, legacy switch, foreign ids, 2 wires, child approval denial)');
} catch (error) {
  // Assertion messages only; never dump headers, bodies or configuration.
  console.error(`Subagent owned loopback FAIL: ${error?.message ?? 'runner'}`);
  process.exitCode = 1;
} finally {
  stop();
  if (server.listening) await new Promise(resolveValue => server.close(resolveValue));
  console.log(`SUBAGENT_OWNED_FIXTURE_ROOT=${workspace}`);
}
