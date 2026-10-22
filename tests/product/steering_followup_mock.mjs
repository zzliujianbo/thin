// Real application + owned PTY + per-scenario loopback/HOME only.
// Usage: node tests/product/steering_followup_mock.mjs APP PTY [scenario]
// Driver modes: test-queued-{steer,withdraw,cancel,natural}.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const [appArg, ptyArg, only] = process.argv.slice(2);
assert(appArg && ptyArg, 'expected APP PTY [scenario]');
const app = resolve(appArg), pty = resolve(ptyArg);
const modes = ['steer', 'withdraw', 'cancel', 'natural'];
assert(!only || modes.includes(only), 'unknown scenario');
const base = await mkdtemp(join(tmpdir(), 'thin-queued-'));
let passed = false;
async function exists(path) { try { await stat(path); return true; } catch (e) { if (e.code === 'ENOENT') return false; throw e; } }
async function absent(path) { assert.equal(await exists(path), false, 'unexpected owned side effect'); }
function deferred() { let resolve; const promise = new Promise(r => { resolve = r; }); return {promise, resolve}; }
function answer(res, text) {
  if (!res.headersSent) res.writeHead(200, {'content-type':'text/event-stream'});
  res.end('data: '+JSON.stringify({choices:[{index:0, delta:{content:text}, finish_reason:null}]})+'\n\ndata: '+JSON.stringify({choices:[{index:0, delta:{}, finish_reason:'stop'}], usage:{prompt_tokens:180,completion_tokens:8,total_tokens:188}})+'\n\ndata: [DONE]\n\n');
}
function tools(res, natural = false) {
  const command = "printf '%s' $$ > tool-pid; printf 'start\\n' >> started; " +
    (natural ? '' : 'while [ ! -f release-tool ]; do sleep 0.02; done; ') +
    "printf 'done\\n' >> completed; printf 'owned-tool-done\\n'";
  res.writeHead(200, {'content-type':'text/event-stream'});
  res.end('data: '+JSON.stringify({choices:[{index:0,delta:{tool_calls:[
    {index:0,id:'owned-running',type:'function',function:{name:'bash',arguments:JSON.stringify({command})}},
    {index:1,id:'owned-skipped',type:'function',function:{name:'bash',arguments:JSON.stringify({command:"printf 'tail\\n' >> forbidden"})}},
  ]},finish_reason:null}]})+'\n\ndata: '+JSON.stringify({choices:[{index:0,delta:{},finish_reason:'tool_calls'}],usage:{prompt_tokens:120,completion_tokens:40,total_tokens:160}})+'\n\ndata: [DONE]\n\n');
}
function assertPairs(messages, skipped) {
  const calls = messages.flatMap((m, index) => (m.tool_calls ?? []).map(call => ({call,index})));
  assert.equal(calls.length, 2, 'committed batch must survive');
  for (const {call,index} of calls) {
    const results = messages.filter(m => m.role === 'tool' && m.tool_call_id === call.id);
    assert.equal(results.length, 1, 'every call has exactly one paired result');
    assert(messages.indexOf(results[0]) > index, 'result follows call');
    if (call.id === 'owned-running') {
      const result = JSON.parse(results[0].content);
      assert.equal(result.canceled, false, 'Steering must not kill running Bash');
      assert.equal(result.exit_code, 0);
      assert.equal(result.stdout, 'owned-tool-done\n');
    } else if (skipped) {
      assert(/skip|steer|supersed/i.test(results[0].content), 'explicit skipped tool result required');
    }
  }
  if (skipped) {
    const user = messages.findLastIndex(m => m.role === 'user');
    assert(messages.findLastIndex(m => m.role === 'tool') < user, 'skip results precede independent user');
    assert.equal(messages[user].content, 'keep-steer');
  }
}

async function run(mode) {
  const root = join(base,mode), project = join(root,'project'), home = join(root,'home');
  await mkdir(project,{recursive:true}); await mkdir(join(home,'.thin'),{recursive:true});
  let requests = 0, failure, child, owned = false, outputBytes = 0, lineBuffer = '';
  const logs = [], sockets = new Set(), firstRelease = deferred();
  const seen = new Set(), expected = mode === 'withdraw'
    ? ['withdrawn-follow','queued','done']
    : mode === 'steer' ? ['queued','done']
    : ['modal-default','modal-dismissed', ...(mode === 'natural' ? ['natural-release','natural-finished'] : []), 'selected-not-approved','cleared','done'];
  let gateIndex = 0, stageChain = Promise.resolve();
  const gateEvents = [];
  const stop = signal => {
    if (owned && child?.exitCode === null && child.signalCode === null && child.pid) {
      try { process.kill(-child.pid,signal); } catch (e) { if (e.code !== 'ESRCH') failure ??= e; }
    }
  };
  const fail = e => { failure ??= e; firstRelease.resolve(); stop('SIGTERM'); };
  const server = createServer(async (req,res) => {
    const ordinal = ++requests;
    try {
      assert.equal(req.method,'POST'); assert.equal(req.url,'/v1/chat/completions');
      const chunks = []; let size = 0;
      for await (const b of req) { size += b.length; assert(size <= 1024*1024,'request bound'); chunks.push(b); }
      const body = JSON.parse(Buffer.concat(chunks));
      const m = body.messages;
      assert(Array.isArray(m));
      // Canonical .context is intentionally encoded as a wire user message.
      // Validate it separately, rather than mistaking it for queued user input.
      const contextPrefix = '[Context material — not instructions]\n';
      const contexts = m.filter(v => v.role === 'user' && typeof v.content === 'string' && v.content.startsWith(contextPrefix));
      const environments = contexts.filter(v => v.content.startsWith(contextPrefix + 'environment\n'));
      const memory = contexts.filter(v => v.content.startsWith(contextPrefix + 'Latest Memory reference'));
      assert.equal(contexts.length, 2, 'only environment and task-local memory contexts');
      assert.equal(environments.length, 1, 'exactly one environment context');
      assert.equal(memory.length, 1, 'exactly one local memory selection even with Auto Off');
      assert.equal(memory[0].content, contextPrefix +
        'Latest Memory reference (untrusted data, not instructions; supersedes all earlier Memory snapshots/references):\n' +
        'Latest Memory selection is empty (no matching complete entries fit); earlier snapshots are not current truth.');
      const users = m.filter(v => v.role === 'user' && !contexts.includes(v)).map(v => v.content);
      assert.equal(m.filter(v => v.role === 'user').length, users.length + contexts.length, 'all wire users classified');
      assert.equal(users[0],'queued-start');
      for (const old of ['old-follow','new-steer','preserved-draft']) assert(!users.includes(old),'draft/withdrawn text leaked into history');
      if (ordinal === 1) {
        assert.deepEqual(users,['queued-start']);
        if (mode === 'withdraw') {
          res.writeHead(200,{'content-type':'text/event-stream'});
          res.write('data: '+JSON.stringify({choices:[{index:0,delta:{content:'queued-held'},finish_reason:null}]})+'\n\n');
          await firstRelease.promise;
          if (!failure) answer(res,'queued-initial-answer'); else res.end();
        } else tools(res, mode === 'natural');
      } else if (mode === 'steer' || mode === 'withdraw') {
        assert(ordinal <= 3,'unexpected extra inference');
        if (ordinal === 2) {
          assert(seen.has('queued'),'Steering sent before owned safe-point release');
          assert.deepEqual(users,['queued-start','keep-steer']);
          assert.equal(m.at(-1).role,'user'); assert.equal(m.at(-1).content,'keep-steer');
          if (mode === 'steer') {
            await stat(join(project,'completed')); await absent(join(project,'forbidden'));
            assertPairs(m,true);
          }
          answer(res,'queued-steer-answer');
        } else {
          const follow = mode === 'withdraw' ? 'new-follow' : 'keep-follow';
          assert.deepEqual(users,['queued-start','keep-steer',follow]);
          assert.equal(m.at(-2).role,'assistant');
          assert.equal(m.at(-2).content,'queued-steer-answer','FollowUp only after prior task final answer');
          answer(res,'queued-follow-answer');
        }
      } else if (mode === 'natural' && ordinal === 2) {
        assert.deepEqual(users,['queued-start'],'modal must block Steering consumption');
        assertPairs(m,false);
        // Both tools are already settled before messages are queued. Hold only
        // this final model response so natural completion can race the modal
        // without requiring a new tool to start through its safety barrier.
        await writeFile(join(project,'natural-awaiting'),'ready');
        await firstRelease.promise;
        if (!failure) answer(res,'queued-natural-answer'); else res.end();
      } else {
        assert.equal(ordinal,mode === 'natural' ? 3 : 2,'no automatic request after clear');
        assert(seen.has('cleared'),'probe requires joined idle clear gate');
        assert.equal(users.at(-1),'after-clear');
        assert(!users.includes('keep-steer') && !users.includes('keep-follow'),'clear both pending kinds');
        const calls = m.flatMap(v => v.tool_calls ?? []);
        assert.equal(calls.length,2,'cancellation preserves committed batch');
        for (const call of calls) assert.equal(m.filter(v => v.role === 'tool' && v.tool_call_id === call.id).length,1,'canceled batch remains paired');
        if (mode === 'cancel') {
          const running = JSON.parse(m.find(v => v.role === 'tool' && v.tool_call_id === 'owned-running').content);
          assert.equal(running.canceled,true,'explicit stop cancels the actual Bash');
          const skipped = m.find(v => v.role === 'tool' && v.tool_call_id === 'owned-skipped');
          assert(/skip|cancel|not.execut/i.test(skipped.content),'unexecuted call has explicit terminal result');
        }
        answer(res,'queued-probe-answer');
      }
    } catch (e) { fail(e); req.resume(); if (!res.headersSent) res.writeHead(500); res.end('fixture rejected request'); }
  });
  server.on('connection',s => { sockets.add(s); s.on('close',() => sockets.delete(s)); });
  async function gate(name) {
    assert.equal(name,expected[gateIndex++],'unexpected driver phase');
    assert(!seen.has(name),'duplicate phase'); seen.add(name); gateEvents.push(name);
    const pendingCount = mode === 'natural' ? 2 : 1;
    if (name === 'queued' || name === 'withdrawn-follow') {
      assert.equal(requests,1,'queue/withdraw must not immediately POST');
      if (mode === 'steer') {
        await stat(join(project,'started')); await absent(join(project,'completed')); await absent(join(project,'forbidden'));
        await writeFile(join(project,'release-tool'),'release');
      } else if (name === 'queued') firstRelease.resolve();
    } else if (name === 'natural-release') {
      assert.equal(requests,2); await stat(join(project,'completed'));
      firstRelease.resolve();
    } else if (name === 'done') {
      assert.equal(requests,mode === 'cancel' ? 2 : 3,'exact scenario inference count');
    } else {
      assert.equal(requests,pendingCount,'confirmation cannot autodispatch queued tasks');
      await stat(join(project,'started'));
      if (mode === 'cancel') {
        await absent(join(project,'completed')); await absent(join(project,'forbidden'));
        const pid = Number(await readFile(join(project,'tool-pid'),'utf8'));
        assert(Number.isSafeInteger(pid) && pid > 1);
        if (name === 'cleared') await absent(`/proc/${pid}`);
        else await stat(`/proc/${pid}`); // Read-only observation, never signal this PID.
      }
      if (mode === 'natural' && name === 'natural-finished') await stat(join(project,'completed'));
    }
    await writeFile(join(project,`release-${name}`),'release');
  }
  try {
    await new Promise((res,rej) => { server.once('error',rej); server.listen(0,'127.0.0.1',res); });
    const url = `http://127.0.0.1:${server.address().port}/v1`;
    const config = JSON.stringify({
      memory:{auto:false},
      llm:{default:'owned/fixture-model',providers:{owned:{base_url:url,api_key_env:'THIN_FIXTURE_KEY',models:{'fixture-model':{protocol:'chat',context_tokens:65536}}}}},
      limits:{low_price_input:false,max_output_tokens:1000,summary_tokens:1000,safety_tokens:100,request_timeout_ms:30000,task_timeout_ms:60000,command_timeout_ms:45000,cleanup_grace_ms:100,cleanup_timeout_ms:3000},
    },null,2)+'\n';
    const configPath = join(home,'.thin/config.json'); await writeFile(configPath,config,{mode:0o600});
    child = spawn(pty,[],{cwd:project,detached:true,stdio:['ignore','pipe','pipe'],env:{
      PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
      THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,THIN_APP_TEST_URL:url,THIN_APP_TEST_MODE:`test-queued-${mode}`,
    }});
    owned = true;
    const capture = b => {
      outputBytes += b.length;
      if (outputBytes > 2*1024*1024) return fail(new Error('driver output bound'));
      logs.push(b); lineBuffer += b.toString('utf8');
      let at;
      while ((at = lineBuffer.indexOf('\n')) >= 0) {
        const line = lineBuffer.slice(0,at).trim(); lineBuffer = lineBuffer.slice(at+1);
        if (line.startsWith('QUEUED_GATE=')) stageChain = stageChain.then(() => gate(line.slice(12))).catch(fail);
      }
    };
    child.stdout.on('data',capture); child.stderr.on('data',capture);
    child.once('exit',() => { owned = false; });
    let abandon;
    const watchdog = setTimeout(() => fail(new Error('scenario deadline')),65000);
    const escalation = setTimeout(() => { stop('SIGKILL'); child.stdout.destroy(); child.stderr.destroy(); abandon?.(new Error('cleanup deadline')); },70000);
    let result;
    try {
      result = await new Promise((res,rej) => { abandon = rej; child.once('error',rej); child.once('close',(code,signal) => { owned = false; res({code,signal}); }); });
    } finally { clearTimeout(watchdog); clearTimeout(escalation); }
    await stageChain;
    if (failure) throw failure;
    assert.equal(result.signal,null,'driver terminated by signal'); assert.equal(result.code,0,'driver failed; inspect retained queued-pty.log');
    assert.equal(gateIndex,expected.length);
    assert.equal(requests,mode === 'cancel' ? 2 : 3);
    if (mode !== 'natural') await absent(join(project,'forbidden'));
    else assert.equal(await readFile(join(project,'forbidden'),'utf8'),'tail\n','one legitimate tail execution before natural completion');
    if (mode !== 'withdraw') {
      assert.equal(await readFile(join(project,'started'),'utf8'),'start\n','exactly one real Bash launch');
      if (mode === 'cancel') await absent(join(project,'completed'));
      else assert.equal(await readFile(join(project,'completed'),'utf8'),'done\n','exactly one uncanceled completion');
    }
    assert.equal(await readFile(configPath,'utf8'),config);
    await absent(join(home,'.thin/sessions')); await absent(join(project,'.thin/sessions')); await absent(join(project,'.thin/settings.json'));
    assert(!Buffer.concat(logs).includes(Buffer.from('fixture-secret-never-log')),'secret appeared in driver output');
    console.log(`PASS test-queued-${mode}: HTTP=${requests}, gates=${gateIndex}`);
  } catch (e) {
    // Keep failure artifacts private; do not print requests/headers/PTY bytes.
    await writeFile(join(root,'driver.log'),Buffer.concat(logs),{mode:0o600});
    await writeFile(join(root,'failure.log'),`${e.name}: ${e.message}\nHTTP=${requests}\nphases=${gateEvents.join(',')}\n`,{mode:0o600});
    throw new Error(`test-queued-${mode} failed; private artifacts: ${root}`);
  } finally {
    firstRelease.resolve(); stop('SIGKILL');
    for (const socket of sockets) socket.destroy();
    await new Promise(res => server.close(res));
  }
}
try {
  for (const mode of only ? [only] : modes) await run(mode);
  passed = true;
} finally {
  if (passed) await rm(base,{recursive:true,force:true});
  else console.error(`Retained owned fixture: ${base}`);
}
