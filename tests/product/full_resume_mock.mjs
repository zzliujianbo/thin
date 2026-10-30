// Real two-process continuation on owned PTYs, fake HOME/key and loopback only.
// Never prints raw terminal captures, payloads, headers, or assertion stacks.
import http from 'node:http';
import {createHash} from 'node:crypto';
import {mkdtemp, mkdir, writeFile, readFile, readdir, stat, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';

export async function fullResumeRegressions({app, pty, execute}) {
  for (const protocol of ['chat', 'responses']) {
    const root = await mkdtemp(join(tmpdir(), 'thin-full-resume-'));
    const home = join(root, 'home'), project = join(root, "project quoted's work");
    const key = 'fixture-secret-never-log';
    const sockets = new Set();
    let requests = 0, fixtureFailed = false, check = 'setup', serverCheck = 'none', wireId = null;
    const server = http.createServer(async (req, res) => {
      try {
        let size = 0; const chunks = [];
        for await (const chunk of req) { size += chunk.length; assert(size < 1024 * 1024); chunks.push(chunk); }
        requests++;
        serverCheck = 'endpoint and credential';
        assert.equal(req.url, protocol === 'chat' ? '/v1/chat/completions' : '/v1/responses');
        assert.equal(req.headers.authorization, `Bearer ${key}`);
        assert(/^[0-9a-f]{32}$/.test(req.headers['x-opencode-session']));
        if (wireId === null) wireId = req.headers['x-opencode-session'];
        else assert.equal(req.headers['x-opencode-session'], wireId);
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        assert.equal(body.model, 'fixture-model');
        const history = protocol === 'chat' ? body.messages : body.input;
        // Session preface (environment/AGENTS) is context-material, not a user turn.
        const users = history.filter(m => m.role === 'user' && !JSON.stringify(m).includes('[Context material'));
        serverCheck = 'exact user history';
        assert(JSON.stringify(users[0]).includes('remember-resume-marker'));
        // Each accepted continuation persists before the next resume.
        assert.equal(users.length, requests <= 2 ? 1 : requests - 1);
        if (requests >= 3) assert(JSON.stringify(users.at(-1)).includes('resume-next-turn'));
        if (requests > 1) {
          serverCheck = 'native replay and closed tools';
          if (protocol === 'chat') {
            const prior = history.find(m => m.tool_calls?.length);
            assert.equal(prior.signature, 'opaque-chat-resume');
            assert.equal(prior.reasoning_content, 'PRIVATE-RESUME-REASONING');
            assert.equal(prior.tool_calls[0].id, 'resume-once');
            const results = history.filter(m => m.role === 'tool' && m.tool_call_id === 'resume-once');
            assert.equal(results.length, 1);
          } else {
            assert.equal(body.store, false);
            const opaque = history.find(m => m.id === 'rs-resume');
            assert.equal(opaque.encrypted_content, 'opaque-responses-resume');
            assert.equal(opaque.summary[0].text, 'PRIVATE-RESUME-REASONING');
            assert.equal(history.filter(m => m.type === 'function_call' && m.call_id === 'resume-once').length, 1);
            assert.equal(history.filter(m => m.type === 'function_call_output' && m.call_id === 'resume-once').length, 1);
            assert.equal(history.find(m => m.call_id === 'resume-once').id, 'fc-resume');
          }
        }
        if (requests >= 3) assert(JSON.stringify(history).includes('resume-first-answer'));
        serverCheck = 'response';
        res.writeHead(200, {'content-type':'text/event-stream'});
        const event = value => res.write(`data: ${JSON.stringify(value)}\n\n`);
        const args = JSON.stringify({command:'printf once >> resume-sentinel.txt'});
        if (protocol === 'chat') {
          const delta = requests === 1 ? {role:'assistant', reasoning_content:'PRIVATE-RESUME-REASONING', signature:'opaque-chat-resume', tool_calls:[{index:0,id:'resume-once',type:'function',function:{name:'bash',arguments:args}}]} : {content: requests === 2 ? 'resume-first-answer' : 'resume-next-answer'};
          event({choices:[{index:0,delta,finish_reason:null}]});
          event({choices:[{index:0,delta:{},finish_reason: requests === 1 ? 'tool_calls' : 'stop'}]});
          res.write('data: [DONE]\n\n');
        } else {
          const output = requests === 1 ? [
            {type:'reasoning',id:'rs-resume',encrypted_content:'opaque-responses-resume',summary:[{type:'summary_text',text:'PRIVATE-RESUME-REASONING'}]},
            {type:'function_call',id:'fc-resume',call_id:'resume-once',name:'bash',arguments:args,status:'completed'},
          ] : [{type:'message',id:`msg-resume-${requests}`,role:'assistant',content:[{type:'output_text',text:requests === 2 ? 'resume-first-answer' : 'resume-next-answer'}],status:'completed'}];
          event({type:'response.completed',response:{id:`response-${requests}`,status:'completed',output}});
        }
        res.end();
      } catch {
        fixtureFailed = true;
        if (!res.headersSent) res.writeHead(500);
        res.end('fixture assertion failed');
      }
    });
    server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
    try {
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      const url = `http://127.0.0.1:${server.address().port}/v1`;
      await mkdir(join(home, '.thin'), {recursive:true,mode:0o700});
      await mkdir(join(project, '.thin'), {recursive:true,mode:0o700});
      const configPath = join(home, '.thin', 'config.json');
      const configObject = {memory:{auto:false},limits:{low_price_input:false},llm:{default:'local/fixture-model',providers:{local:{kind:'opencode_zen',base_url:url,api_key_env:'THIN_FIXTURE_KEY',models:{'fixture-model':{protocol,context_tokens:32768}}}}}};
      const config = JSON.stringify(configObject);
      const settingsPath = join(project, '.thin', 'settings.json');
      const settings = '{"version":1,"reasoning_effort":"low"}\n';
      await writeFile(configPath, config, {mode:0o600});
      await writeFile(settingsPath, settings, {mode:0o600});
      const sessions = join(project, '.thin', 'sessions');
      const env = {PATH:'/usr/bin:/bin', HOME:home, LANG:'C.UTF-8', TERM:'xterm-256color', THIN_FIXTURE_KEY:key,
        THIN_APP_BIN:app, THIN_APP_TEST_PROJECT:project, THIN_APP_TEST_HOME:home, THIN_APP_TEST_URL:url, THIN_APP_TEST_TZ:protocol === 'responses' ? 'UTC-8' : 'UTC0'};
      const run = async (mode, id, expected) => {
        check = `PTY ${mode}`;
        const result = await execute(pty, [], {...env,THIN_APP_TEST_MODE:mode,...(id ? {THIN_APP_TEST_RESTORE_ID:id} : {}),...(expected ? {THIN_APP_TEST_RESTORE_ERROR:expected} : {})}, project);
        const reason = result.output.match(/^error: ([A-Za-z][A-Za-z0-9_]{0,63})$/m)?.[1] ?? 'unclassified';
        const line = [...result.output.matchAll(/src\/tests\/app_pty_test\.zig:(\d+):/g)].map(match => match[1]).slice(0,8).join('-') || 'unknown';
        check = `PTY ${mode} code ${result.code} ${reason} at ${line} requests ${requests} ${serverCheck}`;
        assert.equal(result.code, 0);
        assert(!fixtureFailed);
        return result.output.match(/PTY_SESSION_ID=([0-9a-f]{32})/)?.[1];
      };
      const id = await run('resume-create');
      assert(id);
      assert.equal(id, wireId);
      assert.equal(requests, 2);
      const snapshotPath = join(sessions, `${id}.session`), markerPath = join(sessions, `${id}.resume-lock`);
      check = 'private complete checkpoint';
      const first = await readFile(snapshotPath);
      assert.equal(first.subarray(0,8).toString(), 'THINRSM\0');
      assert(!first.includes(key));
      for (const path of [snapshotPath, markerPath]) assert.equal((await stat(path)).mode & 0o777, 0o600);
      assert.equal((await stat(sessions)).mode & 0o777, 0o700);
      const stateOf = bytes => {
        assert.equal(bytes[8], 2, 'only current frame format is valid');
        const selection = JSON.parse(bytes.subarray(17, 17 + bytes.readUInt32LE(9)).toString());
        assert.equal(selection.version, 2);
        assert.equal(Object.hasOwn(selection, 'session'), false);
        assert(Object.hasOwn(selection, 'provider_name'));
        const state = JSON.parse(bytes.subarray(17 + bytes.readUInt32LE(9)).toString());
        assert.equal(state.version, 2);
        return state;
      };
      const firstState = stateOf(first);
      // Session preface is persisted as context messages; turns are counted separately.
      const turnsOf = state => state.messages.filter(m => m.role !== 'context');
      assert(firstState.messages.some(m => m.role === 'context'));
      assert.equal(turnsOf(firstState).length, 4);
      assert.equal(firstState.selector.selected, protocol);
      assert.equal(await run('resume-next', id), id);
      assert.equal(requests, 3);
      check = 'saved continuation and counter continuity';
      const second = await readFile(snapshotPath), secondState = stateOf(second);
      assert.equal(turnsOf(secondState).length, 6);
      assert(secondState.journal_seq > firstState.journal_seq);
      assert.equal(secondState.journal_turn, firstState.journal_turn + 1);
      const snapshotTree = async () => {
        const files = (await readdir(sessions)).sort();
        return Promise.all(files.map(async name => [name, createHash('sha256').update(await readFile(join(sessions, name))).digest('hex')]));
      };
      const before = await snapshotTree();
      assert.equal(await run('resume-readonly', id), id);
      assert.equal(requests, 4);
      check = 'continuation published automatically';
      assert.notDeepEqual(await snapshotTree(), before);
      const thirdState = stateOf(await readFile(snapshotPath));
      assert.equal(turnsOf(thirdState).length, 8);
      assert(thirdState.journal_seq > secondState.journal_seq);
      assert.equal(thirdState.journal_turn, secondState.journal_turn + 1);
      assert.equal(await run('resume-idle', id), id);
      assert.equal(requests, 4, 'loading alone requested the model');
      check = 'tools never replay and preferences untouched';
      assert.equal(await readFile(join(project, 'resume-sentinel.txt'), 'utf8'), 'once');
      assert.equal(await readFile(configPath, 'utf8'), config);
      assert.equal(await readFile(settingsPath, 'utf8'), settings);
      const clean = await readFile(snapshotPath), cleanMarker = await readFile(markerPath);
      const put = async (bytes, marker = Buffer.concat([Buffer.from('C'), createHash('sha256').update(bytes).digest()])) => {
        await writeFile(snapshotPath, bytes); await writeFile(markerPath, marker);
      };
      check = 'missing checkpoint refusal';
      await run('resume-failure', 'f'.repeat(32), 'ResumeNotFound');
      await writeFile(configPath, JSON.stringify({...configObject,llm:{...configObject.llm,providers:{local:{...configObject.llm.providers.local,api_key_env:'',api_key:'different-fake-key'}}}}));
      await run('resume-idle', id); // Rotation is not a history-load refusal.
      assert.equal(requests,4);
      await writeFile(configPath, config);
      await put(clean, Buffer.from('A')); // Active/stale marker is not authentication.
      await run('resume-idle', id);
      assert.equal(requests,4);
      await put(clean.subarray(0, clean.length - 1), cleanMarker);
      await run('resume-failure', id, 'InvalidResumeLength');
      const corrupted = Buffer.from(clean); corrupted[corrupted.length - 1] = '!'.charCodeAt(0);
      await put(corrupted);
      await run('resume-failure', id, 'InvalidJson');
      const versioned = Buffer.from(clean);
      const payloadOffset = 17 + versioned.readUInt32LE(9);
      const versionAt = versioned.indexOf('"version":2', payloadOffset);
      assert(versionAt >= payloadOffset);
      versioned[versionAt + '"version":'.length] = '1'.charCodeAt(0);
      await put(versioned);
      await run('resume-failure', id, 'UnsupportedVersion');
      const activeMarker = Buffer.from(cleanMarker); activeMarker[0] = 'A'.charCodeAt(0);
      await put(clean, activeMarker);
      await run('resume-idle', id);
      assert.equal(requests,4);
      await put(clean, cleanMarker);
      assert.equal(requests, 4, 'refusal issued a request');
      assert.equal(await readFile(join(project, 'resume-sentinel.txt'), 'utf8'), 'once');
      // No-key startup displays canonical history; /login activates it in place.
      await writeFile(configPath, JSON.stringify({...configObject,llm:{...configObject.llm,providers:{local:{...configObject.llm.providers.local,api_key_env:'MISSING_RESUME_KEY'}}}}));
      await run('resume-login', id);
      assert.equal(requests,5,'login activation must send exactly one continuation');
      assert.equal(await readFile(join(project,'resume-sentinel.txt'),'utf8'),'once');
      console.log(`PASS resume/${protocol}: key/marker-independent loading, damaged/truncated refusal, no-key history/login/send, one side effect, automatic continuation persistence; requests=5`);
    } catch {
      const error = new Error('full resume fixture failed');
      error.fixtureCase = `resume/${protocol}`;
      error.fixtureCheck = check;
      throw error;
    } finally {
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
      await rm(root, {recursive:true,force:true});
    }
  }
}
