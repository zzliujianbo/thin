#!/usr/bin/env node
// Application acceptance only. Run from repo root:
// node tests/product/app_mock.mjs /absolute/path/thin /absolute/path/thin-app-pty
// 文件概览：应用级验收脚本，驱动 thin CLI 与 thin-app-pty（PTY）驱动，
// 并由本地伪造的 OpenAI 兼容服务（chat 与 responses 两种协议）提供固定回复。
// 覆盖：帮助与无配置、普通对话、权限拒绝与信任、自动压缩、畸形与截断响应、取消、输出超限、审批、Unicode 与 PTY 场景。
// 任何断言失败都会以非零退出码结束；错误信息经过脱敏，不输出捕获的终端或模型原文。
// 依赖 Node 内置模块：http 提供伪造服务，child_process 启动 CLI 与 PTY 驱动，assert 做断言。

import http from 'node:http';
import {createHash} from 'node:crypto';
import {spawn} from 'node:child_process';
import {EventEmitter} from 'node:events';
import {PassThrough} from 'node:stream';
import {mkdtemp, mkdir, writeFile, readFile, rm, access, stat, readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {resolve, join} from 'node:path';
import assert from 'node:assert/strict';
import {reviewRegressions} from './review_mock.mjs';
import {logRegressions} from './log_mock.mjs';
import {settingsRegressions} from './settings_mock.mjs';

// 命令行参数：第一个是 thin 可执行文件的绝对路径，第二个是 thin-app-pty 驱动的绝对路径。
const [appArg, ptyArg] = process.argv.slice(2);

// 参数缺失时 assert 直接抛出，进程以非零码退出。
const watchdogOnly = appArg === '--watchdog-test';
assert(watchdogOnly || (appArg && ptyArg), 'usage: app_mock.mjs <thin executable> <PTY executable>');
// 转为绝对路径，避免子进程切换 cwd 后相对路径失效。
const app = resolve(appArg), pty = resolve(ptyArg ?? appArg);
const architectureTable = await readFile(new URL('../../src/tests/architecture_table.md', import.meta.url), 'utf8');

// 假 API 密钥：通过 Authorization 头发送给伪造服务，并断言它不会出现在任何捕获的输出中。
const KEY = 'fixture-secret-never-log';

// 模拟模型输出的 OSC 52 剪贴板注入序列；测试要求它不得出现在 CLI 输出中。
const injection = '\x1b]52;c;ZXZpbA==\x07';

// 异步判断路径是否存在（access 成功即 true）。
const exists = p => access(p).then(() => true, () => false);

// 构造伪造的工具调用对象，arguments 为 JSON 字符串，与真实 API 格式一致。
const tool = (id, name, args) => ({id, name, arguments: JSON.stringify(args)});

/**
 * 校验请求历史中工具调用与结果的配对关系：每个调用必须恰好有一个结果，且结果不能孤立。
 * 返回 call_id 到输出内容的映射。Chat 使用 tool_calls 与 role=tool 消息；
 * Responses 使用 function_call 与 function_call_output 条目。
 */
function associations(body, protocol) {
  // pending 记录尚未得到结果的调用 id，outputs 记录已配对的结果。
  const pending = new Set(), outputs = new Map();
  if (protocol === 'chat') {
    for (const m of body.messages) {
      for (const t of m.tool_calls ?? []) { assert(!pending.has(t.id)); pending.add(t.id); }
      if (m.role === 'tool') { assert(pending.delete(m.tool_call_id), 'orphan chat result'); outputs.set(m.tool_call_id, m.content); }
    }
  } else {
    for (const m of body.input) {
      if (m.type === 'function_call') { assert(!pending.has(m.call_id)); pending.add(m.call_id); }
      if (m.type === 'function_call_output') { assert(pending.delete(m.call_id), 'orphan responses result'); outputs.set(m.call_id, m.output); }
    }
  }

  // 历史结束时不得残留未配对的调用。
  assert.equal(pending.size, 0, 'incomplete call/result association');
  return outputs;
}

/**
 * 以 SSE 格式向客户端发送一条伪造回复：文本、工具调用，或截断（只发送开头，不结束流）。
 * Chat 与 Responses 的事件结构不同，因此按 protocol 分别构造。
 */
function send(res, protocol, text, calls = [], truncated = false, nativeReasoning = false) {
  // SSE 响应头，禁止缓存。
  res.writeHead(200, {'content-type': 'text/event-stream', 'cache-control': 'no-cache'});

  // 把对象编码为一条 SSE data 事件。
  const event = x => res.write(`data: ${JSON.stringify(x)}\n\n`);

  if (protocol === 'chat') {
    // Chat：工具调用放在 delta.tool_calls 中，否则放文本增量。
    const delta = calls.length ? {tool_calls: calls.map((t, index) => ({index, id:t.id, type:'function', function:{name:t.name, arguments:t.arguments}}))} : {content:text};
    // 先发送内容增量。
    event({id:'chat_fixture', choices:[{index:0, delta, finish_reason:null}]});

    // 非截断时补发 finish_reason 与 [DONE]；截断时故意不发送，模拟流中断。
    if (!truncated) { event({id:'chat_fixture', choices:[{index:0, delta:{}, finish_reason:calls.length ? 'tool_calls':'stop'}]}); res.write('data: [DONE]\n\n'); }
  } else {
    // Responses：工具调用生成 function_call 条目，否则生成 assistant 消息。
    const output = calls.length ? calls.map(t => ({id:`item_${t.id}`, type:'function_call', call_id:t.id, name:t.name, arguments:t.arguments, status:'completed'})) : [{id:'message_fixture', type:'message', role:'assistant', content:[{type:'output_text', text}], status:'completed'}];
    if (nativeReasoning) output.unshift({id:'selection-reasoning-item', type:'reasoning', summary:[{type:'summary_text',text:'selection-transient-reasoning'}], encrypted_content:'fixture-opaque-native-reasoning'});

    // 截断时只发送第一个输出项，不发送 response.completed。
    if (truncated) {
      event({type:'response.output_item.added', output_index:0, item:output[0]});
    } else event({type:'response.completed', response:{id:'response_fixture', status:'completed', output}});
  }
  res.end();
}

/**
 * 以独立进程组运行被测程序并捕获输出（上限 2 MiB）。
 * 超时先发 SIGTERM，3 秒后仍在运行则发 SIGKILL；输出超限同样终止进程。
 * 结束后断言输出不含假密钥与注入序列；对 thin 二进制还断言不含任何 ANSI 转义。
 * onChild 回调把子进程句柄及"仍归本函数管理"的判断交给调用方（取消测试需要）。
 */
async function execute(bin, args, env, cwd, onChild, timeout = 30000, spawnChild = spawn) {
  // detached 使子进程成为新进程组，便于整组发送信号。
  const child = spawnChild(bin, args, {cwd, env, detached:true, stdio:['ignore','pipe','pipe']});

  // owned 表示子进程仍由本函数管理；退出后置为 false，防止向已回收的 PID 发信号。
  let owned = true, size = 0, chunks = [], failure, rejectWait;
  // An exited leader cannot be signalled, but inherited pipes may stay open.
  // Stop waiting/capturing independently of PID ownership on watchdog failure.
  const abandonOutput = () => { child.stdout.destroy(); child.stderr.destroy(); rejectWait?.(failure); };

  // 向进程组发送 SIGTERM；忽略进程已退出导致的错误。
  const stop = () => { if (owned) { try { process.kill(-child.pid, 'SIGTERM'); } catch {} } };

  // 看门狗：超时记录失败并停止子进程。
  const timer = setTimeout(() => { failure = new Error('application watchdog expired'); stop(); if (!owned) abandonOutput(); }, timeout);
  // Escalation also bounds the wait for capture EOF, not just the live process.
  const escalator = setTimeout(() => { if (owned) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } abandonOutput(); }, timeout + 3000);

  // 捕获输出；累计超过 2 MiB 则记录失败并终止子进程。
  const capture = b => { size += b.length; if (size <= 2*1024*1024) chunks.push(b); else { failure = new Error('output bound exceeded'); stop(); } };

  // 同时读取 stdout 与 stderr，否则管道写满会阻塞子进程。
  child.stdout.on('data', capture); child.stderr.on('data', capture);

  // 子进程退出后清除 owned 标记。
  child.on('exit', () => { owned = false; if (failure) abandonOutput(); });

  // 把句柄交给调用方（PTY 与取消场景需要向子进程发送信号）。
  onChild?.(child, () => owned);

  try {
    // 等待进程关闭（close 表示 stdio 全部关闭），取得退出码或信号；finally 中无论成功失败都清理定时器并终止残留进程组。
    const result = await new Promise((res, rej) => { rejectWait = rej; child.once('error', rej); child.once('close', (code, signal) => res({code, signal})); });

    // 解码捕获的输出，并做安全断言：假密钥与注入序列不得出现。
    const output = Buffer.concat(chunks).toString('utf8');
    assert(!output.includes(KEY), 'fake key leaked in captured output');
    assert(!output.includes(injection), 'model executable ANSI leaked');
    // 无头模式（thin）的输出必须是纯文本，不得含 ANSI 转义。
    if (bin === app) assert(!output.includes('\x1b'), 'headless ANSI leaked');

    // 安全断言通过后才报告超时或输出超限错误。
    if (failure) throw failure;
    return {...result, output};
  } finally { clearTimeout(timer); clearTimeout(escalator); stop(); }
}

/**
 * 运行一个应用验收场景：创建临时 HOME 与项目目录，启动伪造 OpenAI 兼容服务（chat 或 responses），
 * 写入 config.json，然后运行 CLI 或 PTY 驱动，并按 kind 断言结果。
 * kind 取值：help、no-config、legacy-config、plain、auto、trust、compact、malformed、truncated、stall、auto-tools、
 * cancel、term、output、unicode、auth-missing、auth-empty、auth-activate。场景结束时关闭服务器并删除临时目录。
 */
async function scenario(name, protocol, kind, isPty = false) {
  // 每个场景使用独立的临时根目录，包含 home 与 project 两个子目录。
  const root = await mkdtemp(join(tmpdir(), 'thin-app-'));
  const home = join(root,'home'), project = join(root,'project');
  await mkdir(home); await mkdir(project);

  // 约 1800 字节的种子文件，供 read_file 读取；压缩后仍应能看到其真实内容。
  const seed = 'seed-content-'.repeat(138) + 'end\n'; // ~1800 UTF-8 bytes
  await writeFile(join(project,'seed.txt'), seed);
  if (kind === 'tool-icons') await writeFile(join(project,'r.json'), '{"tool-json-hidden-marker":1}');

  // 场景计数器：请求数、对话轮次、摘要次数，以及压缩后标记。
  let requests = 0, rounds = 0, summaries = 0, afterSummary = false, stable, fixtureError, idleSocket;
  let selectionStage = 0;

  // stalled 表示已到达挂起点；signalChild 与 ownsChild 来自 execute 回调，非 PTY 取消时用于发送 SIGINT。
  let stalled, signalChild, ownsChild;

  // sockets 用于清理；observations 记录每个工具调用 id 对应的输出，供后续断言使用。
  const sockets = new Set(), observations = new Map();

  // 伪造的 OpenAI 兼容服务：校验 Bearer 密钥与路径，读取请求体，并按 kind 决定回复。
  const server = http.createServer(async (req,res) => {
    try {
      requests++;

      // 请求必须携带正确的假密钥，并访问与协议对应的路径。
      assert.equal(req.headers.authorization, `Bearer ${KEY}`);
      assert.equal(req.url, protocol === 'chat' ? '/v1/chat/completions' : '/v1/responses');
      let data = '', bytes = 0;
      // 请求体上限 1 MiB，然后解析 JSON。
      for await (const chunk of req) { bytes += chunk.length; assert(bytes < 1024*1024); data += chunk; }
      const body = JSON.parse(data);
      if (kind === 'stream-markdown' || kind === 'tool-icons') assert.equal(body.reasoning_effort, 'high');
      if (kind === 'auth-activate') {
        // DeepSeek 兼容选项必须真实影响线路参数，避免后端忽略输出上限。
        assert.equal(body.max_tokens, 100);
        assert(!('max_completion_tokens' in body));
      }

      // 校验历史中的工具配对，并记录本次请求携带的工具结果。
      const outputs = associations(body, protocol);
      for (const [id, output] of outputs) observations.set(id, output);

      // tool_choice 为 none 表示 CLI 发起的摘要请求（自动压缩）。
      const summary = body.tool_choice === 'none';
      if (kind === 'compact') {
        // 压缩期间 system 指令与工具 schema 必须保持不变，以保证前缀可被缓存复用。
        const prefix = JSON.stringify([protocol === 'chat' ? body.messages.filter(m=>m.role==='system') : body.instructions, body.tools]);
        stable ??= prefix; assert.equal(prefix, stable, 'system/schema changed during compaction');
      }

      // 摘要请求直接返回固定的摘要文本。
      if (summary) { summaries++; send(res,protocol,'Earlier reads succeeded. Continue reading seed.txt until finished.'); return; }

      // 摘要之后的普通请求，标记已完成压缩。
      if (summaries) afterSummary = true;
      rounds++;

      // 挂起场景：返回 SSE 响应头后不再发送数据；非 PTY 时发送 SIGINT 以测试取消。
      if (kind === 'stall' || kind === 'exit-busy' || (isPty && (kind === 'cancel' || kind === 'term') && rounds === 1)) {
        stalled = true;
        res.writeHead(200, {'content-type':'text/event-stream'}); res.flushHeaders();
        if (!isPty && ownsChild()) signalChild.kill('SIGINT');
        return;
      }

      if (kind === 'exit-busy-tool') {
        assert.equal(requests,1, 'Ctrl+D busy tool must not start another request');
        send(res,protocol,'',[tool('exit-busy-command','bash',{command:'sleep 30; printf must-not-complete'})]);
        return;
      }

      if (kind === 'model-select') {
        selectionStage = 1;
        assert(rounds <= 4, 'session selection request bound; no discovery requests');
        selectionStage = 2;
        assert.equal(body.model, rounds <= 2 ? 'fixture-model' : rounds === 3 ? 'fixture-next' : 'fixture-custom');
        selectionStage = 3;
        assert.equal(protocol === 'chat' ? body.reasoning_effort : body.reasoning?.effort, rounds <= 2 ? 'none' : rounds === 3 ? 'medium' : 'high');
        const serialized = JSON.stringify(protocol === 'chat' ? body.messages : body.input);
        selectionStage = 4;
        assert(serialized.includes(rounds <= 2 ? 'selection-first' : rounds === 3 ? 'selection-second' : 'selection-third'));
        selectionStage = 5;
        assert(!serialized.includes('/model') && !serialized.includes('rejected-busy'), 'local settings leaked into conversation');
        selectionStage = 6;
        if (rounds >= 2) assert(outputs.get('selection-read')?.includes('seed-content-'), 'paired read result lost across selection');
        if (rounds >= 3) {
          selectionStage = 7;
          assert(serialized.includes('selection-answer-one'), 'canonical first answer lost across model change');
          selectionStage = 8;
          if (protocol === 'responses') {
            assert(!body.input.some(item => item.id === 'message_fixture' || item.id === 'item_selection-read' || item.type === 'reasoning'), 'old native replay retained under new model');
            assert(!serialized.includes('fixture-opaque-native-reasoning') && !serialized.includes('selection-transient-reasoning'), 'native-only reasoning reconstructed after switch');
          }
        }
        if (rounds === 1) {
          // Observation window only; production requests are never delayed for UI.
          await new Promise(resolve => setTimeout(resolve, 500));
          send(res, protocol, '', [tool('selection-read','read_file',{path:'seed.txt'})], false, protocol === 'responses');
        } else send(res, protocol, rounds === 2 ? 'selection-answer-one' : rounds === 3 ? 'selection-answer-two' : 'selection-answer-three');
        return;
      }

      // Regular inline terminal: two questions in one owned PTY. Long second
      // reply scrolls the first into history; no external network/tools needed.
      if (kind === 'regular-two') {
        assert(requests <= 2, 'regular request bound');
        const users = body.messages.filter(m => m.role === 'user');
        assert.equal(users.at(-1)?.content, rounds === 1 ? 'regular-first' : 'regular-second');
        if (rounds === 2) assert(body.messages.some(m => m.role === 'assistant' && m.content?.includes('regular-answer-one')), 'first answer missing from history');
        send(res,protocol, rounds === 1 ? 'regular-answer-one' : `${Array.from({length:32}, (_,i)=>`regular filler ${i}`).join('\n')}\nregular-answer-two`);
        return;
      }

      // Split visible reasoning and Markdown over time. PTY must display both
      // before [DONE], not merely repaint the final committed answer.
      if (kind === 'stream-markdown') {
        assert.equal(protocol, 'chat');
        res.writeHead(200, {'content-type':'text/event-stream', 'cache-control':'no-cache'});
        const chunk = delta => res.write(`data: ${JSON.stringify({id:'stream_fixture',choices:[{index:0,delta,finish_reason:null}]})}\n\n`);
        chunk({reasoning_content:'thinking-old-one\nthinking-old-two\nthinking-old-three\nreasoning-stage-one'});
        await new Promise(resolve=>setTimeout(resolve,450));
        chunk({reasoning_content:'\nthinking-new-five\nthinking-new-six\nreasoning-stage-two'});
        await new Promise(resolve=>setTimeout(resolve,600));
        chunk({content:'# Orange heading\n\n**stream-stage-one** and [link](https://example.org) with `inline-marker`\n\n> quote-marker\n\n'});
        await new Promise(resolve=>setTimeout(resolve,600));
        chunk({content:'```text\nconst value = 1;\nexit_code=124\n/root/thin\nexit_code=0\n```\n\n| Item | State |\n| --- | --- |\n| fixture | ready |\n| second-row | verified |\n\nstream-final-answer'});
        await new Promise(resolve=>setTimeout(resolve,200));
        res.write(`data: ${JSON.stringify({id:'stream_fixture',choices:[{index:0,delta:{},finish_reason:'stop'}]})}\n\ndata: ${JSON.stringify({id:'stream_fixture',choices:[],usage:{prompt_tokens:12,completion_tokens:90,total_tokens:102,prompt_tokens_details:{cached_tokens:9},completion_tokens_details:{reasoning_tokens:30}}})}\n\ndata: [DONE]\n\n`);
        res.end();
        return;
      }

      if (kind === 'architecture-table') {
        send(res, protocol, `${architectureTable}\narchitecture-table-final-answer`);
        return;
      }

      if (kind === 'idle-peer') {
        assert(rounds <= 2, 'idle peer request bound; do not replay a POST');
        if (rounds === 1) {
          idleSocket = req.socket;
          res.once('finish', () => {
            const timer = setTimeout(() => idleSocket.end(), 50);
            idleSocket.once('close', () => clearTimeout(timer));
          });
          send(res,protocol,'',[tool('idle_command','bash',{command:'sleep 0.3; printf idle-peer-command-once'})]);
        } else {
          assert.notEqual(req.socket, idleSocket, 'closed idle connection reused');
          assert(outputs.get('idle_command')?.includes('idle-peer-command-once'), 'actual tool result lost');
          send(res,protocol,'fixture-answer idle-peer-final-answer');
        }
        return;
      }

      if (kind === 'tool-icons') {
        assert.equal(protocol, 'chat');
        assert(rounds <= 2, 'tool icon request bound');
        if (rounds === 1) {
          send(res,protocol,'',[
            tool('icon_shell','bash',{command:'sleep 1; cat r.json'}),
            tool('icon_second','bash',{command:'sleep 0.6; printf ok'}),
            tool('icon_failure','bash',{command:'false; # failure-caption-long-enough-to-exercise-80-percent-clipping'})
          ]);
        } else {
          assert(outputs.get('icon_shell')?.includes('tool-json-hidden-marker'), 'tool result absent from protocol history');
          assert(outputs.get('icon_second')?.includes('ok'), 'second tool result absent from protocol history');
          assert(outputs.has('icon_failure'), 'failed command result absent from protocol history');
          send(res,protocol,'tool-icon-final-answer');
        }
        return;
      }

      if (kind === 'memory-summary') {
        assert.equal(protocol,'chat');
        assert(rounds <= 2, 'memory summary request bound');
        const content = 'memory-summary-hidden-body';
        const version = createHash('sha256').update(content).digest('hex');
        if (rounds === 1) send(res,protocol,'',[
          tool('mem_write','memory',{action:'write',topic:'caption-note',content}),
          tool('mem_read','memory',{action:'read',topic:'caption-note'}),
          tool('mem_list','memory',{action:'list'}),
          tool('mem_delete','memory',{action:'delete',topic:'caption-note',expected_version:version})
        ]); else {
          for (const id of ['mem_write','mem_read','mem_list','mem_delete']) assert(outputs.has(id), 'memory paired result absent');
          assert.equal(JSON.parse(outputs.get('mem_read')).content,content);
          assert.equal(JSON.parse(outputs.get('mem_read')).version,version);
          assert.equal(await exists(join(project,'.thin','mem','caption-note.md')),false);
          send(res,protocol,'memory-summary-final-answer');
        }
        return;
      }

      if (kind === 'file-stats') {
        assert.equal(protocol,'chat');
        assert(rounds <= 2, 'file stats request bound');
        if (rounds === 1) send(res,protocol,'',[
          tool('file_create','write_file',{path:'stats.txt',content:'a\nb\nc\nd\ne\n'}),
          tool('file_update','write_file',{path:'stats.txt',content:'a\nB\nx\nc\ne\n',overwrite:true}),
          tool('file_read','read_file',{path:'stats.txt'}),
          tool('file_range','read_file',{path:'stats.txt',offset:1,limit:2}),
          tool('file_clear','write_file',{path:'stats.txt',content:'',overwrite:true}),
          tool('file_failed','write_file',{path:'stats.txt',content:'must-not-write'})
        ]); else {
          for (const id of ['file_create','file_update','file_read','file_range','file_clear','file_failed']) assert(outputs.has(id), 'file tool result absent');
          assert.equal(JSON.parse(outputs.get('file_read')).content,'a\nB\nx\nc\ne\n');
          assert.equal(JSON.parse(outputs.get('file_range')).content,'\nB');
          assert.equal(await readFile(join(project,'stats.txt'),'utf8'),'');
          send(res,protocol,'file-stats-final-answer');
        }
        return;
      }

      // 输出超限场景：返回约 240 KiB 的文本，验证输出上限。
      if (kind === 'output') { send(res,protocol,'x'.repeat(240*1024)); return; }

      // 畸形 SSE 场景：返回非法 JSON。
      if (kind === 'malformed') { res.writeHead(200, {'content-type':'text/event-stream'}); res.end('data: {not-json}\n\n'); return; }

      // 截断场景：发送不完整的工具调用后结束。CLI 不应执行它，forbidden.txt 不得出现。
      if (kind === 'truncated') { send(res,protocol,'', [tool('partial','write_file',{path:'forbidden.txt',content:'bad'})], true); return; }

      // 压缩场景：连续 8 轮读取文件；从第 2 轮起断言上一轮的真实读取结果出现在请求中。
      if (kind === 'compact' && rounds <= 8) {
        if (rounds > 1) assert(observations.get(`read_${rounds-1}`)?.includes('seed-content-'), 'real read result absent from normal/summary request');
        send(res,protocol,'',[tool(`read_${rounds}`,'read_file',{path:'seed.txt'})]); return;
      }

      // 默认信任与兼容 --trust：真实执行写文件、Memory 与 shell，且子进程看不到假密钥。
      if ((kind === 'auto' || kind === 'trust') && rounds === 1) {
        send(res,protocol,'',[
          tool('write','write_file',{path:'written.txt',content:'actual-write'}),
          tool('memory','memory',{action:'write',topic:'acceptance',content:'actual-memory'}),
          tool('shell','bash',{command:'test -z "${THIN_FIXTURE_KEY+x}" && printf child-key-omitted && printf actual-shell > shell.txt'})
        ]); return;
      }

      // 同一 PTY 两轮自动写入，驱动不会发送任何审批按键。
      if (kind === 'auto-tools' && (rounds === 1 || rounds === 3)) {
        send(res,protocol,'',[tool(`auto_${rounds}`,'write_file',{path:rounds===1?'auto-one.txt':'auto-two.txt',content:'executed'})]); return;
      }

      // 第 2 轮：断言三个工具结果与磁盘副作用均已发生。
      if ((kind === 'auto' || kind === 'trust') && rounds === 2) {
        assert.equal(outputs.size, 3);
        assert(outputs.get('shell').includes('child-key-omitted'), 'shell saw key or did not run');
        assert.equal(await readFile(join(project,'written.txt'),'utf8'),'actual-write');
        assert.equal(await readFile(join(project,'shell.txt'),'utf8'),'actual-shell');
        assert((await readFile(join(project,'.thin/mem/acceptance.md'),'utf8')).includes('actual-memory'));
      }

      // 默认回复：包含 Unicode、Markdown 与 OSC 52 注入，用于验证渲染与净化。
      send(res,protocol,`**世界** café\n\n- fixture-answer\n${injection}`);
    // 伪造服务内部断言失败：记录错误并返回 500，由场景末尾统一抛出。
    } catch (error) {
      if (kind === 'model-select') {
        error.fixtureCase = `selection/${protocol}`;
        error.fixtureCheck = `stage-${selectionStage} request-${requests}`;
      }
      fixtureError ??= error;
      res.writeHead(500); res.end('fixture assertion failed');
    }
  });

  // 登记连接，便于场景结束时销毁。
  server.on('connection', socket => { sockets.add(socket); socket.on('close',()=>sockets.delete(socket)); });

  try {
    // 监听回环随机端口，并构造该服务的 /v1 地址。
    await new Promise(r=>server.listen(0,'127.0.0.1',r));
    const url = `http://127.0.0.1:${server.address().port}/v1`;

    // 子进程环境只包含 PATH、HOME 等最小变量，并注入假密钥与 THIN_APP_* 测试参数。
    const env = {PATH:'/usr/bin:/bin', HOME:home, LANG:'C.UTF-8', TERM:'xterm-256color', THIN_FIXTURE_KEY:KEY,
      THIN_APP_BIN:app, THIN_APP_TEST_HOME:home, THIN_APP_TEST_PROJECT:project, THIN_APP_TEST_URL:url, THIN_APP_TEST_MODE:kind};

    // 除 help、no-config 与 auth-missing 外写入 config.json：指定 provider、模型协议、上下文与各项限制。
    // legacy-config 只写旧文件，确认程序不会悄悄回退并连接其中配置的服务。
    if (kind !== 'help' && kind !== 'no-config' && kind !== 'auth-missing') {
      await mkdir(join(home,'.thin'));
      const filename = kind === 'legacy-config' ? 'auth.json' : 'config.json';
      // 空白文件走交互初始化；待激活配置始终使用回环服务，绝不向公共端点发送密钥或消息。
      const provider = ['auth-activate','exit-unconfigured','exit-secret'].includes(kind) ? {base_url:url, api_key_env:'', api_key:null, chat_max_tokens:true} : {base_url:url, api_key_env:'THIN_FIXTURE_KEY'};
      const content = kind === 'auth-empty' ? ' \t\n\r\n ' : JSON.stringify({provider, model:{name:'fixture-model',protocol,context_tokens:kind==='compact'?6000:32768,reasoning_effort:kind==='model-select'?'none':['stream-markdown','tool-icons'].includes(kind)?'high':undefined,reasoning:kind==='model-select'?{format:'standard',map:{off:'none',minimal:'minimal',low:'low',medium:'medium',high:'high',xhigh:'xhigh'}}:undefined}, models:kind==='model-select'?[{name:'fixture-next',protocol,context_tokens:65536,reasoning_effort:'low',reasoning:{format:'standard',map:{off:'none',minimal:'minimal',low:'low',medium:'medium',high:'high',xhigh:'xhigh'}}}]:undefined, limits:{max_output_tokens:100,summary_tokens:100,safety_tokens:100,request_timeout_ms:10000,task_timeout_ms:20000}});
      await writeFile(join(home,'.thin',filename), content);
    }

    // 启动参数：help 使用 --help；其它使用 --print 任务，trust 场景追加 --trust；PTY 不传参数。
    const args = kind === 'help' ? ['--help'] : ['--print','fixture-task', ...(kind==='trust'?['--trust']:[])];

    // 运行 CLI 或 PTY 驱动（PTY 超时 90 秒，其它 30 秒）。
    const result = await execute(isPty?pty:app, isPty?[]:args, env, project, (child, owns) => {signalChild=child; ownsChild=owns;}, isPty?90000:30000);

    // 先检查伪造服务的断言错误，避免被 CLI 的失败掩盖。
    if (fixtureError) throw fixtureError;
    // 失败类场景必须以非零码退出；其余场景必须返回 0。
    const failureCase = ['no-config','legacy-config','malformed','truncated','stall'].includes(kind);
    if (failureCase) assert.notEqual(result.code, 0, `${name} unexpectedly succeeded`);
    else {
      // 只提取 thin:/error: 后的标识符作为诊断信息，不输出原始内容。
      const codes = [...result.output.matchAll(/(?:thin:|error:)\s+[A-Za-z_][A-Za-z0-9_]*/g)].slice(-3).map(m=>m[0]).join(', ');
      assert.equal(result.code, 0, `${name}: exit ${result.code}; ${codes || 'no safe error code'}; captured ${result.output.length} bytes (not rendered)`);
    }

    if (isPty && !['term','output'].includes(kind)) {
      const ids = [...result.output.matchAll(/^PTY_SESSION_ID=([a-f0-9]{32})$/gm)];
      assert.equal(ids.length,1, 'Ctrl+D must announce exactly one restored session identity');
      const announced = ids[0][1];
      const logDir = join(project,'.thin/sessions');
      if (await exists(logDir) && (await stat(logDir)).isDirectory()) {
        for (const file of (await readdir(logDir)).filter(name=>name.endsWith('.jsonl'))) {
          assert(file.includes(`-${announced}-`), 'archive filename differs from announced identity');
          for (const line of (await readFile(join(logDir,file),'utf8')).trimEnd().split('\n').filter(Boolean)) assert.equal(JSON.parse(line).session,announced, 'record identity differs from immutable owner identity');
        }
      }
    }
    if (['exit-no-submit','exit-unconfigured','exit-secret','exit-batched'].includes(kind)) {
      assert.equal(requests,0, 'exit identity must not send a request');
      // The TUI seeds the project default thinking level on startup, so the
      // only allowed project artifact is the private settings file. Identity
      // submission still must not create archives, history, or other storage.
      const projectThin = join(project,'.thin');
      if (await exists(projectThin)) assert.deepEqual(await readdir(projectThin),['settings.json'], 'identity/no-submission created unexpected project storage');
      if (['exit-unconfigured','exit-secret'].includes(kind)) {
        const disk = JSON.parse(await readFile(join(home,'.thin/config.json'),'utf8'));
        assert.equal(disk.provider.api_key,null, 'Ctrl+D secret exit must not save input');
      }
    }
    if (kind === 'exit-no-log') {
      assert.equal(requests,1);
      assert(!await exists(join(project,'.thin/sessions')), 'disabled recording created archives for exit identity');
    }
    if (['exit-busy','exit-busy-tool'].includes(kind)) {
      assert.equal(requests,1);
      assert(!result.output.includes('must-not-complete'));
      if (kind === 'exit-busy') assert(stalled);
    }

    // help 与 no-config 不应发起任何请求，也不应创建 .thin 目录；非失败场景还要检查输出内容。
    if (kind === 'help' || kind === 'no-config') {
      assert.equal(requests,0); assert(!await exists(join(home,'.thin'))); assert(!await exists(join(project,'.thin')));
      if (kind==='help') assert(result.output.includes('Usage: thin'));
    } else if (kind === 'legacy-config') {
      assert.equal(requests,0);
      assert(!await exists(join(home,'.thin/config.json')));
      assert(!await exists(join(project,'.thin')));
    } else if (!failureCase && !isPty) assert(result.output.includes('fixture-answer'));

    // 帮助与缺少新配置时的诊断均应指向 config.json，而不是旧文件名。
    if (['help','no-config','legacy-config'].includes(kind)) {
      assert(result.output.includes('~/.thin/config.json'));
      assert(!result.output.includes('~/.thin/auth.json'));
    }

    // 交互配置验收：驱动检查屏幕、密钥脱敏与终端恢复，这里检查持久化与网络/文件副作用。
    if (['auth-missing','auth-empty','auth-activate'].includes(kind)) {
      const authPath = join(home,'.thin/config.json');
      const auth = JSON.parse(await readFile(authPath,'utf8'));
      assert.equal((await stat(authPath)).mode & 0o777, 0o600, 'auth file must be private');
      assert.equal(auth.provider.api_key_env, '');
      if (kind !== 'auth-activate') {
        assert(!await exists(join(project,'.thin/sessions')), 'initialization created session records without submission');
        assert(!await exists(join(project,'.thin')));
        assert.deepEqual((await readdir(project)).sort(), ['seed.txt'], 'unexpected project files');
      }
      if (kind === 'auth-activate') {
        const logs = join(project,'.thin/sessions');
        const files = (await readdir(logs)).filter(f => f.endsWith('.jsonl'));
        assert(files.length > 0, 'activation chat did not create logs');
        let hasUser = false, hasFinished = false;
        for (const file of files) {
          const raw = await readFile(join(logs,file),'utf8');
          assert(!raw.includes(KEY), 'activation key leaked in logs');
          for (const line of raw.trimEnd().split('\n')) {
            const row = JSON.parse(line);
            hasUser ||= row.event === 'user'; hasFinished ||= row.event === 'finished';
          }
        }
        assert(hasUser && hasFinished, 'activation conversation missing');
        assert.equal(auth.provider.api_key, KEY);
        assert.equal(auth.provider.base_url, url, 'activation must preserve loopback endpoint');
        assert.equal(auth.model.name, 'fixture-model');
        assert.equal(auth.model.protocol, protocol);
        assert.equal(requests, 1, 'activation must send exactly one request');
      } else {
        assert(auth.provider.api_key == null || auth.provider.api_key === '', 'initialized template must not contain a key');
        assert.equal(auth.provider.base_url, 'https://api.deepseek.com');
        assert.equal(auth.model.name, 'deepseek-flash');
        assert.equal(auth.model.context_tokens, 1000000);
        assert.equal(auth.model.protocol, 'chat');
        assert.equal(auth.provider.chat_max_tokens, true);
        assert.equal(requests, 0, 'initialization must not send requests');
        if (kind === 'auth-missing') assert.equal((await stat(join(home,'.thin'))).mode & 0o777, 0o700, 'created auth directory must be private');
      }
    }

    if (kind === 'compact') {
      // 压缩场景应共 9 轮（8 次读取加 1 次最终回复），至少触发一次自动摘要，且摘要后仍能看到 8 个读取结果。
      assert.equal(rounds,9); assert(summaries>=1,'automatic compaction not reached: tune context using measured evidence'); assert(afterSummary);
      for (let i=1;i<=8;i++) assert(observations.get(`read_${i}`)?.includes('seed-content-'), `read ${i} result missing`);
    }

    // 畸形与截断的工具调用仍不得执行，即使默认信任。
    if (kind==='malformed' || kind==='truncated') {
      for (const path of ['written.txt','shell.txt','forbidden.txt','.thin/mem/acceptance.md']) assert(!await exists(join(project,path)), `unexpected effect: ${path}`);
    }

    // 默认执行不进入审批；文件、shell 与 Memory 的真实结果仍正确回填。
    if (kind === 'auto' || kind === 'trust' || kind === 'auto-tools') {
      assert(!result.output.includes('Approval #'), 'default tool execution requested approval');
      assert(!result.output.includes('privileged tools denied'), 'default tool execution denied');
      if (kind === 'auto-tools') {
        assert.equal(await readFile(join(project,'auto-one.txt'),'utf8'),'executed');
        assert.equal(await readFile(join(project,'auto-two.txt'),'utf8'),'executed');
        assert.equal(rounds,4);
      }
      const files = (await readdir(join(project,'.thin/sessions'))).filter(f=>f.endsWith('.jsonl'));
      for (const file of files) {
        const events = (await readFile(join(project,'.thin/sessions',file),'utf8')).trimEnd().split('\n').map(line=>JSON.parse(line));
        assert(!events.some(row=>row.event==='permission'||row.event==='decision'||(row.event==='state'&&row.data.state==='awaiting_permission')), 'default execution entered authorization');
        assert(events.some(row=>row.event==='tool_started'), 'real tool execution did not start');
      }
    }

    // 取消类场景必须确实到达挂起点。
    if (kind === 'stall' || kind === 'cancel' || kind === 'term') assert(stalled, 'cancel never reached HTTP fixture');

    // stall：SIGINT 应使 CLI 以 130（128 + SIGINT）退出。
    if (kind === 'stall') assert.equal(result.code, 130, 'SIGINT must return canceled status');
    // cancel：取消后 CLI 应能继续发起第二轮请求。
    if (kind === 'cancel') assert.equal(rounds,2, 'did not resume after cancel');
    if (kind === 'model-select') {
      assert.equal(requests,4, 'selection issued discovery or extra requests');
      const disk = JSON.parse(await readFile(join(home,'.thin/config.json'),'utf8'));
      assert.equal(disk.model.name,'fixture-model');
      assert.equal(disk.model.reasoning_effort,'none');
      assert.equal(disk.model.context_tokens,32768);
      assert.equal(disk.models[0].name,'fixture-next');
      assert.equal(disk.models[0].reasoning_effort,'low');
      assert.deepEqual(JSON.parse(await readFile(join(project,'.thin/settings.json'),'utf8')), {version:1,reasoning_effort:'high'});
    }
    if (kind === 'regular-two') assert.equal(requests,2, 'regular two-turn request count');
    if (kind === 'tool-icons') assert.equal(requests,2, 'tool icon request count');
    if (kind === 'file-stats') assert.equal(requests,2, 'file stats request count');
    if (kind === 'idle-peer') {
      assert.equal(requests,2, 'idle peer must issue exactly the two intended calls');
      assert(result.output.includes('idle-peer-final-answer'), 'idle peer final body missing');
      assert(!result.output.includes('ModelRequestFailed'), 'idle peer transport still failed');
    }

    // 场景通过，输出请求数与摘要数（不含内容）。
    console.log(`PASS ${name}: requests=${requests} summaries=${summaries}`);
  } finally {
    // finally：销毁残留连接，关闭服务器，删除临时目录。
    for (const socket of sockets) socket.destroy();
    await new Promise(r=>server.close(r));
    await rm(root,{recursive:true,force:true});
  }
}
async function watchdogRegression() {
  // Deterministic exit-without-close: no real PID is borrowed or signalled.
  const child = new EventEmitter();
  child.stdout = new PassThrough(); child.stderr = new PassThrough();
  let pidReads = 0;
  Object.defineProperty(child, 'pid', {get() { pidReads++; throw new Error('reaped PID accessed'); }});
  let stillOwned;
  const pending = execute('fixture', [], {}, '.', (_, owned) => { stillOwned = owned; }, 25, () => child);
  child.emit('exit', 0);
  assert.equal(stillOwned(), false);
  let guard;
  try {
    await assert.rejects(Promise.race([pending, new Promise((_, reject) => {
      guard = setTimeout(() => reject(new Error('capture did not stop')), 1000);
    })]), /application watchdog expired/);
    assert(child.stdout.destroyed && child.stderr.destroyed);
    assert.equal(pidReads, 0);
  } finally { clearTimeout(guard); child.emit('close', 0); await pending.catch(() => {}); }
  console.log('PASS capture-watchdog: exited leader, open pipes, no stale PID signalling');
}

try {
  await watchdogRegression();
  if (!watchdogOnly) {
  // 运行全部场景：先测无配置的 help 与 print，再对 chat 与 responses 运行通用场景，最后运行 PTY 场景（仅 chat）。
  await scenario('PTY model/effort selection chat','chat','model-select',true);
  await scenario('PTY model/effort selection responses','responses','model-select',true);
  for (const kind of ['exit-batched','exit-no-submit','exit-no-log','exit-unconfigured','exit-secret','exit-busy','exit-busy-tool']) await scenario(`PTY/${kind}`,'chat',kind,true);
  await scenario('help without configuration','chat','help');
  await scenario('print without configuration','chat','no-config');
  await scenario('legacy configuration is not loaded','chat','legacy-config');

  // 对两种协议分别运行全部通用场景。
  for (const protocol of ['chat','responses']) {
    for (const kind of ['plain','auto','trust','compact','malformed','truncated','stall','idle-peer']) await scenario(`${protocol}/${kind}`,protocol,kind);
  }

  // PTY 场景：通过 thin-app-pty 驱动交互式终端，仅使用 chat 协议。
  for (const kind of ['unicode','regular-two','stream-markdown','architecture-table','tool-icons','file-stats','memory-summary','auto-tools','cancel','term','output','auth-missing','auth-empty','auth-activate']) await scenario(`PTY/${kind}`,'chat',kind,true);
  await reviewRegressions(app);
  await logRegressions(app,pty);
  await settingsRegressions({app,pty,execute,send});
  console.log('Application fixture suite passed; general PTY tests exercise chat, model selection also covers responses.');
  }

// 顶层捕获：任何场景失败都打印脱敏后的错误（替换密钥、去除控制字符），并以退出码 1 结束。
} catch (error) {
  // 中文：不要渲染捕获的终端或模型输出、响应头或请求体。
  // Do not render captured terminal/model output, headers, or request bodies.
  const label = /^(?:log|selection|settings)\/[a-z-]+$/.test(error.fixtureCase ?? '') && /^[a-zA-Z0-9 /:_-]+$/.test(error.fixtureCheck ?? '')
    ? `${error.fixtureCase}: ${error.fixtureCheck}` : 'offline fixture assertion failed (details withheld)';
  console.error(`FAIL application acceptance: ${label}`);
  process.exitCode = 1;
}
