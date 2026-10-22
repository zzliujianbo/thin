// Owned PTYs and loopback only. Command phase must make zero inference calls.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const [appArg, ptyArg, onlyMode] = process.argv.slice(2);
assert(appArg && ptyArg);
const modes = ['accept','deny','cancel','timeout','stable'];
assert(onlyMode === undefined || modes.includes(onlyMode));
const app = resolve(appArg), pty = resolve(ptyArg);
const base = await mkdtemp(join(tmpdir(), 'thin-local-command-'));
let active, failure, requests = 0, connections = 0, scenarios = 0;
const sockets = new Set();
const server = createServer(async (req, res) => {
  requests++;
  try {
    // The only allowed HTTP is the explicit normal turn AFTER local execution.
    assert.equal(active?.mode, 'accept', 'command-only scenario sent HTTP');
    assert.equal(requests, 1, 'extra primary/summary/decision HTTP');
    const chunks = []; let bytes = 0;
    for await (const chunk of req) {
      bytes += chunk.length; assert(bytes <= 512 * 1024); chunks.push(chunk);
    }
    const body = JSON.parse(Buffer.concat(chunks));
    const messages = body.messages;
    assert(Array.isArray(messages));
    assert.equal(messages.at(-1).role, 'user');
    assert.equal(messages.at(-1).content, 'command-normal-proof', 'inference before explicit normal turn');
    assert.equal(await readFile(join(active.project, 'marker'), 'utf8'), '');
    const calls = messages.flatMap((m, i) => (m.tool_calls ?? []).map(call => ({call, i})));
    assert.equal(calls.length, 1, 'exactly one local command tool call');
    const {call, i} = calls[0];
    assert.equal(call.function.name, 'bash');
    assert.equal(messages[i - 1].role, 'user');
    assert(messages[i - 1].content.startsWith('  !'), 'local command preserves original user input');
    assert.equal(JSON.parse(call.function.arguments).command, "printf 'OUT\\n'; printf 'ERR\\n' >&2; touch marker; rm -rf absent; exit 7");
    const result = messages[i + 1];
    assert.equal(result.role, 'tool'); assert.equal(result.tool_call_id, call.id);
    const value = JSON.parse(result.content);
    assert.equal(value.stdout, 'OUT\n'); assert.equal(value.stderr, 'ERR\n');
    assert.equal(value.exit_code, 7); assert.equal(value.timed_out, false);
    assert.equal(value.canceled, false);
    active.normalRequests++;
    res.writeHead(200, {'content-type':'text/event-stream'});
    res.end('data: '+JSON.stringify({choices:[{index:0,delta:{content:'command-pair-verified'},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:'stop'}],usage:{prompt_tokens:100,completion_tokens:5,total_tokens:105}})+'\n\ndata: [DONE]\n\n');
  } catch (e) { failure ??= e; req.resume(); res.writeHead(500); res.end('unexpected HTTP'); }
});
server.on('connection', socket => { connections++; sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
async function missing(path) { await assert.rejects(stat(path), {code:'ENOENT'}); }
async function run(mode, url) {
  const home = join(base, mode, 'home'), project = join(base, mode, 'project');
  await mkdir(join(home, '.thin'), {recursive:true}); await mkdir(project, {recursive:true});
  const config = JSON.stringify({
    memory:{auto:false},
    llm:{default:'local/fixture-model', providers:{local:{base_url:url, api_key_env:'THIN_FIXTURE_KEY', models:{'fixture-model':{protocol:'chat', context_tokens:32768}}}}},
    ...(mode === 'deny' ? {decision:{enabled:false,model:'local/fixture-model'}} : {}),
    limits:{low_price_input:false,max_output_tokens:100,summary_tokens:100,safety_tokens:100,request_timeout_ms:3000,task_timeout_ms:10000,command_timeout_ms:mode === 'timeout' ? 250 : 5000,cleanup_grace_ms:100,cleanup_timeout_ms:2000},
  }, null, 2)+'\n';
  const path = join(home, '.thin/config.json'); await writeFile(path, config, {mode:0o600});
  active = {mode, project, normalRequests:0};
  const before = requests, beforeConnections = connections;
  const child = spawn(pty, [], {cwd:project, detached:true, stdio:['ignore','pipe','pipe'], env:{
    PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
    THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,
    THIN_APP_TEST_URL:url,THIN_APP_TEST_MODE:`settings-command-${mode}`,
  }});
  let owned = true, localFailure, size = 0, rejectWait;
  const chunks = [];
  const stop = signal => {
    // No cached PID/PGID signal after leader exit, including pipe-held-open close.
    if (owned && child.exitCode === null && child.signalCode === null && child.pid) {
      try { process.kill(-child.pid, signal); } catch (e) { if (e.code !== 'ESRCH') localFailure ??= e; }
    }
  };
  const abandon = () => { child.stdout.destroy(); child.stderr.destroy(); rejectWait?.(localFailure); };
  const timer = setTimeout(() => { localFailure ??= new Error(`${mode}: watchdog`); stop('SIGTERM'); if (!owned) abandon(); }, 45000);
  const escalation = setTimeout(() => { localFailure ??= new Error(`${mode}: cleanup watchdog`); stop('SIGKILL'); abandon(); }, 48000);
  const capture = b => { size += b.length; if (size <= 2*1024*1024) chunks.push(b); else { localFailure ??= new Error('output bound'); stop('SIGTERM'); } };
  child.stdout.on('data', capture); child.stderr.on('data', capture);
  child.once('exit', () => { owned = false; if (localFailure) abandon(); });
  child.once('close', () => { owned = false; });
  try {
    const result = await new Promise((res, rej) => {
      rejectWait = rej;
      child.once('error', e => { owned = false; rej(e); });
      child.once('close', (code, signal) => res({code,signal}));
    });
    const output = Buffer.concat(chunks).toString('utf8');
    assert(!output.includes('fixture-secret-never-log'));
    if (localFailure) throw localFailure;
    if (failure) throw failure;
    assert.equal(result.signal, null, `${mode}: PTY signal\n${output}`);
    assert.equal(result.code, 0, `${mode}: PTY failed\n${output}`);
    const normal = mode === 'accept' ? 1 : 0;
    assert.equal(requests-before, normal); assert.equal(active.normalRequests, normal);
    if (!normal) assert.equal(connections-beforeConnections, 0);
    if (mode === 'accept') await stat(join(project,'marker'));
    for (const name of ['denied','pasted','batch-first','batch-tail','stable-executed']) await missing(join(project,name));
    if (mode === 'cancel' || mode === 'timeout') {
      await stat(join(project,'started'));
      const pid = Number((await readFile(join(project,'child'),'utf8')).trim());
      assert(Number.isSafeInteger(pid) && pid > 1);
      // Observe only: never signal a PID read from disk. Runtime must reap it.
      await missing(`/proc/${pid}`);
    }
    assert.equal(await readFile(path,'utf8'), config, 'command changed config');
    await missing(join(home,'.thin/sessions')); await missing(join(project,'.thin/sessions'));
    await missing(join(project,'.thin/settings.json'));
    assert(!output.includes('PTY_SESSION_ID='));
    scenarios++;
    console.log(`PASS command-${mode}: command HTTP=0, explicit normal HTTP=${normal}`);
  } finally { clearTimeout(timer); clearTimeout(escalation); stop('SIGTERM'); }
}
try {
  await new Promise((res,rej) => {server.once('error',rej);server.listen(0,'127.0.0.1',res);});
  const url = `http://127.0.0.1:${server.address().port}/v1`;
  for (const mode of onlyMode === undefined ? modes : [onlyMode]) await run(mode,url);
  console.log(`PASS test-command: scenarios=${scenarios}, command HTTP=0, explicit normal HTTP=${requests}`);
} catch (error) {
  console.error(`FAIL test-command: completed=${scenarios}, HTTP=${requests}, TCP=${connections}, explicit normal HTTP=${active?.normalRequests ?? 0}`);
  throw error;
} finally {
  for (const socket of sockets) socket.destroy();
  await new Promise(res => server.close(res));
  await rm(base,{recursive:true,force:true});
}
