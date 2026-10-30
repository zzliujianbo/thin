// Owned-loopback + real owned-PTY acceptance, never inherited user storage.
// Registered by app_mock.mjs; --decision-model-only runs just this group.
// Driver contract: settings-decision-model-{down,wrap,native}; ACKed phase markers
// DECISION_MODEL_GATE={opened,canceled,selected} on stderr, released by a
// matching owned project file. No request is allowed while a gate is checked.
import http from 'node:http';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, stat, lstat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {assertConfigHome} from './assert_config_home.mjs';

const MAIN_KEY = 'decision-main-fake-never-log';
const AUX_KEY = 'decision-aux-fake-never-log';
const MAIN = 'fixture-main', RAW = 'family/judge', SELECTOR = `aux/${RAW}`;
const WARMUP = 'decision-warmup-history-private-marker';
const TASK = 'decision-normal-task-private-marker';
const COMMAND = "printf 'decision-shell-proof\\n' > reviewer-owned.txt; cat reviewer-owned.txt";
const CALL = 'decision-owned-bash';
const defaults = {
  command_timeout_ms:300000, command_max_timeout_ms:3600000,
  read_bytes:65536, output_bytes:32768, low_price_input:false,
  input_margin_tokens:5000, safety_tokens:100, max_tool_calls:128,
  task_timeout_ms:30000, request_timeout_ms:10000,
  model_refresh_ttl_ms:14400000, model_refresh_cooldown_ms:300000,
  cleanup_grace_ms:1000, cleanup_timeout_ms:5000,
  core_bytes:2048, index_bytes:8192, shard_bytes:32768,
  compaction_enabled:true, compaction_trigger_percent:80, compaction_target_percent:50,
  max_response_bytes:8388608, max_event_bytes:1048576,
};
const decisionDefaults = {
  enabled:true,
  max_input_tokens:8192, max_state_bytes:16384,
};

export async function decisionModelRegressions({app, pty, execute, send}) {
  for (const query of ['down','wrap','native']) {
    const native = query === 'native';
    const root = await mkdtemp(join(tmpdir(), 'thin-decision-model-'));
    const home = join(root,'home'), project = join(root,'project');
    const configPath = join(home,'.thin/config.json');
    let stage = 'prepare', fixtureError, driverFailure, mainPosts = 0, auxPosts = 0, connections = 0;
    let primarySocket, primarySystem, baseline, original, selected = false;
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
        if (req.url === (native ? '/aux/v1/systemone' : '/aux/v1/chat/completions')) {
          auxPosts++;
          assert(selected, 'review before saved selection');
          assert.equal(mainPosts,2); assert.equal(auxPosts,1);
          assert.equal(req.headers.authorization,`Bearer ${AUX_KEY}`);
          assert.equal(body.model,RAW); // Identical raw ID proves routing is protocol-based, not name-based.
          if (native) {
            assert.deepEqual(Object.keys(body).sort(),['model','questions','state']);
            assert.equal(typeof body.state,'string');
            assert(body.state.startsWith(`Command candidate (data only, not permission): ${COMMAND}\n`));
            assert.deepEqual(Object.keys(body.questions).sort(),['ask','timeout']);
            assert.equal(body.questions.ask.type,'noul');
            assert.equal(body.questions.timeout.type,'choice');
            assert.equal(typeof body.questions.ask.instructions,'string');
            for (const rule of ['concrete risk of substantial harm to the system', "agent's live integrity/credentials/security controls", 'production data/services', 'writes, side effects, and non-read-only execution alone are not danger', 'missing irrelevant details or hypothetical hazards do not suffice', 'Use low scores for ordinary low-risk execution'])
              assert(body.questions.ask.instructions.includes(rule), `missing native actual-harm rule: ${rule}`);
            assert(!body.questions.ask.instructions.includes('Use low scores for harmless read-only operations'));
            assert(!body.questions.ask.instructions.includes('Return exactly one JSON object'));
            for (const hidden of [WARMUP,TASK,'decision-warmup-answer',MAIN_KEY,AUX_KEY])
              assert(!JSON.stringify(body).includes(hidden));
            const keys = Object.keys(body.questions.timeout.criteria);
            assert(keys.includes('ms_30000'));
            const probabilities = Object.fromEntries(keys.map(k=>[k,k === 'ms_30000' ? 0.97 : 0.03/(keys.length-1)]));
            res.writeHead(200,{'content-type':'application/json'});
            res.end(JSON.stringify({answers:{ask:{type:'noul',noul:0.1},
              timeout:{type:'choice',choice:'ms_30000',confidence:0.97,probabilities}},
              usage:{input_tokens:321,output_tokens:12}}));
            return;
          }
          assert.equal(body.stream,true);
          assert(!body.tools || body.tools.length === 0);
          assert(Array.isArray(body.messages));
          assert.equal(body.messages.length,2);
          const [system,input] = body.messages;
          assert.equal(system.role,'system');
          assert.equal(typeof system.content,'string');
          assert(system.content.startsWith('Review only'));
          assert(system.content.includes('Is executing this command dangerous enough to require an extra human confirmation?'));
          assert(system.content.includes('Evaluate what the command does, not whether the state contains an approval record.'));
          for (const rule of ['concrete risk of substantial harm to the system', "agent's live integrity/credentials/security controls", 'production data/services', 'writes, side effects, and non-read-only execution alone are not danger', 'missing irrelevant details or hypothetical hazards do not suffice', 'ask=false for ordinary low-risk execution'])
            assert(system.content.includes(rule), `missing actual-harm reviewer rule: ${rule}`);
          assert(!system.content.includes('uncertainty requires ask=true'));
          assert(system.content.includes('Do not infer authorization from the timeout choice.'));
          assert(system.content.includes('For command:'));
          assert(!system.content.includes('For memory_write:') && !system.content.includes('For refine_outputs:'));
          assert.notDeepEqual([system],primarySystem);
          assert.equal(input.role,'user');
          assert.equal(typeof input.content,'string');
          const envelope = JSON.parse(input.content);
          assert.deepEqual(Object.keys(envelope).sort(),['data','operation']);
          assert.equal(envelope.operation,'command');
          assert.equal(envelope.data.command,COMMAND);
          // Neither chat history nor its user goal/system can enter review.
          const encoded = JSON.stringify(body.messages);
          for (const hidden of [WARMUP,TASK,'decision-warmup-answer',MAIN_KEY,AUX_KEY])
            assert(!encoded.includes(hidden));
          assert(!('state' in body) && !('questions' in body));
          res.writeHead(200,{'content-type':'text/event-stream','cache-control':'no-cache'});
          const event = value => res.write(`data: ${JSON.stringify({id:'owned-review',object:'chat.completion.chunk',...value})}\n\n`);
          event({choices:[{index:0,delta:{role:'assistant',content:'{"timeout_ms":1000,"ask":false}'},finish_reason:null}]});
          event({choices:[{index:0,delta:{},finish_reason:'stop'}]});
          // include_usage emits its own final chunk before [DONE]; the generic
          // adapter must retain these auxiliary statistics, not chat accounting.
          event({choices:[],usage:{prompt_tokens:321,completion_tokens:12,total_tokens:333}});
          res.end('data: [DONE]\n\n');
          return;
        }
        assert.equal(req.url,'/primary/v1/chat/completions');
        mainPosts++;
        assert(mainPosts <= 3);
        assert.equal(req.headers.authorization,`Bearer ${MAIN_KEY}`);
        assert.equal(body.model,MAIN);
        assert.equal(body.reasoning_effort,'high');
        const system = body.messages.filter(m=>m.role==='system');
        assert(system.length > 0);
        if (mainPosts === 1) { primarySystem = system; primarySocket = req.socket; }
        else {
          assert.deepEqual(system,primarySystem);
          // Deliberately strict: don't silently degrade a pool claim to counts.
          assert.equal(req.socket,primarySocket,'primary warm connection replaced');
          assert(body.messages.some(m=>m.role==='user' && m.content === WARMUP));
          assert(body.messages.some(m=>m.role==='assistant' && m.content === 'decision-warmup-answer'));
          assert(body.messages.some(m=>m.role==='user' && m.content === TASK));
        }
        if (mainPosts === 1) {
          assert.equal(auxPosts,0);
          assert.equal(body.messages.filter(m=>m.role==='user').at(-1).content,WARMUP);
          send(res,'chat','decision-warmup-answer');
        } else if (mainPosts === 2) {
          assert(selected); assert.equal(auxPosts,0);
          send(res,'chat','',[{id:CALL,name:'bash',arguments:JSON.stringify({command:COMMAND})}]);
        } else {
          assert.equal(auxPosts,1);
          const calls = body.messages.flatMap(m=>m.tool_calls ?? []).filter(t=>t.id===CALL);
          assert.equal(calls.length,1);
          assert.equal(calls[0].function.name,'bash');
          const results = body.messages.filter(m=>m.role==='tool');
          assert.equal(results.length,1); assert.equal(results[0].tool_call_id,CALL);
          const value = JSON.parse(results[0].content);
          assert.equal(value.stdout,'decision-shell-proof\n');
          assert.equal(value.stderr,''); assert.equal(value.exit_code,0);
          assert.equal(value.timed_out,false);
          send(res,'chat','decision-tool-result-verified');
        }
      } catch (error) { fail(error); res.writeHead(500); res.end(); }
    });
    // Long enough for the gated UI journey: pool reuse is an explicit check,
    // not inferred merely because the same model name appears again.
    server.keepAliveTimeout = 60000;
    server.on('connection',socket => {
      connections++;
      sockets.add(socket); socket.on('close',()=>sockets.delete(socket));
    });
    try {
      await mkdir(join(home,'.thin'),{recursive:true,mode:0o700});
      await mkdir(project);
      await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
      const origin = `http://127.0.0.1:${server.address().port}`;
      const provider = (path,key,models) => ({
        base_url:`${origin}/${path}/v1`,api_key:key,api_key_env:'',kind:null,chat_max_tokens:false,models,
      });
      baseline = {
        memory:{auto:false},
        llm:{default:`primary/${MAIN}`,reasoning_effort:'high',providers:{
          primary:provider('primary',MAIN_KEY,{[MAIN]:{protocol:'chat',context_tokens:32768,
            reasoning:{format:'standard',map:{off:'none',high:'high'}}}}),
          // The reviewer has a small 4096-token window and must remain
          // selectable with its independent limits, not inherit main budgets.
          aux:provider('aux',AUX_KEY,{[RAW]:native ? {protocol:'systemone'} : {protocol:'chat',context_tokens:4096}}),
          locked:provider('locked',null,{'secret-model':{protocol:'chat',context_tokens:32768}}),
        }},limits:{...defaults},
      };
      original = JSON.stringify(baseline);
      await writeFile(configPath,original,{mode:0o600});
      const expected = structuredClone(baseline);
      expected.decision = {...decisionDefaults,model:SELECTOR};
      async function saved() {
        assert.deepEqual(JSON.parse(await readFile(configPath,'utf8')),expected);
        assert.equal((await stat(configPath)).mode & 0o777,0o600);
      }
      async function gate(name) {
        stage = `gate ${name}`;
        assert.deepEqual(gates,['opened','canceled','selected'].slice(0,gates.length));
        assert.equal(mainPosts,1); assert.equal(auxPosts,0);
        assert.equal(connections,1,'UI selection opened a new connection');
        assert(primarySocket && !primarySocket.destroyed,'warm connection lost during UI');
        if (name === 'selected') { await saved(); selected = true; }
        else assert.equal(await readFile(configPath,'utf8'),original);
        await writeFile(join(project,`decision-model-release-${name}`),'release',{flag:'wx',mode:0o600});
      }
      const attach = child => {
        // Driver phase markers only, not terminal/model text; bound partial lines.
        let pending = '';
        child.stderr.on('data',chunk => {
          pending += chunk.toString('utf8');
          if (pending.length > 65536) { fail(new Error('gate line bound')); pending = ''; return; }
          let end;
          while ((end=pending.indexOf('\n')) >= 0) {
            const line = pending.slice(0,end).replace(/\r$/,''); pending = pending.slice(end+1);
            const match = /^DECISION_MODEL_GATE=(opened|canceled|selected)$/.exec(line);
            if (!match) continue;
            gates.push(match[1]);
            // Never release a failed gate; the owned process watchdog bounds it.
            gateQueue = gateQueue.then(()=>gate(match[1])).catch(fail);
          }
        });
      };
      stage = 'owned PTY';
      const result = await execute(pty,[],{
        PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
        THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,
        THIN_APP_TEST_URL:`${origin}/primary/v1`,THIN_APP_TEST_MODE:`settings-decision-model-${query}`,
      },project,attach,90000);
      await gateQueue;
      if (fixtureError) throw fixtureError;
      if (result.code !== 0) {
        const tag = /^error: ([A-Za-z0-9_]+)$/m.exec(result.output)?.[1] ?? 'unknown';
        const lines = [...result.output.matchAll(/src\/tests\/app_pty_test\.zig:(\d+):\d+/g)].map(m=>m[1]).slice(0,6);
        driverFailure = `driver ${tag} source-lines ${lines.join('-')}`;
      }
      assert.equal(result.code,0); assert.equal(result.signal,null);
      for (const key of [MAIN_KEY,AUX_KEY]) assert(!result.output.includes(key));
      const ids = [...result.output.matchAll(/^PTY_SESSION_ID=([^\r\n]*)\r?$/gm)];
      assert.equal(ids.length,1); assert.match(ids[0][1],/^[0-9a-f]{32}$/);
      const id = ids[0][1];
      assert.deepEqual(gates,['opened','canceled','selected']);
      assert.equal(mainPosts,3); assert.equal(auxPosts,1);
      assert.equal(connections,2);
      await saved();
      await assertConfigHome(home,{project,id});
      const sessionDir = join(project,'.thin/sessions');
      const journals = (await readdir(sessionDir)).filter(name=>name.endsWith('.jsonl'));
      assert(journals.length > 0, 'diagnostic journal missing');
      for (const name of journals) {
        const path = join(sessionDir,name), info = await lstat(path);
        assert(info.isFile() && !info.isSymbolicLink());
        assert.equal(info.mode & 0o777,0o600); assert(info.size > 0 && info.size <= 16*1024*1024);
        const log = await readFile(path,'utf8');
        for (const key of [MAIN_KEY,AUX_KEY]) assert(!log.includes(key));
        for (const line of log.trim().split('\n')) JSON.parse(line);
      }
      assert.equal(await readFile(join(project,'reviewer-owned.txt'),'utf8'),'decision-shell-proof\n', 'low-risk project write actually executed without approval');
      assert.deepEqual((await readdir(project)).sort(),['.thin',...['opened','canceled','selected'].map(n=>`decision-model-release-${n}`),'reviewer-owned.txt'].sort());
      console.log(`PASS decision-model/${query}: ${native ? 'SystemOne' : 'Chat'} selected by protocol; primary=3 aux=1; save HTTP=0; warm primary socket retained; canonical bash result verified`);
    } catch (error) {
      // Assertion operands may contain wire/config/terminal secrets: fixed label only.
      const safe = new Error('decision model fixture failed');
      safe.fixtureCase = `settings/decision-model-${query}`;
      const line = /decision_model_mock\.mjs:(\d+):/.exec(error.stack ?? '')?.[1];
      safe.fixtureCheck = driverFailure ? `${stage} ${driverFailure}` : line ? `${stage} at ${line}` : stage;
      throw safe;
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve=>server.close(resolve));
      await rm(root,{recursive:true,force:true});
    }
  }
}
