// Owned-process global preference acceptance; loopback only, no user storage.
import http from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, rm, access, stat, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';

const KEY = 'fixture-secret-never-log';
const exists = p => access(p).then(() => true, () => false);
const sparse = {off:'none',low:'low',high:'high',max:'max'};
const custom = {off:'none',low:'provider-low',high:'provider-high'};
const preference = effort => JSON.stringify({version:1,reasoning_effort:effort});
// Seed the declaration writer's non-null implementation defaults explicitly so
// global saves can retain strict whole-document equality, not loose subsets.
const limitDefaults = {
  command_timeout_ms:300000,command_max_timeout_ms:3600000,read_bytes:65536,output_bytes:32768,
  input_margin_tokens:5000,max_tool_calls:128,model_refresh_ttl_ms:14400000,model_refresh_cooldown_ms:300000,
  cleanup_grace_ms:1000,cleanup_timeout_ms:5000,core_bytes:2048,index_bytes:8192,shard_bytes:32768,
  compaction_enabled:true,compaction_trigger_percent:80,compaction_target_percent:50,
  max_response_bytes:8388608,max_event_bytes:1048576,
};

export async function settingsRegressions({app,pty,execute,send}) {
  let label = 0;
  async function group(kind, protocol, body) {
    const root = await mkdtemp(join(tmpdir(),'thin-settings-'));
    const home = join(root,'home'), project = join(root,'project'), other = join(root,'other');
    let stage = 'prepare', requests = 0, expected = [], fixtureError;
    const sockets = new Set();
    const server = http.createServer(async (req,res) => {
      try {
        assert.equal(req.headers.authorization,`Bearer ${KEY}`);
        assert.equal(req.url,protocol==='chat'?'/v1/chat/completions':'/v1/responses');
        let raw = '', bytes = 0;
        for await (const chunk of req) { bytes += chunk.length; assert(bytes < 1024*1024); raw += chunk; }
        const wire = JSON.parse(raw), next = expected.shift();
        requests++;
        assert(next, 'unexpected request');
        assert.equal(wire.model,'fixture-model');
        if (next.savedEffort !== undefined) {
          const disk = JSON.parse(await readFile(next.configPath,'utf8'));
          assert.equal(disk.llm.reasoning_effort,next.savedEffort);
        }
        if (next.format === 'deepseek') {
          assert.equal(protocol,'chat');
          assert.deepEqual(wire.thinking,{type:next.level==='off'?'disabled':'enabled'});
          if (next.level==='off') assert(!('reasoning_effort' in wire));
          else assert.equal(wire.reasoning_effort,next.wire);
          assert(!('reasoning' in wire));
        } else if (protocol==='responses') {
          assert.equal(wire.reasoning?.effort,next.wire);
          assert(!('reasoning_effort' in wire));
          assert(!('thinking' in wire));
        } else {
          assert.equal(wire.reasoning_effort,next.wire);
          assert(!('reasoning' in wire));
          assert(!('thinking' in wire));
        }
        send(res,protocol,'settings-answer');
      } catch (error) { fixtureError ??= error; res.writeHead(500); res.end(); }
    });
    server.on('connection',socket => { sockets.add(socket); socket.on('close',()=>sockets.delete(socket)); });
    try {
      await mkdir(home); await mkdir(project); await mkdir(other); await mkdir(join(home,'.thin'));
      await new Promise(r=>server.listen(0,'127.0.0.1',r));
      const url = `http://127.0.0.1:${server.address().port}/v1`;
      const configPath = join(home,'.thin/config.json');
      const settingsPath = p => join(p,'.thin/settings.json');
      let configBytes;
      async function configure({map=sparse,format='standard',effort='off',globalEffort=null,pending=false,unknown=false}={}) {
        // Match the declaration-only writer's sparse nullable mappings while
        // retaining strict /login baseline equality for all declared models.
        const completeMap = Object.fromEntries(['off','minimal','low','medium','high','xhigh','max'].filter(level => map[level] != null).map(level => [level,map[level]]));
        configBytes = JSON.stringify({llm:{default:'local/fixture-model',reasoning_effort:globalEffort,providers:{local:{base_url:url,api_key:null,kind:null,chat_max_tokens:false,api_key_env:pending?'':'THIN_FIXTURE_KEY',models:{'fixture-model':{protocol,context_tokens:32768,reasoning_effort:effort,...(unknown?{}:{reasoning:{format,map:completeMap}})}}}}},limits:{...limitDefaults,low_price_input:false,max_output_tokens:100,summary_tokens:100,safety_tokens:100,request_timeout_ms:10000,task_timeout_ms:20000}});
        await writeFile(configPath,configBytes,{mode:0o600});
      }
      const legacyFixtures = new Map();
      async function seed(p,raw) {
        await mkdir(join(p,'.thin'),{mode:0o700});
        await writeFile(settingsPath(p),raw,{mode:0o600});
        legacyFixtures.set(p,raw);
      }
      async function run(mode, levels=[], {p=project, map=sparse, format='standard', headless=false, savedEffort}={}) {
        stage = 'owned process';
        assert.equal(expected.length,0);
        expected = levels.map(level => ({level,wire:map[level] ?? level,format,savedEffort,configPath}));
        const env = {PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',THIN_FIXTURE_KEY:KEY,THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:p,THIN_APP_TEST_URL:url,THIN_APP_TEST_MODE:mode};
        const result = await execute(headless?app:pty,headless?['--no-log','--print','settings-task']:[],env,p,undefined,headless?30000:90000);
        if (fixtureError) throw fixtureError;
        assert.equal(result.code,0);
        assert.equal(expected.length,0);
        assert(!result.output.includes(KEY));
        if (!headless) assert.equal([...result.output.matchAll(/^PTY_SESSION_ID=([a-f0-9]{32})$/gm)].length,0);
        stage = 'storage assertions';
        for (const directory of [project,other]) {
          // Only an explicitly seeded legacy fixture may have a .thin directory.
          const legacy = legacyFixtures.get(directory);
          assert.equal(await exists(join(directory,'.thin')),legacy !== undefined);
          if (legacy !== undefined) {
            assert.deepEqual(await readdir(join(directory,'.thin')),['settings.json']);
            await legacyUnchanged(directory,legacy);
          }
          assert.deepEqual(await readdir(directory),legacy !== undefined?['.thin']:[]);
        }
        assert.deepEqual(await readdir(join(home,'.thin')),['config.json']);
        return result;
      }
      async function savedGlobal(effort,{login=false}={}) {
        const disk = JSON.parse(await readFile(configPath,'utf8'));
        const baseline = JSON.parse(configBytes);
        assert.deepEqual(disk.llm.providers.local.models,baseline.llm.providers.local.models);
        baseline.llm.reasoning_effort = effort;
        if (login) baseline.llm.providers.local.api_key = KEY;
        assert.deepEqual(disk,baseline);
        assert.equal((await stat(configPath)).mode & 0o777,0o600);
      }
      async function legacyUnchanged(p,raw) {
        assert.equal(await readFile(settingsPath(p),'utf8'),raw);
        assert.equal((await stat(settingsPath(p))).mode & 0o777,0o600);
        assert.equal((await stat(join(p,'.thin'))).mode & 0o777,0o700);
      }
      async function globalUnchanged() {
        assert.equal(await readFile(configPath,'utf8'),configBytes);
      }
      await body({configure,seed,run,savedGlobal,legacyUnchanged,globalUnchanged,project,other});
      console.log(`PASS settings-${++label}: requests=${requests}`);
    } catch (error) {
      // Never promote assertion messages (which can contain actual wire data).
      const safe = new Error('settings fixture failed');
      safe.fixtureCase = `settings/${kind}`;
      // Only a fixed source filename's numeric line, never assertion operands.
      const line = /settings_mock\.mjs:(\d+):/.exec(error.stack ?? '')?.[1];
      safe.fixtureCheck = line ? `${stage} at ${line}` : stage;
      throw safe;
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise(r=>server.close(r));
      await rm(root,{recursive:true,force:true});
    }
  }

  for (const format of ['standard','deepseek']) await group(format,'chat',async t => {
    await t.configure({format});
    await t.run('settings-initial');
    await t.globalUnchanged(); // Null global keeps the model's fixed off default.
    // Only the first off -> low switch precedes the first user goal. Later
    // high/max/off and the final max switch are session-only after history.
    await t.run('settings-cycle',['low','high','max','off'],{format,savedEffort:'low'});
    await t.savedGlobal('low');
    await t.run('settings-probe-low',['low'],{format}); // Actual PTY restart, same project.
    await t.savedGlobal('low');
    await t.run('settings-probe-low',['low'],{p:t.other,format});
    await t.savedGlobal('low');
    await t.run('', ['low'],{headless:true,format});
    await t.savedGlobal('low');
  });

  for (const protocol of ['chat','responses']) await group(protocol,protocol,async t => {
    await t.configure({map:custom,effort:'none'});
    await t.run('settings-map',['low','high','off'],{map:custom,savedEffort:'low'});
    await t.savedGlobal('low'); // Save the logical level, never the provider alias.
    await t.run('settings-probe-low',['low'],{map:custom});
    await t.savedGlobal('low');
    await t.run('settings-probe-low',['low'],{p:t.other,map:custom});
    await t.savedGlobal('low');
    await t.run('', ['low'],{headless:true,map:custom});
    await t.savedGlobal('low');
  });

  await group('clamp','chat',async t => {
    await t.configure({globalEffort:'medium'});
    await t.run('settings-clamp-high',['high']);
    await t.globalUnchanged(); // Clamp the active level, not the logical global.
    await t.run('', ['high'],{headless:true});
    await t.globalUnchanged();
    // No supported level above max: fallback searches downward.
    const map = {off:'none',low:'low'};
    await t.configure({map,globalEffort:'max'});
    await t.run('settings-clamp-low',['low'],{map});
    await t.globalUnchanged();
    await t.run('', ['low'],{headless:true,map});
    await t.globalUnchanged();
  });

  await group('unknown','chat',async t => {
    await t.configure({unknown:true,effort:'low'});
    await t.seed(t.project,preference('high'));
    await t.run('settings-unknown-low',['low']);
    await t.legacyUnchanged(t.project,preference('high'));
    await t.globalUnchanged();
    await t.run('settings-blocked-low',['low'],{p:t.other});
    // Unknown capabilities retain explicit raw low, but cannot authorize a
    // cycle or write global preferences (nor initialize project settings).
    await t.globalUnchanged();
    await t.run('', ['low'],{headless:true});
    await t.globalUnchanged();
  });

  for (const [kind,raw] of [['malformed','{"version":1,"reasoning_effort":'],['oversize',' '.repeat(1025)]]) await group(kind,'chat',async t => {
    await t.configure({effort:'low'});
    await t.seed(t.project,raw);
    await t.run('settings-probe-low',['low']);
    await t.legacyUnchanged(t.project,raw);
    await t.globalUnchanged();
    await t.run('', ['low'],{headless:true});
    await t.legacyUnchanged(t.project,raw);
    await t.globalUnchanged();
  });

  await group('pending-auth','chat',async t => {
    await t.configure({pending:true});
    await t.run('settings-pending-auth',['low'],{savedEffort:'low'});
    // Known map permits the pre-login empty-session cycle to save logical low.
    // Login adds credentials without rewriting the model's fixed off declaration.
    await t.savedGlobal('low',{login:true});
    await t.run('settings-probe-low',['low']);
    await t.savedGlobal('low',{login:true});
  });
}
