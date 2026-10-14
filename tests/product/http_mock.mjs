// Offline transport integration: no credentials, model APIs, OS tools, or trust changes.
// 文件概览：离线传输集成测试夹具，为 Zig HTTP 集成测试提供本地 mock 服务（Chat Completions 与 Responses 两种协议的 SSE 响应）。
// 运行方式：node tests/product/http_mock.mjs <Linux Zig 测试可执行文件>。脚本启动该程序，并校验每个场景的请求次数与线格式。
// 场景由 URL 路径 /<场景名>/responses 或 /<场景名>/chat/completions 选择，覆盖分片流、工具调用往返、错误状态码、
// 重定向（不得泄露 Authorization）、停滞与取消、截断等。不使用凭据、真实模型 API 或系统工具，也不修改信任设置。
// 依赖 Node 内置模块：http 提供本地服务，assert 做断言，child_process 启动被测程序。

import http from 'node:http';
import https from 'node:https';
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// 第一个命令行参数是 Linux Zig 测试可执行文件；缺失或非 Linux 时直接抛出错误。
if (!process.argv[2] || process.platform !== 'linux') throw new Error('Usage: node http_mock.mjs <Linux Zig test binary>');

// 为本次运行创建临时 HOME 目录，结束时删除。
const home = mkdtempSync(join(tmpdir(), 'thin-http-local-'));

// 运行期状态：活动 socket、服务器列表、各路由的请求计数、各场景的历史请求、错误列表，以及子进程与看门狗。
const sockets = new Set();
const servers = [];
// 键为 "场景:端点"，值为请求次数；最终与期望值做精确比较。
const counts = new Map();
const histories = new Map();
const idleSockets = new Map();
const errors = [];
// interrupted 表示收到信号或看门狗超时；targetHits 统计重定向目标被访问的次数。
let child, watchdog, interrupted = false, targetHits = 0;

// 把值编码为一条 SSE data 帧（以 CRLF 结尾的事件）。字符串原样发送（如 [DONE]），其它值 JSON 序列化。
const frame = value => `data: ${typeof value === 'string' ? value : JSON.stringify(value)}\r\n\r\n`;

// 构造 Chat Completions 的流式 chunk。
const chatDelta = (delta, finish_reason = null) => ({ choices: [{ index: 0, delta, finish_reason }] });

// 固定的 Responses assistant 消息，文本为 "你"（多字节 UTF-8，用于验证分片解码）。
const message = { id: 'msg_actual', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: '你' }] };

// 固定的 Responses function_call 条目，call_id 为 call_actual，参数由调用方给出。
const tool = args => ({ type: 'function_call', id: 'fc_actual', call_id: 'call_actual', name: 'lookup', arguments: args, status: 'completed' });

// 不透明的 reasoning 条目（encrypted_content）。测试要求它被原样回放到下一次请求中。
const opaque = { type: 'reasoning', id: 'rs_actual', summary: [], encrypted_content: 'opaque-native-replay' };

// 构造 response.completed 事件，包含输出列表与 usage 统计。
const completed = output => ({ type: 'response.completed', response: { status: 'completed', output, usage: { input_tokens: 10, output_tokens: 4 } } });

/**
 * 生成纯文本回复的 SSE 流。chat 为 Chat Completions 增量；否则为 Responses 事件。
 * reasoning 为 true 时在文本前加入推理内容（Chat 为 reasoning_content，Responses 为 reasoning 条目与摘要）。
 */
function textStream(chat, reasoning = false) {
  if (chat) return (reasoning ? frame(chatDelta({ reasoning_content: 'plan' })) : '') + frame(chatDelta({ content: '你' })) + frame(chatDelta({}, 'stop')) + frame({ choices: [], usage: { prompt_tokens: 10, completion_tokens: 4 } }) + frame('[DONE]');
  return (reasoning ? frame({ type: 'response.output_item.added', output_index: 0, item: { type: 'reasoning', id: 'rs_actual' } }) + frame({ type: 'response.reasoning_summary_text.delta', output_index: 0, item_id: 'rs_actual', delta: 'plan' }) : '') + frame({ type: 'response.output_item.added', output_index: reasoning ? 1 : 0, item: { id: 'msg_actual', type: 'message', role: 'assistant' } }) + frame({ type: 'response.output_text.delta', output_index: reasoning ? 1 : 0, item_id: 'msg_actual', delta: '你' }) + frame(completed(reasoning ? [{ ...opaque, summary: [{ type: 'summary_text', text: 'plan' }] }, message] : [message]));
}

/**
 * 生成工具调用的 SSE 流，调用名为 lookup，参数字符串为 args。
 * Responses 的 response.completed 中同时包含 function_call 与不透明的 reasoning 条目。
 */
function toolStream(chat, args = '{}') {
  if (chat) return frame(chatDelta({ tool_calls: [{ index: 0, id: 'call_actual', type: 'function', function: { name: 'lookup', arguments: args } }] })) + frame(chatDelta({}, 'tool_calls')) + frame('[DONE]');
  return frame({ type: 'response.output_item.added', output_index: 0, item: { ...tool(''), status: 'in_progress' } }) + frame({ type: 'response.function_call_arguments.delta', output_index: 0, item_id: 'fc_actual', delta: args }) + frame(completed([tool(args), opaque]));
}

/**
 * 发送 SSE 响应。split 为 true 时按 1 字节间隔写出，使 UTF-8 码点与 CRLF 被切开，
 * 以测试客户端能否跨 chunk 正确拼接。
 */
function send(res, body, split = false) {
  res.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8' });
  if (!split) return res.end(body);
  const bytes = Buffer.from(body);
  let i = 0;

  // 中文：计时式 1 字节写入会切开 UTF-8 码点与 CRLF 边界。
  // Separate timed one-byte writes split UTF-8 codepoints and CRLF boundaries.
  const timer = setInterval(() => {
    if (i === bytes.length) { clearInterval(timer); res.end(); }
    else res.write(bytes.subarray(i, ++i));
  }, 1);
  res.once('close', () => clearInterval(timer));
}

/**
 * 校验请求的线格式：方法、Bearer 密钥、模型名、stream 标志、工具 schema，
 * 以及 Chat 与 Responses 各自特有的字段（messages/instructions/store/include 等）。
 * 任何不符合预期的字段都会导致断言失败。
 */
function checkWire(req, body, chat) {
  assert.equal(req.method, 'POST');
  assert.equal(req.headers.authorization, 'Bearer fake-local-key');
  assert.equal(body.model, 'fixture-model');
  assert.equal(body.stream, true);
  assert.equal(body.tools.length, 1);

  if (chat) {
    assert.equal(body.instructions, undefined);
    assert.equal(body.input, undefined);
    assert.equal(body.messages[0].role, 'system');
    assert.equal(body.messages[0].content, 'fixed fixture system');
    assert.equal(body.tools[0].function.name, 'lookup');
  } else {
    assert.equal(body.messages, undefined);
    assert.equal(body.instructions, 'fixed fixture system');
    assert.equal(body.tools[0].name, 'lookup');
    assert.equal(body.tools[0].strict, false);
    assert.equal(body.store, false);
    assert.deepEqual(body.include, ['reasoning.encrypted_content']);
    assert.equal(body.previous_response_id, undefined);
  }

  // 工具 schema 在两种协议中的位置不同，这里按协议取出后统一校验描述与参数。
  const schema = chat ? body.tools[0].function : body.tools[0];
  assert.equal(schema.description, 'Local fixture only');
  assert.deepEqual(schema.parameters, { type: 'object', properties: {} });
}

/**
 * 在 127.0.0.1 的随机端口监听并登记服务器，返回实际端口。同时记录连接以便清理。
 */
async function listen(server) {
  servers.push(server);

  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });

  await new Promise((ok, fail) => { server.once('error', fail); server.listen(0, '127.0.0.1', ok); });
  return server.address().port;
}

/** 以 SIGKILL 结束子进程组；进程已不存在（ESRCH）时忽略。 */
function kill() {
  if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch (e) { if (e.code !== 'ESRCH') throw e; } }
}

// 收到信号时标记中断并结束子进程组。
function interrupt() { interrupted = true; kill(); }

// 注册信号处理，以便 Ctrl-C 或 SIGTERM 时也能清理子进程。
process.on('SIGINT', interrupt);
process.on('SIGTERM', interrupt);

try {
  // 重定向目标服务器：收到请求即记录错误（若携带 Authorization 说明密钥泄露），并计数。
  const targetPort = await listen(http.createServer((req, res) => {
    ++targetHits;
    if (req.headers.authorization) errors.push('Redirect leaked Authorization');
    res.writeHead(500); res.end();
  }));

  // Shared HTTP/TLS handler; TLS uses only an owned generated loopback cert.
  const handler = (req, res) => {
    const chunks = [];
    let size = 0;

    // 忽略客户端中止引起的请求错误。
    req.on('error', () => {});

    // 请求体上限 64 KiB，超出即销毁请求。
    req.on('data', chunk => { size += chunk.length; if (size > 65536) req.destroy(); else chunks.push(chunk); });

    req.on('end', () => {
      try {
        // 解析 URL：/<场景名>/responses 或 /<场景名>/chat/completions；否则断言失败。
        const match = /^\/([^/]+)\/(responses|chat\/completions)$/.exec(req.url);
        assert.ok(match, `Unexpected URL ${req.url}`);
        const [, scenario, endpoint] = match;
        const chat = endpoint === 'chat/completions';

        // 统计每个 场景:端点 的请求次数，用于最终精确断言。
        const key = `${scenario}:${endpoint}`;
        const n = (counts.get(key) ?? 0) + 1;
        counts.set(key, n);

        // 解析请求体并校验线格式。
        const body = JSON.parse(Buffer.concat(chunks));
        checkWire(req, body, chat);

        if (scenario.startsWith('idle-')) {
          assert(n <= 2, 'idle checks must not replay POSTs');
          if (n === 1) idleSockets.set(scenario, req.socket);
          else if (scenario.startsWith('idle-reuse-')) assert.equal(req.socket, idleSockets.get(scenario), 'healthy short idle socket not reused');
          else assert.notEqual(req.socket, idleSockets.get(scenario), 'stale idle socket reused');
          if (n === 1 && scenario.startsWith('idle-close-')) {
            const socket = req.socket;
            res.once('finish', () => {
              const timer = setTimeout(() => socket.end(), 50);
              socket.once('close', () => clearTimeout(timer));
            });
          }
          return send(res, textStream(chat));
        }

        // auto 场景：第一次 Responses 请求返回 404 不支持，之后应回退到 Chat Completions。
        if (scenario === 'auto' && !chat) {
          assert.equal(n, 1);
          res.writeHead(404, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ error: { code: 'unsupported_endpoint' }, usage: { input_tokens: 7, output_tokens: 1 } }));
        }

        // error 场景：普通错误不得回退到 Chat，直接以对应状态码返回错误体。
        if (scenario.startsWith('error')) {
          assert.equal(chat, false, 'ordinary error must not retry Chat');
          const status = Number(scenario.slice(5));
          res.writeHead(status, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ error: status === 404 ? { message: 'endpoint unsupported' } : { code: 'unsupported_endpoint', param: 'response_format' } }));
        }

        // redirect 场景：返回 307 指向目标服务器，客户端不得跟随或泄露 Authorization。
        if (scenario.startsWith('redirect')) {
          res.writeHead(307, { location: `http://127.0.0.1:${targetPort}/target` }); return res.end();
        }

        // stall/cancel 场景：第一次请求只发送响应头（或保活注释）后挂起，测试客户端超时与取消。
        if ((scenario.startsWith('stall') || scenario.startsWith('cancel')) && n === 1) {
          if (scenario.endsWith('body')) { res.writeHead(200, { 'content-type': 'text/event-stream' }); res.write(': keepalive\r\n\r\n'); }
          return;
        }

        // tools 场景：第一次返回工具调用；第二次校验历史中的工具往返与不透明条目被原样回放；第三次校验历史与工具列表与第二次完全一致。
        if (scenario.startsWith('tools')) {
          if (n === 1) return send(res, toolStream(chat));

          // 按协议取出历史消息（Chat 为 messages，Responses 为 input）。
          const history = chat ? body.messages : body.input;

          if (chat) {
            assert.equal(history[1].content, 'hello fixture');
            assert.equal(history[2].tool_calls[0].id, 'call_actual');
            assert.equal(history[2].tool_calls[0].function.arguments, '{}');
            assert.equal(history[3].role, 'tool');
            assert.equal(history[3].tool_call_id, 'call_actual');
            assert.equal(history[3].content, 'fixture result');
          } else {
            assert.equal(history[0].content[0].text, 'hello fixture');
            assert.deepEqual(history[1], tool('{}'));
            assert.deepEqual(history[2], opaque);
            assert.deepEqual(history[3], { type: 'function_call_output', call_id: 'call_actual', output: 'fixture result' });
          }

          // 第二次请求时保存历史，供第三次请求比较。
          if (n === 2) histories.set(scenario, body);
          else {
            assert.equal(n, 3);
            const prior = histories.get(scenario);
            assert.equal(body.tool_choice, 'none');
            assert.deepEqual(history, chat ? prior.messages : prior.input);
            assert.deepEqual(body.tools, prior.tools);
          }
          return send(res, textStream(chat));
        }

        // missing 场景：流在完成前结束，缺少完成事件。
        if (scenario.startsWith('missing')) return send(res, chat ? frame(chatDelta({ content: 'draft' })) : frame({ type: 'response.created', response: { id: 'r' } }));

        // invalid 场景：工具参数不是 JSON 对象（为 []）。
        if (scenario.startsWith('invalid')) return send(res, toolStream(chat, '[]'));

        // incomplete 场景：工具参数被截断为 "{"。
        if (scenario.startsWith('incomplete')) return send(res, toolStream(chat, '{'));

        // truncated 场景：声明的 Content-Length 比实际多 100 字节，并在 30ms 后销毁连接。
        if (scenario.startsWith('truncated')) {
          const data = textStream(chat);
          res.writeHead(200, { 'content-type': 'text/event-stream', 'content-length': Buffer.byteLength(data) + 100 });
          res.write(data);
          // 30ms 后销毁响应，模拟网络中断。
          const timer = setTimeout(() => res.destroy(), 30);
          res.once('close', () => clearTimeout(timer));
          return;
        }

        // 默认分支：返回纯文本回复；scenario 以 split 开头时分片发送，并包含推理内容。
        return send(res, textStream(chat, scenario.startsWith('split')), scenario.startsWith('split'));
      } catch (error) {
        errors.push(error.stack);
        if (!res.headersSent) res.writeHead(500);
        res.end('Fixture assertion failed');
      }
    });
  };
  const port = await listen(http.createServer(handler));
  const certPath = join(home, 'fixture-cert.pem');
  const keyPath = join(home, 'fixture-key.pem');
  execFileSync('openssl', ['req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=127.0.0.1','-addext','subjectAltName=IP:127.0.0.1','-keyout',keyPath,'-out',certPath], {stdio:'ignore',timeout:10000});
  // Exercise TLS1.3 by default, including its ordinary session tickets. The
  // same exact-count/socket-identity cases can be rerun with a TLS1.2 control.
  const tlsVersion = process.env.THIN_HTTP_TLS_VERSION ?? 'TLSv1.3';
  assert(['TLSv1.2','TLSv1.3'].includes(tlsVersion), 'unsupported fixture TLS version');
  const tlsPort = await listen(https.createServer({key:readFileSync(keyPath),cert:readFileSync(certPath),minVersion:tlsVersion,maxVersion:tlsVersion}, handler));

  // 以独立进程组启动被测程序，stdout/stderr 继承到父进程；只注入假密钥与本地 URL 等最小环境变量。
  child = spawn(resolve(process.argv[2]), [], { detached: true, stdio: ['ignore', 'inherit', 'inherit'], env: {
    PATH: '/usr/bin:/bin', LANG: 'C.UTF-8', HOME: home,
    THIN_HTTP_FIXTURE_URL: `http://127.0.0.1:${port}`, THIN_HTTP_TLS_FIXTURE_URL: `https://127.0.0.1:${tlsPort}`, THIN_FAKE_KEY: 'fake-local-key',
  } });

  // 60 秒看门狗：超时后标记中断并结束子进程组。
  watchdog = setTimeout(() => { console.error('HTTP integration watchdog expired'); interrupted = true; kill(); }, 60000);

  // 等待被测程序关闭；被信号终止时视为失败（退出码 1）。
  const code = await new Promise((ok, fail) => { child.once('error', fail); child.once('close', (code, signal) => ok(signal ? 1 : code)); });
  child = undefined;

  if (!code && !interrupted) {
    // 期望的请求计数：每个场景与端点的精确次数。只有在子进程正常结束且未中断时才校验。
    const expected = new Map();

    // 对两种协议都期望对应的请求次数。
    for (const protocol of ['chat', 'responses']) {
      const endpoint = protocol === 'chat' ? 'chat/completions' : 'responses';
      expected.set(`split-${protocol}:${endpoint}`, 1);
      expected.set(`tools-${protocol}:${endpoint}`, 3);
      for (const scenario of ['missing', 'truncated', 'invalid', 'incomplete', 'redirect']) expected.set(`${scenario}-${protocol}:${endpoint}`, 1);
    }

    for (const transport of ['tcp', 'tls']) for (const protocol of ['chat', 'responses']) {
      const endpoint = protocol === 'chat' ? 'chat/completions' : 'responses';
      for (const scenario of ['idle-reuse', 'idle-close', 'idle-expire', 'idle-buffer', 'idle-poll-error']) expected.set(`${scenario}-${transport}-${protocol}:${endpoint}`, 2);
    }
    for (const scenario of ['lock-cancel', 'lock-timeout']) expected.set(`${scenario}:chat/completions`, 1);

    // auto 场景：Responses 只请求 1 次（404），Chat 请求 2 次。
    expected.set('auto:responses', 1); expected.set('auto:chat/completions', 2);
    for (const status of [404, 400, 401, 403, 429, 503]) expected.set(`error${status}:responses`, 1);
    for (const scenario of ['stall-header', 'stall-body', 'cancel-header', 'cancel-body']) expected.set(`${scenario}:chat/completions`, 2);
    assert.deepEqual(counts, expected, 'Every scenario and exact request count must run');

    // 重定向目标不得被访问。
    assert.equal(targetHits, 0, 'Redirect must remain unhandled');
  }

  // 输出夹具内部记录的错误后再报告统计信息。
  for (const error of errors) console.error(error);
  console.log(`LOCAL_HTTP requests=${[...counts.values()].reduce((a, b) => a + b, 0)} routes=${counts.size} redirect_target_hits=${targetHits} fixture_errors=${errors.length} tls_version=${tlsVersion}`);

  // 中断返回 124；夹具错误返回 1；否则返回子进程退出码。
  process.exitCode = interrupted ? 124 : errors.length ? 1 : code ?? 1;

// 顶层捕获：打印异常并以退出码 1 结束。
} catch (error) {
  console.error(error);
  process.exitCode = 1;
// finally：无论成功失败都取消看门狗、结束子进程、销毁连接、关闭服务器并删除临时目录。
} finally {
  clearTimeout(watchdog);
  kill();
  for (const socket of sockets) socket.destroy();
  await Promise.all(servers.map(server => new Promise(ok => server.close(ok))));
  rmSync(home, { recursive: true, force: true });
  process.off('SIGINT', interrupt); process.off('SIGTERM', interrupt);
}
