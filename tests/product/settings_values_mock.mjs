// Owned HOME/project + loopback + real owned PTY. No real credentials or APIs.
// --settings-values-only; driver mode settings-values. Each stderr gate is
// emitted after a completed frame and released only after disk/socket checks.
import http from 'node:http';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const MAIN_KEY = 'values-main-fake-never-log', AUX_KEY = 'values-aux-fake-never-log';
const MAIN = 'fixture-main', AUX = 'family/judge';
const WARMUP = 'values-warmup-private-marker', TASK = 'values-task-private-marker';
const COMMAND = "printf 'values-shell-proof\\n'", CALL = 'values-owned-bash';
const phases = [
  'opened', 'compaction', 'current', 'invalid-empty', 'invalid-zero',
  'invalid-overflow', 'edit-cancel', 'staged-cancel', 'canceled', 'command-staged', 'command',
  'request', 'output', 'output-auto', 'output-restored', 'task', 'decision-menu', 'closed',
];
const changes = {
  compaction:['limits','compaction_enabled',false],
  command:['limits','command_timeout_ms',120000],
  request:['limits','request_timeout_ms',60000],
  output:['limits','max_output_tokens',4096],
  'output-auto':['limits','max_output_tokens',null],
  'output-restored':['limits','max_output_tokens',4096],
  task:['limits','task_timeout_ms',900000],
};

export async function settingsValuesRegressions({app, pty, execute, send}) {
  const root = await mkdtemp(join(tmpdir(),'thin-settings-values-'));
  const home = join(root,'home'), project = join(root,'project');
  const configPath = join(home,'.thin/config.json');
  let stage = 'prepare', fixtureError, mainPosts = 0, auxPosts = 0, connections = 0;
  let primarySocket, primarySystem, expected, previousBytes, closed = false, warmAt, driverResult;
  const sockets = new Set(), gates = [];
  let gateQueue = Promise.resolve();
  const fail = error => { fixtureError ??= error; };
  const server = http.createServer(async (req,res) => {
    try {
      assert.equal(req.method,'POST');
      let raw = '', bytes = 0;
      for await (const chunk of req) {
        bytes += chunk.length; assert(bytes < 1024*1024); raw += chunk;
      }
      const body = JSON.parse(raw);
      assert.equal(body.stream,true,'ordinary Chat must use SSE');
      if (req.url === '/aux/v1/chat/completions') {
        auxPosts++;
        assert(closed); assert.equal(mainPosts,2); assert.equal(auxPosts,1);
        assert.equal(req.headers.authorization,`Bearer ${AUX_KEY}`);
        assert.equal(body.model,AUX);
        assert(!body.tools || body.tools.length === 0);
        assert.equal(body.max_tokens ?? body.max_completion_tokens,1024);
        assert.equal(body.messages.length,2);
        const [system,input] = body.messages;
        assert.equal(system.role,'system'); assert(system.content.startsWith('Review only'));
        assert.notDeepEqual([system],primarySystem);
        assert.equal(input.role,'user');
        const envelope = JSON.parse(input.content);
        assert.deepEqual(Object.keys(envelope).sort(),['data','operation']);
        assert.equal(envelope.operation,'command'); assert.equal(envelope.data.command,COMMAND);
        for (const hidden of [WARMUP,TASK,'values-warmup-answer',MAIN_KEY,AUX_KEY])
          assert(!JSON.stringify(body.messages).includes(hidden));
        // Valid strict JSON review carried by normal streaming Chat chunks.
        send(res,'chat','{"timeout_ms":1000,"ask":false}');
        return;
      }
      assert.equal(req.url,'/primary/v1/chat/completions');
      mainPosts++; assert(mainPosts <= 3);
      assert.equal(req.headers.authorization,`Bearer ${MAIN_KEY}`);
      assert.equal(body.model,MAIN); assert.equal(body.reasoning_effort,'high');
      const system = body.messages.filter(m=>m.role==='system'); assert(system.length > 0);
      assert.equal(body.max_tokens ?? body.max_completion_tokens,mainPosts === 1 ? 100 : 4096);
      if (mainPosts === 1) {
        primarySystem = system; primarySocket = req.socket; warmAt = performance.now();
        assert.equal(auxPosts,0);
        assert.equal(body.messages.filter(m=>m.role==='user').at(-1).content,WARMUP);
        send(res,'chat','values-warmup-answer');
      } else {
        assert(closed); assert.deepEqual(system,primarySystem);
        // Exact object identity is required: counts alone cannot prove reuse.
        assert.equal(req.socket,primarySocket,'warm primary socket replaced');
        assert(body.messages.some(m=>m.role==='user' && m.content === WARMUP));
        assert(body.messages.some(m=>m.role==='assistant' && m.content === 'values-warmup-answer'));
        assert(body.messages.some(m=>m.role==='user' && m.content === TASK));
        if (mainPosts === 2) {
          assert(performance.now()-warmAt < 30000,'UI journey exceeded primary idle TTL');
          assert.equal(auxPosts,0);
          send(res,'chat','',[{id:CALL,name:'bash',arguments:JSON.stringify({command:COMMAND})}]);
        } else {
          assert.equal(auxPosts,1);
          const calls = body.messages.flatMap(m=>m.tool_calls ?? []);
          assert.equal(calls.length,1); assert.equal(calls[0].id,CALL);
          assert.equal(calls[0].function.name,'bash');
          const results = body.messages.filter(m=>m.role==='tool');
          assert.equal(results.length,1); assert.equal(results[0].tool_call_id,CALL);
          const value = JSON.parse(results[0].content);
          assert.equal(value.stdout,'values-shell-proof\n'); assert.equal(value.stderr,'');
          assert.equal(value.exit_code,0); assert.equal(value.timed_out,false);
          send(res,'chat','values-tool-result-verified');
        }
      }
    } catch (error) { fail(error); res.writeHead(500); res.end(); }
  });
  server.keepAliveTimeout = 60000;
  server.on('connection',socket => {
    connections++; sockets.add(socket); socket.on('close',()=>sockets.delete(socket));
  });
  try {
    await mkdir(join(home,'.thin'),{recursive:true,mode:0o700}); await mkdir(project);
    await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
    const origin = `http://127.0.0.1:${server.address().port}`;
    const provider = (path,key,models) => ({base_url:`${origin}/${path}/v1`,api_key:key,
      api_key_env:'',kind:null,chat_max_tokens:false,models});
    expected = {
      memory:{auto:false},
      llm:{default:`primary/${MAIN}`,reasoning_effort:'high',providers:{
        primary:provider('primary',MAIN_KEY,{[MAIN]:{protocol:'chat',context_tokens:32768,
          output_tokens:8192,reasoning:{format:'standard',map:{off:'none',high:'high'}}}}),
        aux:provider('aux',AUX_KEY,{[AUX]:{protocol:'chat',context_tokens:4096}}),
      }},
      limits:{command_timeout_ms:123456,command_max_timeout_ms:3600000,
        read_bytes:65536,output_bytes:32768,low_price_input:false,input_margin_tokens:5000,
        safety_tokens:100,max_tool_calls:128,task_timeout_ms:30000,request_timeout_ms:10000,
        model_refresh_ttl_ms:14400000,model_refresh_cooldown_ms:300000,
        cleanup_grace_ms:1000,cleanup_timeout_ms:5000,core_bytes:2048,index_bytes:8192,
        shard_bytes:32768,compaction_enabled:true,compaction_trigger_percent:80,
        compaction_target_percent:50,max_response_bytes:8388608,max_event_bytes:1048576,
        max_output_tokens:100,summary_tokens:100},
      decision:{enabled:true,model:`aux/${AUX}`,
        max_input_tokens:8192,max_output_tokens:1024,max_state_bytes:16384},
    };
    previousBytes = JSON.stringify(expected);
    await writeFile(configPath,previousBytes,{mode:0o600});
    async function saved() {
      const bytes = await readFile(configPath,'utf8');
      assert.deepEqual(JSON.parse(bytes),expected,'whole disk JSON changed outside target preference');
      assert.equal((await stat(configPath)).mode & 0o777,0o600);
      assert.deepEqual(await readdir(join(home,'.thin')),['config.json']);
      return bytes;
    }
    async function gate(name) {
      stage = `gate ${name}`;
      assert.deepEqual(gates,phases.slice(0,gates.length));
      assert.equal(mainPosts,1); assert.equal(auxPosts,0); assert.equal(connections,1);
      assert(primarySocket && !primarySocket.destroyed,'primary warm socket lost in menu');
      if (changes[name]) {
        const [section,key,value] = changes[name];
        if (value === null) delete expected[section][key]; // writeDisk omits null optionals.
        else expected[section][key] = value;
      }
      const bytes = await saved();
      if (!changes[name]) assert.equal(bytes,previousBytes,'cancel/stage/invalid rewrote config');
      if (name === 'output-auto') assert(!Object.hasOwn(JSON.parse(bytes).limits,'max_output_tokens'));
      previousBytes = bytes;
      if (name === 'closed') closed = true;
      await writeFile(join(project,`settings-values-release-${name}`),'release',{flag:'wx',mode:0o600});
    }
    const attach = child => {
      let pending = '';
      child.stderr.on('data',chunk => {
        pending += chunk.toString('utf8');
        if (pending.length > 65536) { fail(new Error('gate line bound')); pending = ''; return; }
        let end;
        while ((end=pending.indexOf('\n')) >= 0) {
          const line = pending.slice(0,end).replace(/\r$/,''); pending = pending.slice(end+1);
          const match = /^SETTINGS_VALUES_GATE=([a-z-]+)$/.exec(line);
          if (!match) continue;
          if (!phases.includes(match[1])) { fail(new Error('unknown gate')); continue; }
          gates.push(match[1]);
          gateQueue = gateQueue.then(()=>gate(match[1])).catch(fail);
        }
      });
    };
    stage = 'owned PTY';
    const result = driverResult = await execute(pty,[],{
      PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
      THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,
      THIN_APP_TEST_URL:`${origin}/primary/v1`,THIN_APP_TEST_MODE:'settings-values',
    },project,attach,60000);
    await gateQueue;
    if (fixtureError) throw fixtureError;
    assert.equal(result.code,0); assert.equal(result.signal,null);
    for (const key of [MAIN_KEY,AUX_KEY]) assert(!result.output.includes(key));
    assert(!result.output.includes('PTY_SESSION_ID='));
    assert.deepEqual(gates,phases); assert.equal(mainPosts,3); assert.equal(auxPosts,1);
    assert.equal(connections,2); await saved();
    assert.deepEqual((await readdir(project)).sort(),phases.map(n=>`settings-values-release-${n}`).sort());
    console.log('PASS settings/values: five preferences and shared request timeout; decision menu has no timeout; stage/cancel/invalid unchanged; output Auto omitted; zero menu HTTP; warm socket and canonical bash verified');
  } catch (error) {
    // Never print assertion operands containing config/wire/terminal secrets.
    const safe = new Error('settings values fixture failed');
    safe.fixtureCase = 'settings/values';
    const line = /settings_values_mock\.mjs:(\d+):/.exec(error.stack ?? '')?.[1];
    const tag = /(?:error|Error): ([A-Za-z0-9_]+)/.exec(driverResult?.output ?? '')?.[1] ?? 'none';
    safe.fixtureCheck = `${stage}${line ? ` at ${line}` : ''} primary:${mainPosts} aux:${auxPosts} connections:${connections} driver:${driverResult?.code ?? 'unknown'}/${driverResult?.signal ?? 'none'} tag:${tag}`;
    throw safe;
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve=>server.close(resolve));
    await rm(root,{recursive:true,force:true});
  }
}
