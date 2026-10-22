// 回归审查发现的应用层边界；只使用临时 HOME、假凭据、固定工具操作与回环服务。
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, symlink, access, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {createServer} from 'node:http';
import {spawn} from 'node:child_process';

const KEY = 'review-fixture-fake-key';
const REFUSAL = 'fixture-refusal-answer';

async function exists(path) {
  try { await access(path); return true; }
  catch { return false; }
}

// 只返回白名单断言所需输出；失败时不把原始进程输出带进诊断。
async function run(app, args, home, project) {
  const child = spawn(app, args, {
    cwd: project,
    env: {PATH: '/usr/bin:/bin', HOME: home, LANG: 'C.UTF-8'},
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '';
  let errors = '';
  child.stdout.on('data', bytes => { output += bytes; });
  child.stderr.on('data', bytes => { errors += bytes; });
  // 场景只写文件/读取/显示，不会创建 bash 后代；精确终止我们启动的直接子进程。
  const timer = setTimeout(() => child.kill('SIGKILL'), 15000);
  try {
    const code = await new Promise((resolve, reject) => {
      child.once('error', reject);
      child.once('close', resolve);
    });
    return {code, output, errors};
  } finally {
    clearTimeout(timer);
  }
}

export async function reviewRegressions(app) {
  for (const kind of ['canonical-home', 'symlink-home', 'duplicate-tool-id', 'refusal']) {
    const root = await mkdtemp(join(tmpdir(), 'thin-app-review-'));
    const home = join(root, 'home');
    const isProtection = kind.endsWith('-home');
    const project = isProtection ? home : join(root, 'project');
    const alias = join(root, 'home-alias');
    let requests = 0;
    let credentialInHistory = false;
    let fixtureError = null;
    const server = createServer(async (req, res) => {
      try {
        assert.equal(req.method, 'POST');
        assert.equal(req.url, '/chat/completions');
        // 不比较并打印 header 值；断言失败只输出固定信息。
        assert(req.headers.authorization === `Bearer ${KEY}`, 'unexpected fixture authorization');
        let raw = '';
        for await (const bytes of req) raw += bytes;
        const body = JSON.parse(raw);
        requests++;
        assert(requests <= 2, 'unexpected extra request');
        credentialInHistory ||= body.messages.some(m => m.role === 'tool' && typeof m.content === 'string' && m.content.includes(KEY));
        let delta;
        let finish;
        if (kind === 'refusal') {
          delta = {refusal: REFUSAL};
          finish = 'stop';
        } else if (kind === 'duplicate-tool-id' || requests === 1) {
          const name = isProtection ? 'read_file' : 'write_file';
          const args = isProtection
            ? {path: '.thin/config.json'}
            : {path: requests === 1 ? 'one.txt' : 'two.txt', content: 'fixture-only', overwrite: false};
          delta = {tool_calls: [{index: 0, id: 'same-call-id', type: 'function', function: {name, arguments: JSON.stringify(args)}}]};
          finish = 'tool_calls';
        } else {
          delta = {content: 'fixture-done', refusal: null};
          finish = 'stop';
        }
        res.writeHead(200, {'content-type': 'text/event-stream'});
        res.end(`data: ${JSON.stringify({choices: [{index: 0, delta, finish_reason: finish}]})}\n\ndata: [DONE]\n\n`);
      } catch (error) {
        fixtureError = error;
        res.destroy();
      }
    });

    try {
      await mkdir(join(home, '.thin'), {recursive: true, mode: 0o700});
      if (!isProtection) await mkdir(project);
      if (kind === 'symlink-home') await symlink(home, alias);
      await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
      await writeFile(join(home, '.thin/config.json'), JSON.stringify({
        memory: {auto:false},
        llm: {default:'local/fixture',providers:{local:{base_url:`http://127.0.0.1:${server.address().port}`,api_key:KEY,models:{fixture:{protocol:'chat',context_tokens:32768}}}}},
        limits: {low_price_input: false, max_output_tokens: 100, summary_tokens: 100, safety_tokens: 100, request_timeout_ms: 5000, task_timeout_ms: 10000},
      }), {mode: 0o600});
      const args = ['--print', 'fixture-only'];
      const result = await run(app, args, kind === 'symlink-home' ? alias : home, project);
      if (fixtureError) throw fixtureError;
      assert(!credentialInHistory, 'configuration credential entered model history');
      assert(!result.output.includes(KEY) && !result.errors.includes(KEY), 'credential entered CLI output');
      if (kind === 'duplicate-tool-id') {
        assert.equal(result.code, 1, 'duplicate response must fail');
        assert.equal(requests, 2);
        assert(await exists(join(project, 'one.txt')));
        assert(!await exists(join(project, 'two.txt')), 'duplicate response executed its tool');
        assert(result.errors.includes('DuplicateToolId'), 'duplicate id must be rejected before encoding');
      } else {
        assert.equal(result.code, 0, 'fixture application failed');
        assert.equal(requests, kind === 'refusal' ? 1 : 2);
        assert(result.output.trim() === (kind === 'refusal' ? REFUSAL : 'fixture-done'), 'committed answer missing');
      }
      console.log(`PASS review/${kind}: requests=${requests}`);
    } catch (error) {
      throw new Error(`review/${kind}: ${String(error.message).replaceAll(KEY, '[redacted]')}`);
    } finally {
      server.closeAllConnections();
      await new Promise(resolve => server.close(resolve));
      await rm(root, {recursive: true, force: true});
    }
  }
}
