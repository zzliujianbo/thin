//! 命令行参数解析与帮助文本。只做语法层面的解析，不读取配置或环境。

const std = @import("std");
const ids = @import("session_id.zig");

/// 运行模式。默认是普通本地前台；绝不因为缺少参数、连接失败或历史恢复而进入守护模式。
/// foreground/connect/attach 需要真正的终端，daemon 与内部 worker 必须能在无 TTY 环境运行。
pub const Mode = enum {
    foreground,
    daemon,
    connect,
    attach,
    worker,

    pub fn requiresTty(self: Mode) bool {
        return switch (self) {
            .foreground, .connect, .attach => true,
            .daemon, .worker => false,
        };
    }
};

/// 内部 worker 会话的 owner：普通前台启动器，还是守护服务。仅 --internal-worker 使用。
pub const WorkerOwner = enum { foreground, daemon };

/// 解析后的选项。prompt 为 null 表示交互模式；非 null 表示 --print 一次性模式。
/// 普通工具调用直接执行；危险 bash 在执行前按命令内容分类，必须逐次明确批准。
/// 这不是沙箱。--print 没有审批界面，因此直接拒绝危险命令。
pub const Options = struct {
    prompt: ?[]const u8 = null,
    restore_selection: ?ids.Id = null,
    resume_session: ?ids.Id = null,
    auto_refresh_models: bool = true,
    help: bool = false,
    version: bool = false,
    /// 默认普通前台；只有显式的 --daemon/--connect/--attach 或内部 worker 参数会改变它。
    mode: Mode = .foreground,
    /// --attach 的目标会话；连接既有会话，不隐式启动服务。
    attach_session: ?ids.Id = null,
    /// Explicit daemon-only numeric TCP address, e.g. 127.0.0.1:2222 or [::1]:2222.
    ssh_listen: ?[]const u8 = null,
    /// Internal SSH+TUI child. Accepted socket is stdin; parent pid is checked.
    ssh_owner: ?u32 = null,
    /// 仅与 --attach 一起使用，表示替换已有的可写控制台。
    takeover: bool = false,
    /// 内部 worker 的 AF_UNIX endpoint；只由 --internal-worker 设置。
    worker_endpoint: ?[]const u8 = null,
    /// 内部 worker 承载的会话 ID；只由 --internal-worker 设置。
    worker_session: ?ids.Id = null,
    /// 内部 worker 的会话 owner；只由 --internal-worker 设置。
    worker_owner: WorkerOwner = .daemon,
    /// 仅内部允许：worker 从既有 checkpoint 恢复，不得与公开 --resume/--restore-selection 混用。
    worker_resume: bool = false,
    /// 仅内部允许：worker 按原 --restore-selection 语义只读入旧选择（新空会话），不得与公开 flag 混用。
    worker_restore_selection: ?ids.Id = null,
};

/// 解析 argv。args[0] 是程序名，因此从 1 开始遍历。
/// 无效参数返回错误（InvalidArguments、InvalidSessionID、UnknownOption），由调用方决定如何提示。
pub fn parse(args: []const [:0]const u8) !Options {
    var result: Options = .{};
    // 已出现的运行模式（公开 flag 或内部 worker）；用于检测重复与互斥。
    var selected: ?Mode = null;

    // 使用显式索引循环，以便 --print 能在处理时跳过下一个参数（即 prompt）。
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // --print 要求后面紧跟一个 prompt，且不允许重复指定，避免静默覆盖。
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) result.help = true else if (std.mem.eql(u8, arg, "--version")) result.version = true else if (std.mem.eql(u8, arg, "--no-model-auto-refresh")) result.auto_refresh_models = false else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            if (result.prompt != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            result.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--restore-selection") or std.mem.eql(u8, arg, "--resume")) {
            if (result.restore_selection != null or result.resume_session != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            const id = try parseId(args[i]);
            if (std.mem.eql(u8, arg, "--resume")) result.resume_session = id else result.restore_selection = id;
        } else if (std.mem.eql(u8, arg, "--daemon") or std.mem.eql(u8, arg, "--connect")) {
            // 显式守护服务模式；--connect 只连接已运行的同类服务，永不自动拉起。
            const mode: Mode = if (std.mem.eql(u8, arg, "--daemon")) .daemon else .connect;
            if (selected != null) return error.InvalidArguments;
            selected = mode;
            result.mode = mode;
        } else if (std.mem.eql(u8, arg, "--ssh-listen")) {
            if (result.ssh_listen != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            if (args[i].len == 0) return error.InvalidArguments;
            result.ssh_listen = args[i];
        } else if (std.mem.eql(u8, arg, "--internal-ssh")) {
            if (selected != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            for (args[i]) |byte| if (byte < '0' or byte > '9') return error.InvalidArguments;
            const owner = std.fmt.parseInt(u32, args[i], 10) catch return error.InvalidArguments;
            if (owner <= 1 or owner > std.math.maxInt(c_int)) return error.InvalidArguments;
            result.ssh_owner = owner;
            result.mode = .connect;
            selected = .connect;
        } else if (std.mem.eql(u8, arg, "--attach")) {
            if (selected != null or result.attach_session != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            result.attach_session = try parseId(args[i]);
            selected = .attach;
            result.mode = .attach;
        } else if (std.mem.eql(u8, arg, "--takeover")) {
            if (result.takeover) return error.InvalidArguments;
            result.takeover = true;
        } else if (std.mem.eql(u8, arg, "--internal-worker")) {
            // 内部入口，不在 help 中推广：endpoint、会话 ID、owner 三项必填。
            if (selected != null or i + 3 >= args.len) return error.InvalidArguments;
            i += 1;
            if (args[i].len == 0) return error.InvalidArguments;
            result.worker_endpoint = args[i];
            i += 1;
            result.worker_session = try parseId(args[i]);
            i += 1;
            if (std.mem.eql(u8, args[i], "foreground")) {
                result.worker_owner = .foreground;
            } else if (std.mem.eql(u8, args[i], "daemon")) {
                result.worker_owner = .daemon;
            } else return error.InvalidArguments;
            selected = .worker;
            result.mode = .worker;
        } else if (std.mem.eql(u8, arg, "--worker-resume")) {
            if (result.worker_resume) return error.InvalidArguments;
            result.worker_resume = true;
        } else if (std.mem.eql(u8, arg, "--worker-restore-selection")) {
            // 内部入口，不在 help 中推广：把老的 --restore-selection 迁入 foreground worker。
            if (result.worker_restore_selection != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            result.worker_restore_selection = try parseId(args[i]);
        } else return error.UnknownOption;
    }

    if (result.ssh_listen != null and result.mode != .daemon) return error.InvalidArguments;
    if ((result.restore_selection != null or result.resume_session != null) and result.prompt != null) return error.InvalidArguments;
    // 显式运行模式与 --print/--resume/--restore-selection 互斥；--resume 仍属于普通前台模式。
    if (selected != null and (result.prompt != null or result.resume_session != null or result.restore_selection != null)) return error.InvalidArguments;
    // 只有 --attach 可以带 --takeover：替换已有的可写控制台，而不是新起服务。
    if (result.takeover and result.mode != .attach) return error.InvalidArguments;
    // 内部 worker 的恢复标记只能在 worker 模式使用，且不得与公开 --resume/--restore-selection 混用。
    if (result.worker_resume and (result.mode != .worker or result.resume_session != null or result.restore_selection != null or result.prompt != null)) return error.InvalidArguments;
    // 内部 worker 的选择恢复同样只允许 worker 模式，并与 --worker-resume、公开模式参数互斥。
    if (result.worker_restore_selection != null and
        (result.mode != .worker or result.worker_resume or result.resume_session != null or result.restore_selection != null or result.prompt != null)) return error.InvalidArguments;
    return result;
}

test "SSH listener is explicit daemon-only; internal child is not a public attach mode" {
    const daemon = try parse(&.{ "thin", "--ssh-listen", "127.0.0.1:2222", "--daemon" });
    try std.testing.expectEqual(Mode.daemon, daemon.mode);
    try std.testing.expectEqualStrings("127.0.0.1:2222", daemon.ssh_listen.?);
    try std.testing.expect((try parse(&.{"thin"})).ssh_listen == null);
    const child = try parse(&.{ "thin", "--internal-ssh", "1234", "--no-model-auto-refresh" });
    try std.testing.expectEqual(Mode.connect, child.mode);
    try std.testing.expectEqual(@as(u32, 1234), child.ssh_owner.?);
    try std.testing.expect(!child.auto_refresh_models);
    for ([_][]const [:0]const u8{
        &.{ "thin", "--ssh-listen", "127.0.0.1:2222" },
        &.{ "thin", "--connect", "--ssh-listen", "127.0.0.1:2222" },
        &.{ "thin", "--daemon", "--ssh-listen" },
        &.{ "thin", "--daemon", "--ssh-listen", "" },
        &.{ "thin", "--daemon", "--ssh-listen", "a", "--ssh-listen", "b" },
        &.{ "thin", "--internal-ssh", "1" },
        &.{ "thin", "--internal-ssh", "-4" },
        &.{ "thin", "--internal-ssh", "+4" },
        &.{ "thin", "--internal-ssh", "2147483648" },
        &.{ "thin", "--internal-ssh", "4", "--daemon" },
        &.{ "thin", "--internal-ssh", "4", "--print", "x" },
    }) |args| try std.testing.expectError(error.InvalidArguments, parse(args));
}

/// 会话 ID 必须是 32 个小写十六进制字符；调用方不做二次校验。
fn parseId(value: []const u8) !ids.Id {
    if (value.len != 32) return error.InvalidSessionID;
    const id: ids.Id = value[0..32].*;
    if (!ids.valid(id)) return error.InvalidSessionID;
    return id;
}

/// 帮助文本，由 --help 输出。字符串内容即为用户可见的文档。
pub const help =
    \\thin - minimal local agent (Linux x86_64, Zig 0.17.0)
    \\
    \\Usage: thin
    \\       thin --print "prompt"
    \\       thin --restore-selection <32-lowerhex-session-id>
    \\       thin --resume <32-lowerhex-session-id>
    \\       thin --daemon [--ssh-listen <numeric-address:port>]
    \\       thin --connect
    \\       thin --attach <32-lowerhex-session-id> [--takeover]
    \\       thin --help | --version
    \\
    \\Modes: ordinary local foreground by default; nothing starts a service implicitly.
    \\Only --daemon explicitly runs the per-user service, kept in the foreground
    \\for a service manager (no self-daemonizing fork).
    \\--ssh-listen is daemon-only and opt-in; e.g. 127.0.0.1:2222 or [::1]:2222.
    \\It serves only the TUI via libssh/public-key authentication, never a shell.
    \\Use protocol user thin; put Ed25519 public keys in ~/.thin/authorized_keys.
    \\Keep ~/.thin mode 0700 and key files 0600. A missing host key is generated
    \\at ~/.thin/ssh_host_ed25519_key; an existing identity is never overwritten.
    \\No password/PAM, exec, SFTP, forwarding, or system SSH configuration is used.
    \\--connect joins the already running daemon service; it requires that service.
    \\--attach <id> joins an existing session worker, which ordinary foreground thin
    \\or the daemon may publish, so it does not require a running daemon.
    \\Neither --connect nor --attach starts a service and neither sends a request.
    \\A missing service, endpoint or session is reported, never auto-started.
    \\--daemon, --connect and --attach are mutually exclusive and also exclude
    \\--print, --resume and --restore-selection; a repeated mode flag is an error.
    \\--takeover is valid only with --attach and replaces the previous writable console.
    \\Foreground, connect and attach need a terminal; the daemon does not.
    \\A session keeps one writable owner; an unattended dangerous command still waits.
    \\Disconnecting from a daemon session detaches the view, it does not cancel work.
    \\
    \\Configuration: ~/.thin/config.json
    \\Startup initializes a missing/empty file for DeepSeek (deepseek-flash).
    \\Use /login in the TUI for hidden key entry; the key is saved locally with mode 0600.
    \\Never put a key in chat or command arguments. Saving never calls model inference.
    \\Successful /login returns to the prompt and refreshes that provider's official model list.
    \\Existing nonempty configurations are preserved. Advanced configuration example:
    \\  {"llm":{"default":"local/your-model","reasoning_effort":"medium",
    \\    "providers":{"local":{"base_url":"https://your-provider.example/v1",
    \\      "api_key_env":"THIN_API_KEY","models":{"your-model":{
    \\        "context_tokens":128000,"protocol":"chat"}}}}}}
    \\Use either api_key_env (environment variable) or api_key per provider, not both.
    \\--print requires usable credentials/model settings; it never opens the setup UI.
    \\Protocols: auto (Responses then one explicitly supported fallback), responses, chat, anthropic.
    \\Anthropic Messages must be selected explicitly; auto never probes it.
    \\For Go Claude: /login OpenCode Go, then /model opencode-go/claude-haiku-5-5.
    \\Model context and effort use exact-route metadata or explicit local declarations.
    \\Anthropic uses x-api-key and signed native replay; custom base_url must end before /messages.
    \\Anthropic thinking uses verified capability maps; unverified options are not invented.
    \\Known DeepSeek thinking format selects Chat locally; it never probes Responses.
    \\
    \\Interactive uses regular terminal scrollback, not an alternate full-screen buffer.
    \\Committed output remains after exit; only the live input/status area is redrawn.
    \\Context percentage shows the latest provider-reported request total, not cumulative use.
    \\A fresh session starts at 0.0%; unreported usage shows ?. Safety budgets still use estimates.
    \\Startup shows three lines: Thin version, directory, local time with UTC offset.
    \\Enter sends; Ctrl+J adds newline; Esc or Ctrl+C cancels the current task; Ctrl+D exits.
    \\Up/Down browse this session's submitted inputs only from an empty composer.
    \\Manual edits stop browsing; navigation never submits. Keyboard recall is session-local.
    \\Session diagnostics are separate and still follow the recording settings below.
    \\After normal exit and a successful save, only thin --resume <ID> is printed.
    \\Empty chats print no session information or resume command.
    \\Run the resume command from the same project with the current Thin version on PATH.
    \\PgUp/PgDn scroll; Ctrl+R toggles visible reasoning; Shift+Tab cycles supported effort.
    \\/ opens /model and /login choices; Up/Down wraps, Enter confirms (no Tab shortcut).
    \\Pickers: Up/Down selects, Enter confirms, Left returns, Esc cancels; at most 10 rows.
    \\Tab and PgUp/PgDn are not picker shortcuts. Esc also clears secret-paste quarantine.
    \\/model directly lists models for locally logged-in aliases; /model exact-id selects while idle.
    \\/model --refresh refreshes official model availability and context metadata.
    \\First eligible interactive startup tries each configured provider once; failures do not auto-retry.
    \\--no-model-auto-refresh disables startup/login refresh (manual refresh remains available).
    \\Cache: ~/.thin/model-metadata.json. Refresh combines official /models and public models.dev data.
    \\Missing capacities may use exact presets; unknown capacities remain unavailable.
    \\Explicit local profiles take precedence.
    \\Successful listing refresh hides absent catalog entries; failed refresh keeps the last list.
    \\K/M are decimal token units; official/default is the capacity source, not actual usage.
    \\Green checks mean current model or credentials saved locally, not a verified online login.
    \\Refresh does not change the active budget; cached capacities apply on model selection.
    \\Model changes in an empty chat save defaults to ~/.thin/config.json.
    \\With conversation history, model changes stay in that session only.
    \\Empty-chat effort changes also save llm.reasoning_effort globally.
    \\With conversation history, effort changes stay in that session only.
    \\Per-provider models:{raw_id:{context_tokens,protocol,reasoning_effort,reasoning}}
    \\declares local profiles (maximum 64 total); custom IDs need explicit compatible profiles.
    \\Logical levels: off/minimal/low/medium/high/xhigh/max; only supported levels cycle.
    \\Legacy none means off. Global logical defaults wait for known capabilities.
    \\Without a global override, unknown capabilities retain fixed model options.
    \\Custom/proxy models can declare reasoning:{format:"standard",map:{off:"none",high:"high"}}.
    \\A null/missing mapping is unsupported; DeepSeek format uses thinking.type (Chat only).
    \\Only explicitly mapped model protocols are offered; unknown API IDs are not guessed.
    \\No trial inference requests or automatic changes to global defaults.
    \\Ordinary tool calls run without approval prompts.
    \\Commands run with your account permissions; bash is NOT a sandbox.
    \\High-risk bash is classified before it runs and requires explicit approval each time.
    \\Patterns: recursive rm, find -delete, git clean -f, mkfs and dd onto devices,
    \\writes or chmod/chown of /etc, /usr, /bin, /root or ~/.ssh, curl|bash and wget|sh, and fork bombs.
    \\The confirmation popup uses arrows, Enter and Esc; the next dangerous command asks again.
    \\On denial the model gets an error and nothing runs.
    \\--print cannot approve dangerous bash, so those calls are denied.
    \\--print returns the final committed visible answer with the same tool policy.
    \\
    \\Model and logical thinking defaults share ~/.thin/config.json (0600).
    \\Legacy project settings.json is ignored, never created or rewritten.
    \\Restoring history/selection alone does not rewrite global defaults.
    \\An unsupported saved level is adjusted effectively without rewriting the preference.
    \\Project Memory: <startup directory>/.thin/memory/*.md, changed through memory tools.
    \\Session records: <startup directory>/.thin/sessions/*.jsonl (local plaintext, 0600).
    \\Recording starts automatically on the first submitted message.
    \\Records include messages, tools, stages, usage and errors, not /login input,
    \\hidden reasoning or native replay. The configured key is redacted; other sensitive
    \\content may remain. Records are not restored or automatically sent to the provider.
    \\Large fields are explicitly truncated/omitted; files rotate without deleting old records.
    \\View locally with ls -lt .thin/sessions and tail -f <chosen.jsonl>.
    \\<session-id>.session is the saved conversation for that id. It stores the
    \\full context and the committed provider/model/protocol/effort selection.
    \\It is rewritten after each completed model turn, tool result, compaction,
    \\cancellation, and again on normal exit. Each publish is an atomic rename plus fsync.
    \\Loading checks bounded file structure, not API credentials or frozen request budgets.
    \\Available saved history can be opened even after an interrupted run.
    \\--restore-selection reads that selection into a NEW EMPTY CHAT.
    \\It does NOT restore conversation history, tools, native replay or the old session ID.
    \\Missing providers, keys or usable model settings are shown in the dialogue interface.
    \\Use /login or /model before sending. --print cannot restore a selection.
    \\--resume continues that SAME ID and model context, including native provider state.
    \\Loading never sends a request or reruns tools; only new input starts work.
    \\The exit command is printed only after a successful full save. Empty chats create none.
    \\Checkpoints are private PLAINTEXT (0600), not redacted or encrypted; they can contain
    \\prompts, tool output and opaque reasoning. API credentials are resolved locally.
    \\Changing an API key does not prevent loading. There is no key-bound authentication.
    \\Compacted context stays lossy; discarded pre-compaction history cannot be recovered.
    \\Loading never replays an interrupted tool or grants historical approvals.
    \\Resume uses the startup project's saved conversation, not current global selection defaults.
    \\No model probing or cache warming. Usage is reported when available;
    \\monetary cost is unknown without provider pricing.
    \\
;

test "CLI help describes global defaults and actual metadata sources" {
    try std.testing.expect(std.mem.indexOf(u8, help, "llm.reasoning_effort globally") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "official /models and public models.dev") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Legacy project settings.json is ignored") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Global logical defaults wait for known capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "saved project selection preferences") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "no third-party data") == null);
}

// 交互与 --print 不审批普通工具；危险 bash 逐次明确批准。
test "CLI selection restore is explicit bounded and interactive only" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqualStrings(id, &options.restore_selection.?);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "../history" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "0123456789abcdef0123456789abcdeF" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "-p", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--restore-selection", id }));
}

test "CLI resume is distinct same-session interactive selection and rejects conflicts" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--resume", id });
    try std.testing.expectEqualStrings(id, &options.resume_session.?);
    try std.testing.expect(options.restore_selection == null);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--resume", "../invalid" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--print", "go" }));
}

test "CLI ordinary tools run directly and print requires a prompt" {
    const options = try parse(&.{ "thin", "--print", "hello" });
    try std.testing.expectEqualStrings("hello", options.prompt.?);
    try std.testing.expect(std.mem.indexOf(u8, help, "run without approval prompts") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "No automatic command-risk classifier") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "High-risk bash is classified") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "requires explicit approval each time") != null);
    try std.testing.expect((try parse(&.{"thin"})).auto_refresh_models);
    try std.testing.expect(!(try parse(&.{ "thin", "--no-model-auto-refresh" })).auto_refresh_models);
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--no-log" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--print", "hello", "--no-log" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--config", "other.json" }));
}

// 默认必须是普通前台：不因为没有模式参数、不因为历史恢复而进入守护模式。
test "CLI defaults to foreground and resume stays foreground" {
    const plain = try parse(&.{"thin"});
    try std.testing.expectEqual(Mode.foreground, plain.mode);
    try std.testing.expect(plain.attach_session == null and !plain.takeover);
    try std.testing.expect(plain.worker_endpoint == null and plain.worker_session == null);
    try std.testing.expectEqual(WorkerOwner.daemon, plain.worker_owner);
    try std.testing.expect(!plain.worker_resume);

    const id = "0123456789abcdef0123456789abcdef";
    const resumed = try parse(&.{ "thin", "--resume", id });
    try std.testing.expectEqual(Mode.foreground, resumed.mode);
    try std.testing.expectEqualStrings(id, &resumed.resume_session.?);
    const restored = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqual(Mode.foreground, restored.mode);
    try std.testing.expectEqualStrings(id, &restored.restore_selection.?);
    const printed = try parse(&.{ "thin", "--print", "hello" });
    try std.testing.expectEqual(Mode.foreground, printed.mode);

    // 仅前台/connect/attach 需要终端；daemon 与内部 worker 必须能在无 TTY 下进入。
    try std.testing.expect(Mode.foreground.requiresTty());
    try std.testing.expect(Mode.connect.requiresTty());
    try std.testing.expect(Mode.attach.requiresTty());
    try std.testing.expect(!Mode.daemon.requiresTty());
    try std.testing.expect(!Mode.worker.requiresTty());
}

test "CLI daemon connect attach are exclusive with each other and other run modes" {
    const id = "0123456789abcdef0123456789abcdef";
    const other = "fedcba9876543210fedcba9876543210";

    try std.testing.expectEqual(Mode.daemon, (try parse(&.{ "thin", "--daemon" })).mode);
    try std.testing.expectEqual(Mode.connect, (try parse(&.{ "thin", "--connect" })).mode);
    const attached = try parse(&.{ "thin", "--attach", id });
    try std.testing.expectEqual(Mode.attach, attached.mode);
    try std.testing.expectEqualStrings(id, &attached.attach_session.?);
    try std.testing.expect(!attached.takeover);

    // 重复与互相冲突。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--attach", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--attach", other }));

    // 与 --print/--resume/--restore-selection 冲突，包括反向顺序。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--print", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print", "go", "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--print", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--connect" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--attach", id }));

    // 缺少或无效的会话 ID。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--attach", "../session" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--attach", "0123456789abcdef0123456789abcdeF" }));
}

test "CLI takeover belongs to attach only" {
    const id = "0123456789abcdef0123456789abcdef";
    const attached = try parse(&.{ "thin", "--attach", id, "--takeover" });
    try std.testing.expectEqual(Mode.attach, attached.mode);
    try std.testing.expect(attached.takeover);

    // 不带 --attach，或在其它模式下使用，一律拒绝；重复也一样。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--connect", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print", "go", "--takeover" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--attach", id, "--takeover", "--takeover" }));
}

// 内部 worker 入口：不在 help 推广，但必须能在无 TTY 环境中完整表达 owner 与 endpoint。
test "CLI internal worker carries endpoint session and owner" {
    const id = "0123456789abcdef0123456789abcdef";
    const socket = "/run/user/1000/thin/workers/session.sock";

    const daemon_side = try parse(&.{ "thin", "--internal-worker", socket, id, "daemon" });
    try std.testing.expectEqual(Mode.worker, daemon_side.mode);
    try std.testing.expect(!Mode.worker.requiresTty());
    try std.testing.expectEqualStrings(socket, daemon_side.worker_endpoint.?);
    try std.testing.expectEqualStrings(id, &daemon_side.worker_session.?);
    try std.testing.expectEqual(WorkerOwner.daemon, daemon_side.worker_owner);
    try std.testing.expect(!daemon_side.worker_resume);

    const foreground_side = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground" });
    try std.testing.expectEqual(WorkerOwner.foreground, foreground_side.worker_owner);
    try std.testing.expectEqual(Mode.worker, foreground_side.mode);

    const resumed_worker = try parse(&.{ "thin", "--worker-resume", "--internal-worker", socket, id, "foreground" });
    try std.testing.expectEqual(Mode.worker, resumed_worker.mode);
    try std.testing.expect(resumed_worker.worker_resume);

    // 缺参、空 endpoint、未知 owner、无效 ID。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", "", id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "system" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, "not-a-session", "daemon" }));

    // 重复 worker 入口或与公开模式混用都是冲突。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--daemon", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--print", "go" }));

    // --worker-resume 是内部标记：不能与公开 --resume/--restore-selection 混用，也不能单独使用。
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--worker-resume" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--worker-resume", "--worker-resume", "--internal-worker", socket, id, "daemon" }));
    try std.testing.expect(std.mem.indexOf(u8, help, "--worker-restore-selection") == null);
}

// 老 --restore-selection 迁入 foreground worker 的内部选项：仍保持公开参数为普通前台。
test "CLI worker restore-selection is worker-only and exclusive" {
    const id = "0123456789abcdef0123456789abcdef";
    const prior = "fedcba9876543210fedcba9876543210";
    const socket = "/run/user/1000/thin/workers/session.sock";

    // 合法：两个 worker 模式都可带，且不写公开字段。
    const migrated = try parse(&.{ "thin", "--internal-worker", socket, id, "foreground", "--worker-restore-selection", prior });
    try std.testing.expectEqual(Mode.worker, migrated.mode);
    try std.testing.expectEqualStrings(prior, &migrated.worker_restore_selection.?);
    try std.testing.expect(migrated.restore_selection == null and !migrated.worker_resume);
    try std.testing.expectEqualStrings(id, &migrated.worker_session.?);

    // 参数顺序无关。
    const reordered = try parse(&.{ "thin", "--worker-restore-selection", prior, "--internal-worker", socket, id, "daemon" });
    try std.testing.expectEqualStrings(prior, &reordered.worker_restore_selection.?);
    try std.testing.expectEqual(WorkerOwner.daemon, reordered.worker_owner);

    // 公开 --restore-selection 仍是普通前台，不设置内部字段。
    const public = try parse(&.{ "thin", "--restore-selection", id });
    try std.testing.expectEqual(Mode.foreground, public.mode);
    try std.testing.expect(public.worker_restore_selection == null);

    // 无参数仍是普通前台：它不是 worker 负例。
    const plain = try parse(&.{"thin"});
    try std.testing.expectEqual(Mode.foreground, plain.mode);
    try std.testing.expect(plain.worker_restore_selection == null and plain.worker_session == null);

    // 表格：全部拒绝的组合。
    const rejected = [_][]const [:0]const u8{
        &.{ "thin", "--worker-restore-selection", prior }, // 缺内部入口
        &.{ "thin", "--worker-restore-selection" }, // 缺参数
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection" }, // 缺参数
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--worker-restore-selection", prior }, // 重复
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-resume", "--worker-restore-selection", prior }, // 与 worker-resume 混用
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--worker-resume" },
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--resume", id }, // 公开 resume
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--restore-selection", id }, // 公开 restore
        &.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", prior, "--print", "go" }, // 公开 print
    };
    for (rejected) |args| try std.testing.expectError(error.InvalidArguments, parse(args));

    // 非法 ID 保持 InvalidSessionID。
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", "../session" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--internal-worker", socket, id, "daemon", "--worker-restore-selection", "0123456789ABCDEF0123456789ABCDEF" }));
}

test "CLI help documents explicit modes without advertising internal entry" {
    try std.testing.expect(std.mem.indexOf(u8, help, "ordinary local foreground by default") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Only --daemon explicitly runs the per-user service") != null);
    // 只有 --connect 依赖 daemon；--attach 可连普通前台公布的 worker，两者都不自启服务。
    try std.testing.expect(std.mem.indexOf(u8, help, "--connect joins the already running daemon service") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "or the daemon may publish, so it does not require a running daemon") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "Neither --connect nor --attach starts a service") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "requires an already running service") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "are mutually exclusive") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--takeover is valid only with --attach") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "need a terminal; the daemon does not") != null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--internal-worker") == null);
    try std.testing.expect(std.mem.indexOf(u8, help, "--worker-resume") == null);
}
