// Owned loopback/PTY acceptance only; never inherited credentials or storage.
// IMAGE_MODEL_GATE phases are completed fresh-frame observations, released by
// exclusive files after HTTP/socket/config assertions, not timer evidence.
import http from 'node:http';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, readdir, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';

const MAIN_KEY = 'image-primary-fake-never-log', AUX_KEY = 'image-aux-fake-never-log';
const MAIN = 'fixture-main', SELECTOR = 'aux/deepseek-flash';
const WARMUP = 'image-warmup-history-private-marker', TASK = 'image-normal-task-private-marker';
const QUESTION = 'What is visible in this owned test image?';
const DESCRIPTION = 'Owned one-pixel image inspected.';
const REMOTE_SECRET = 'image-raw-remote-error-must-not-leak';
const CALL = 'owned-read-image', FILE = 'owned-pixel.png';
const FIRST_FOUR = ['read_file','write_file','bash','memory'];
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
  max_output_tokens:100, summary_tokens:100,
};
// Same 1x1 PNG container as tools/image_file.zig, independently repair/verify
// chunk CRCs. Exact bytes are compared after decoding the received data URL.
function ownedPng() {
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jP1sAAAAASUVORK5CYII=','base64');
  for (let pos=8; pos<bytes.length;) {
    const n = bytes.readUInt32BE(pos);
    let crc = 0xffffffff;
    for (const byte of bytes.subarray(pos+4,pos+8+n)) {
      crc ^= byte;
      for (let bit=0;bit<8;bit++) crc = (crc>>>1) ^ ((crc&1) ? 0xedb88320 : 0);
    }
    bytes.writeUInt32BE((crc ^ 0xffffffff)>>>0,pos+8+n);
    pos += n+12;
  }
  return bytes;
}
const PNG = ownedPng();
const forbidden = [MAIN_KEY,AUX_KEY,REMOTE_SECRET,PNG.toString('base64'),'data:image/'];
function clean(bytes) {
  const text = bytes.toString('utf8');
  for (const hidden of forbidden) assert(!text.includes(hidden),'private wire payload leaked');
  assert(!bytes.includes(PNG),'raw image leaked');
}
async function scan(directory) {
  let files = 0;
  for (const entry of await readdir(directory,{withFileTypes:true})) {
    const path = join(directory,entry.name);
    if (entry.isDirectory()) files += await scan(path);
    else { assert(entry.isFile()); clean(await readFile(path)); files++; }
  }
  return files;
}

export async function imageModelRegressions({app,pty,execute,send}) {
  for (const kind of ['pty','success','malformed','timeout']) {
    const isPty = kind === 'pty';
    const root = await mkdtemp(join(tmpdir(),'thin-image-model-'));
    const home = join(root,'home'), project = join(root,'project'), configPath = join(home,'.thin/config.json');
    let stage = 'prepare', fixtureError, mainPosts = 0, auxPosts = 0, connections = 0;
    let primarySocket, primarySystem, primaryTools, original, baseline, selected = !isPty, off = false;
    const sockets = new Set(), gates = [];
    let gateQueue = Promise.resolve();
    const fail = error => { fixtureError ??= error; };
    const server = http.createServer(async (req,res) => {
      try {
        assert.equal(req.method,'POST');
        let raw = '', bytes = 0;
        for await (const chunk of req) { bytes += chunk.length; assert(bytes < 1024*1024); raw += chunk; }
        const body = JSON.parse(raw);
        if (req.url === '/aux/v1/chat/completions') {
          auxPosts++;
          assert(selected && !off); assert.equal(auxPosts,1);
          assert.equal(mainPosts,isPty ? 2 : 1);
          assert.notEqual(req.socket,primarySocket);
          assert.equal(req.headers.authorization,`Bearer ${AUX_KEY}`);
          assert.deepEqual(Object.keys(body).sort(),['max_tokens','messages','model','stream','thinking']);
          assert.equal(body.model,'deepseek-flash'); assert.equal(body.stream,false);
          assert.deepEqual(body.thinking,{type:'disabled'});
          assert(Number.isInteger(body.max_tokens) && body.max_tokens > 0 && body.max_tokens <= 2048);
          assert.equal(body.messages.length,2);
          const [system,user] = body.messages;
          assert.deepEqual(Object.keys(system).sort(),['content','role']);
          assert.equal(system.role,'system'); assert.equal(typeof system.content,'string');
          assert(system.content.startsWith('Inspect the supplied image'));
          assert(system.content.includes('untrusted data'));
          assert.deepEqual(Object.keys(user).sort(),['content','role']);
          assert.equal(user.role,'user'); assert.equal(user.content.length,2);
          assert.deepEqual(user.content[0],{type:'text',text:QUESTION});
          const url = user.content[1].image_url.url;
          assert.deepEqual(user.content[1],{type:'image_url',image_url:{url}});
          assert(url.startsWith('data:image/png;base64,'));
          assert.deepEqual(Buffer.from(url.slice('data:image/png;base64,'.length),'base64'),PNG);
          for (const hidden of [MAIN_KEY,AUX_KEY,WARMUP,TASK,'image-warmup-answer',FILE,project,home]) assert(!raw.includes(hidden));
          if (kind === 'timeout') return; // Owned socket stalls until shared request deadline.
          res.writeHead(200,{'content-type':'application/json'});
          res.end(JSON.stringify(kind === 'malformed' ? {choices:[],error:{message:REMOTE_SECRET}} : {
            choices:[{message:{role:'assistant',content:DESCRIPTION},finish_reason:'stop'}],
            usage:{prompt_tokens:321,completion_tokens:12,total_tokens:333,prompt_tokens_details:{cached_tokens:7}},
          }));
          return;
        }
        assert.equal(req.url,'/primary/v1/chat/completions');
        mainPosts++; assert(mainPosts <= (isPty ? 4 : 2));
        assert.equal(req.headers.authorization,`Bearer ${MAIN_KEY}`);
        assert.equal(body.model,MAIN); assert.equal(body.reasoning_effort,'high');
        clean(Buffer.from(raw));
        const system = body.messages.filter(m=>m.role==='system');
        if (mainPosts === 1) { primarySocket = req.socket; primarySystem = system; primaryTools = body.tools.slice(0,4); }
        else {
          assert.equal(req.socket,primarySocket,'warm primary socket replaced');
          assert.deepEqual(system,primarySystem);
        }
        const names = body.tools.map(t=>t.function.name);
        assert.deepEqual(names, selected && !off ? [...FIRST_FOUR,'read_image'] : FIRST_FOUR);
        assert.deepEqual(body.tools.slice(0,4),primaryTools,'Image changed an existing tool schema');
        if (isPty && mainPosts === 1) {
          assert.equal(auxPosts,0); assert.equal(body.messages.at(-1).content,WARMUP);
          send(res,'chat','image-warmup-answer'); return;
        }
        if (isPty) {
          assert(body.messages.some(m=>m.role==='user' && m.content===WARMUP));
          assert(body.messages.some(m=>m.role==='assistant' && m.content==='image-warmup-answer'));
        }
        if (mainPosts === (isPty ? 2 : 1)) {
          assert.equal(auxPosts,0); assert.equal(body.messages.at(-1).content,TASK);
          send(res,'chat','',[{id:CALL,name:'read_image',arguments:JSON.stringify({path:FILE,question:QUESTION})}]);
        } else {
          assert.equal(auxPosts,1);
          const calls = body.messages.flatMap(m=>m.tool_calls ?? []);
          assert.equal(calls.length,1); assert.equal(calls[0].id,CALL);
          assert.equal(calls[0].function.name,'read_image');
          const results = body.messages.filter(m=>m.role==='tool');
          assert.equal(results.length,1); assert.equal(results[0].tool_call_id,CALL);
          assert.equal(typeof results[0].content,'string');
          if (kind === 'malformed' || kind === 'timeout') {
            assert(!results[0].content.includes(DESCRIPTION));
            assert(results[0].content.includes(kind === 'malformed' ? 'InvalidImageResponse' : 'Timeout'));
          } else {
            const value = JSON.parse(results[0].content);
            assert.deepEqual(Object.keys(value).sort(),['description','height','mime','path','usage','usage_scope','width']);
            assert.equal(value.path,FILE); assert.equal(value.mime,'image/png');
            assert.equal(value.width,1); assert.equal(value.height,1); assert.equal(value.description,DESCRIPTION);
            assert.equal(value.usage_scope,'auxiliary_image');
            assert.equal(value.usage.input_tokens,321); assert.equal(value.usage.output_tokens,12);
            assert.equal(value.usage.total_tokens,333); assert.equal(value.usage.cached_input_tokens,7);
          }
          if (off) assert.equal(body.messages.at(-1).content,'image-off-proof');
          send(res,'chat',off ? 'image-off-verified' : 'image-tool-result-verified');
        }
      } catch (error) { fail(error); res.writeHead(500); res.end(); }
    });
    server.keepAliveTimeout = 60000;
    server.on('connection',socket=>{connections++; sockets.add(socket);socket.on('close',()=>sockets.delete(socket));});
    try {
      await mkdir(join(home,'.thin'),{recursive:true,mode:0o700}); await mkdir(project);
      await writeFile(join(project,FILE),PNG,{mode:0o600});
      await new Promise((resolve,reject)=>{server.once('error',reject);server.listen(0,'127.0.0.1',resolve);});
      const origin = `http://127.0.0.1:${server.address().port}`;
      const provider = (path,key,models)=>({base_url:`${origin}/${path}/v1`,api_key:key,api_key_env:'',kind:null,chat_max_tokens:false,models});
      baseline = {llm:{default:`primary/${MAIN}`,reasoning_effort:'high',providers:{
        primary:provider('primary',MAIN_KEY,{[MAIN]:{protocol:'chat',context_tokens:32768,reasoning:{format:'standard',map:{off:'none',high:'high'}}}}),
        aux:provider('aux',AUX_KEY,{'deepseek-flash':{},'not-image':{protocol:'chat',context_tokens:32768}}),
        locked:provider('locked',null,{'deepseek-flash':{}}),
      }},limits:{...defaults,request_timeout_ms:kind === 'timeout' ? 300 : 10000}};
      if (!isPty) baseline.image = {enabled:true,model:SELECTOR};
      original = JSON.stringify(baseline);
      await writeFile(configPath,original,{mode:0o600});
      const expected = structuredClone(baseline);
      async function saved(enabled) {
        // Off disables the helper but deliberately retains the chosen identity.
        expected.image = {enabled,model:SELECTOR};
        assert.deepEqual(JSON.parse(await readFile(configPath,'utf8')),expected);
        assert.equal((await stat(configPath)).mode & 0o777,0o600);
      }
      async function gate(name) {
        stage = `gate ${name}`;
        assert.deepEqual(gates,['opened','canceled','selected','off'].slice(0,gates.length));
        assert.equal(mainPosts,name === 'off' ? 3 : 1); assert.equal(auxPosts,name === 'off' ? 1 : 0);
        assert.equal(connections,name === 'off' ? 2 : 1);
        assert(primarySocket && !primarySocket.destroyed);
        if (name === 'selected') { await saved(true); selected = true; }
        else if (name === 'off') { await saved(false); off = true; }
        else assert.equal(await readFile(configPath,'utf8'),original);
        await writeFile(join(project,`image-model-release-${name}`),'release',{flag:'wx',mode:0o600});
      }
      const attach = child=>{
        let pending = '';
        child.stderr.on('data',chunk=>{
          pending += chunk.toString('utf8');
          if (pending.length > 65536) {fail(new Error('gate line bound'));pending='';return;}
          let end;
          while ((end=pending.indexOf('\n'))>=0) {
            const line = pending.slice(0,end).replace(/\r$/,''); pending=pending.slice(end+1);
            const match = /^IMAGE_MODEL_GATE=(opened|canceled|selected|off)$/.exec(line);
            if (match) {gates.push(match[1]);gateQueue=gateQueue.then(()=>gate(match[1])).catch(fail);}
          }
        });
      };
      stage = isPty ? 'owned PTY' : 'owned CLI';
      const result = await execute(isPty ? pty : app,isPty ? [] : ['--no-model-auto-refresh','--print',TASK],{
        PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',
        THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:project,
        THIN_APP_TEST_URL:`${origin}/primary/v1`,THIN_APP_TEST_MODE:'settings-image-model',
      },project,isPty ? attach : undefined,isPty ? 90000 : 15000);
      await gateQueue;
      if (fixtureError) throw fixtureError;
      clean(Buffer.from(result.output));
      if (result.code !== 0) {
        const tag = /^error: ([A-Za-z0-9_]+)$/m.exec(result.output)?.[1] ?? 'unknown';
        const lines = [...result.output.matchAll(/src\/tests\/app_pty_test\.zig:(\d+):\d+/g)].map(m=>m[1]).slice(0,6);
        stage += ` driver ${tag} source-lines ${lines.join('-')}`;
      }
      assert.equal(result.code,0); assert.equal(result.signal,null);
      assert.equal(mainPosts,isPty ? 4 : 2); assert.equal(auxPosts,1); assert.equal(connections,2);
      if (isPty) {
        assert.deepEqual(gates,['opened','canceled','selected','off']); await saved(false);
        assert.deepEqual(await readdir(join(home,'.thin')),['config.json']);
        assert.deepEqual((await readdir(project)).sort(),['.thin',FILE,...gates.map(n=>`image-model-release-${n}`)].sort());
      } else {
        assert(result.output.includes('image-tool-result-verified'));
        assert.equal(await readFile(configPath,'utf8'),original);
        // Scan only emitted private storage, NOT the original PNG or config.
      }
      {
        const entries = (await readdir(join(home,'.thin'))).filter(n=>n!=='config.json');
        let scanned = 0;
        for (const name of entries) {
          const path = join(home,'.thin',name);
          if ((await stat(path)).isDirectory()) scanned += await scan(path);
          else {clean(await readFile(path));scanned++;}
        }
        const projectEntries = (await readdir(project)).filter(n=>n!==FILE && !n.startsWith('image-model-release-'));
        for (const name of projectEntries) {
          const path = join(project,name);
          if ((await stat(path)).isDirectory()) scanned += await scan(path);
          else {clean(await readFile(path));scanned++;}
        }
        assert(scanned > 0,'logged CLI must exercise persisted history');
        const sessionDir = join(project,'.thin/sessions');
        const sessionFiles = await readdir(sessionDir);
        assert(sessionFiles.some(n=>n.endsWith('.jsonl')),'diagnostic journal missing');
        if (isPty) {
          // Headless print journals diagnostics but has no interactive resume
          // checkpoint. The real logged PTY must publish canonical state.
          const checkpoint = sessionFiles.filter(n=>n.endsWith('.session'));
          assert.equal(checkpoint.length,1,'canonical checkpoint missing');
          const bytes = await readFile(join(sessionDir,checkpoint[0]));
          assert(bytes.includes(Buffer.from(DESCRIPTION)),'image result absent from checkpoint');
          assert(bytes.includes(Buffer.from('image-off-verified')),'final checkpoint not current');
        }
      }
      console.log(`PASS image-model/${kind}: primary=${mainPosts} aux=1 TCP=2; isolated exact PNG/auth; textual canonical result; ${isPty ? 'menu HTTP=0, socket retained, Off removes fifth tool' : 'persisted storage scanned, no payload/credential leak, no retry'}`);
    } catch (error) {
      const safe = new Error('image model fixture failed');
      safe.fixtureCase = `settings/image-model-${kind}`;
      const line = /image_model_mock\.mjs:(\d+):/.exec(error.stack ?? '')?.[1];
      safe.fixtureCheck = `${stage}${line ? ` at ${line}` : ''}`;
      throw safe;
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve=>server.close(resolve));
      await rm(root,{recursive:true,force:true});
    }
  }
}
