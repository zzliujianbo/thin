// Owned-process project preference acceptance; loopback only, no user storage.
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
      async function configure({map=sparse,format='standard',effort='off',pending=false,unknown=false}={}) {
        // Match the declaration-only writer's sparse nullable mappings while
        // retaining strict /login baseline equality for all declared models.
        const completeMap = Object.fromEntries(['off','minimal','low','medium','high','xhigh','max'].filter(level => map[level] != null).map(level => [level,map[level]]));
        configBytes = JSON.stringify({llm:{default:'local/fixture-model',providers:{local:{base_url:url,api_key_env:pending?'':'THIN_FIXTURE_KEY',...(pending?{api_key:null}:{}),models:{'fixture-model':{protocol,context_tokens:32768,reasoning_effort:effort,...(unknown?{}:{reasoning:{format,map:completeMap}})}}}}},limits:{low_price_input:false,max_output_tokens:100,summary_tokens:100,safety_tokens:100,request_timeout_ms:10000,task_timeout_ms:20000}});
        await writeFile(configPath,configBytes,{mode:0o600});
      }
      async function seed(p,raw) {
        await mkdir(join(p,'.thin'),{mode:0o700});
        await writeFile(settingsPath(p),raw,{mode:0o600});
      }
      async function run(mode, levels=[], {p=project, map=sparse, format='standard', headless=false}={}) {
        stage = 'owned process';
        assert.equal(expected.length,0);
        expected = levels.map(level => ({level,wire:map[level] ?? level,format}));
        const env = {PATH:'/usr/bin:/bin',HOME:home,LANG:'C.UTF-8',TERM:'xterm-256color',THIN_FIXTURE_KEY:KEY,THIN_APP_BIN:app,THIN_APP_TEST_HOME:home,THIN_APP_TEST_PROJECT:p,THIN_APP_TEST_URL:url,THIN_APP_TEST_MODE:mode};
        const result = await execute(headless?app:pty,headless?['--no-log','--print','settings-task']:[],env,p,undefined,headless?30000:90000);
        if (fixtureError) throw fixtureError;
        assert.equal(result.code,0);
        assert.equal(expected.length,0);
        if (!headless) assert.equal([...result.output.matchAll(/^PTY_SESSION_ID=([a-f0-9]{32})$/gm)].length,0);
        stage = 'storage assertions';
        if (await exists(join(p,'.thin'))) assert.deepEqual(await readdir(join(p,'.thin')),['settings.json']);
        assert.deepEqual(await readdir(join(home,'.thin')),['config.json']);
        assert.deepEqual(await readdir(p),await exists(join(p,'.thin'))?['.thin']:[]);
        return result;
      }
      async function saved(p,effort) {
        assert.deepEqual(JSON.parse(await readFile(settingsPath(p),'utf8')),{version:1,reasoning_effort:effort});
        assert.equal((await stat(settingsPath(p))).mode & 0o777,0o600);
        assert.equal((await stat(join(p,'.thin'))).mode & 0o777,0o700);
      }
      async function unchanged(p,raw,mode) {
        assert.equal(await readFile(settingsPath(p),'utf8'),raw);
        assert.equal((await stat(settingsPath(p))).mode & 0o777,mode);
      }
      await body({configure,seed,run,saved,unchanged,project,other,settingsPath,configPath,getConfig:()=>configBytes});
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
    await t.saved(t.project,'off');
    await t.run('settings-cycle',['low','high','max','off'],{format});
    await t.saved(t.project,'max');
    const before = await readFile(t.settingsPath(t.project),'utf8');
    await t.run('settings-probe-max',['max'],{format}); // Actual PTY restart, same project.
    await t.unchanged(t.project,before,0o600);
    await t.run('settings-probe-off',['off'],{p:t.other,format});
    await t.saved(t.other,'off');
    await t.run('', ['max'],{headless:true,format});
    assert.equal(await readFile(t.configPath,'utf8'),t.getConfig());
  });

  for (const protocol of ['chat','responses']) await group(protocol,protocol,async t => {
    await t.configure({map:custom,effort:'none'});
    await t.run('settings-map',['low','high','off'],{map:custom});
    await t.saved(t.project,'off'); // Config-only none alias never persists as none.
    await t.run('settings-probe-off',['off'],{map:custom});
    assert.equal(await readFile(t.configPath,'utf8'),t.getConfig());
  });

  await group('clamp','chat',async t => {
    await t.configure();
    const raw = ' {"version":1,"reasoning_effort":"medium"}\n';
    await t.seed(t.project,raw);
    await t.run('settings-clamp-high',['high']);
    await t.unchanged(t.project,raw,0o600);
    await t.run('', ['high'],{headless:true});
    await t.unchanged(t.project,raw,0o600);
    // No supported level above max: fallback searches downward.
    await t.configure({map:{off:'none',low:'low'}});
    await writeFile(t.settingsPath(t.project),preference('max'));
    await t.run('settings-clamp-low',['low']);
    await t.unchanged(t.project,preference('max'),0o600);
  });

  await group('unknown','chat',async t => {
    await t.configure({unknown:true,effort:'low'});
    await t.seed(t.project,preference('high'));
    await t.run('settings-unknown-low',['low']);
    await t.unchanged(t.project,preference('high'),0o600);
    await t.run('settings-blocked-low',['low'],{p:t.other});
    // Unknown capabilities block cycling, not initialization of an explicit
    // local preference. The configured wire value remains unchanged above.
    await t.saved(t.other,'low');
    assert.equal(await readFile(t.configPath,'utf8'),t.getConfig());
  });

  for (const [kind,raw] of [['malformed','{"version":1,"reasoning_effort":'],['oversize',' '.repeat(1025)]]) await group(kind,'chat',async t => {
    await t.configure({effort:'low'});
    await t.seed(t.project,raw);
    await t.run('settings-blocked-low',['low']);
    await t.unchanged(t.project,raw,0o600);
    assert.equal(await readFile(t.configPath,'utf8'),t.getConfig());
  });

  await group('pending-auth','chat',async t => {
    await t.configure({pending:true});
    await t.run('settings-pending-auth',['low']);
    await t.saved(t.project,'low');
    const disk = JSON.parse(await readFile(t.configPath,'utf8'));
    const baseline = JSON.parse(t.getConfig());
    assert.deepEqual(disk.llm.providers.local.models,baseline.llm.providers.local.models);
    assert.equal(disk.llm.providers.local.base_url,baseline.llm.providers.local.base_url);
    assert.equal(disk.llm.providers.local.api_key,KEY);
    assert.equal(disk.llm.providers.local.models['fixture-model'].reasoning_effort,'off');
  });
}
