// 独立离线日志验收：只读取本 suite 创建的临时项目，永不读取用户日志。
import http from 'node:http';
import {spawn} from 'node:child_process';
import {mkdtemp, mkdir, writeFile, readFile, rm, access, stat, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';

const KEY = 'fixture-secret-never-log';
const JSON_KEY = 'fixture-quote-"-slash-\\-secret';
const hidden = 'hidden-reasoning-must-not-be-persisted';
const native = 'native-wire-marker-not-conversation';
const exists = p => access(p).then(() => true, () => false);
const datePattern = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[.,]\d{9}[+-]\d{2}:\d{2}/;

function send(res, text, call) {
  res.writeHead(200, {'content-type':'text/event-stream'});
  const event = x => res.write(`data: ${JSON.stringify(x)}\n\n`);
  event({id:native, choices:[{index:0, delta:{reasoning_content:hidden}, finish_reason:null}]});
  const delta = call ? {tool_calls:[{index:0, id:call.id, type:'function', function:{name:call.name, arguments:JSON.stringify(call.args)}}]} : {content:text};
  event({id:native, choices:[{index:0, delta, finish_reason:null}]});
  event({id:native, choices:[{index:0, delta:{}, finish_reason:call?'tool_calls':'stop'}], usage:{prompt_tokens:20, completion_tokens:10, total_tokens:30}});
  res.end('data: [DONE]\n\n');
}

// stdout/stderr 分开捕获；所有 watchdog 与输出均有界，只终止尚未回收的自有进程组。
async function execute(bin, args, env, cwd) {
  const child = spawn(bin, args, {cwd, env, detached:true, stdio:['ignore','pipe','pipe']});
  let owned = true, size = 0, failed = false, rejectPending;
  const stdout = [], stderr = [];
  const kill = signal => { if (owned && child.pid) { try { process.kill(-child.pid, signal); } catch {} } };
  const timer = setTimeout(() => { failed = true; kill('SIGTERM'); }, 30000);
  const escalator = setTimeout(() => {
    kill('SIGKILL'); child.stdout.destroy(); child.stderr.destroy();
    rejectPending?.(new Error('bounded child shutdown failed'));
  }, 33000);
  const capture = list => b => {
    size += b.length;
    if (size <= 2*1024*1024) list.push(b);
    else { failed = true; kill('SIGTERM'); }
  };
  child.stdout.on('data', capture(stdout)); child.stderr.on('data', capture(stderr));
  child.once('exit', () => { owned = false; });
  try {
    const code = await new Promise((resolve, reject) => {
      rejectPending = reject;
      child.once('error', reject); child.once('close', resolve);
    });
    assert(!failed, 'bounded child execution failed');
    if (code !== 0) {
      const diagnostic = Buffer.concat(stderr).toString('utf8').split('\n').find(line => /^(?:thin: (?:(?:failed|canceled)(?:: [A-Za-z0-9_]+)?(?: \/ [a-z_]+)?|[A-Za-z][A-Za-z0-9_]*)|error: [A-Za-z][A-Za-z0-9_]*)$/.test(line));
      const error = new Error('application did not exit successfully');
      error.fixtureCheck = diagnostic ?? 'application did not exit successfully';
      throw error;
    }
    return {stdout:Buffer.concat(stdout).toString('utf8'), stderr:Buffer.concat(stderr).toString('utf8')};
  } finally { clearTimeout(timer); clearTimeout(escalator); kill('SIGKILL'); }
}

async function records(project, began, ended, key) {
  const dir = join(project,'.thin/sessions');
  assert(!await exists(join(project,'.thin/logs')), 'legacy log directory created');
  assert((await stat(dir)).mode % 512 === 0o700, 'log directory permissions');
  const marker = join(dir,'.gitignore');
  assert((await stat(marker)).mode % 512 === 0o600, 'log marker permissions');
  assert(await readFile(marker,'utf8') === '*\n', 'log ignore marker missing');
  const files = (await readdir(dir)).filter(f => f.endsWith('.jsonl'));
  assert(files.length > 0, 'missing JSONL files');
  const rows = [];
  for (const file of files) {
    const path = join(dir,file);
    assert((await stat(path)).mode % 512 === 0o600, 'log file permissions');
    const raw = await readFile(path,'utf8');
    assert(raw.endsWith('\n'), 'incomplete JSONL record');
    assert(!raw.includes(key) && !raw.includes(JSON.stringify(key).slice(1,-1)), 'known key leaked');
    assert(!raw.includes(hidden) && !raw.includes(native), 'private provider content persisted');
    for (const line of raw.slice(0,-1).split('\n')) rows.push(JSON.parse(line));
  }
  rows.sort((a,b) => a.seq-b.seq);
  const session = rows[0]?.session;
  assert(typeof session === 'string' && session.length > 0, 'session missing');
  let elapsed = -1;
  for (const [index,row] of rows.entries()) {
    assert(row.schema === 1 && row.session === session && row.seq === index+1, 'invalid envelope sequence/session');
    assert(row.turn === 1, 'unexpected turn');
    assert(Number.isSafeInteger(row.timestamp_ms) && row.timestamp_ms >= began-1000 && row.timestamp_ms <= ended+1000, 'invalid timestamp');
    assert(Number.isSafeInteger(row.elapsed_ms) && row.elapsed_ms >= elapsed, 'elapsed time regressed');
    elapsed = row.elapsed_ms;
    assert(typeof row.event === 'string' && row.data && typeof row.data === 'object', 'invalid event/data');
    assert(!['reasoning','native','text_delta'].includes(row.event), 'private event persisted');
    if (row.event === 'first_response') assert(!('text' in row.data) && !('content' in row.data), 'first response contains content');
    // 工具 text/content 可能逐层包装 JSON；不能只检查最外层转义后的字节。
    const safe = (value, depth = 0) => {
      assert(depth <= 64, 'redaction verification nesting bound');
      if (typeof value === 'string') {
        assert(!value.includes(key), 'decoded key leaked');
        let nested;
        try { nested = JSON.parse(value); } catch { return; }
        safe(nested, depth + 1);
      } else if (value && typeof value === 'object') {
        for (const [k,v] of Object.entries(value)) { safe(k, depth + 1); safe(v, depth + 1); }
      }
    };
    safe(row);
  }
  return rows;
}

async function scenario(app, pty, kind) {
  const root = await mkdtemp(join(tmpdir(),'thin-log-'));
  const home = join(root,'home'), project = join(root,'project');
  const key = kind === 'redact-json' ? JSON_KEY : KEY;
  let requests = 0, fixtureFailed = false, actualDate;
  const sockets = new Set();
  const date = kind === 'date' || kind === 'date-pty';
  const redact = kind === 'redact' || kind === 'redact-json';
  const memoryAuto = kind === 'memory-auto';
  const writeAuto = kind === 'write-auto';
  const usesTool = date || memoryAuto || writeAuto || redact;
  const user = redact ? `user ${key}` : kind === 'date-pty' ? '获取时间' : 'log-fixture-task';
  const answer = redact ? `assistant ${key}` : date ? 'date-completed' : 'log-fixture-answer';
  const server = http.createServer(async (req,res) => {
    try {
      requests++;
      assert(requests <= 2, 'request bound');
      assert(req.headers.authorization === `Bearer ${key}`, 'fixture authorization mismatch');
      assert(req.url === '/v1/chat/completions', 'unexpected endpoint');
      let data = '', bytes = 0;
      for await (const chunk of req) { bytes += chunk.length; assert(bytes <= 1024*1024, 'request too large'); data += chunk; }
      const body = JSON.parse(data);
      assert(body.messages.some(m => m.role === 'user' && m.content === user), 'submitted user absent');
      if (requests === 1 && usesTool) {
        const call = memoryAuto ? {id:'fixture-call', name:'memory', args:{action:'write', topic:'core', content:JSON.stringify({secret:key}).replaceAll('-', '\\u002d')}} :
          redact ? {id:'fixture-call', name:'read_file', args:{path:`secret-${key}.json`}} :
          {id:'fixture-call', name:'bash', args:{command:writeAuto ? 'printf automatic > automatic.txt' : 'date -Ins'}};
        send(res,'',call); return;
      }
      if (requests === 2) {
        const results = body.messages.filter(m => m.role === 'tool');
        assert(results.length === 1 && results[0].tool_call_id === 'fixture-call', 'canonical result association');
        const output = results[0].content;
        if (date) { actualDate = output.match(datePattern)?.[0]; assert(actualDate, 'real date output absent'); }
        if (memoryAuto || writeAuto) assert(!/denied/i.test(output), 'default execution denied');
        if (redact) assert(output.includes(JSON.stringify(key).slice(1,-1)), 'JSON tool fixture not returned');
      }
      send(res,answer);
    } catch {
      fixtureFailed = true;
      if (!res.headersSent) res.writeHead(500);
      res.end('fixture failed');
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close',()=>sockets.delete(socket)); });
  try {
    await mkdir(home); await mkdir(project); await mkdir(join(home,'.thin'));
    await new Promise((resolve,reject) => { server.once('error',reject); server.listen(0,'127.0.0.1',resolve); });
    const url = `http://127.0.0.1:${server.address().port}/v1`;
    await writeFile(join(home,'.thin/config.json'), JSON.stringify({memory:{auto:false},llm:{default:'local/fixture-model',providers:{local:{base_url:url,api_key_env:'THIN_FIXTURE_KEY',models:{'fixture-model':{protocol:'chat',context_tokens:32768}}}}}, limits:{low_price_input:false,max_output_tokens:100,summary_tokens:80,request_timeout_ms:5000,task_timeout_ms:15000}}));
    if (redact) await writeFile(join(project,`secret-${key}.json`), JSON.stringify({secret:key, [key]:key}));
    if (kind === 'failure' || kind === 'failure-pty') { await mkdir(join(project,'.thin')); await writeFile(join(project,'.thin/sessions'),'occupied'); }
    const env = {PATH:'/usr/bin:/bin', HOME:home, LANG:'C.UTF-8', TERM:'xterm-256color', THIN_FIXTURE_KEY:key,
      THIN_APP_BIN:app, THIN_APP_TEST_HOME:home, THIN_APP_TEST_PROJECT:project, THIN_APP_TEST_URL:url,
      THIN_APP_TEST_MODE:kind === 'date-pty' ? 'date' : kind === 'failure-pty' ? 'log-failure' : 'log-idle'};
    const isPty = ['date-pty','failure-pty','idle'].includes(kind);
    const args = kind === 'help' ? ['--help'] : kind === 'version' ? ['--version'] : ['--print',user, ...(kind === 'no-log' ? ['--no-log'] : [])];
    const began = Date.now();
    const result = await execute(isPty?pty:app, isPty?[]:args, env, project);
    const ended = Date.now();
    const announced = isPty ? [...(result.stdout + '\n' + result.stderr).matchAll(/^PTY_SESSION_ID=([a-f0-9]{32})$/gm)] : [];
    if (isPty) assert.equal(announced.length,kind === 'date-pty' ? 1 : 0,'resume command must reflect a saved nonempty conversation');
    assert(!fixtureFailed, 'loopback fixture failed');
    if (kind === 'help') {
      assert(result.stdout.includes('.thin/sessions/*.jsonl') && !result.stdout.includes('.thin/logs'), 'session path missing from help');
    }
    if (['help','version','idle','no-log'].includes(kind)) {
      assert(!await exists(join(project,'.thin/sessions')), 'session record created without enabled submission');
      assert(!await exists(join(project,'.thin/logs')), 'legacy log directory created');
      assert(requests === (kind === 'no-log' ? 1 : 0), 'unexpected request count');
      if (kind === 'no-log') assert(result.stdout.includes(answer), 'no-log changed answer');
    } else if (kind === 'failure' || kind === 'failure-pty') {
      assert(requests === 1, 'logger failure changed request count');
      if (kind === 'failure') {
        assert(result.stdout.includes(answer), 'logger failure changed answer');
        assert(result.stderr.includes('session recording disabled'), 'logger failure not visible on stderr');
      }
      assert(await readFile(join(project,'.thin/sessions'),'utf8') === 'occupied', 'obstruction overwritten');
    } else {
      assert(requests === (usesTool ? 2 : 1), 'unexpected conversation length');
      const rows = await records(project,began,ended,key);
      if (isPty) assert(rows.every(row => row.session === announced[0][1]), 'announced/archive session identity differs');
      const events = name => rows.filter(r => r.event === name).map(r => r.data);
      const users = events('user'), assistants = events('assistant'), finished = events('finished');
      assert(users.length === 1 && users[0].source_bytes === Buffer.byteLength(user) && users[0].truncated === false, 'user metadata missing');
      assert(assistants.length === 1 && Number.isInteger(assistants[0].message_index) && Number.isInteger(assistants[0].block_index), 'assistant metadata missing');
      if (!redact) { assert(users[0].text === user, 'user text missing'); assert(assistants[0].text === answer, 'assistant text missing'); }
      else assert(users[0].text.includes('[redacted]') && assistants[0].text.includes('[redacted]'), 'text redaction missing');
      assert(events('state').some(d => d.state === 'calling_model'), 'runtime state missing');
      assert(finished.length === 1 && finished[0].status === 'success', 'successful finish missing');
      assert(['detail','model_failure','http_status','usage'].every(k => k in finished[0]), 'finish metadata missing');
      assert(rows.at(-1).event === 'finished', 'finished must close conversation');
      assert(events('first_response').length > 0, 'first response metadata missing');
      if (usesTool) {
        const calls = events('tool_call'), results = events('tool_result');
        assert(calls.length === 1 && results.length === 1 && calls[0].call_id === 'fixture-call' && results[0].call_id === calls[0].call_id, 'logged call/result pairing');
        assert(calls[0].name === (memoryAuto?'memory':redact?'read_file':'bash') && 'arguments' in calls[0], 'call metadata missing');
        assert(['is_error','canceled','truncated','cleanup_failed'].every(k => typeof results[0][k] === 'boolean'), 'result flags missing');
        if (date) assert(results[0].text.includes(actualDate) && !results[0].is_error, 'real time missing from log');
        if (redact) assert(results[0].text.includes('[redacted]'), 'JSON result not redacted');
        assert(!results[0].is_error && !results[0].canceled, 'default tool execution failed');
        assert(events('permission').length === 0 && events('decision').length === 0, 'default execution asked approval');
        assert(!events('state').some(d=>d.state==='awaiting_permission'), 'default execution waited for approval');
        assert(events('tool_started').length === 1, 'default execution did not start');
        if (writeAuto) assert(await readFile(join(project,'automatic.txt'),'utf8') === 'automatic', 'shell write did not execute');
        if (memoryAuto) {
          assert(JSON.parse(await readFile(join(project,'.thin/mem/core.md'),'utf8')).secret === key, 'memory write did not execute');
          assert(calls[0].arguments.content.includes('[redacted]'), 'encoded memory content leaked in archive');
        }
      }
    }
    console.log(`PASS log/${kind}: requests=${requests}`);
  } catch (error) {
    // 本文件的 assert 只使用固定标签；不传播 actual/expected、捕获输出或 JSON 错误正文。
    const failure = new Error('offline log acceptance failed');
    failure.fixtureCase = `log/${kind}`;
    failure.fixtureCheck = error.fixtureCheck ?? (error.code === 'ERR_ASSERTION' ? error.message : 'execution-or-json');
    throw failure;
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(root,{recursive:true,force:true});
  }
}

export async function logRegressions(app, pty) {
  for (const kind of ['plain','no-log','help','version','idle','date','write-auto','memory-auto','redact','redact-json','failure','date-pty','failure-pty']) await scenario(app,pty,kind);
}
