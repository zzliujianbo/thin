//! 命令行参数解析与帮助文本。只做语法层面的解析，不读取配置或环境。

const std = @import("std");
const ids = @import("session_id.zig");

/// 解析后的选项。prompt 为 null 表示交互模式；非 null 表示 --print 一次性模式。
/// 当前 CLI 默认信任本进程的工具调用，不逐次审批；--trust 仅保留兼容。
/// 这不是命令风险分类或沙箱，Runtime 的授权接口仍保留给嵌入调用方。
pub const Options = struct { prompt: ?[]const u8 = null, restore_selection: ?ids.Id = null, resume_session: ?ids.Id = null, trusted: bool = true, logging: bool = true, help: bool = false, version: bool = false };

/// 解析 argv。args[0] 是程序名，因此从 1 开始遍历。
/// 无效参数返回错误（InvalidArguments、UnknownOption），由调用方决定如何提示。
pub fn parse(args: []const [:0]const u8) !Options {
    var result: Options = .{};

    // 使用显式索引循环，以便 --print 能在处理时跳过下一个参数（即 prompt）。
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        // --print 要求后面紧跟一个 prompt，且不允许重复指定，避免静默覆盖。
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) result.help = true else if (std.mem.eql(u8, arg, "--version")) result.version = true else if (std.mem.eql(u8, arg, "--trust")) result.trusted = true else if (std.mem.eql(u8, arg, "--no-log")) result.logging = false else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            if (result.prompt != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            result.prompt = args[i];
        } else if (std.mem.eql(u8, arg, "--restore-selection") or std.mem.eql(u8, arg, "--resume")) {
            if (result.restore_selection != null or result.resume_session != null or i + 1 >= args.len) return error.InvalidArguments;
            i += 1;
            if (args[i].len != 32) return error.InvalidSessionID;
            const id: ids.Id = args[i][0..32].*;
            if (!ids.valid(id)) return error.InvalidSessionID;
            if (std.mem.eql(u8, arg, "--resume")) result.resume_session = id else result.restore_selection = id;
        } else return error.UnknownOption;
    }

    if ((result.restore_selection != null or result.resume_session != null) and result.prompt != null) return error.InvalidArguments;
    return result;
}

/// 帮助文本，由 --help 输出。字符串内容即为用户可见的文档。
pub const help =
    \\thin - minimal local agent (Linux x86_64, Zig 0.17.0)
    \\
    \\Usage: thin [--trust] [--no-log]
    \\       thin --print "prompt" [--trust] [--no-log]
    \\       thin --restore-selection <32-lowerhex-session-id> [--no-log]
    \\       thin --resume <32-lowerhex-session-id> [--no-log]
    \\       thin --help | --version
    \\
    \\Configuration: ~/.thin/config.json
    \\Interactive startup initializes a missing/empty file for DeepSeek (deepseek-flash).
    \\Use /auth in the TUI for hidden key entry; the key is saved locally with mode 0600.
    \\Never put a key in chat or command arguments. Saving does not send an API request.
    \\Existing nonempty configurations are preserved. Advanced configuration example:
    \\  {"provider":{"base_url":"https://your-provider.example/v1",
    \\    "api_key_env":"THIN_API_KEY"},
    \\   "model":{"name":"your-model","context_tokens":128000,"protocol":"auto"}}
    \\Use either provider.api_key_env (environment variable) or provider.api_key, not both.
    \\--print requires an already configured file; it does not open the setup UI.
    \\Protocols: auto (Responses then one explicitly supported fallback), responses, chat.
    \\Known DeepSeek thinking format selects Chat locally; it never probes Responses.
    \\
    \\Interactive uses regular terminal scrollback, not an alternate full-screen buffer.
    \\Committed output remains after exit; only the live input/status area is redrawn.
    \\Context percentage shows the latest provider-reported request total, not cumulative use.
    \\A fresh session starts at 0.0%; unreported usage shows ?. Safety budgets still use estimates.
    \\Startup shows the current directory, Thin version and local time with UTC offset.
    \\Enter sends; Ctrl+J adds newline; Esc or Ctrl+C cancels the current task; Ctrl+D exits.
    \\Up/Down browse this session's submitted inputs only from an empty composer.
    \\Manual edits stop browsing; navigation never submits. Keyboard recall is session-local.
    \\Session diagnostics are separate and still follow the recording settings below.
    \\After normal exit and a successful save, only thin --resume <ID> is printed.
    \\Empty chats and --no-log exits print no session information or resume command.
    \\Run the resume command from the same project with the current Thin version on PATH.
    \\PgUp/PgDn scroll; Ctrl+R toggles visible reasoning; Shift+Tab cycles supported effort.
    \\/model opens a searchable picker; /model exact-id selects directly while idle.
    \\Model selection is session-only. Effort is saved per startup project, not globally.
    \\Optional models:[{name,context_tokens,protocol,reasoning_effort,reasoning}] profiles
    \\share the endpoint (maximum 64); a custom ID inherits current context/options.
    \\Logical levels: off/minimal/low/medium/high/xhigh/max; only supported levels cycle.
    \\Legacy none means off. Unknown model capabilities keep fixed configured options.
    \\Custom/proxy models can declare reasoning:{format:"standard",map:{off:"none",high:"high"}}.
    \\A null/missing mapping is unsupported; DeepSeek format uses thinking.type (Chat only).
    \\No model discovery, trial requests or automatic changes to global defaults.
    \\Tool calls are trusted for THIS PROCESS and run without approval prompts.
    \\Commands run with your account permissions; bash is NOT a sandbox.
    \\No automatic command-risk classifier is enabled. --trust is a compatibility flag.
    \\--print returns the final committed visible answer with the same tool policy.
    \\
    \\Project settings: <startup directory>/.thin/settings.json (last logical effort, 0600).
    \\Normal startup initializes missing settings; explicit effort saves even with --no-log.
    \\Restoring a selection never initializes or rewrites project settings.
    \\An unsupported saved level is adjusted effectively without rewriting the preference.
    \\Project Memory: <startup directory>/.thin/mem/*.md, changed through memory tools.
    \\Session records: <startup directory>/.thin/sessions/*.jsonl (local plaintext, 0600).
    \\Recording starts on the first submitted message; --no-log disables it for this run.
    \\Records include messages, tools, stages, usage and errors, not /auth input,
    \\hidden reasoning or native replay. The configured key is redacted; other sensitive
    \\content may remain. Records are not restored or automatically sent to the provider.
    \\Large fields are explicitly truncated/omitted; files rotate without deleting old records.
    \\View locally with ls -lt .thin/sessions and tail -f <chosen.jsonl>.
    \\Separate <session-id>.selection.json snapshots retain the latest committed selection.
    \\They start on first submission and update on successful model/effort changes.
    \\--restore-selection restores provider/model/protocol/effort into a NEW EMPTY CHAT.
    \\It does NOT restore conversation history, tools, native replay or the old session ID.
    \\Credentials are resolved locally; missing endpoints, keys or custom profiles are refused.
    \\Old IDs without snapshots are not guessed. --print cannot restore a selection.
    \\--no-log disables snapshot writes too, but permits explicit reading of an old snapshot.
    \\Normal interactive exit saves a separate <session-id>.session full-context checkpoint.
    \\--resume continues that SAME ID and model context, including native provider state.
    \\Loading never sends a request or reruns tools; only new input starts work.
    \\The exit command is printed only after a successful full save. Empty chats create none.
    \\Checkpoints are private PLAINTEXT (0600), not redacted or encrypted; they can contain
    \\prompts, tool output and opaque reasoning. API credentials are resolved locally.
    \\Authentication is bound to the current key: key rotation or tampering refuses resume.
    \\Compacted context stays lossy; discarded pre-compaction history cannot be recovered.
    \\No automatic crash recovery: interrupted/poisoned resumed sessions are refused.
    \\--no-log writes no checkpoint and prints no command for unsaved changes.
    \\Resume uses the startup project and bypasses saved project selection preferences.
    \\No model probing or cache warming. Usage is reported when available;
    \\monetary cost is unknown without provider pricing.
    \\
;

// 交互与 --print 默认均不审批，--trust 保持兼容；错误参数仍拒绝。
test "CLI selection restore is explicit bounded and interactive only" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--restore-selection", id, "--no-log" });
    try std.testing.expectEqualStrings(id, &options.restore_selection.?);
    try std.testing.expect(!options.logging);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "../history" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--restore-selection", "0123456789abcdef0123456789abcdeF" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "-p", "go" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--restore-selection", id }));
}

test "CLI resume is distinct same-session interactive selection and rejects conflicts" {
    const id = "0123456789abcdef0123456789abcdef";
    const options = try parse(&.{ "thin", "--resume", id, "--no-log" });
    try std.testing.expectEqualStrings(id, &options.resume_session.?);
    try std.testing.expect(options.restore_selection == null and !options.logging);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume" }));
    try std.testing.expectError(error.InvalidSessionID, parse(&.{ "thin", "--resume", "../invalid" }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--restore-selection", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--restore-selection", id, "--resume", id }));
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--resume", id, "--print", "go" }));
}

test "CLI tools are trusted by default and print requires a prompt" {
    const options = try parse(&.{ "thin", "--print", "hello", "--trust" });
    try std.testing.expect(options.trusted);
    try std.testing.expectEqualStrings("hello", options.prompt.?);
    try std.testing.expect((try parse(&.{"thin"})).trusted);
    try std.testing.expect((try parse(&.{ "thin", "--print", "hello" })).trusted);
    try std.testing.expect((try parse(&.{ "thin", "--no-log" })).trusted);
    try std.testing.expect(std.mem.indexOf(u8, help, "run without approval prompts") != null);
    try std.testing.expect((try parse(&.{"thin"})).logging);
    try std.testing.expect(!(try parse(&.{ "thin", "--no-log" })).logging);
    try std.testing.expect(!(try parse(&.{ "thin", "--print", "hello", "--no-log" })).logging);
    try std.testing.expectError(error.InvalidArguments, parse(&.{ "thin", "--print" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "thin", "--config", "other.json" }));
}
