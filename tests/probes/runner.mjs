// Loopback-only fixtures for Zig probes. No model API or third-party Node package.
// 文件概览：为 Zig 探针测试提供本地回环 HTTP/HTTPS 夹具，并运行已编译的 Zig 测试可执行文件。
// 运行方式：node tests/probes/runner.mjs <编译后的 Zig 测试可执行文件>（仅 Linux，需要系统中有 openssl）。
// 所有服务都绑定 127.0.0.1 的随机端口；被测进程只拿到假密钥和本地 URL，不访问真实模型或云服务。
// Node 内置模块：http/https 提供回环服务，child_process 启动被测程序，fs/os/path 管理临时目录。

import http from 'node:http';
import https from 'node:https';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

// 第一个命令行参数是待运行的 Zig 测试可执行文件；仅支持 Linux，缺参数或平台不符时以退出码 2 结束。
const executable = process.argv[2];
if (!executable || process.platform !== 'linux') {
  console.error('These probes require Linux and a compiled Zig test executable.');
  process.exit(2);
}

// 为本次运行创建独立临时目录（作为子进程 HOME 与证书目录），结束时递归删除。
const directory = mkdtempSync(join(tmpdir(), 'thin-io-probes-'));

// 运行期状态：活动 socket、受管进程组 PID、服务器列表、子进程句柄、看门狗与超时标记。
const sockets = new Set();
const processGroups = new Set();
const servers = [];
let child;
let watchdog;
let timedOut = false;
let connectionId = 0;

// 临时自签名证书与私钥路径，由 openssl 在 try 块中生成。
const key = join(directory, 'key.pem');
const cert = join(directory, 'cert.pem');

/**
 * 向进程组（负 PID）发送信号。拒绝非法或过小的 PID（<= 1），避免误杀系统进程；
 * 进程组已不存在（ESRCH）视为成功，其它错误原样抛出。
 */
function signalGroup(pid, signal) {
  if (!Number.isSafeInteger(pid) || pid <= 1) throw new Error('Invalid owned process group');
  try { process.kill(-pid, signal); }
  catch (error) { if (error.code !== 'ESRCH') throw error; }
}

/** 强制结束被测子进程组以及 processGroups 中登记的所有进程组（SIGKILL）。 */
function stopChild() {
  if (child?.pid) signalGroup(child.pid, 'SIGKILL');
  for (const pid of processGroups) signalGroup(pid, 'SIGKILL');
}

/**
 * 本地 mock 路由：
 * /health 返回连接编号；/echo 回显不超过 8192 字节的 POST 请求体；
 * /stream 以 1 字节为间隔发送 SSE，刻意切开 UTF-8 与 CRLF；
 * /stall 保持连接直到客户端取消；/abrupt 声明 128 字节但只发送少量数据后断开；其它路径返回 404。
 */
function handler(request, response) {
  if (request.url === '/health') {
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ ok: true, connection: request.socket.probeId }));
  } else if (request.url === '/echo' && request.method === 'POST') {
    const chunks = [];
    let size = 0;

    // 超过 8192 字节即销毁请求，防止无限制读取。
    request.on('data', chunk => {
      size += chunk.length;
      if (size > 8192) request.destroy();
      else chunks.push(chunk);
    });
    request.on('end', () => {
      response.setHeader('content-type', 'application/json');
      response.end(Buffer.concat(chunks));
    });
  } else if (request.url === '/stream') {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    const body = Buffer.from('event: delta\r\ndata: {"text":"你"}\r\n\r\ndata: [DONE]\n\n');
    let offset = 0;

    // 以下 1 字节写入用于制造分片边界，确保客户端的解析器能处理被切开的字符。
    // One-byte writes deliberately split UTF-8 and CRLF. The OS may coalesce them.
    const timer = setInterval(() => {
      if (offset < body.length) response.write(body.subarray(offset, ++offset));
      else { clearInterval(timer); response.end(); }
    }, 3);
    response.once('close', () => clearInterval(timer));
  } else if (request.url === '/stall') {
    response.writeHead(200, { 'content-type': 'text/event-stream' });

    // 先写一个字节，确认流已建立；之后不再写入也不结束响应。
    response.write('x');
    // Remains open until the client cancels. No uncancellable server timer.
  } else if (request.url === '/abrupt') {
    // 声明 128 字节 Content-Length 但只发送 5 字节，20ms 后销毁连接，用于验证截断响应的处理。
    response.writeHead(200, { 'content-length': '128' });
    response.write('short');
    const timer = setTimeout(() => response.destroy(), 20);
    response.once('close', () => clearTimeout(timer));
  } else {
    response.writeHead(404);
    response.end('not found');
  }
}

/**
 * 在 127.0.0.1 的随机端口（0）上监听，返回实际端口。
 * 同时登记服务器以便清理，并为每个连接分配递增的 probeId。
 */
async function listen(server) {
  servers.push(server);

  // 登记 socket 以便结束时销毁，并分配连接编号。
  server.on('connection', socket => {
    socket.probeId = ++connectionId;
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });

  // 中文：不受信任证书与主机名不匹配的负向测试会触发 TLS 错误，此处静默忽略以免污染输出。
  // Expected from the untrusted-certificate and hostname-negative tests.
  server.on('tlsClientError', () => {});
  await new Promise((resolveListen, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  return server.address().port;
}

/**
 * 把子进程的输出流原样转发到 destination，并按行解析 PROBE_GROUP <pid> 与
 * PROBE_GROUP_DONE <pid> 标记，用于登记和注销需要清理的进程组。跨 chunk 的不完整行会被缓存。
 */
function relay(stream, destination) {
  let partial = '';
  stream.on('data', chunk => {
    destination.write(chunk);
    partial += chunk.toString();

    const lines = partial.split('\n');
    partial = lines.pop();
    for (const line of lines) {
      const match = /^PROBE_GROUP (\d+)$/.exec(line);
      if (match) processGroups.add(Number(match[1]));
      const done = /^PROBE_GROUP_DONE (\d+)$/.exec(line);
      if (done) processGroups.delete(Number(done[1]));
    }
  });
}

// 收到 SIGTERM/SIGINT 时标记超时并结束被测进程组，随后由 finally 完成清理。
const interrupted = () => { timedOut = true; stopChild(); };
process.on('SIGTERM', interrupted);
process.on('SIGINT', interrupted);

try {
  // 使用 openssl 生成 1 天有效的自签名证书（CN=localhost，SAN=DNS:localhost），仅用于本地 HTTPS 测试。
  execFileSync('openssl', [
    'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
    '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost',
    '-addext', 'basicConstraints=critical,CA:TRUE',
    '-keyout', key, '-out', cert,
  ], { stdio: 'ignore', env: { PATH: process.env.PATH, HOME: directory } });

  // 启动 HTTP 与 HTTPS 两个回环服务，端口均由系统分配。
  const httpPort = await listen(http.createServer(handler));
  const httpsPort = await listen(https.createServer({ key: readFileSync(key), cert: readFileSync(cert) }, handler));

  // 以独立进程组（detached）启动被测程序；只注入探针所需的 URL、证书路径与假密钥，不转发宿主机凭据。
  child = spawn(resolve(executable), [], {
    detached: true,
    stdio: ['ignore', 'pipe', 'pipe'],
    // 中文：环境变量只从白名单复制（PATH、LANG 等），宿主机的模型或云凭据不会进入被测进程。
    // No ambient model/cloud credentials are forwarded into the test process.
    env: {
      PATH: process.env.PATH,
      HOME: directory,
      LANG: 'C.UTF-8',
      THIN_PROBE_HTTP_URL: `http://127.0.0.1:${httpPort}`,
      THIN_PROBE_HTTPS_URL: `https://localhost:${httpsPort}`,
      THIN_PROBE_WRONG_HOST_URL: `https://127.0.0.1:${httpsPort}`,
      THIN_PROBE_CA: cert,
      THIN_PROBE_SECRET: 'fake-probe-secret',
    },
  });

  // 转发 stdout/stderr，并解析进程组登记标记。
  relay(child.stdout, process.stdout);
  relay(child.stderr, process.stderr);

  // 60 秒看门狗：超时后标记 timedOut 并杀死所有受管进程组。
  watchdog = setTimeout(() => {
    timedOut = true;
    console.error('PROBE WATCHDOG: exceeded 60 seconds; killing owned test processes.');
    stopChild();
  }, 60_000);

  // 等待子进程关闭；被信号终止时视为失败（退出码 1）。
  const code = await new Promise((resolveExit, reject) => {
    child.once('error', reject);
    child.once('close', (exitCode, signal) => resolveExit(signal ? 1 : exitCode));
  });
  child = undefined;

  // 超时返回 124（与 timeout(1) 约定一致）；否则返回子进程退出码。
  process.exitCode = timedOut ? 124 : code ?? 1;
// harness 自身失败（如 openssl 缺失、监听失败）时打印错误并返回 1。
} catch (error) {
  console.error('Probe harness failed:', error.message);
  process.exitCode = 1;
// 无论成功还是失败都执行：取消看门狗、杀死残留进程组、销毁连接、关闭服务器并删除临时目录。
} finally {
  clearTimeout(watchdog);
  stopChild();
  for (const socket of sockets) socket.destroy();
  await Promise.all(servers.map(server => new Promise(resolveClose => server.close(resolveClose))));
  rmSync(directory, { recursive: true, force: true });
  process.off('SIGTERM', interrupted);
  process.off('SIGINT', interrupted);
}
