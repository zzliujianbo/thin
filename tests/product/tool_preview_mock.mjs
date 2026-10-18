// Owned loopback + PTY acceptance: no real HOME, credentials or metadata.
// Gates are emitted by the driver only after a complete cursor-ACK frame and
// an independent access(ENOENT), not inferred from a later canonical result.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const [appArg, ptyArg] = process.argv.slice(2);
assert(appArg && ptyArg, 'expected existing thin and PTY artifacts');
const app = resolve(appArg), pty = resolve(ptyArg);
const base = await mkdtemp(join(tmpdir(), 'thin-tool-preview-'));
const content = 'PREVIEW_RAW_CONTENT_SECRET' + 'x'.repeat(24000);
const command = "sleep 0.7; printf 'preview-%s-proof' bash; : " + 'bounded-label-'.repeat(12);
const sockets = new Set();
let active, failure, requests = 0, scenarios = 0;
async function absent(path) { await assert.rejects(stat(path), {code:'ENOENT'}); }
function delta(res, value, finish = null) {
  res.write('data: '+JSON.stringify({id:'preview-chat',choices:[{index:0,delta:value,finish_reason:finish}]})+'\n\n');
}
function end(res, reason) { delta(res, {}, reason); res.end('data: [DONE]\n\n'); }
function args(res, arguments_) { delta(res,{tool_calls:[{index:0,function:{arguments:arguments_}}]}); }
function gate(f, name) {
  if (f.gates.has(name)) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {f.waiters.delete(name); reject(new Error(`${f.mode}: missing ACK gate ${name}`));}, 12000);
    f.waiters.set(name, () => {clearTimeout(timer); resolve();});
  });
}
const server = createServer(async (req, res) => {
  requests++;
  const f = active;
  try {
    assert(f, 'request outside scenario');
    assert.equal(req.method, 'POST'); assert.equal(req.url, '/v1/chat/completions');
    const chunks = []; let size = 0;
    for await (const chunk of req) { size += chunk.length; assert(size <= 512*1024); chunks.push(chunk); }
    const body = JSON.parse(Buffer.concat(chunks));
    f.requests++;
    assert(f.requests <= (f.mode === 'cancel' ? 1 : 2), 'extra inference/summary/decision');
    res.writeHead(200, {'content-type':'text/event-stream','cache-control':'no-cache'});
    if (f.requests === 1) {
      assert.equal(body.messages.at(-1).content, 'preview-task');
      delta(res,{tool_calls:[{index:0,id:'preview-write',type:'function',function:{name:'write_file',arguments:''}}]});
      await gate(f,'header');
      args(res,'{"path":"preview-owned');
      await gate(f,'partial');
      args(res,'.txt","content":"'+content);
      await gate(f,'path-absent');
      await absent(join(f.project,'preview-owned.txt'));
      f.earlyAbsence++;
      if (f.mode === 'cancel') {
        // Never close the argument string or emit finish_reason/tool_calls.
        await gate(f,'canceled');
        await absent(join(f.project,'preview-owned.txt'));
        res.end();
      } else {
        await gate(f,'finish');
        await absent(join(f.project,'preview-owned.txt'));
        args(res,'"}');
        delta(res,{tool_calls:[{index:1,id:'preview-bash',type:'function',function:{name:'bash',arguments:JSON.stringify({command})}}]});
        end(res,'tool_calls');
      }
    } else {
      assert.equal(f.mode,'success');
      assert.equal(await readFile(join(f.project,'preview-owned.txt'),'utf8'), content);
      const calls = body.messages.flatMap(m => m.tool_calls ?? []);
      assert.equal(calls.length,2);
      assert.deepEqual(calls.map(c => [c.id,c.function.name]), [['preview-write','write_file'],['preview-bash','bash']]);
      assert.deepEqual(JSON.parse(calls[0].function.arguments), {path:'preview-owned.txt',content});
      assert.equal(JSON.parse(calls[1].function.arguments).command,command);
      const results = body.messages.filter(m => m.role === 'tool');
      assert.equal(results.length,2); assert.deepEqual(results.map(m => m.tool_call_id),['preview-write','preview-bash']);
      assert(JSON.parse(results[0].content).written_bytes > 0);
      const bash = JSON.parse(results[1].content);
      assert.equal(bash.stdout,'preview-bash-proof'); assert.equal(bash.exit_code,0);
      assert.equal(bash.canceled,false); assert.equal(bash.timed_out,false);
      f.results = results.length;
      delta(res,{content:'preview-final-answer'}); end(res,'stop');
    }
  } catch (e) {
    failure ??= e;
    req.resume();
    if (!res.headersSent) res.writeHead(500);
    res.end();
  }
});
server.on('connection', socket => {sockets.add(socket);socket.once('close',()=>sockets.delete(socket));});

async function run(mode, url) {
  const home = join(base,mode,'home'), project = join(base,mode,'project');
  await mkdir(join(home,'.thin'),{recursive:true}); await mkdir(project,{recursive:true});
  const config = JSON.stringify({
    llm:{default:'local/fixture-model',providers:{local:{base_url:url,api_key_env:'THIN_FIXTURE_KEY',models:{'fixture-model':{protocol:'chat',context_tokens:32768}}}}},
    // Explicit opt-out: fixture has no external metadata/known input price.
    limits:{low_price_input:false,max_output_tokens:16000,summary_tokens:100,safety_tokens:100,request_timeout_ms:20000,task_timeout_ms:30000,command_timeout_ms:3000,cleanup_grace_ms:100,cleanup_timeout_ms:2000},
  },null,2)+'\n';
  const configPath = join(home,'.thin/config.json');
  await writeFile(configPath,config,{mode:0o600});
  const f = active = {mode,project,requests:0,results:0,earlyAbsence:0,gates:new Set(),waiters:new Map()};
  const child = spawn(pty,[],{cwd:project,detached:true,stdio:['ignore','pipe','pipe'],env:{
    PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
    THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,
    THIN_APP_TEST_URL:url,THIN_APP_TEST_MODE:`tool-preview-${mode}`,
  }});
  let owned = true, localFailure, bytes = 0, rejectWait, gateTail = '';
  const chunks = [];
  const stop = signal => {
    if (owned && child.exitCode === null && child.signalCode === null && child.pid) {
      try {process.kill(-child.pid,signal);} catch(e) {if(e.code !== 'ESRCH') localFailure ??= e;}
    }
  };
  const abandon = () => {child.stdout.destroy();child.stderr.destroy();rejectWait?.(localFailure);};
  const timer = setTimeout(()=>{localFailure ??= new Error(`${mode}: watchdog`);stop('SIGTERM');if(!owned) abandon();},40000);
  const escalation = setTimeout(()=>{localFailure ??= new Error(`${mode}: cleanup watchdog`);stop('SIGKILL');abandon();},43000);
  const capture = b => {
    bytes += b.length;
    if(bytes > 2*1024*1024) {localFailure ??= new Error('output bound');stop('SIGTERM');return;}
    chunks.push(b);
  };
  child.stdout.on('data',capture);
  child.stderr.on('data',b=>{
    capture(b); gateTail += b.toString('utf8');
    let at;
    while((at=gateTail.indexOf('\n')) >= 0) {
      const line = gateTail.slice(0,at);gateTail=gateTail.slice(at+1);
      if(line.startsWith('PREVIEW_GATE=')) {
        const name=line.slice('PREVIEW_GATE='.length);
        if(f.gates.has(name)) {localFailure ??= new Error(`duplicate gate ${name}`);stop('SIGTERM');}
        f.gates.add(name);f.waiters.get(name)?.();f.waiters.delete(name);
      }
    }
    if(gateTail.length>8192) gateTail=gateTail.slice(-8192);
  });
  child.once('exit',()=>{owned=false;if(localFailure) abandon();});
  try {
    const result = await new Promise((resolve,reject)=>{
      rejectWait=reject;
      child.once('error',e=>{owned=false;reject(e);});
      child.once('close',(code,signal)=>{owned=false;resolve({code,signal});});
    });
    const output=Buffer.concat(chunks).toString('utf8');
    if(localFailure) throw localFailure;
    if(failure) throw failure;
    assert.equal(result.signal,null,`${mode}: signal`);
    assert.equal(result.code,0,`${mode}: driver failed\n${output}`);
    for(const secret of ['fixture-secret-never-log','PREVIEW_RAW_CONTENT_SECRET','PTY_SESSION_ID=']) assert(!output.includes(secret));
    assert.deepEqual([...f.gates],['header','partial','path-absent',mode==='cancel'?'canceled':'finish','verified']);
    assert.equal(f.requests,mode==='cancel'?1:2); assert.equal(f.earlyAbsence,1);
    assert.equal(f.results,mode==='cancel'?0:2);
    if(mode==='cancel') await absent(join(project,'preview-owned.txt'));
    else assert.equal(await readFile(join(project,'preview-owned.txt'),'utf8'),content);
    assert.equal(await readFile(configPath,'utf8'),config);
    await absent(join(home,'.thin/sessions'));await absent(join(project,'.thin/sessions'));
    await absent(join(project,'.thin/settings.json'));
    scenarios++;
    console.log(`PASS tool-preview-${mode}: HTTP=${f.requests}, ACK gates=${f.gates.size}, early absence=${f.earlyAbsence}, real results=${f.results}`);
  } finally {clearTimeout(timer);clearTimeout(escalation);stop('SIGTERM');}
}
try {
  await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
  const url=`http://127.0.0.1:${server.address().port}/v1`;
  for(const mode of ['success','cancel']) await run(mode,url);
  console.log(`PASS test-tool-preview: scenarios=${scenarios}, HTTP=${requests}, no external APIs`);
} catch(e) {console.error(`FAIL test-tool-preview: completed=${scenarios}, HTTP=${requests}`);throw e;}
finally {
  for(const socket of sockets) socket.destroy();
  await new Promise(resolve=>server.close(resolve));
  await rm(base,{recursive:true,force:true});
}
