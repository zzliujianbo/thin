// Selection-only restoration on an owned PTY and loopback server. Never uses
// real HOME/config, public providers or the user's terminal. Capture stays local.
import http from 'node:http';
import {createHash} from 'node:crypto';
import {mkdtemp, mkdir, writeFile, readFile, readdir, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';

export async function selectionRestoreRegressions({app, pty, execute}) {
  const root = await mkdtemp(join(tmpdir(), 'thin-selection-restore-'));
  const home = join(root, 'home'), project = join(root, 'project');
  const id = '0123456789abcdef0123456789abcdef';
  const key = 'fixture-secret-never-log';
  const sockets = new Set();
  let requests = 0, fixtureFailed = false, restoredId = null;
  let checkpoint = 'setup', serverCheck = 'no request';
  const server = http.createServer(async (req, res) => {
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        assert(size <= 1024 * 1024);
        chunks.push(chunk);
      }
      requests++;
      serverCheck = 'protocol';
      assert.equal(req.url, '/v1/responses');
      assert.equal(req.headers.authorization, `Bearer ${key}`);
      restoredId = req.headers['x-opencode-session'];
      assert(/^[0-9a-f]{32}$/.test(restoredId) && restoredId !== id);
      const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      serverCheck = 'model and effort';
      assert.equal(body.model, 'fixture-restored');
      assert.equal(body.reasoning.effort, 'high');
      serverCheck = 'new history';
      assert.equal(body.input.length, 1);
      assert.equal(body.input[0].role, 'user');
      assert(JSON.stringify(body.input).includes('restore-new-turn'));
      assert(!JSON.stringify(body).includes('OLD-HISTORY-MUST-NOT-APPEAR'));
      serverCheck = 'response';
      res.writeHead(200, {'content-type': 'text/event-stream'});
      res.end(`data: ${JSON.stringify({type:'response.completed', response:{id:'restored-response', status:'completed', output:[{id:'restored-message', type:'message', role:'assistant', content:[{type:'output_text', text:'restore-fresh-answer'}]}]}})}\n\n`);
    } catch {
      fixtureFailed = true;
      res.writeHead(500);
      res.end('fixture assertion failed');
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.on('close', () => sockets.delete(socket)); });
  try {
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    const url = `http://127.0.0.1:${server.address().port}/v1`;
    const sessions = join(project, '.thin', 'sessions');
    await mkdir(join(home, '.thin'), {recursive:true, mode:0o700});
    await mkdir(sessions, {recursive:true, mode:0o700});
    const reasoning = {format:'standard', map:{low:'low', medium:'medium', high:'high'}};
    const config = JSON.stringify({provider:{kind:'opencode_zen', base_url:url, api_key_env:'THIN_FIXTURE_KEY'}, model:{name:'fixture-model', protocol:'chat', context_tokens:32768, reasoning}, models:[{name:'fixture-restored', protocol:'chat', context_tokens:32768, reasoning_effort:'low', reasoning}]});
    const settings = '{ "version": 1, "reasoning_effort": "low" }\n';
    const snapshot = {version:1, session:id, provider:'opencode_zen', endpoint:createHash('sha256').update(url).digest('hex'), model:'fixture-restored', protocol:'responses', effort:'high', effort_hash:null};
    const snapshotPath = join(sessions, `${id}.selection.json`);
    await writeFile(join(home, '.thin', 'config.json'), config, {mode:0o600});
    await writeFile(join(project, '.thin', 'settings.json'), settings, {mode:0o600});
    await writeFile(join(sessions, '.gitignore'), '*\n', {mode:0o600});
    // Deliberately invalid diagnostic JSONL must never be opened/replayed.
    await writeFile(join(sessions, 'not-replayable.jsonl'), 'OLD-HISTORY-MUST-NOT-APPEAR\n', {mode:0o600});
    await writeFile(snapshotPath, JSON.stringify(snapshot), {mode:0o600});
    const before = (await readdir(sessions)).sort();
    const env = {PATH:'/usr/bin:/bin', HOME:home, LANG:'C.UTF-8', TERM:'xterm-256color', THIN_FIXTURE_KEY:key,
      THIN_APP_BIN:app, THIN_APP_TEST_PROJECT:project, THIN_APP_TEST_HOME:home,
      THIN_APP_TEST_URL:url, THIN_APP_TEST_MODE:'restore-selection', THIN_APP_TEST_RESTORE_ID:id};
    checkpoint = 'owned PTY';
    const result = await execute(pty, [], env, project);
    const terminalReason = result.output.match(/^error: ([A-Za-z][A-Za-z0-9_]{0,63})$/m)?.[1] ?? 'unclassified';
    checkpoint = `PTY exit ${result.code} ${terminalReason} requests ${requests} ${serverCheck}`;
    assert.equal(result.code, 0, 'selection PTY failed');
    checkpoint = 'new identity and no log';
    assert(!result.output.includes('PTY_SESSION_ID='), 'no-log exit announced a session');
    assert(restoredId && restoredId !== id, 'restore reused the old wire identity');
    assert.equal(requests, 1);
    assert(!fixtureFailed);
    assert.deepEqual((await readdir(sessions)).sort(), before, 'no-log restore created an archive');
    assert.equal(await readFile(join(home, '.thin', 'config.json'), 'utf8'), config);
    assert.equal(await readFile(join(project, '.thin', 'settings.json'), 'utf8'), settings);
    const emptyHome = join(root, 'empty-home'), emptyProject = join(root, 'empty-project');
    await mkdir(emptyHome, {mode:0o700});
    await mkdir(emptyProject, {mode:0o700});
    const cliEnv = {...env, HOME:emptyHome};
    checkpoint = 'CLI help';
    const help = await execute(app, ['--help'], cliEnv, emptyProject);
    assert.equal(help.code, 0);
    assert(help.output.includes('--restore-selection'));
    for (const [args, expected] of [
      [['--restore-selection', '../bad'], 'InvalidSessionID'],
      [['--restore-selection', id, '--restore-selection', id], 'InvalidArguments'],
      [['--restore-selection', id, '--print', 'not sent'], 'InvalidArguments'],
      [['--restore-selection', id], 'TtyRequiredUsePrint'],
    ]) {
      checkpoint = `CLI ${expected}`;
      const failed = await execute(app, args, cliEnv, emptyProject);
      assert.notEqual(failed.code, 0);
      assert(failed.output.includes(expected));
    }
    assert.deepEqual(await readdir(emptyHome), []);
    assert.deepEqual(await readdir(emptyProject), []);
    for (const expected of ['SelectionNotFound', 'ApiKeyNotFound', 'SelectionEndpointUnavailable']) {
      checkpoint = `PTY ${expected}`;
      if (expected === 'SelectionEndpointUnavailable') {
        await writeFile(snapshotPath, JSON.stringify({...snapshot, endpoint:'0'.repeat(64)}));
      }
      const failed = await execute(pty, [], {...env, THIN_APP_TEST_MODE:'restore-failure',
        THIN_APP_TEST_RESTORE_ID:expected === 'SelectionNotFound' ? 'f'.repeat(32) : id,
        THIN_APP_TEST_RESTORE_ERROR:expected}, project);
      assert.equal(failed.code, 0, 'PTY startup refusal assertion failed');
    }
    assert.deepEqual((await readdir(sessions)).sort(), before);
    assert.equal(requests, 1, 'restore failure issued a request');
    assert.equal(await readFile(join(home, '.thin', 'config.json'), 'utf8'), config);
    assert.equal(await readFile(join(project, '.thin', 'settings.json'), 'utf8'), settings);
    console.log('PASS selection/restore: owned PTY, new history/id, saved protocol/effort, unchanged defaults, no-log, 3 PTY refusal cases and 4 CLI refusal cases; requests=1');
  } catch {
    const error = new Error('selection restoration fixture failed');
    error.fixtureCase = 'selection/restore';
    error.fixtureCheck = checkpoint;
    throw error;
  } finally {
    for (const socket of sockets) socket.destroy();
    await new Promise(resolve => server.close(resolve));
    await rm(root, {recursive:true, force:true});
  }
}
