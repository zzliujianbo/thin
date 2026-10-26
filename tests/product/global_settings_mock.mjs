// Real thin + existing owned-PTY driver. No inherited credentials or sessions.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {createServer} from 'node:http';
import {mkdtemp, mkdir, writeFile, readFile, stat, lstat, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';

const [appArg, ptyArg] = process.argv.slice(2);
assert(appArg && ptyArg, 'expected thin and existing PTY artifact');
const app = resolve(appArg), pty = resolve(ptyArg);
const base = await mkdtemp(join(tmpdir(), 'thin-global-settings-'));
let requests = 0, connections = 0, scenarios = 0;
const sockets = new Set();
const server = createServer((req, res) => {
  requests++;
  req.resume();
  res.writeHead(500); res.end('settings must not send HTTP');
});
server.on('connection', socket => {
  connections++; sockets.add(socket);
  socket.on('close', () => sockets.delete(socket));
});

async function missing(path) {
  await assert.rejects(stat(path), {code:'ENOENT'}, `unexpected file: ${path}`);
}

async function run(mode, home, project, url, options = {}) {
  const child = spawn(pty, [], {cwd:project, detached:true, stdio:['ignore','pipe','pipe'], env:{
    PATH:'/usr/bin:/bin', HOME:home, LANG:'C.UTF-8', TERM:'xterm-256color',
    THIN_APP_BIN:app, THIN_APP_TEST_HOME:home, THIN_APP_TEST_PROJECT:project,
    THIN_APP_TEST_URL:url, THIN_APP_TEST_MODE:mode,
  }});
  let owned = true, failure, size = 0;
  const chunks = [];
  const stop = signal => {
    if (owned && child.exitCode === null && child.signalCode === null && child.pid) { try { process.kill(-child.pid, signal); } catch (e) { if (e.code !== 'ESRCH') failure ??= e; } }
  };
  let rejectWait;
  const abandon = () => { child.stdout.destroy(); child.stderr.destroy(); rejectWait?.(failure); };
  const watchdog = options.watchdogMs ?? 45000;
  const timer = setTimeout(() => { failure ??= new Error(`${mode}: watchdog`); stop('SIGTERM'); if (!owned) abandon(); }, watchdog);
  const escalation = setTimeout(() => { failure ??= new Error(`${mode}: cleanup watchdog`); stop('SIGKILL'); abandon(); }, watchdog + 3000);
  const capture = b => {
    size += b.length;
    if (size <= 2 * 1024 * 1024) chunks.push(b);
    else { failure ??= new Error(`${mode}: output bound`); stop('SIGTERM'); }
  };
  child.stdout.on('data', capture); child.stderr.on('data', capture);
  // Proxy gates are emitted only after a complete replayed frame and released
  // only after this owner checked the whole on-disk declaration.
  let gateQueue = Promise.resolve();
  if (options.gate) {
    let pending = '';
    child.stderr.on('data', chunk => {
      pending += chunk.toString('utf8');
      if (pending.length > 65536) { failure ??= new Error(`${mode}: gate line bound`); pending = ''; return; }
      let end;
      while ((end = pending.indexOf('\n')) >= 0) {
        const line = pending.slice(0, end).replace(/\r$/, ''); pending = pending.slice(end + 1);
        const match = /^SETTINGS_PROXY_GATE=([a-z][a-z-]*)$/.exec(line);
        if (!match) continue;
        gateQueue = gateQueue.then(() => options.gate(match[1])).catch(error => { failure ??= error; });
      }
    });
  }
  child.once('exit', () => { owned = false; if (failure) abandon(); });
  child.once('close', () => { owned = false; });
  try {
    const result = await new Promise((res, rej) => {
      rejectWait = rej;
      child.once('error', e => { owned = false; rej(e); });
      child.once('close', (code, signal) => res({code, signal}));
    });
    await gateQueue;
    const output = Buffer.concat(chunks).toString('utf8');
    assert(!output.includes('fixture-secret-never-log'), 'fixture key leaked');
    if (failure) throw failure;
    assert.equal(result.signal, null, `${mode}: signalled`);
    assert.equal(result.code, 0, `${mode}: PTY failed\n${output}`);
    assert(!output.includes('PTY_SESSION_ID='), 'no-log recorded a session');
    assert.equal(requests, 0, `${mode}: HTTP requests`);
    assert.equal(connections, 0, `${mode}: unexpected connection`);
    await missing(join(project, '.thin/settings.json'));
    await missing(join(project, '.thin/sessions'));
    scenarios++;
    console.log(`PASS ${mode}: HTTP=${requests}, connections=${connections}`);
  } finally {
    clearTimeout(timer); clearTimeout(escalation); stop('SIGTERM');
  }
}

const proxyModels = {
  existing:'zen/fixture-zen/model-x',
  native:'native/family/native-review',
  second:'go/Repo/Model-X',
  unlogged:'ghost/Case-Model',
};

// Literal keys make native and the second model independent of injected env
// credentials. The ghost alias declares an env name this fixture never sets,
// so it is a real declared-but-unauthenticated negative candidate.
async function proxyFixture(name, url, configured) {
  const home = join(base, name, 'home'), project = join(base, name, 'project');
  await mkdir(join(home, '.thin'), {recursive:true});
  await mkdir(project, {recursive:true});
  const address = '127.0.0.1', port = 8888, models = [proxyModels.existing];
  const config = JSON.stringify({
    memory:{auto:false},
    llm:{default:'local/fixture-model', providers:{
      local:{base_url:url, api_key_env:'THIN_FIXTURE_KEY', models:{
        'fixture-model':{protocol:'chat', context_tokens:32768},
      }},
      zen:{base_url:'https://opencode.ai/zen/v1', api_key:'zen-fixture-key', models:{
        'fixture-zen/model-x':{protocol:'chat', context_tokens:32768},
      }},
      go:{base_url:'https://opencode.ai/zen/go/v1', api_key:'go-fixture-key', models:{
        'Repo/Model-X':{protocol:'responses', context_tokens:65536},
      }},
      native:{base_url:'https://opencode.ai/inference/systemone/v1', api_key:'native-fixture-key', models:{
        'family/native-review':{protocol:'systemone'},
      }},
      ghost:{base_url:'https://ghost.invalid/v1', api_key_env:'THIN_MISSING_KEY', models:{
        'Case-Model':{protocol:'chat', context_tokens:32768},
      }},
    }},
    ...(configured ? {proxy:{address, port, models}} : {}),
    limits:{low_price_input:true, safety_tokens:100, request_timeout_ms:3000, task_timeout_ms:5000},
  }, null, 2) + '\n';
  const configPath = join(home, '.thin/config.json');
  await writeFile(configPath, config, {mode:0o600});
  return {home, project, config, configPath, settings:join(home, '.thin/settings.json'), proxy:{address, port, models}};
}

async function fixture(name, decision, url) {
  const home = join(base, name, 'home'), project = join(base, name, 'project');
  await mkdir(join(home, '.thin'), {recursive:true});
  await mkdir(project, {recursive:true});
  const config = JSON.stringify({
    memory:{auto:false},
    llm:{default:'local/fixture-model', providers:{local:{base_url:url, api_key_env:'THIN_FIXTURE_KEY', models:{
      'fixture-model':{protocol:'chat', context_tokens:32768},
    }},
    zen:{base_url:'https://opencode.ai/zen/v1', api_key:'zen-fixture-key', models:{}},
    go:{base_url:'https://opencode.ai/zen/go/v1', api_key:'go-fixture-key', models:{}},
    native:{base_url:'https://opencode.ai/inference/systemone/v1', api_key:'native-fixture-key', models:{
      'family/native-review':{protocol:'systemone'},
    }},
    }},
    ...(decision ? {decision:{model:'native/family/native-review'}} : {}),
    limits:{low_price_input:true, safety_tokens:100, request_timeout_ms:3000, task_timeout_ms:5000},
  }, null, 2) + '\n';
  const configPath = join(home, '.thin/config.json');
  await writeFile(configPath, config, {mode:0o600});
  return {home, project, config, configPath, settings:join(home, '.thin/settings.json')};
}
async function savedProxyModels(f, expectedProxy) {
  const disk = JSON.parse(await readFile(f.configPath, 'utf8'));
  assert.deepEqual(disk.proxy, expectedProxy, 'final proxy allowlist');
  assert.deepEqual(disk, canonicalConfig(f, expectedProxy), 'final whole JSON');
  assert.equal((await stat(f.configPath)).mode & 0o777, 0o600);
}

async function unchanged(f) {
  assert.equal(await readFile(f.configPath, 'utf8'), f.config, 'config declarations changed byte-for-byte');
}
// Canonical defaults materialized by core/config.zig writeDisk. Each value is
// an authored expectation, never derived from the file under test.
const limitsDefaults = {
  command_timeout_ms:300000, command_max_timeout_ms:3600000,
  read_bytes:65536, output_bytes:32768,
  low_price_input:true, input_margin_tokens:5000, safety_tokens:4096,
  max_tool_calls:128, task_timeout_ms:1800000, request_timeout_ms:300000,
  model_refresh_ttl_ms:14400000, model_refresh_cooldown_ms:300000,
  cleanup_grace_ms:1000, cleanup_timeout_ms:5000,
  core_bytes:2048, index_bytes:8192, shard_bytes:32768,
  compaction_enabled:true, compaction_trigger_percent:80,
  compaction_target_percent:50, max_response_bytes:8388608,
  max_event_bytes:1048576,
};

async function values(f, low, decision, newlySelected = false) {
  const expected = JSON.parse(f.config);
  if (newlySelected) expected.decision = {model:'native/family/native-review'};
  // Mirror only known core/config.zig writeDisk canonical defaults, never
  // derive expected fields from the saved file (unknown additions must fail).
  // Provider fields are written individually, including optional nulls;
  // Limits/Decision structs omit optional nulls. ModelPatch stays sparse.
  for (const provider of Object.values(expected.llm.providers)) {
    Object.assign(provider, {api_key:null, api_key_env:'', chat_max_tokens:false, kind:null, ...provider});
  }
  expected.limits = {...limitsDefaults, ...expected.limits, low_price_input:low};
  expected.decision = {
    enabled:true,
    max_input_tokens:8192, max_state_bytes:16384,
    ...expected.decision,
    enabled:decision,
  };
  // Whole-object equality excludes changes to models, routes, credential
  // declarations, other limits, or any field beyond these explicit defaults.
  assert.deepEqual(JSON.parse(await readFile(f.configPath, 'utf8')), expected);
  assert.equal((await stat(f.configPath)).mode & 0o777, 0o600);
}
// Canonical whole-object expectation for a save that only edits proxy.models.
// Providers, limits and an already declared decision are written with the
// same explicit defaults as values(); an absent decision stays absent.
function canonicalConfig(f, proxy) {
  const expected = JSON.parse(f.config);
  for (const provider of Object.values(expected.llm.providers)) {
    Object.assign(provider, {api_key:null, api_key_env:'', chat_max_tokens:false, kind:null, ...provider});
  }
  expected.limits = {...limitsDefaults, ...expected.limits};
  if (expected.decision) expected.decision = {enabled:true, max_input_tokens:8192, max_state_bytes:16384, ...expected.decision};
  if (proxy !== undefined) expected.proxy = proxy;
  return expected;
}

// HOME/.thin may hold config/settings plus the daemon's private discovery
// index. The index is optional (lazy) but must never persist session records:
// real 0700 directories only, bounded depth, no files below a project key.
async function thinHome(home, allowed) {
  const root = join(home, '.thin');
  const info = await lstat(root);
  assert(info.isDirectory() && !info.isSymbolicLink(), `${root}: not a real directory`);
  for (const name of await readdir(root)) assert(name === 'session-index' || allowed.includes(name), `unexpected path: .thin/${name}`);
  let index;
  try { index = await lstat(join(root, 'session-index')); } catch (e) { if (e.code === 'ENOENT') return; throw e; }
  assert(index.isDirectory() && !index.isSymbolicLink(), '.thin/session-index: not a real directory');
  assert.equal(index.mode & 0o777, 0o700, '.thin/session-index: mode');
  for (const key of await readdir(join(root, 'session-index'), {withFileTypes:true})) {
    assert(key.isDirectory() && !key.isSymbolicLink(), `.thin/session-index/${key.name}: not a real directory`);
    const dir = join(root, 'session-index', key.name);
    assert.equal((await lstat(dir)).mode & 0o777, 0o700, `${dir}: mode`);
    for (const name of await readdir(dir)) assert.fail(`${dir}/${name}: session data persisted`);
  }
}
async function snapshot(path) {
  return {bytes:await readFile(path), info:await stat(path, {bigint:true})};
}
async function untouched(path, before) {
  const after = await snapshot(path);
  assert.deepEqual(after.bytes, before.bytes, `${path}: read-only operation changed bytes`);
  assert.equal(after.info.mtimeNs, before.info.mtimeNs, `${path}: read-only operation changed mtime`);
  assert.equal(after.info.ino, before.info.ino, `${path}: read-only operation replaced inode`);
}

try {
  await new Promise((res, rej) => { server.once('error', rej); server.listen(0, '127.0.0.1', res); });
  const url = `http://127.0.0.1:${server.address().port}/v1`;
  const f = await fixture('configured', true, url);
  // Invalid retired settings must neither affect startup nor be repaired.
  await writeFile(f.settings, '{ broken legacy settings\n', {mode:0o600});
  const legacy = await snapshot(f.settings);
  await run('settings-global-off', f.home, f.project, url);
  await values(f, false, false);
  await untouched(f.settings, legacy);
  await run('settings-global-on', f.home, f.project, url);
  await values(f, true, true);
  await untouched(f.settings, legacy);
  const saved = await snapshot(f.configPath);
  await run('settings-global-verify', f.home, f.project, url);
  await values(f, true, true);
  await untouched(f.configPath, saved);
  await untouched(f.settings, legacy);

  const n = await fixture('unconfigured', false, url);
  const unconfigured = await snapshot(n.configPath);
  await run('settings-global-unconfigured', n.home, n.project, url);
  await missing(n.settings);
  await unchanged(n);
  await untouched(n.configPath, unconfigured);
  await thinHome(n.home, ['config.json']);
  // Reverse preferences in a retired file must be ignored, including low-price.
  const existing = '{ "version": 1, "low_price_input": false, "decision_enabled": false }\n';
  await writeFile(n.settings, existing, {mode:0o600});
  const baseline = await snapshot(n.settings);
  await run('settings-global-unconfigured', n.home, n.project, url);
  await untouched(n.settings, baseline);
  await untouched(n.configPath, unconfigured);
  await unchanged(n);
  const p = await fixture('native-selection', false, url);
  await writeFile(p.settings, existing, {mode:0o600});
  const nativeLegacy = await snapshot(p.settings);
  await run('settings-global-native', p.home, p.project, url);
  await values(p, true, true, true);
  await untouched(p.settings, nativeLegacy);
  const nativeSaved = await snapshot(p.configPath);
  await run('settings-global-verify', p.home, p.project, url);
  await values(p, true, true, true);
  await untouched(p.configPath, nativeSaved);
  await untouched(p.settings, nativeLegacy);

  // Proxy allowlist: preserved pre-existing entry, a literal-key SystemOne
  // model, and a second literal-key model whose raw ID keeps a slash and case.
  const proxy = await proxyFixture('proxy-configured', url, true);
  // A retired settings file is inert: never read for preferences, repaired or removed.
  await writeFile(proxy.settings, '{ broken legacy settings\n', {mode:0o600});
  const proxyLegacy = await snapshot(proxy.settings);
  let expectedProxy = proxy.proxy;
  let expected = canonicalConfig(proxy, expectedProxy);
  let learned = await snapshot(proxy.configPath);
  assert.deepEqual(JSON.parse(proxy.config).proxy, expectedProxy);
  const proxyOrder = [];
  const proxyStates = {
    'native-added':[proxyModels.existing, proxyModels.native],
    'added':[proxyModels.existing, proxyModels.native, proxyModels.second],
    'removed':[proxyModels.existing, proxyModels.native],
  };
  const proxyPhases = ['opened','unlogged','native-added','added','root-return','reopened','removed','persisted'];
  await run('settings-proxy-configured', proxy.home, proxy.project, url, {
    watchdogMs: 90000,
    gate: async name => {
      try {
        proxyOrder.push(name);
        assert(proxyPhases.includes(name), `${name}: unknown proxy gate`);
        await untouched(proxy.settings, proxyLegacy);
        await missing(join(proxy.project, '.thin/settings.json'));
        await missing(join(proxy.project, '.thin/sessions'));
        if (proxyStates[name]) {
          expectedProxy = {...expectedProxy, models:[...proxyStates[name]]};
          expected = canonicalConfig(proxy, expectedProxy);
          const disk = JSON.parse(await readFile(proxy.configPath, 'utf8'));
          assert.deepEqual(disk, expected, `${name}: only proxy.models may change`);
          assert.equal(disk.proxy.address, '127.0.0.1', `${name}: proxy address`);
          assert.equal(disk.proxy.port, 8888, `${name}: proxy port`);
          assert.equal((await stat(proxy.configPath)).mode & 0o777, 0o600, `${name}: mode`);
          learned = await snapshot(proxy.configPath);
        } else await untouched(proxy.configPath, learned);
      } finally {
        await writeFile(join(proxy.project, `settings-proxy-release-${name}`), 'release', {flag:'wx', mode:0o600});
      }
    },
  });
  assert.deepEqual(proxyOrder, proxyPhases);
  await savedProxyModels(proxy, expectedProxy);
  await untouched(proxy.settings, proxyLegacy);
  await thinHome(proxy.home, ['config.json','settings.json']);
  assert.deepEqual((await readdir(proxy.project)).sort(), proxyPhases.map(n => `settings-proxy-release-${n}`).sort());

  // Without a proxy host/port the picker is read-only and never writes.
  const off = await proxyFixture('proxy-unconfigured', url, false);
  const offSnapshot = await snapshot(off.configPath);
  const offPhases = ['opened','unconfigured'];
  const offOrder = [];
  await run('settings-proxy-unconfigured', off.home, off.project, url, {
    watchdogMs: 90000,
    gate: async name => {
      try {
        offOrder.push(name);
        assert(offPhases.includes(name), `${name}: unknown proxy gate`);
        await untouched(off.configPath, offSnapshot);
        assert.equal(await readFile(off.configPath, 'utf8'), off.config, `${name}: declarations changed`);
        await missing(off.settings);
        await missing(join(off.project, '.thin/settings.json'));
        await missing(join(off.project, '.thin/sessions'));
      } finally {
        await writeFile(join(off.project, `settings-proxy-release-${name}`), 'release', {flag:'wx', mode:0o600});
      }
    },
  });
  assert.deepEqual(offOrder, offPhases);
  await thinHome(off.home, ['config.json']);
  assert.deepEqual((await readdir(off.project)).sort(), offPhases.map(n => `settings-proxy-release-${n}`).sort());

  for (const x of [f, n, p]) await thinHome(x.home, ['config.json','settings.json']);
  console.log(`PASS test-settings: scenarios=${scenarios}, HTTP requests=${requests}, connections=${connections}`);
} catch (error) {
  console.error(`FAIL test-settings: completed scenarios=${scenarios}, HTTP requests=${requests}, connections=${connections}`);
  throw error;
} finally {
  for (const socket of sockets) socket.destroy();
  await new Promise(res => server.close(res));
  await rm(base, {recursive:true, force:true});
}
